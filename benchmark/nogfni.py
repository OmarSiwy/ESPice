#!/usr/bin/env python3
"""Build a GFNI-free copy of the espice binary so valgrind can profile it.

valgrind (3.x, as packaged here) does not implement `vgf2p8affineqb` and kills
the process with SIGILL the first time one executes. LLVM emits that
instruction when it lowers `@reduce(.Or, mask)`, which sits on the BJT/VerA
device-eval path, so callgrind could not profile any deck with a BJT in it --
which is most of the interesting ones.

The fix is not to change espice. It is to replace six instructions that are a
provable no-op WITH RESPECT TO THEIR ONLY CONSUMER, in a throwaway copy of the
binary, and then prove the copy computes the same thing.

    vpacksswb / vpermq / vpshufd        ; bytes are 0x00 or 0xFF
    vgf2p8affineqb $0x0, <const>, %xmm, %xmm
    vpmovmskb %xmm, %eax                ; reads ONLY bit 7 of each byte

The constant qword is 0x0000000000000001, i.e. a GF(2) matrix with one set bit,
so the transform is `dst.bit[7] := src.bit[0]` and every other bit is cleared.
`vpmovmskb` reads bit 7 and nothing else. On a `vpacksswb` output -- which is a
saturated comparison mask, so every byte is 0x00 or 0xFF and bit 0 == bit 7 --
`vpmovmskb(affine(x)) == vpmovmskb(x)`. The instruction is dead.

The replacement is the 10-byte canonical NOP, the same length as the RIP-
relative encoding it overwrites, so every address in the binary is unchanged
and instruction COUNTS are comparable between the two builds.

Four other `vgf2p8affineqb` sites in the binary are left alone: three are a
byte bit-reverse behind `vmovq`/`bswap` and one is a string-compare mask fed by
`vpxor`/`vpor`, none of which satisfy the bit-0-equals-bit-7 precondition.

Usage:
    python3 benchmark/nogfni.py                      # patch + verify, 19 decks
    python3 benchmark/nogfni.py --decks all          # verify on every fixture
    python3 benchmark/nogfni.py --no-verify          # patch only

or `zig build nogfni`. Exits non-zero if the byte-identity claim fails, so an
unverified binary is never left on disk under the output name.
"""

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

# 10 bytes: the RIP-relative `vgf2p8affineqb $0x0,disp32(%rip),%xmm,%xmm` form
# is exactly this long, so the patch is length-preserving and no address moves.
NOP10 = bytes.fromhex("662e0f1f8400" + "00000000")

# Only the one-set-bit matrix makes the instruction a no-op. Any other constant
# is a real transform and must not be patched.
EXPECTED_CONST_QWORD = (1).to_bytes(8, "little")

# The instruction must be bracketed by these to be dead: a saturating pack
# (which is what guarantees bytes are 0x00/0xFF) before, and a consumer that
# reads only bit 7 after.
PRODUCERS = ("vpacksswb",)
CONSUMER = "vpmovmskb"

# Decks the byte-identity claim is checked on. The first six are the ones that
# SIGILL under valgrind on the unpatched binary -- i.e. the whole reason this
# exists -- and the rest spread across analyses and device families so a patch
# that broke a non-BJT path could not hide.
SIGILL_DECKS = [
    "ngspice/schmitt",
    "tran/fourbitadder",
    "ngspice/fourbitadder",
    "devices/bjt_npn_output",
    "ngspice/rca3040",
    "devices/hfet_inverter",
]
DEFAULT_DECKS = SIGILL_DECKS + [
    "ac/rc_lowpass",
    "bjt/common_emitter",
    "bypass/burst_clock",
    "devices/hicum2_output",
    "devices/lossy_tline",
    "devices/mos6_inverter",
    "devices/vbic_output",
    "devices/vbic_temp",
    "ensemble/pvt_corners",
    "golden/op",
    "golden/tran",
    "medium/ladder_filter",
    "tline/txl1_1_line",
]


