# Design review: the VPI `$systf` host (#197)

- **Change**: device ABI 29 carries a device's LRM §12.32 `$name` calls (`DeviceVtable.systf_calls`) to the host. An instance of a module that calls one is refused by name (`UnregisteredSystf`), because ESPice loads no VPI application yet. Before this, a release build called through a null `Instance.systf`.
- **Domain skill(s)**: spice-engine (device evaluation), api-design (the VerA host contract and the device ABI)
- **Hot/cold**: cold. Evidence: no built-in model declares `systf_calls`, and refused devices never evaluate.
- **Stages run**: R1, R6, R7, R9 (a change to the device ABI, §1.1)

## Boundary (R1)

The host-side usage, in `NetBuilder.addDynDevices`:

```zig
if (vt.systf_calls.len != 0) {
    std.log.err("{s}: module '{s}' calls `{s}`: no VPI application registered (LRM 12.32), so its value is unknown; see #198", ...);
    return error.UnregisteredSystf;
}
```

- Granularity: one slice per device type, read once per instance at build time.
- Redundancy: none. The table is VerA's `systf_calls` as generated (name, tok, outs).
- Coupling: the host sees `contract.Systf`, which `abi.zig` already imports.
- Retention: the slice points into the device image, which the loader never unloads.
- Flow control: the host's.

ABI: `DeviceVtable` grows a slice, so `layoutHash` changes. `abi_version` goes from 28 to 29. Model and Instance PODs are not in `layoutHash` (`abi.zig` `layoutHash` hashes the listed ABI types only). No shipped device's Instance changes. Integration needs the default (GPU) build and `zig build test-gpu`, because the vtable is shared by every device object.

## Containment (R6)

| Module | Error set | Boundary validation | Check budget (Principle 17.10) | Bounds |
| ------ | --------- | ------------------- | ------------------------------ | ------ |
| frontend (`builder.zig`) | `UnregisteredSystf` added to the inferred set | refusal at the `.hdl` instance boundary, before any blob is staged | operating error, ships in release | n.a. |
| device (`eval.zig`) | none added | none (comptime device data) | `ProtoStore.append` asserts `Instance.systf != null` for a systf device: a programmer error once the refusal holds; on in ReleaseSafe | n.a. |

A built-in model that calls a `$systf` fails its build with a `@compileError` naming the call, since it has no `.hdl` card to refuse.

## Test plan (R7)

| Bug class | Oracle | Layer | Tier | Harness / file |
| --------- | ------ | ----- | ---- | -------------- |
| host cannot see the calls (vtable drops them) | names and tok written in the mock device | unit | merge | `src/device/tests/eval.zig` "systf: the vtable names every $systf call…" |
| a systf device sent to the GPU | `gpuRefusal(D) == .systf` | unit | merge | same |
| a used `$systf` value invented (0, NaN) or a null binding called | input contract: refused, category `unsupported_input` | corpus | merge | `tests/fixtures/invalid/veriloga_systf_value_refused.sp` |
| a task-position call changes the result | analytic, independent of any `$systf` value: v(out) = 0.5 V | corpus | merge | `tests/fixtures/hdl/veriloga_systf_task.sp`, XFAIL (KNOWN GAP) until VerA marks task calls (V1) |

The harness checks the error category, not the message text, so the wording of the named error is pinned only by review.
Exit criteria: `zig build test -Dgpu=false -Doptimize=ReleaseSafe` exits 0 with the two new `VERDICTS.tsv` rows as written (PASS, XFAIL); the default build and `test-gpu` pass.

## What VPI loading needs from VerA

Sent to the lead on 2026-10-18 (pinned VerA `vera-0.9.0-fzAu7CKX…`):

- V1: `contract.Systf` says whether a call is a task (additive, like `outs`). Without it the host cannot tell a no-op task call from a used value on a cache hit.
- V2: more than one design. `root.design` and `analog_run`'s call tables are process globals keyed by k, so two modules collide.
- V3: instance identity in `HostCall`, so per-call application state does not mix instances.
- V4: a setter for the analysis, time and frequency `calltf` reads (`analog_run` writes them only in its own walk).
- V5: a calls-only `attach` (today it needs the whole testbench `Lib`), with value reads refused by name when no solution is attached.

`vpi` is already importable: VerA's build.zig adds every `module_specs` row with `addModule` (`defineModules(b, target, true)`).

## Record (R9)

S12 in `dev/decisions.md`. `docs/using/devices.md` and `docs/using/diagnostics.md` describe the refusal, and `dev/devices/gpu-evaluation.md` lists the GPU rule.

## Checklist

| #   | Check | Source | Verdict | Evidence (file:line, probe, number) |
| --- | ----- | ------ | ------- | ----------------------------------- |
| 1 | Refuse by name, never invent a value | §2.7.6 | pass | `builder.zig` `addDynDevices`, `UnregisteredSystf` |
| 2 | No global mutable state | R6 | pass | none added |
| 3 | ABI bump recorded | §2.9 | pass | `abi.zig` `abi_version` 29 with its comment |

## Accepted exceptions

A task-position call is refused too, until VerA's V1 lands (lead's ruling, 2026-10-18: "if VerA can't tell the two positions apart, refuse both").
