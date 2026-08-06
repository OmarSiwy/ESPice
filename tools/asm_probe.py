#!/usr/bin/env python3
"""Codegen probe: does an abstraction leave runtime residue next to the hand-written version?

Usage:
    asm_probe.py <file.s> gen=hand [gen=hand ...] [--report]
    asm_probe.py --self-test

<file.s> is x86-64 Intel-syntax assembly (zig build-obj -femit-asm, or rustc --emit asm
with -C llvm-args=-x86-asm-syntax=intel). Each gen=hand pair names two exported functions:
the abstraction and the loop it claims to equal. Verdicts, best first:

    FOLDED      LLVM merged both bodies into one symbol
    IDENTICAL   same instruction stream after label and constant normalization
    EQUIVALENT  same mnemonic sequence, different register allocation
    NEGATIVE    gen does strictly less static work, or is vectorized where hand is not
    RESIDUE     gen leaves extra work behind

Exit status is 1 when any pair is RESIDUE or a symbol is missing, so a build step that runs
this fails on a regression. --report prints the same table and always exits 0 (lab use).

Counts are static (instructions in the listing, not instructions executed). A NEGATIVE or
IDENTICAL verdict says the code has no residue; it does not say the code is fast. Benchmark
before claiming a speedup.
"""

import re
import sys

# Rust's legacy mangling appends a hash; strip it so `..._len_fail17h0123456789abcdefE`
# still reads as ending in `_fail`.
RUST_HASH = re.compile(r"17h[0-9a-f]{16}E$")
RELOC = re.compile(r"@(PLT|GOTPCREL|GOT)$")
# Packed SIMD mnemonics. `p[a-z]+` alone would count push/pop/pause/prefetch and the BMI2
# scalar ops pdep/pext as vector instructions, so those prefixes are excluded explicitly.
VECTOR_MNEMONIC = re.compile(
    r"^v?(p(?!ush|op|ause|refetch|dep|ext)[a-z]+"
    r"|[a-z]+p[sd]"
    r"|movdq[au]|broadcast[a-z0-9]*|perm[a-z0-9]*|insert[a-z0-9]+|extract[a-z0-9]+"
    r"|shuf[a-z]+|unpck[a-z]+|blend[a-z]*)$"
)
# Bitwise ops on xmm alone are how scalar code zeroes a register (`vxorps xmm0, xmm0, xmm0`)
# and takes @abs / negation (`vandpd xmm0, xmm0, [mask]`), so on xmm they are not vector work.
# On ymm/zmm they still count.
SCALAR_BITWISE = re.compile(r"^v?(andn?p[sd]|orp[sd]|xorp[sd]|pandn?|por|pxor[dq]?)$")
WIDE_REGISTER = re.compile(r"\b[yz]mm\d+\b")
CONST_POOL = re.compile(r"\.LCPI\d+_\d+")
LOCAL_LABEL = re.compile(r"\.L[A-Za-z_]*\d+(?:_\d+)?")


def is_symbol_char(c):
    return c.isalnum() or c == "_"


def ends_with_symbol(name, symbol):
    """`name` is `symbol`, optionally behind a `module.` qualifier (Zig emits `probe.foo`)."""
    if name == symbol:
        return True
    return name.endswith(symbol) and not is_symbol_char(name[-len(symbol) - 1])


def parse_aliases(text):
    """Assembler equates: `a = b` and `.set a, b`. LLVM writes a folded body as one of these."""
    aliases = {}
    for raw in text.splitlines():
        line = raw.strip()
        m = re.match(r"^\.set\s+([^,\s]+)\s*,\s*([^\s]+)$", line) or re.match(
            r"^([^\s=]+)\s*=\s*([^\s+\-]+)$", line
        )
        if m:
            aliases[m.group(1).strip('"')] = m.group(2).strip('"')
    return aliases


def lookup(table, symbol):
    for key in table:
        if ends_with_symbol(key, symbol):
            return table[key]
    return None