def section_map(binary):
    """(vma, size, file_offset) per section, for vaddr -> file offset."""
    out = subprocess.run(
        ["objdump", "-h", str(binary)], capture_output=True, text=True, check=True
    ).stdout
    rows = []
    for line in out.splitlines():
        f = line.split()
        # "Idx Name Size VMA LMA File off Algn"
        if len(f) >= 7 and f[0].isdigit():
            size, vma, off = int(f[2], 16), int(f[3], 16), int(f[5], 16)
            if size:
                rows.append((vma, size, off))
    return rows


def to_file_offset(rows, vaddr):
    for vma, size, off in rows:
        if vma <= vaddr < vma + size:
            return off - vma + vaddr
    raise LookupError(f"vaddr {vaddr:#x} is in no section")


INSN = re.compile(r"^\s*([0-9a-f]+):\t([0-9a-f ]+)\t(\S+)(.*)$")
RIPREF = re.compile(r"#\s*([0-9a-f]+)\s")


def find_sites(binary, rows, blob):
    """Every vgf2p8affineqb whose only consumer cannot see what it changed.

    Returns (dead, live): dead is [(vaddr, file_offset)], live is [(vaddr, why)].
    A site is dead only if ALL of: imm8 is 0, the source is RIP-relative memory
    holding the one-set-bit matrix, the encoding is 10 bytes, a saturating pack
    is within the two preceding instructions, and the next instruction is a
    bit-7-only mask extract.
    """
    proc = subprocess.Popen(
        # --insn-width keeps every instruction's bytes on ONE line; without it
        # objdump wraps at 7 and the length check silently sees a truncation.
        ["objdump", "-d", "--insn-width=16", str(binary)],
        stdout=subprocess.PIPE,
        text=True,
    )
    dead, live, window, pending = [], [], [], None
    for line in proc.stdout:
        m = INSN.match(line)
        if not m:
            continue
        vaddr, raw, mnem, args = int(m.group(1), 16), m.group(2), m.group(3), m.group(4)
        nbytes = len(raw.split())

        if pending is not None:
            if mnem == CONSUMER:
                dead.append(pending[:2])
            else:
                live.append((pending[0], f"consumer is {mnem}, not {CONSUMER}"))
            pending = None

        if mnem == "vgf2p8affineqb":
            why = None
            const = RIPREF.search(args)
            if "$0x0," not in args:
                why = "imm8 is not 0"
            elif const is None:
                why = "source is a register, not the known constant"
            elif nbytes != 10:
                why = f"encoding is {nbytes} bytes, not 10 (cannot NOP in place)"
            elif not any(p in window for p in PRODUCERS):
                why = f"not preceded by {'/'.join(PRODUCERS)}; byte lanes are not 0x00/0xFF"
            else:
                off = to_file_offset(rows, int(const.group(1), 16))
                if blob[off : off + 8] != EXPECTED_CONST_QWORD:
                    why = f"matrix is {blob[off:off + 8].hex()}, not a single set bit"
            if why:
                live.append((vaddr, why))
            else:
                # Consumer is on the NEXT line; decide there.
                pending = (vaddr, to_file_offset(rows, vaddr), None)

        window = ([mnem] + window)[:2]
    proc.stdout.close()
    proc.wait()
    if pending is not None:
        live.append((pending[0], "no following instruction"))
    return dead, live


def run_deck(binary, deck, raw, timeout=300):
    r = subprocess.run(
        [str(binary), "-b", "--backend", "cpu", "-r", str(raw), str(deck)],
        capture_output=True,
        timeout=timeout,
    )
    return r.returncode, r.stdout


def verify(orig, patched, decks, workdir):
    """Byte-identical raw output on every deck. Any difference is a failure."""
    bad, ran = [], 0
    for name in decks:
        deck = REPO / "benchmark" / "fixtures" / name / "circuit.sp"
        if not deck.exists():
            bad.append(f"{name}: no such fixture")
            continue
        a, b = workdir / "a.raw", workdir / "b.raw"
        for p in (a, b):
            p.unlink(missing_ok=True)
        rc_a, out_a = run_deck(orig, deck, a)
        rc_b, out_b = run_deck(patched, deck, b)
        if rc_a != rc_b:
            bad.append(f"{name}: exit {rc_a} vs {rc_b}")
            continue
        if rc_a != 0:
            print(f"  skip  {name} (espice exits {rc_a} on both)")
            continue
        ba = a.read_bytes() if a.exists() else None
        bb = b.read_bytes() if b.exists() else None
        if ba is None or ba != bb:
            bad.append(f"{name}: raw output differs")
            continue
        if out_a != out_b:
            bad.append(f"{name}: stdout differs")
            continue
        ran += 1
        print(f"  ok    {name} ({len(ba)} bytes identical)")
    return ran, bad


