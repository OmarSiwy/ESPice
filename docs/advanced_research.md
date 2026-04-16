# Advanced Research: OSDI, Digital, Cosim, and Compute Crates

This document provides an in-depth technical analysis of four key crates in the BigOSpice
ecosystem: `bigospice-osdi`, `bigospice-digital`, `bigospice-cosim`, and `bigospice-compute`.
These crates implement Phase 4 of the mixed-signal simulation plan: compiled Verilog-A model
loading (OSDI), native XSPICE digital simulation, Verilator co-simulation, and
GPU/parallel compute kernels.

---

## 1. OSDI: OpenVAF Compiled-Model Loader (`crates/osdi`)

### 1.1 Purpose and Architecture

The OSDI crate enables BigOSpice to load **any** device model compiled by
[OpenVAF](https://openvaf.semimod.de/) into a `.osdi` shared object at runtime via
`dlopen`. This includes BSIM4, BSIM6, BSIM-CMG, PSP, HiSIM2, HICUM, MEXTRAM, EKV, VBIC,
and other industry-standard compact models. The approach is architecturally elegant:
BigOSpice never links OpenVAF (which is GPL-3), it only consumes OpenVAF's *output* — a
position-independent `.so` that exports a documented C ABI. The OSDI ABI itself is
LGPL-compatible.

**Architecture flow:**
```
bigospice CLI --dlopen--> bsim4.osdi (.so)
                             |
                  OsdiPlugin (Library handle + descriptor slice)
                             |
                  OsdiRegistry (descriptor name -> entry map)
                             |
                  OsdiInstance (per-device: Box<[u8]> handle + Arc<Library>)
                             |
                  OsdiTrampoline (SoaBuffers: voltage/residual/Jacobian columns)
                             |
                  BigOSpice stamper (maps node pairs to MNA matrix)
```

### 1.2 OSDI v0.3 ABI Specification (`abi.rs`)

The ABI is defined in `abi.rs` with `#[repr(C)]` structs that **must** match OpenVAF's
emitted layout byte-for-byte. The version constants are:

```rust
pub const OSDI_VERSION_MAJOR: u32 = 0;
pub const OSDI_VERSION_MINOR: u32 = 3;  // v0.3
```

The plugin exports four symbols validated on load:
- `OSDI_VERSION_MAJOR` / `OSDI_VERSION_MINOR` — version scalars
- `OSDI_NUM_DESCRIPTORS` — number of device descriptors (u32)
- `OSDI_DESCRIPTORS` — pointer to array of `OsdiDescriptor`

**Key types:**

`OsdiDescriptor` is the central structure — a pointer-table that describes one device kind:

```rust
#[repr(C)]
pub struct OsdiDescriptor {
    pub name: *const c_char,              // e.g. "bsim4nmos"
    pub num_terminals: u32,               // external electrical terminals
    pub num_nodes: u32,                   // internal Verilog-A nodes
    pub nodes: *const OsdiNode,          // per-node metadata
    pub num_jacobian_entries: u32,        // conductance matrix entries
    pub jacobian_entries: *const OsdiNodePair,
    pub num_react_entries: u32,           // reactive (charge/flux) entries
    pub react_entries: *const OsdiNodePair,
    pub instance_size: u32,               // bytes caller allocates for per-instance state
    pub model_size: u32,                   // shared model-card state (e.g. BSIM4 params)
    pub num_params: u32,
    pub params: *const OsdiParamOpvar,   // parameter metadata (name, offset, type)
    pub num_opvars: u32,                  // operating-point output variables
    pub opvars: *const OsdiParamOpvar,

    // Function table
    pub setup_model: Option<OsdiSetupModelFn>,      // bake model-card params
    pub setup_instance: Option<OsdiSetupInstanceFn>, // bake per-instance params
    pub init_instance: Option<OsdiInitInstanceFn>,   // initialize (called once)
    pub eval: Option<OsdiEvalFn>,                     // compute g(x), q(x) — hot path
    pub load_residual_resist: Option<OsdiLoadResidualFn>,    // read g(x) into buffer
    pub load_residual_react: Option<OsdiLoadResidualReactFn>,// read q(x) into buffer
    pub load_jacobian_resist: Option<OsdiLoadJacobianFn>,    // dI/dV conductance
    pub load_jacobian_react: Option<OsdiLoadJacobianReactFn>,// dQ/dV * alpha (transient)
    pub load_jacobian_contrib: Option<OsdiLoadJacobianContribFn>, // Verilog-A <+ contributions
    pub load_noise: Option<OsdiLoadNoiseFn>,                 // noise at frequency
    pub access: Option<OsdiAccessFn>,                         // parameter GET/SET
}
```

**Function pointer signatures (all `unsafe extern "C"`):**

```rust
pub type OsdiEvalFn = unsafe extern "C" fn(
    instance: *mut c_void,
    sim_info: *mut OsdiSimInfo,
) -> u32;

pub type OsdiLoadJacobianReactFn = unsafe extern "C" fn(
    instance: *mut c_void,
    dst: *mut f64,
    alpha: f64,  // integration alpha from the NR loop
) -> ();
```

The `OsdiSimInfo` structure carries simulation context on every call:

```rust
pub struct OsdiSimInfo {
    pub paras: OsdiSimParas,   // global parameters (names + f64 values)
    pub abstime: f64,          // absolute simulation time
    pub prev_solve: *mut f64, // previous-step solution (for transient state)
    pub prev_state: *mut f64, // optional state buffer
    pub next_state: *mut f64, // optional next-state buffer
    pub flags: u32,           // analysis kind flags (DC/TRAN/AC/NOISE)
}
```

### 1.3 Plugin Loading (`loader.rs`)

`OsdiPlugin::open(path)` performs the full handshake:

1. `dlopen` via `libloading::Library::new()` — returns `Arc<Library>`
2. Reads major/minor version scalars; validates compatibility
3. Resolves `OSDI_DESCRIPTORS` symbol; captures a `NonNull<OsdiDescriptor>` pointer
4. Wraps in `OsdiPlugin` with the path, version, and descriptor slice

The descriptor table is never copied — it borrows from the plugin's `.rodata`/`.bss` for
the lifetime of the `Arc<Library>`. The `descriptors()` method returns `&[OsdiDescriptor]`
with lifetime tied to `&self`.

`find_descriptor(name)` performs a linear scan over the descriptor array (typically 1-4
entries per plugin).

### 1.4 Instance Management (`instance.rs`)

`OsdiInstance::new()` allocates per-device state and initializes it:

```rust
let instance_buf = vec![0u8; descriptor.instance_size as usize].into_boxed_slice();
let model_buf = if descriptor.model_size > 0 {
    Some(vec![0u8; descriptor.model_size as usize].into_boxed_slice())
} else { None };
```

The OSDI spec mandates zeroed memory for the instance buffer. The plugin's
`setup_instance(handle, model_handle, sim_info)` and `init_instance(handle, sim_info, temp)`
functions are called immediately — the instance is ready for `eval` after construction.

The instance keeps an `Arc<Library>` so the shared object stays mapped at least as long
as any live instance.

**Harmonic Balance evaluation** (`eval_hb`): Iterates over `num_harmonics`, extracting
per-harmonic voltage slices, calling `evaluate` (trampoline), and assembling:
- `currents[harm * num_nodes + node]` — resistive residual (I)
- `jacobians[harm * num_jacobian_entries + entry]` — conductance dI/dV
- `charges[harm * num_nodes + node]` — reactive residual (Q)

### 1.5 Trampoline: The Hot-Path Bridge (`trampoline.rs`)

`OsdiTrampoline` owns the SoA buffers and orchestrates the call sequence on every
Newton-Raphson iteration:

```text
BigOSpice state --> write_voltages() --> OsdiSimInfo (paras.vals = voltages)
                                     --> eval(handle, &mut sim_info)
                                     --> load_residual_resist(handle, dst)
                                     --> load_jacobian_resist(handle, dst)
                                     --> load_jacobian_react(handle, dst, alpha)
                                     --> load_jacobian_contrib(handle, dst)  [optional]
```

**SoA Buffer layout** (`SoaBuffers`):

| Buffer              | Length                          |
|---------------------|---------------------------------|
| `voltages`          | `num_terminals`                 |
| `residual_resist`   | `num_terminals + num_nodes`     |
| `residual_react`    | `num_terminals + num_nodes`     |
| `jacobian_resist`   | `num_jacobian_entries`          |
| `jacobian_react`    | `num_react_entries`             |

Buffer sizes are fixed at construction — **zero allocations on the hot path**. The
`jacobian_iter()` method zips `jacobian_entries` (the `OsdiNodePair` array from the
descriptor) with the `jacobian_resist` buffer to produce `(OsdiNodePair, f64)` pairs,
which the stamper maps into CSC matrix coordinates.

### 1.6 Registry (`registry.rs`)

`OsdiRegistry` is the top-level orchestrator:

```rust
pub struct OsdiRegistry {
    plugins: Vec<Arc<OsdiPlugin>>,       // loaded libraries (stable order)
    by_name: HashMap<String, DescriptorEntry>,  // name -> (plugin_idx, descriptor_idx)
    instances: Vec<OsdiInstance>,          // SoA: all live instances
    trampolines: Vec<OsdiTrampoline>,     // parallel array
}
```

`create_instance(name, params, temperature)`:
1. Looks up descriptor by name
2. Allocates `OsdiTrampoline::new(descriptor)` (pure Rust, infallible)
3. Calls `OsdiInstance::new(...)` (fallible — OSDI init can fail)
4. Pushes both to the parallel `Vec`s, returns `OsdiInstanceIdx`

`evaluate(idx, voltages, time, alpha)` does the split borrow dance:
```rust
let instance: &mut OsdiInstance = &mut self.instances[i];
let trampoline: &mut OsdiTrampoline = &mut self.trampolines[i];
trampoline.write_voltages(voltages, descriptor)?;
trampoline.evaluate(instance, time, alpha)?;
```

### 1.7 DeviceKind Integration (`device_kind.rs`)

The existing `DeviceKind` enum in `bigospice-core` is closed — adding an `Osdi` variant
would require touching every `match` in the codebase. Instead, `OsdiDeviceKind` wraps
the essential data needed by the dispatch layer:

```rust
pub struct OsdiDeviceKind {
    pub instance: OsdiInstanceIdx,   // u32 index into registry's instance arena
    pub num_terminals: u8,
    pub needs_branch: bool,          // OSDI tells us: no branch current row needed
}
```

A sentinel `DeviceKind` (e.g., `DeviceKind::VbicNpn`, which is never used in OSDI
contexts) is used as the synthetic discriminant. The actual type information lives in
`OsdiDeviceKind` alongside it.

### 1.8 Safety Contract

All `unsafe` blocks are annotated with `// SAFETY:` justifying soundness:

1. **Plugin lifetime**: `OsdiPlugin` holds `Arc<Library>`. Each `OsdiInstance` clones that
   `Arc`, keeping the `.so` mapped.
2. **Buffer ownership**: `Box<[u8]>` is owned by Rust; plugin sees only a raw `*mut c_void`.
3. **Descriptor immutability**: `OsdiDescriptor` table is read-only `.rodata`; exposed as
   `&[OsdiDescriptor]` tied to `Arc<Library>` lifetime.
4. **No GPL linkage**: `libloading` is a pure Rust crate; no compile-time OpenVAF dependency.

---

## 2. Digital Simulation Engine (`crates/digital`)

### 2.1 Overview

`bigospice-digital` implements Phase 4.1 of the mixed-signal plan: a data-oriented
event-driven simulator for native XSPICE-class digital logic that interworks with the
analog Newton-Raphson transient solver via `adc_bridge` / `dac_bridge` elements.

**Design philosophy:** Zero allocations on the hot path. All capacity reserved up-front.
SoA storage for all collections. Branchless primitive dispatch via flat `match` on
`PrimitiveKind`.

### 2.2 12-State Logic Encoding (`state.rs`)

`DigState` packs a logic level and drive strength into a single `u8`:

```
bits 7..4 : strength (Strong=3, Weak=2, Resistive=1, HiZ=0)
bits 3..0 : level    (Zero=0, One=1, X=2, Z=3)
```

`Z` (high-impedance) ignores strength encoding; its bits are always zero. This gives
10 distinct states (3 strengths × {0,1,X} + Z), with two reserved encodings for forward
compatibility.

**Level predicates:** `is_zero()`, `is_one()`, `is_x()`, `is_z()`, `is_defined()`,
`is_strong()` — all single-mask operations.

**Strength resolution:** `DigState::resolve(a, b)` applies XSPICE-style drive strength
resolution:
- `Z` loses to anything non-`Z`
- Stronger driver wins
- Equal strength + conflicting levels → `X` at that strength
- Equal strength + same level → that level

### 2.3 Event Queue (`event_queue.rs`)

The `EventQueue` is a **struct-of-arrays** min-heap priority queue:

```rust
pub struct EventQueue {
    times:   Vec<f64>,           // event times
    nodes:   Vec<DigNodeIdx>,   // target digital nodes
    values:  Vec<DigState>,     // driven value
    heap:    Vec<u32>,          // min-heap permutation over slot indices
    free_list: Vec<u32>,        // popped slots available for reuse
}
```

**Key operations:**

`schedule(t, node, val)` — O(log n):
- Reuses a free-list slot if available, otherwise appends to the data arrays
- Pushes slot index onto heap, sifts up

`pop_due(t_now, out)` — drains all events with `time <= t_now`:
- Repeatedly pops heap root, swaps in last heap entry, sifts down
- Appends to `out` (caller-supplied scratch buffer, cleared first)
- Returns popped slots to `free_list`

`rollback(t_after)` — drops all events with `time > t_after`:
- Linear scan building a new heap from non-rollbacked entries
- Full heap rebuild via bottom-up sifts
- Used when a failed Newton step must retry with smaller `h`

**Invariant:** The data arrays (`times`, `nodes`, `values`) are **append-only**; the heap
permutation is the only thing reordered. This means individual event payloads are never
moved or reallocated.

### 2.4 Digital Primitives (`primitives.rs`)

**Storage:** SoA `PrimitiveBlock` with parallel vectors:

```rust
pub struct PrimitiveBlock {
    pub kinds:       Vec<PrimitiveKind>,             // 1-byte discriminant
    pub inputs:      Vec<SmallVec<[DigNodeIdx; 4]>>,// input node lists
    pub outputs:     Vec<SmallVec<[DigNodeIdx; 4]>>,// output node lists
    pub rise_delays: Vec<f64>,                       // 0→1 propagation delay [s]
    pub fall_delays: Vec<f64>,                       // 1→0 propagation delay [s]
    pub edges:       Vec<EdgeKind>,                  // clock polarity
    pub memory:      Vec<DigState>,                  // per-primitive 1-byte scratch
}
```

**Primitive kinds:**

Combinational (0–11):
- `Buf`, `Not` — single input
- `And`, `Nand`, `Or`, `Nor`, `Xor`, `Xnor` — multi-input reduction
- `Mux2`, `Mux4` — 2:1 and 4:1 multiplexers (sel followed by data)
- `Demux2`, `Demux4` — 1:2 and 1:4 demultiplexers

Sequential (12–13):
- `DLatch` — level-sensitive D latch (transparent when gate=1)
- `DFlipFlop` — edge-triggered D flip-flop (rising or falling)

Sources (14–16):
- `DPulse` — clock generator; `tick_pulses()` drives the queue directly
- `DSource` — externally scheduled; no eval-time logic
- `DState` — user-supplied state machine placeholder

**Eval dispatch** (`eval(id, node_state)`): Flat `match` on `PrimitiveKind` — no
vtables, no boxing. Returns `SmallVec<[(DigNodeIdx, DigState); 4]>` of
output changes (empty if no change).

```rust
PrimitiveKind::And => result.push((outs[0], reduce(ins, node_state, AndOp)))
```

`reduce<O: BinOp>` applies a binary operator across all inputs with the identity value
(`AND` → 1, `OR` → 0). The `BinOp` trait has `apply(a, b)` and `identity()` — three
implementations: `AndOp`, `OrOp`, `XorOp`.

**DFF edge detection:** `memory[id]` stores the previous clock value. On each `eval`,
the rising/falling edge transition is detected by comparing against the current clock.
The new clock value is stored back to `memory[id]`. On trigger, the D input value is
scheduled.

**Pulse generation:** `tick_pulses(t_now, queue)` iterates all `DPulse` primitives,
alternating between `ONE` and `ZERO` on each call, scheduling transitions at
`t_now + period/2`.

### 2.5 Analog/Digital Bridges (`bridges.rs`)

**AdcBridge** — analog → digital with hysteresis:
- Monitors one analog node voltage
- `v >= in_high` → schedule `ONE` event
- `v <= in_low`  → schedule `ZERO` event
- `in_low < v < in_high` → no change (hysteresis band)
- Returns `true` if a threshold was crossed (used by the runtime)

**DacBridge** — digital → analog with linear ramps:
- `on_digital_event(t, new_state)` records the ramp start point and target
- `current_voltage(t)` computes the linear interpolation between `v_start` and
  `v_target` over `t_rise` or `t_fall`
- X/Z states are treated as "hold current target" (no ramp initiated)

**BridgeBlock** SoA storage:
```rust
pub struct BridgeBlock {
    pub adcs: Vec<AdcBridge>,
    pub dacs: Vec<DacBridge>,
}
```

`tick_adcs(t, analog_voltages, queue)` iterates all ADCs, looks up the analog voltage
by `analog_node` index, and calls `adc.step()`. `dispatch_event_to_dacs(t, node, value)`
iterates all DACs, finds those whose `digital_node` matches, and calls
`dac.on_digital_event()`.

### 2.6 XSPICE A-Element Parsing (`element.rs`)

`parse_a_element(line)` parses XSPICE `A` element syntax:
```
A<name> [in1 in2 ...] [out1 out2 ...] model_name
```

Returns `AElement { name, inputs, outputs, model_name }`.

`AModelKind::from_model_name(name)` maps model names to kinds:

| Model name patterns | Kind |
|---|---|
| `buf`, `d_buffer` | `Primitive(Buf)` |
| `not`, `inv`, `d_inverter` | `Primitive(Not)` |
| `and`/`nand`/`or`/`nor`/`xor`/`xnor` + variants | `Primitive(...)` |
| `mux2`/`mux4`, `demux2`/`demux4` | `Primitive(Mux2/Mux4/Demux2/Demux4)` |
| `dff`, `dlatch` | `Primitive(DFlipFlop/DLatch)` |
| `adc_bridge` | `AdcBridge` |
| `dac_bridge` | `DacBridge` |
| `d_source`, `d_pulse`, `d_state` | `DSource/DPulse/DState` |
| (unknown) | `Unknown` |

### 2.7 Transient Solver Integration (`transient_hook.rs`)

`DigitalRuntime::flush(t_now, analog_voltages)` is the integration point called before
each Newton-Raphson step:

```
1. tick_pulses(t_now, queue)        — advance clock generators
2. tick_adcs(t_now, voltages, queue)— ADC threshold crossings
3. pop_due(t_now, &mut scratch)     — drain due events
4. Apply events to node_state[] + dispatch to DACs
5. Re-evaluate all primitives (coarse — no sensitivity list)
   for each output change: queue.schedule(t_now + delay, node, value)
6. Return number of events processed
```

`dac_voltage(node, t)` queries the time-varying voltage of any DAC bridge with a given
digital input node. This is what the analog stamper calls during NR iterations to stamp
the DAC as a time-varying voltage source.

`rollback(t_after)` delegates to `queue.rollback(cutoff)` using the configured policy
(`StrictlyAfter` or `AtOrAfter`).

---

## 3. Verilator Co-Simulation (`crates/cosim`)

### 3.1 Architecture

`bigospice-cosim` implements Phase 4.2: black-box integration with Verilator-compiled
SystemVerilog designs via `dlopen`. BigOSpice does **not** bundle, link, or redistribute
Verilator's source. Instead, it treats the user's `verilator --cc design.v --build -j`
output (`libdesign.so`) as a black box and dispatches into it through a thin C shim.

```
User's SystemVerilog --> verilator --cc --> libdesign.so
                                               |
                           VerilatorModel::load() via dlopen
                                               |
                           bigospice_cosim::DCosim (digital device)
                                               |
                           digital_event_runtime (event-driven sim)
```

### 3.2 Verilator Symbol Loading (`loader.rs`)

`VerilatorModel::load_with_symbols(path, syms)` resolves four entry points from the
`.so` (plus a constructor):

```rust
type EvalFn        = unsafe extern "C" fn(*mut c_void);
type FinalFn       = unsafe extern "C" fn(*mut c_void);
type SetSignalFn   = unsafe extern "C" fn(*mut c_void, *const c_char, u64);
type GetSignalFn   = unsafe extern "C" fn(*mut c_void, *const c_char) -> u64;
type CtorFn        = unsafe extern "C" fn() -> *mut c_void;  // returns top-module handle
```

Default symbol names (configurable via `VerilatorSymbols`):
```
bigospice_verilator_new       — constructor (returns opaque ctx handle)
bigospice_verilator_eval      — advance one combinational pass
bigospice_verilator_final     — terminate and free state
bigospice_verilator_set_signal — drive input port by name
bigospice_verilator_get_signal — read output port by name
```

The user writes a thin C shim that wraps the Verilated model:
```c
extern "C" void bigospice_verilator_eval(void* ctx) {
    VerilatedModel* m = (VerilatedModel*)ctx;
    m->eval();
}
extern "C" void bigospice_verilator_set_signal(void* ctx, const char* name, uint64_t v) {
    // look up port by name and drive it
}
```

### 3.3 DCosim Device (`d_cosim.rs`)

`DCosim` wraps a loaded Verilator model and exposes its ports as digital nodes:

```rust
pub struct DCosim {
    pub model: VerilatorModel,
    pub ports: Vec<DCosimPort>,  // digital node -> signal name mapping
    pub clock: ClockMode,
    pub last_clock_high: bool,
}

pub struct DCosimPort {
    pub name: String,
    pub node: DigNodeIdx,
    pub dir: PortDirection,       // Input or Output
    pub width: u8,                // 1..=64 bits
    pub last_value: u64,         // for change-detection
}
```

`DCosim::tick(t, digital_state, queue)` — called from the digital runtime each timestep:

1. **Eval decision** (clock-driven vs. continuous):
   - `Continuous`: always eval
   - `ClockDriven(spec)`: eval only on rising edge of clock node

2. **Drive inputs**: iterate ports with `dir == Input`, read current `DigState` from
   `digital_state[node.index()]`, map to `u64` (ONE=1, others=0), call
   `model.set_signal(name, value)`

3. **Step model**: `model.eval()`

4. **Read outputs**: iterate ports with `dir == Output`, call `model.get_signal(name)`,
   if value changed, `queue.schedule(t, port.node, new_state)`, update `last_value`

### 3.4 Clock Modes (`clock_mode.rs`)

```rust
pub enum ClockMode {
    Continuous,                  // eval every timestep (combinational designs)
    ClockDriven(ClockSpec),     // eval only on rising clock edge
}

pub struct ClockSpec {
    pub node: DigNodeIdx,       // clock digital node
    pub period: f64,             // informational
}
```

Rising edge detection: `!self.last_clock_high && cur_clock.is_one()`. The previous clock
value is cached in `last_clock_high`.

### 3.5 DPI-C Bridge (`dpi.rs`)

`DpiBridge` is a thread-safe registry of callbacks callable from SystemVerilog via
`import "DPI-C" function ...;` declarations:

```rust
pub type DpiCallback = Box<dyn Fn(&str) -> f64 + Send + 'static>;

pub struct DpiBridge {
    table: Mutex<AHashMap<String, DpiCallback>>,
}

impl DpiBridge {
    pub fn register<F>(&self, name: &str, f: F)
    where F: Fn(&str) -> f64 + Send + 'static;

    pub fn call(&self, name: &str, arg: &str) -> Option<f64>;
}
```

The user writes a C wrapper that calls into the closure table. For example, a DPI
export in SystemVerilog:
```systemverilog
import "DPI-C" function real bigospice_get_voltage(input string node);
```

The C wrapper calls `bigospice_get_voltage` which forwards to the registered Rust
closure via `DpiBridge::call("bigospice_get_voltage", node_name)`.

---

## 4. Compute / GPU Acceleration (`crates/compute`)

### 4.1 Overview

`bigospice-compute` provides parallel compute backends (CPU via Rayon, GPU via wgpu)
and GPU-ready memory allocators. It also contains the BSIM4 batch evaluation path
that is the primary target for GPU acceleration.

### 4.2 Backend Trait (`backend.rs`)

```rust
pub trait ComputeBackend: Send + Sync {
    fn eval_batch(&self, voltages: &[f64], num_devices: usize,
                  num_terminals: usize, results: &mut [f64]);

    fn axpy(&self, alpha: f64, x: &[f64], y: &mut [f64]);   // y += alpha * x
    fn dot(&self, x: &[f64], y: &[f64]) -> f64;               // sum(x[i] * y[i])
    fn norm_inf(&self, x: &[f64]) -> f64;                     // max(|x[i]|)
    fn scale(&self, alpha: f64, x: &mut [f64]);               // x *= alpha
    fn name(&self) -> &str;
}
```

All operations take plain slices. Callers use any storage (`Vec<f64>`, `AlignedVec`,
`&[f64]`). The trait is object-safe.

### 4.3 CPU Backend (`CpuBackend`)

CPU backend using Rayon for parallelism and auto-vectorization for sequential SIMD:

**Parallelism threshold:** Default `min_parallel_size = 1024`. Below this threshold, the
sequential scalar path is used. Above it, Rayon `par_chunks(_mut)` is used.

**Sequential SIMD kernels:**
```rust
fn simd_axpy(alpha: f64, x: &[f64], y: &mut [f64]) {
    y.iter_mut().zip(x.iter()).for_each(|(yi, &xi)| *yi += alpha * xi);
}
```

These scalar loops are auto-vectorized by the compiler into SIMD instructions (AVX2
with `RUSTFLAGS="-C target-cpu=native"`).

**`eval_batch`**: Parallelizes over devices. Default evaluation (stub) computes the sum
of terminal voltages per device. Real BSIM4 batch evaluation goes through
`eval_bsim4_batch_cpu()`.

### 4.4 GPU Backend — WGSL (`gpu_backend.rs` + `shaders/blas.wgsl`)

`WgpuBackend` uses the **wgpu** crate (Rust wrapper over Vulkan/Metal/DX12) to dispatch
compute shaders. Four pipelines are compiled at construction time from `blas.wgsl`:

| Pipeline | Entry | Operation |
|---|---|---|
| `axpy_pipeline` | `axpy` | `x[i] += alpha * y[i]` (f64 packed as 2×u32) |
| `scale_pipeline` | `scale` | `x[i] *= alpha` |
| `dot_pipeline` | `dot_partial` | partial sums for dot product (WG_SIZE=256) |
| `norm_inf_pipeline` | `norm_inf_partial` | partial max for infinity norm |

**GPU buffer layout:**

```wgsl
@group(0) @binding(0) var<uniform>          params: Params;   // n, alpha, alpha_hi/lo
@group(0) @binding(1) var<storage, read_write> x: array<u32>; // f64 packed as 2×u32
@group(0) @binding(2) var<storage, read>    y: array<u32>;    // f64 packed as 2×u32
@group(0) @binding(3) var<storage, read_write> result: array<u32>; // partial results
```

**`Params` uniform** packs an f64 alpha as two u32 halves (WGLSL doesn't support f64 natively):
```rust
struct GpuParams {
    n: u32,
    alpha: f32,
    alpha_hi: u32,  // high 32 bits of f64
    alpha_lo: u32,  // low 32 bits of f64
}
```

**Reduction pattern:** `dot_partial` and `norm_inf_partial` use a tree-reduction within
the workgroup with `workgroupBarrier()` synchronization, then write one partial result
per workgroup to `result[]`. The host sums the partial results on read-back.

**GPU fallback:** If `x.len() < min_gpu_size`, all operations fall back to a scalar
CPU loop. Default `min_gpu_size` is set at construction. The GPU path is only worthwhile
when transfer overhead is amortized over enough work.

**`dispatch_and_read`:** The full GPU dispatch pipeline is:
1. Create command encoder
2. `begin_compute_pass` → `set_pipeline` → `set_bind_group` → `dispatch_workgroups`
3. `encoder.copy_buffer_to_buffer` (result → staging)
4. `queue.submit`
5. `slice.map_async` + `device.poll(wgpu::PollType::Wait)` for read-back
6. Return `Vec<u8>`, then `bytemuck::cast_slice` to `f64` or `f32`

### 4.5 BSIM4 Batch Evaluation (`bsim4_batch.rs` + `shaders/bsim4_eval.wgsl`)

**Purpose:** Evaluate a batch of BSIM4 MOSFET devices in parallel on GPU (or CPU), computing
drain current (Ids) and small-signal conductances (gm, gds, gmbs) from terminal voltages.

**Input/Output types:**
```rust
pub struct Bsim4BatchInput {
    pub vgs: Vec<f32>,   // gate-source voltages [V], one per device
    pub vds: Vec<f32>,   // drain-source voltages [V]
    pub vbs: Vec<f32>,   // bulk-source voltages [V]
    pub temp: f32,       // lattice temperature [K]
}

pub struct Bsim4BatchOutput {
    pub ids:  Vec<f32>,   // drain current [A]
    pub gm:   Vec<f32>,   // transconductance dIds/dVgs [S]
    pub gds:  Vec<f32>,   // output conductance dIds/dVds [S]
    pub gmbs: Vec<f32>,   // body transconductance dIds/dVbs [S]
}
```

**WGSL kernel structure** (`bsim4_eval.wgsl`):

The kernel is a direct port of `crates/device/src/bsim4/eval.rs` (DC load path only):

```wgsl
@compute @workgroup_size(64)
fn bsim4_eval(@builtin(global_invocation_id) gid: vec3<u32>) {
    let idx = gid.x;
    if idx >= uniforms.n_devices { return; }

    let b = biases[idx];    // Bias { vgs, vds, vbs }
    let p = params[idx];    // Bsim4Params (37 fields)

    // Steps:
    // 1. compute_vth()     — threshold voltage + body effect + SCE + DIBL
    // 2. compute_vgsteff() — effective Vgs with subthreshold smoothing
    // 3. compute_mobility()— mu_eff with vertical field and Coulomb scattering
    // 4. compute_vdsat()  — velocity-saturation limited Vds
    // 5. compute_vdseff() — smooth min(Vds, Vdsat)
    // 6. Ids = beta0 * vgsteff * vdseff * bracket / denom * CLM
    // 7. Conductances: gm, gds, gmbs from derivative chain rule
    // 8. GIDL/GISL (simplified, absorbed into gds)
    // 9. Polarity (+1 NMOS / -1 PMOS) and source-drain swap restoration

    output[idx] = Bsim4Out { ids, gm, gds, gmbs };
}
```

**CPU mirror** (`eval_bsim4_batch_cpu`): Uses Rayon `into_par_iter().map(eval_one)` where
`eval_one` is a direct Rust translation of the WGSL kernel. The CPU path is the fallback
when GPU is unavailable.

**Default parameters:** `default_bsim4_params(temp)` provides 65nm PTM LP NMOS process
constants (Leff=100nm, Weff=1µm, Vth0=0.5V, etc.) for smoke testing.

### 4.6 AlignedVec (`aligned_vec.rs`)

64-byte cache-line-aligned `Vec<f64>` for SIMD loads/stores:

```rust
pub struct AlignedVec {
    data: Vec<f64>,
}

impl AlignedVec {
    pub fn new(n: usize) -> Self { /* Layout::from_size_align(n * 8, 64) */ }
    pub fn zeros(n: usize) -> Self;
    pub fn from_slice(s: &[f64]) -> Self;
}
```

Uses `std::alloc::Layout::from_size_align` for guaranteed 64-byte alignment. Custom `Drop`
deallocates with the matching aligned layout (avoids the default deallocator's alignment
assumption).

### 4.7 MemoryPool (`memory_pool.rs`)

Arena-style memory pool that avoids `malloc`/`free` on the hot path:

```rust
pub struct MemoryPool {
    arenas:    RefCell<Vec<Vec<u8>>>,    // pre-allocated blocks
    block_size: usize,
    free_list: RefCell<Vec<usize>>,       // arena indices with free space
    cursors:   RefCell<Vec<usize>>,       // per-arena write cursors
}
```

`alloc(size)` returns a `&mut [u8]` borrowed from the internal arena. Uses a free-list
to find a block with sufficient remaining capacity; otherwise allocates a new block
(capacity = `max(block_size, size)`).

`alloc_slice<T: Copy + Default>(count)` overallocates by `(align-1)` bytes, aligns the
pointer, and zeroes via `write_bytes`. Limited to `align <= 8` (use `AlignedVec` for
cache-line data).

`reset()` returns all blocks to the free list without deallocating — all previously
returned slices are invalidated but the memory is still mapped.

### 4.8 Parallel Utilities (`parallel.rs`)

```rust
pub fn parallel_for<F>(range: usize, config: &ParallelConfig, f: F)
where F: Fn(usize) + Sync + Send;

pub fn parallel_reduce<T, F, R>(
    range: usize, config: &ParallelConfig,
    identity: T, f: F, reduce: R,
) -> T
where T: Clone + Send + Sync, F: Fn(usize) -> T + Sync + Send, R: Fn(T, T) -> T + Sync + Send;
```

Default threshold: `min_parallel_size = 1024`, `chunk_size = 256`. Uses Rayon
`into_par_iter()` above threshold; sequential loop below.

---

## 5. Key Design Patterns Across All Crates

### 5.1 Struct-of-Arrays (SoA) Everywhere

Every collection that processes many items uses SoA over AoS:
- `SoaBuffers` in OSDI trampoline: parallel `Vec<f64>` columns for voltages,
  residuals, Jacobians
- `PrimitiveBlock`: parallel `Vec<PrimitiveKind>`, `Vec<SmallVec>`, `Vec<f64>`, `Vec<DigState>`
- `EventQueue`: parallel `Vec<f64>`, `Vec<DigNodeIdx>`, `Vec<DigState>` with heap permutation
- `MemoryPool`: multiple `Vec<u8>` arenas

### 5.2 Zero-Allocation Hot Path

All crates pre-allocate capacity at construction and reuse it across simulation steps:
- OSDI `SoaBuffers` fixed at trampoline construction
- `EventQueue` capacity reserved at creation; `free_list` recycles popped slots
- `MemoryPool` pre-allocates arenas; `alloc` never calls the system allocator after warmup
- `AlignedVec` allocates once with 64-byte alignment

### 5.3 unsafe Contract

All `unsafe` blocks across all four crates carry explicit `// SAFETY:` comments with
justification. The OSDI crate has the most complex safety invariants due to the FFI
boundary with plugin shared objects.

### 5.4 enum Dispatch Over Trait Objects

The digital crate uses flat `match` on `PrimitiveKind` for zero-cost branching.
The compute crate uses `enum Backend { Cpu(CpuBackend), Gpu(WgpuBackend) }` with a
`match` in the `ComputeBackend` impl rather than dynamic dispatch.

### 5.5 dlopen Pattern

Both `osdi` and `cosim` use `libloading::Library` to dynamically load `.so` files at
runtime. The pattern is identical in both: load symbols, resolve constructor, create
RAII wrapper. The primary difference is the complexity of the plugin ABI (OSDI's
descriptor table + function pointers vs. cosim's fixed 5-symbol interface).

---

## 6. Open Questions / Research Gaps

1. **OSDI v0.4**: The loader implements OSDI v0.3. OpenVAF may ship v0.4 support in future;
   the ABI struct layouts would need verification.

2. **GPU BSIM4 eval**: `WgpuBackend::eval_batch` is currently a no-op stub (`TODO:
   implement device eval kernel in WGSL`). The `bsim4_eval.wgsl` shader is written but
   not yet integrated into the GPU path. The CPU path in `bsim4_batch.rs` is complete.

3. **Digital primitive sensitivity list**: `flush()` currently re-evaluates **all**
   primitives when any event fires. A proper sensitivity list would dramatically reduce
   work for sparse netlists.

4. **Verilator continuous mode**: The `DCosim` continuous-assignment mode calls
   `eval()` every timestep but the Verilator model may not have any inputs changing
   between ticks. Verilator's internal scheduling could be leveraged more efficiently.

5. **DPI-C string handling**: `DpiBridge::call` passes `&str` node names. The C shim
   must forward these to the Rust closure. The lifetime management of the `CString`
   in `VerilatorModel::set_signal`/`get_signal` is correct but creates a small
   allocation per signal access.

6. **OSDI Harmonic Balance**: `OsdiInstance::eval_hb()` loops over harmonics calling
   the trampoline for each. The OSDI spec supports multi-harmonic evaluation natively;
   the current implementation calls `eval` (single-tone) per harmonic. This works but
   may miss native OSDI HB optimizations.

---

*Document version: 2026-04-16. Source: BigOSpice `crates/osdi`, `crates/digital`,
`crates/cosim`, `crates/compute`. Refer to individual `#[cfg(test)]` modules and
`docs/` for integration-level context.*