def resolve(aliases, symbol):
    current = symbol
    # ponytail: alias chains are one or two hops; the bound stops a malformed file looping.
    for _ in range(8):
        nxt = lookup(aliases, current)
        if nxt is None or nxt == current:
            return current
        current = nxt
    return current


def same_symbol(a, b):
    return a == b or ends_with_symbol(a, b) or ends_with_symbol(b, a)


def parse_constants(text):
    """Constant-pool label -> its data directives, so `.LCPI3_0` and `.LCPI7_0` compare by value."""
    pools, current = {}, None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.endswith(":"):
            label = line[:-1]
            current = label if CONST_POOL.fullmatch(label) else None
            if current:
                pools[current] = []
        elif current and line.startswith("."):
            if line.startswith((".section", ".text", ".p2align", ".globl", ".type")):
                current = None
            else:
                pools[current].append(" ".join(line.split()))
        else:
            current = None
    return {k: "|".join(v) for k, v in pools.items()}


def body(text, symbol):
    """Instruction lines of `symbol`, with jump targets rewritten to instruction indices.

    Labels (`.LBB0_3:`, Zig's `.Ltmp12:` debug labels) are dropped. A branch to a label
    becomes `@<index of the instruction the label points at>`, so two bodies that differ
    only in label numbering compare equal.
    """
    lines, labels, inside = [], {}, False
    for raw in text.splitlines():
        line = raw.strip()
        if not inside:
            if line.endswith(":") and ends_with_symbol(line[:-1].strip('"'), symbol):
                inside = True
            continue
        if line.startswith(".size") or line.startswith(".cfi_endproc"):
            break
        code = line.split("#", 1)[0].strip()
        if not code:
            continue
        if code.endswith(":"):
            labels[code[:-1]] = len(lines)
            continue
        if code.startswith("."):
            continue  # directive
        lines.append(code)
    if not inside:
        return None
    out = []
    for code in lines:
        out.append(LOCAL_LABEL.sub(lambda m: f"@{labels[m.group(0)]}" if m.group(0) in labels else m.group(0), code))
    return out


def normalize(lines, constants):
    return [CONST_POOL.sub(lambda m: f"const[{constants.get(m.group(0), m.group(0))}]", c) for c in lines]


def split(code):
    parts = code.split(None, 1)
    return parts[0].lower(), (parts[1] if len(parts) > 1 else "")


def call_target(operand):
    """Symbol a call/jump goes to, or None when the target is only known at run time."""
    op = operand.strip()
    m = re.fullmatch(r"(?:qword ptr )?\[rip\s*\+\s*([^\]\s]+)@GOTPCREL\]", op)
    if m:
        return m.group(1)  # through the GOT, but the callee is a fixed symbol: a direct call
    if "[" in op or is_register(op):
        return None
    return RELOC.sub("", op)


REGISTERS = re.compile(r"^(r[a-z]{1,2}|e[a-z]{2}|r\d{1,2}[dwb]?|[abcd][xlh]|[sd]il?|[bs]pl?)$")


def is_register(op):
    return bool(REGISTERS.match(op))


def is_panic(symbol):
    s = RUST_HASH.sub("", RELOC.sub("", symbol))
    return "panic" in s.lower() or s.endswith("_fail") or "outOfBounds" in s


def stats(lines):
    s = dict(instructions=len(lines), vector=0, calls=0, indirect_calls=0, panics=0, branches=0)
    for code in lines:
        mnemonic, operand = split(code)
        wide = WIDE_REGISTER.search(operand)
        if wide or (VECTOR_MNEMONIC.match(mnemonic) and not SCALAR_BITWISE.match(mnemonic)):
            s["vector"] += 1
        if mnemonic == "ud2":
            s["panics"] += 1
        if mnemonic.startswith("j") and mnemonic != "jmp":
            s["branches"] += 1
        tail = mnemonic == "jmp" and not operand.startswith("@")
        if mnemonic == "call" or tail:
            target = call_target(operand)
            if target is None:
                if mnemonic == "call":
                    s["indirect_calls"] += 1
            else:
                s["calls"] += 1
                if is_panic(target):
                    s["panics"] += 1
    return s