def check_sigill(orig, patched, workdir):
    """The claim this whole file exists for: unpatched dies, patched does not.

    Skipped rather than failed when valgrind is absent -- the byte-identity
    check above is the correctness gate; this one is the motivation.
    """
    if shutil.which("valgrind") is None:
        print("note: valgrind not found; SIGILL check skipped")
        return []
    deck = REPO / "benchmark" / "fixtures" / SIGILL_DECKS[0] / "circuit.sp"
    out = []
    for label, binary in (("unpatched", orig), ("patched", patched)):
        r = subprocess.run(
            ["valgrind", "--tool=none", "--error-exitcode=42", str(binary),
             "-b", "--backend", "cpu", "-r", str(workdir / "vg.raw"), str(deck)],
            capture_output=True, text=True, timeout=1800,
        )
        sigill = "SIGILL" in r.stderr or "Illegal" in r.stderr
        print(f"  valgrind {label:<9} SIGILL={sigill}")
        out.append(sigill)
    bad = []
    if not out[0]:
        bad.append("unpatched binary did NOT SIGILL under valgrind — "
                   "either valgrind grew GFNI support or the build changed; "
                   "this patch may no longer be needed")
    if out[1]:
        bad.append("patched binary STILL SIGILLs — a GFNI site was missed")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=str(REPO / "zig-out/bin/espice"))
    ap.add_argument("--out", default=str(REPO / "zig-out/bin/espice-nogfni"))
    ap.add_argument("--decks", default="default",
                    help="'default' (19), 'all', or a comma-separated cat/name list")
    ap.add_argument("--no-verify", action="store_true")
    ap.add_argument("--no-sigill-check", action="store_true")
    args = ap.parse_args()

    src = pathlib.Path(args.binary)
    if not src.exists():
        sys.exit(f"error: {src} not found — run `zig build` first")

    blob = bytearray(src.read_bytes())
    rows = section_map(src)
    dead, live = find_sites(src, rows, blob)

    print(f"{len(dead) + len(live)} vgf2p8affineqb sites in {src}")
    for vaddr, why in live:
        print(f"  keep  {vaddr:#x}  {why}")
    for vaddr, off in dead:
        print(f"  NOP   {vaddr:#x}  (file offset {off:#x})")
    if not dead:
        sys.exit("error: no patchable site found — the codegen changed; "
                 "re-derive the idiom before trusting any profile")

    for _, off in dead:
        blob[off : off + len(NOP10)] = NOP10

    # Write under a temporary name; only rename in once verification passes, so
    # an unverified binary never exists at the name a profiling run would use.
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".unverified")
    tmp.write_bytes(blob)
    tmp.chmod(0o755)

    if args.no_verify:
        tmp.rename(out)
        print(f"\nwrote {out} (UNVERIFIED — --no-verify was passed)")
        return

    if args.decks == "all":
        decks = sorted(
            f"{p.parent.parent.name}/{p.parent.name}"
            for p in (REPO / "benchmark/fixtures").glob("*/*/circuit.sp")
        )
    elif args.decks == "default":
        decks = DEFAULT_DECKS
    else:
        decks = [d.strip() for d in args.decks.split(",") if d.strip()]

    with tempfile.TemporaryDirectory() as td:
        work = pathlib.Path(td)
        print(f"\nverifying byte-identical output on {len(decks)} decks:")
        ran, bad = verify(src, tmp, decks, work)
        if not args.no_sigill_check and not bad:
            print("\nvalgrind SIGILL check:")
            bad += check_sigill(src, tmp, work)

    if bad:
        tmp.unlink(missing_ok=True)
        print("\nFAILED — patched binary is NOT equivalent:", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        sys.exit(1)

    tmp.rename(out)
    print(f"\n{ran} decks byte-identical. wrote {out}")


if __name__ == "__main__":
    main()
