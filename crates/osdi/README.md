# `pisim-osdi` — OSDI / OpenVAF compiled-model loader

> OSDI ABI definitions follow the public OpenVAF OSDI spec; this crate
> contains no OpenVAF source code.

`pisim-osdi` lets PiSIM load any device model that has been compiled by
[OpenVAF](https://openvaf.semimod.de/) into an `.osdi` shared object —
BSIM4, BSIM6, BSIM-CMG, PSP, HiSIM2, HICUM, MEXTRAM, EKV, VBIC, and so
on — at runtime via `dlopen`.

PiSIM remains LGPL-3 because **we never link OpenVAF**. We only consume
its *output*: a position-independent shared library that exports a
documented C ABI (the OSDI table). The OSDI ABI itself is not GPL.

---

## User workflow

```bash
# 1. Compile a Verilog-A model with OpenVAF (separate, GPL-3 tool —
#    install it however you want; PiSIM does not depend on it).
openvaf bsim4.va -o bsim4.osdi

# 2. Run PiSIM with the compiled .osdi loaded as a runtime plugin.
pisim --osdi bsim4.osdi circuit.sp
```

Multiple `--osdi` flags can be passed; descriptors are merged into a
single `OsdiRegistry` and resolved by name when the SPICE parser hits a
matching `.MODEL` card.

---

## Crate layout

```text
crates/osdi/
├── Cargo.toml
├── README.md           ← this file
├── src/
│   ├── lib.rs          ← public API + OsdiError
│   ├── abi.rs          ← #[repr(C)] OSDI structs + fn-pointer types
│   ├── loader.rs       ← OsdiPlugin::open() via libloading::Library
│   ├── instance.rs     ← OsdiInstance — Box<[u8]> handle buffer
│   ├── trampoline.rs   ← OsdiTrampoline + SoaBuffers (DOD)
│   ├── device_kind.rs  ← integration shim with pisim-device dispatch
│   └── registry.rs     ← OsdiRegistry — runtime descriptor table
└── tests/
    └── loader.rs       ← unit tests + #[ignore]'d real-dlopen test
```

---

## Public API at a glance

```rust
use pisim_osdi::{OsdiPlugin, OsdiRegistry, OsdiError};
use pisim_core::ParamMap;

// 1. Load a plugin
let plugin = OsdiPlugin::open("bsim4.osdi")?;
println!("OSDI {:?}, {} descriptors", plugin.version(), plugin.num_descriptors());

// 2. Or use the registry, which keeps an Arc<OsdiPlugin> internally
let mut registry = OsdiRegistry::new();
let names = registry.load_plugin("bsim4.osdi")?;
println!("registered: {names:?}");

// 3. Instantiate a device
let mut params = ParamMap::new();
params.set("vth0", 0.5);
let idx = registry.create_instance("bsim4nmos", &params, 300.0)?;

// 4. Each NR iteration: write voltages, eval, read Jacobian
let trampoline = registry.evaluate(idx, &[1.2, 0.0, 0.0, 0.0], 0.0, 1.0)?;
for (pair, g) in trampoline.jacobian_iter(registry.descriptor("bsim4nmos").unwrap()) {
    // stamp into the global CSC matrix
}
# Ok::<(), OsdiError>(())
```

---

## Data-oriented layout

The trampoline holds a [`SoaBuffers`](src/trampoline.rs) struct of
contiguous `Vec<f64>` columns:

| Buffer            | Length                                |
| ----------------- | ------------------------------------- |
| `voltages`        | `descriptor.num_terminals`            |
| `residual_resist` | `num_terminals + num_nodes`           |
| `residual_react`  | same                                  |
| `jacobian_resist` | `descriptor.num_jacobian_entries`     |
| `jacobian_react`  | `descriptor.num_react_entries`        |

Buffer sizes are fixed at construction, so the hot path never allocates.
Trampolines live in a `Vec<OsdiTrampoline>` parallel to the
`Vec<OsdiInstance>` arena owned by the registry — same SoA discipline as
the rest of PiSIM's device dispatch.

---

## Safety contract

Every `unsafe` block in this crate is annotated with a `// SAFETY:`
comment justifying soundness. The crate's invariants are:

1. **Plugin lifetime.** `OsdiPlugin` holds an `Arc<libloading::Library>`.
   Every `OsdiInstance` clones that `Arc` so the shared object stays
   mapped at least as long as any live instance.

2. **Buffer ownership.** The per-instance `Box<[u8]>` is owned by Rust
   and freed in `Drop`. The plugin only sees a raw pointer to it during
   the lifetime of an `&mut OsdiInstance` borrow.

3. **Descriptor immutability.** The `OsdiDescriptor` table is read-only
   data inside the plugin's `.rodata`. We expose it as `&[OsdiDescriptor]`
   tied to `&OsdiPlugin`'s lifetime.

4. **No GPL linkage.** This crate has zero compile-time dependency on
   OpenVAF. Cargo cannot accidentally pull it in.

---

## Testing

```bash
# Pure-Rust tests (no external tooling required)
nix develop -c cargo test --package pisim-osdi

# Real dlopen end-to-end test (requires a system C compiler)
nix develop -c cargo test --package pisim-osdi -- --ignored
```

The ignored test compiles a tiny C stub that exports a single
`OSDI_DESCRIPTORS` table, dlopens it through `OsdiPlugin::open`, and
verifies the descriptor reads back correctly. Use this to validate your
toolchain before pointing the loader at a real BSIM4 plugin.