WORK = ("instructions", "calls", "indirect_calls", "panics", "branches")


def verdict(gen, hand, gs, hs):
    if gen == hand:
        return "IDENTICAL"
    if [split(c)[0] for c in gen] == [split(c)[0] for c in hand]:
        return "EQUIVALENT"
    no_extra = all(gs[k] <= hs[k] for k in ("calls", "indirect_calls", "panics"))
    if gs["vector"] > 0 and hs["vector"] == 0 and no_extra:
        return "NEGATIVE"
    if all(gs[k] <= hs[k] for k in WORK) and any(gs[k] < hs[k] for k in WORK):
        return "NEGATIVE"
    return "RESIDUE"


def probe(text, gen_name, hand_name):
    """Returns (verdict, gen stats, hand stats, gen body, hand body)."""
    aliases = parse_aliases(text)
    gen_sym, hand_sym = resolve(aliases, gen_name), resolve(aliases, hand_name)
    constants = parse_constants(text)
    gen, hand = body(text, gen_sym), body(text, hand_sym)
    if gen is None or hand is None:
        missing = gen_name if gen is None else hand_name
        raise LookupError(f"symbol '{missing}' not found (exported? spelled as in the source?)")
    gen, hand = normalize(gen, constants), normalize(hand, constants)
    gs, hs = stats(gen), stats(hand)
    if same_symbol(gen_sym, hand_sym):
        return "FOLDED", gs, hs, gen, hand
    return verdict(gen, hand, gs, hs), gs, hs, gen, hand


COLUMNS = ("instructions", "vector", "calls", "indirect_calls", "panics", "branches")


def main(argv):
    if argv[1:] == ["--self-test"]:
        self_test()
        print("asm_probe: self-test passed")
        return 0
    report = "--report" in argv
    args = [a for a in argv[1:] if a != "--report"]
    if len(args) < 2 or not all("=" in a for a in args[1:]):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    with open(args[0]) as f:
        text = f.read()
    failed = False
    header = f"{'function':<32} " + " ".join(f"{c[:8]:>8}" for c in COLUMNS)
    for pair in args[1:]:
        gen_name, hand_name = pair.split("=", 1)
        try:
            v, gs, hs, gen, hand = probe(text, gen_name, hand_name)
        except LookupError as e:
            print(f"MISSING     {pair}: {e}")
            failed = True
            continue
        print(f"{v:<11} {gen_name} vs {hand_name}")
        print("  " + header)
        for name, s in ((gen_name, gs), (hand_name, hs)):
            print(f"  {name:<32} " + " ".join(f"{s[c]:>8}" for c in COLUMNS))
        if v == "RESIDUE":
            failed = True
            for i in range(max(len(gen), len(hand))):
                a = gen[i] if i < len(gen) else "<end>"
                b = hand[i] if i < len(hand) else "<end>"
                print(f"  {' ' if a == b else '>'} {a:<44} {b}")
        print()
    return 0 if report or not failed else 1


