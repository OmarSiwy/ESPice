### Verilog -> VF codegen -> `devices` contract-shaped Zig

VF is a code generator. It does not import `modules/devices/src/contract.zig`,
instantiate device types internally, or invoke the Zig compiler as part of the
library API.

The intended flow is:

```text
Verilog source
  -> verilator --json-only -> VF codegen
  -> generated Zig file in the shape expected by modules/devices/src/contract.zig
  -> caller's build.zig compiles that file however it wants
```

The generated file is allowed to import `contract`; VF itself does not.

Entry points:

```zig
const source = try zvf.fromVerilog(gpa, io, verilog_source);
const source = try zvf.fromSystemVerilog(gpa, io, sv_source); // via sv2v

// or hand-written specs, bypassing verilator:
const source = try zvf.codegen.generateDevice(allocator, .{
    .name = "and2",
    .ports = &.{
        .{ .name = "a", .direction = .input },
        .{ .name = "b", .direction = .input },
        .{ .name = "y", .direction = .output },
    },
    .eval_stmts = "    const _y: u64 = a & b;\n",
});
```

That emits a full generated device file with:

```zig
pub const U = enum(u8) { ... };
pub const num_ports: usize = ...;
pub const u_kinds = ...;
pub const g_pattern_override = ...;
pub const Model = struct { ... };
pub const Instance = struct {};
pub const State = struct { ... };
pub fn initState(...) State;
pub fn updateState(...) contract.UpdateResult;
pub fn iS(...) void;
comptime { contract.validate(Self); }
// plus zpicey_* exports for dynamic (.so) loading by the engine,
// including the v2 ABI (zpicey_eval_v2 + zpicey_set_model_param /
// zpicey_set_instance_param) so vil/vih/vlo/vhi/rout are deck-settable
// per .model card and `strength` (drive multiplier, Rout/strength) per
// instance. Param access is byte-copy based: the engine's buffers carry
// no alignment guarantee.
```

The math bridge is:

```text
digital input bit  = analog_input >= (VIL + VIH) / 2
digital state      = evalBits(input bits)
analog output      = Thevenin source driven toward VLO or VHI

F_output_node   = I_branch
F_output_branch = V_output - V_logic(bit) + I_branch * Rout
```

Limits (rejected loudly, never silently miscompiled): port widths 1..64
(values are carried in a u64), at most 256 unknowns per device (contract
requires a dense `enum(u8)`), single-clock synchronous logic only (no async
reset / multi-clock always blocks), no `if`/reset logic inside clocked blocks.

Conformance (`zig build conformance`) runs every fixture through
verilator -> VF, checks structural goldens, and compiles the generated file
against the real `modules/devices/src/contract.zig` so `contract.validate`
runs at comptime.