def self_test():
    # Folded: both names equated to a third symbol.
    t = "gen = probe.other\nhand = probe.other\nprobe.other:\n\tret\n\t.size probe.other, 1\n"
    assert probe(t, "gen", "hand")[0] == "FOLDED"
    # A name that merely ends with the symbol is a different symbol.
    assert not ends_with_symbol("x_foo", "foo") and ends_with_symbol("probe.foo", "foo")

    # Identical apart from label numbering (Zig .Ltmp and LLVM .LBB numbering differ).
    a = "gen:\n.Ltmp0:\n\ttest rsi, rsi\n\tje .LBB0_2\n.LBB0_1:\n\tdec rsi\n\tjne .LBB0_1\n.LBB0_2:\n\tret\n\t.size gen, 9\n"
    b = a.replace("gen", "hand").replace("LBB0", "LBB1").replace(".Ltmp0:\n", "")
    assert probe(a + b, "gen", "hand")[0] == "IDENTICAL"

    # Constant pools compare by value, not by label number.
    pool = ".LCPI0_0:\n\t.long 0x3f800000\n.LCPI1_0:\n\t.long 0x3f800000\n.LCPI2_0:\n\t.long 0x40000000\n"
    g = "gen:\n\tvmulss xmm0, xmm0, dword ptr [rip + .LCPI0_0]\n\tret\n\t.size gen, 1\n"
    h = "hand:\n\tvmulss xmm0, xmm0, dword ptr [rip + .LCPI1_0]\n\tret\n\t.size hand, 1\n"
    o = "other:\n\tvmulss xmm0, xmm0, dword ptr [rip + .LCPI2_0]\n\tret\n\t.size other, 1\n"
    assert probe(pool + g + h + o, "gen", "hand")[0] == "IDENTICAL"
    assert probe(pool + g + h + o, "gen", "other")[0] == "EQUIVALENT"

    # Register allocation differs only.
    g = "gen:\n\tmov rax, rdi\n\tret\n\t.size gen, 1\n"
    h = "hand:\n\tmov rcx, rdi\n\tret\n\t.size hand, 1\n"
    assert probe(g + h, "gen", "hand")[0] == "EQUIVALENT"

    # push/pop/pdep are not vector instructions; vpaddd and ymm operands are.
    s = stats(["push rbx", "pop rbx", "pdep rax, rbx, rcx", "popcnt rax, rbx", "vpaddd ymm0, ymm0, ymm1",
               "vaddps xmm0, xmm0, xmm1", "vaddss xmm0, xmm0, xmm1", "vmovups ymmword ptr [rdi], ymm0",
               "vxorps xmm0, xmm0, xmm0", "vandpd xmm0, xmm0, xmmword ptr [rip + .LCPI0_0]",
               "vandpd ymm0, ymm0, ymm1"])
    assert s["vector"] == 4, s

    # Zig quotes symbols that contain spaces or parentheses.
    q = '"Map(f32,dbl).run":\n\tret\n\t.size "Map(f32,dbl).run", 1\nalias = "Map(f32,dbl).run"\n'
    assert body(q, "Map(f32,dbl).run") == ["ret"] and parse_aliases(q)["alias"] == "Map(f32,dbl).run"

    # A GOT call is direct; a register or memory call is indirect.
    s = stats(["call qword ptr [rip + memcpy@GOTPCREL]", "call r15", "call qword ptr [rax + 24]", "call foo@PLT"])
    assert (s["calls"], s["indirect_calls"]) == (2, 2), s

    # Rust panics end in _fail (after the hash) or mention panic; ud2 is a trap.
    s = stats(["call _ZN4core5slice5index24slice_end_index_len_fail17h0123456789abcdefE",
               "call _ZN4core9panicking18panic_bounds_check17h0123456789abcdefE", "ud2", "call helper"])
    assert s["panics"] == 3 and s["calls"] == 3, s

    # Vectorized where hand is scalar, no extra calls: NEGATIVE. An extra indirect call: RESIDUE.
    g = "gen:\n\tvaddps ymm0, ymm0, ymmword ptr [rdi]\n\tvaddps ymm0, ymm0, ymm1\n\tret\n\t.size gen, 1\n"
    h = "hand:\n\tvaddss xmm0, xmm0, dword ptr [rdi]\n\tret\n\t.size hand, 1\n"
    d = "dyn:\n\tcall r15\n\tvaddss xmm0, xmm0, dword ptr [rdi]\n\tret\n\t.size dyn, 1\n"
    assert probe(g + h + d, "gen", "hand")[0] == "NEGATIVE"
    assert probe(g + h + d, "dyn", "hand")[0] == "RESIDUE"
    try:
        probe(h, "gen", "hand")
        assert False, "missing symbol must raise"
    except LookupError:
        pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
