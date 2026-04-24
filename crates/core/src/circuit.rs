use crate::device::{DeviceId, DeviceInstance, DeviceKind};
use crate::error::SimError;
use crate::expr::BsourceExpr;
use crate::graph::CompressedGraph;
use crate::node::{Node, NodeId};
use crate::param::{ParamKey, ParamMap};
use ahash::AHashMap;
use smallvec::SmallVec;

/// Describes one AC excitation source in the circuit.
///
/// During AC analysis the MNA right-hand side is set to zero except for
/// entries that correspond to active AC sources.
///
/// - `VoltageSource(branch_row, re, im)` — the V-source branch equation row
///   carries the complex excitation: RHS[branch_row] = re (real) and
///   RHS[dim + branch_row] = im (imaginary).
/// - `CurrentSource(pos_node, neg_node, re, im)` — the current source injects
///   into node KCL rows: RHS[pos_node] += re/im; RHS[neg_node] -= re/im.
///
/// `branch_row` is the MNA index (= `num_vars + branch_index`).
/// Node rows are MNA indices (0-based, ground excluded).
#[derive(Debug, Clone, Copy)]
pub enum AcStimulus {
    /// V-source: (mna_branch_row, real_part, imag_part)
    VoltageSource(usize, f64, f64),
    /// I-source: (pos_node_row, neg_node_row_opt, real_part, imag_part)
    CurrentSource(usize, Option<usize>, f64, f64),
}

/// A voltage constraint between two nodes.
///
/// Single-ended `.IC v(node)=value` and `.NODESET v(node)=value` entries are
/// represented as `neg_node = GND`, while differential forms use the explicit
/// second node from `V(pos,neg)=value`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VoltageConstraint {
    pub pos_node: NodeId,
    pub neg_node: NodeId,
    pub voltage: f64,
}

impl VoltageConstraint {
    pub fn new(pos_node: NodeId, neg_node: NodeId, voltage: f64) -> Self {
        Self {
            pos_node,
            neg_node,
            voltage,
        }
    }

    pub fn single_ended(node: NodeId, voltage: f64) -> Self {
        Self::new(node, NodeId::GROUND, voltage)
    }
}

/// History buffer for a single lossless T-line (Branin's method).
///
/// Stores `(time, E)` samples where `E(t) = V_far(t) + Z0 * I_far(t)` is the
/// incident wave observable at one port, used to compute the delayed source
/// `E(t - TD)` at the opposite port.
///
/// Implemented as a ring buffer for O(1) insert.  Capacity is set at construction
/// to hold at least `ceil(TD / min_timestep)` samples.
#[derive(Debug, Clone)]
pub struct TlineHistory {
    /// Characteristic impedance in ohms.
    pub z0: f64,
    /// Propagation delay in seconds.
    pub td: f64,
    /// Ring buffer of `(time, E_port1)` samples (port-1 incident wave).
    pub samples_p1: Vec<(f64, f64)>,
    /// Ring buffer of `(time, E_port2)` samples (port-2 incident wave).
    pub samples_p2: Vec<(f64, f64)>,
    /// Write head index for `samples_p1`.
    pub head_p1: usize,
    /// Write head index for `samples_p2`.
    pub head_p2: usize,
}

impl TlineHistory {
    /// Create a new history buffer.
    ///
    /// `capacity` should be large enough to span at least `TD` seconds of history
    /// (e.g. `ceil(TD / min_timestep) + 4` for safety).
    pub fn new(z0: f64, td: f64, capacity: usize) -> Self {
        let cap = capacity.max(4);
        Self {
            z0,
            td,
            samples_p1: vec![(0.0, 0.0); cap],
            samples_p2: vec![(0.0, 0.0); cap],
            head_p1: 0,
            head_p2: 0,
        }
    }

    /// Push a new `(time, E)` sample for port 1, overwriting the oldest entry.
    pub fn push_p1(&mut self, time: f64, e: f64) {
        self.samples_p1[self.head_p1] = (time, e);
        self.head_p1 = (self.head_p1 + 1) % self.samples_p1.len();
    }

    /// Push a new `(time, E)` sample for port 2, overwriting the oldest entry.
    pub fn push_p2(&mut self, time: f64, e: f64) {
        self.samples_p2[self.head_p2] = (time, e);
        self.head_p2 = (self.head_p2 + 1) % self.samples_p2.len();
    }

    /// Linearly interpolate `E(target_time)` from the stored samples.
    ///
    /// Returns `0.0` when the target time is before any stored sample (cold-start
    /// assumption: the line is quiescent before t=0).
    pub fn interpolate(samples: &[(f64, f64)], target_time: f64) -> f64 {
        // Collect all samples, sort by ascending time.
        let mut pts: Vec<(f64, f64)> = samples.iter().copied().collect();

        if pts.is_empty() {
            return 0.0;
        }

        pts.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());

        if target_time <= pts[0].0 {
            return 0.0; // Causal: zero before first sample
        }
        if target_time >= pts[pts.len() - 1].0 {
            return pts[pts.len() - 1].1;
        }

        // Binary search for the bracket.
        let idx = pts.partition_point(|&(t, _)| t <= target_time);
        let (t0, e0) = pts[idx - 1];
        let (t1, e1) = pts[idx];
        let frac = (target_time - t0) / (t1 - t0);
        e0 + frac * (e1 - e0)
    }

    /// Look up the delayed port-1 wave `E_p1(t - TD)`.
    pub fn delayed_p1(&self, current_time: f64) -> f64 {
        Self::interpolate(&self.samples_p1, current_time - self.td)
    }

    /// Look up the delayed port-2 wave `E_p2(t - TD)`.
    pub fn delayed_p2(&self, current_time: f64) -> f64 {
        Self::interpolate(&self.samples_p2, current_time - self.td)
    }
}

/// Per-instance history store for an LTRA lossy transmission line.
///
/// **SoA layout:** each observable is a separate contiguous `Vec<f64>`,
/// so the convolution kernel can iterate over one field without touching
/// the others (cache-friendly for long transient runs).
#[derive(Debug, Clone, Default)]
pub struct LtraHistoryStore {
    /// Sample timestamps (seconds), strictly ascending.
    pub times: Vec<f64>,
    /// V(port1+) − V(port1−) at each sample.
    pub v1: Vec<f64>,
    /// V(port2+) − V(port2−) at each sample.
    pub v2: Vec<f64>,
    /// Accepted port-1 axial current into the line at each sample.
    pub i1: Vec<f64>,
    /// Accepted port-2 axial current into the line at each sample.
    pub i2: Vec<f64>,
}

impl LtraHistoryStore {
    /// Create a new empty store with pre-allocated capacity.
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            times: Vec::with_capacity(cap),
            v1: Vec::with_capacity(cap),
            v2: Vec::with_capacity(cap),
            i1: Vec::with_capacity(cap),
            i2: Vec::with_capacity(cap),
        }
    }

    /// Push one accepted sample.
    pub fn push(&mut self, t: f64, v1: f64, v2: f64, i1: f64, i2: f64) {
        self.times.push(t);
        self.v1.push(v1);
        self.v2.push(v2);
        self.i1.push(i1);
        self.i2.push(i2);
    }

    /// Number of stored samples.
    #[inline]
    pub fn len(&self) -> usize {
        self.times.len()
    }

    /// Whether no samples have been stored yet.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.times.is_empty()
    }
}

// ── Digital (XSPICE) bridge / primitive specs ────────────────────────────
//
// Plain-data descriptions of ADC/DAC bridges and digital primitives parsed
// from `A` element lines.  Stored on `Circuit` so the analysis crate can
// construct a `DigitalRuntime` without the core crate depending on the
// digital crate.

/// Specification for an ADC bridge (analog -> digital).
#[derive(Debug, Clone)]
pub struct AdcBridgeSpec {
    /// MNA row index of the analog node being observed.
    pub analog_node_idx: u32,
    /// Allocated digital node index for the output.
    pub digital_node: u32,
    /// Propagation delay before the bridge emits the sampled logic state.
    pub delay: f64,
    /// Lower hysteresis threshold (volts).
    pub in_low: f64,
    /// Upper hysteresis threshold (volts).
    pub in_high: f64,
}

/// Specification for a DAC bridge (digital -> analog).
#[derive(Debug, Clone)]
pub struct DacBridgeSpec {
    /// MNA row index of the analog node being driven.
    pub analog_node_idx: u32,
    /// Digital node index whose state drives this bridge.
    pub digital_node: u32,
    /// Output voltage for logic 0.
    pub out_low: f64,
    /// Output voltage for logic 1.
    pub out_high: f64,
    /// Rise time [s].
    pub t_rise: f64,
    /// Fall time [s].
    pub t_fall: f64,
}

/// Specification for a digital primitive (combinational or sequential gate).
#[derive(Debug, Clone)]
pub struct DigitalPrimitiveSpec {
    /// Primitive kind tag (maps to `PrimitiveKind` repr).
    pub kind: u8,
    /// Digital input node indices.
    pub inputs: Vec<u32>,
    /// Digital output node indices.
    pub outputs: Vec<u32>,
    /// Rise propagation delay: 0→1 transition delay [s].
    pub rise_delay: f64,
    /// Fall propagation delay: 1→0 transition delay [s].
    pub fall_delay: f64,
}

/// Complete specification of the digital sub-system attached to a circuit.
///
/// Built by the parser from `PendingADevice` records.  Consumed by the
/// analysis crate to construct a `DigitalRuntime`.
#[derive(Debug, Clone, Default)]
pub struct DigitalNetSpec {
    /// Total number of digital nodes (determines node-state vector size).
    pub num_dig_nodes: u32,
    pub adc_bridges: Vec<AdcBridgeSpec>,
    pub dac_bridges: Vec<DacBridgeSpec>,
    pub primitives: Vec<DigitalPrimitiveSpec>,
}

impl DigitalNetSpec {
    pub fn is_empty(&self) -> bool {
        self.adc_bridges.is_empty() && self.dac_bridges.is_empty() && self.primitives.is_empty()
    }
}

/// Model type tag parsed from `.MODEL` directives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelKind {
    Nmos,
    Pmos,
    Npn,
    Pnp,
    Diode,
    Resistor,
    Capacitor,
    /// Any unrecognised type string, stored verbatim (lowercased).
    Other(String),
}

impl ModelKind {
    /// Parse a model type string (case-insensitive).
    pub fn from_str(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "nmos" => ModelKind::Nmos,
            "pmos" => ModelKind::Pmos,
            "npn"  => ModelKind::Npn,
            "pnp"  => ModelKind::Pnp,
            "d"    => ModelKind::Diode,
            "r"    => ModelKind::Resistor,
            "c"    => ModelKind::Capacitor,
            other  => ModelKind::Other(other.to_string()),
        }
    }
}

/// Definition of a `.SUBCKT` block for later instantiation.
///
/// Stores the header information (name, terminal list, default params) and the
/// raw netlist bytes of the body so the body can be re-parsed during
/// subcircuit expansion.  For now the body is stored verbatim; inline
/// expansion is a future step.
#[derive(Debug, Clone)]
pub struct SubcktDef {
    /// Subcircuit name (lowercased).
    pub name: String,
    /// Ordered list of terminal/port names (as written in the netlist).
    pub terminals: Vec<String>,
    /// Default parameter values declared in the `.SUBCKT` header.
    pub params: ParamMap,
    /// Raw netlist bytes of the body (everything between `.SUBCKT` and `.ENDS`).
    pub body: Vec<u8>,
}

/// A pending subcircuit call (X-instance) collected during parsing.
///
/// After parsing is complete, each `SubcktCall` is resolved by looking up
/// the named subcircuit definition and inlining its devices with renamed
/// nodes and device names.
#[derive(Debug, Clone)]
pub struct SubcktCall {
    /// DeviceId of the placeholder X device in `Circuit::devices`.
    pub device_id: DeviceId,
    /// Instance name (e.g. `"x1"`), lowercased.
    pub instance_name: String,
    /// Name of the subcircuit being instantiated (lowercased).
    pub subckt_name: String,
    /// Ordered list of NodeIds matching the subcircuit's terminal list.
    pub terminal_nodes: Vec<NodeId>,
    /// Parameter overrides specified on the instance line.
    pub params: ParamMap,
}

/// The central circuit representation.
///
/// Data-oriented layout: parallel arrays indexed by NodeId/DeviceId.
/// This is the source of truth for topology, parameters, and stamp mappings.
#[derive(Debug, Clone)]
pub struct Circuit {
    // --- Topology (Level 5 cache) ---
    nodes: Vec<Node>,
    devices: Vec<DeviceInstance>,
    topology: Option<CompressedGraph>,

    // --- Parameter→device dependency: which devices depend on each param ---
    param_deps: AHashMap<ParamKey, SmallVec<[DeviceId; 4]>>,

    // --- Name→ID lookup ---
    node_names: AHashMap<String, NodeId>,
    device_names: AHashMap<String, DeviceId>,

    // --- MNA dimensions ---
    /// Number of voltage unknowns (nodes - ground).
    num_vars: u32,
    /// Number of branch current unknowns (V-sources, inductors).
    num_branches: u32,

    // --- Model registry: .MODEL name type (params) ---
    /// Keyed by model name (lowercased). Value = (kind, params).
    pub models: AHashMap<String, (ModelKind, ParamMap)>,

    // --- Global parameters: .PARAM name=value ---
    pub global_params: AHashMap<String, f64>,

    // --- AC stimuli ---
    /// List of active AC excitation sources, populated by the parser.
    ac_stimuli: Vec<AcStimulus>,

    // --- B-source expressions ---
    /// Per-device behavioral expression store for B-source devices.
    ///
    /// Keyed by `DeviceId`.  The stamper looks up this map for any device
    /// whose kind is `BsourceV` or `BsourceI` and evaluates the expression
    /// directly, bypassing the `DeviceRegistry` (which cannot hold per-instance
    /// data).
    bsource_exprs: AHashMap<DeviceId, BsourceExpr>,

    // --- Transient initial conditions ---
    /// `.IC v(node)=value` / `.IC v(pos,neg)=value` constraints.
    ///
    /// These force node voltages or voltage differences during the DC OP that
    /// precedes a transient.
    initial_conditions: Vec<VoltageConstraint>,

    // --- Solver initial-guess biases ---
    /// `.NODESET v(node)=value` / `.NODESET v(pos,neg)=value` constraints.
    ///
    /// These bias the Newton solver starting point but do not force final values.
    node_sets: Vec<VoltageConstraint>,

    // --- Operating temperatures ---
    /// `.TEMP t1 [t2 ...]` — operating temperatures in Kelvin.
    ///
    /// Multiple entries drive multi-temperature sweeps.
    temperatures: Vec<f64>,

    // --- Mutual inductance couplings ---
    /// `K L1 L2 k_value` entries: (id_of_L1, id_of_L2, coupling_coefficient).
    ///
    /// Populated by the parser. The stamper reads these to add off-diagonal
    /// inductive-coupling entries to the MNA branch-equation rows during transient.
    mutual_couplings: Vec<(DeviceId, DeviceId, f64)>,

    // --- Global nodes ---
    /// `.GLOBAL node1 node2 ...` — node names that are not mangled during subcircuit expansion.
    ///
    /// These names are visible at the top level of the hierarchy and bypass
    /// the normal `instance.node` mangling that subcircuit expansion applies.
    globals: Vec<String>,

    // --- Subcircuit definitions ---
    /// `.SUBCKT` blocks parsed from the netlist, keyed by name (lowercased).
    ///
    /// The body bytes are stored verbatim for deferred expansion.  Inline
    /// expansion (X-instance elaboration) is performed by `flatten_subcircuits`.
    pub subckt_defs: AHashMap<String, SubcktDef>,

    // --- Pending subcircuit calls ---
    /// X-instance records accumulated during parsing, consumed by `flatten_subcircuits`.
    pub subckt_calls: Vec<SubcktCall>,

    // --- T-line (lossless transmission line) history buffers ---
    /// Per-T-line history buffers for Branin's method.
    ///
    /// Indexed by `DeviceId` (sparse: only entries for `DeviceKind::Tline` exist).
    /// Each buffer stores `(time, E_value)` samples where `E(t) = V_far(t) + Z0*I_far(t)`
    /// is the outgoing wave observable at the *far* end, to be looked up at `t - TD`.
    tline_histories: ahash::AHashMap<DeviceId, TlineHistory>,

    // --- LTRA (lossy transmission line) history buffers ---
    /// Per-LTRA history buffers for Roychowdhury-Pederson convolution.
    ltra_histories: ahash::AHashMap<DeviceId, LtraHistoryStore>,

    // --- Digital (XSPICE) bridge / primitive configuration ---
    /// Specification of ADC/DAC bridges and digital primitives parsed from
    /// A-device lines.  When non-empty, the transient analysis constructs a
    /// `DigitalRuntime` and integrates it into the NR loop.
    digital_spec: Option<DigitalNetSpec>,
}

impl Circuit {
    pub fn new() -> Self {
        let mut c = Self {
            nodes: Vec::new(),
            devices: Vec::new(),
            topology: None,
            param_deps: AHashMap::new(),
            node_names: AHashMap::new(),
            device_names: AHashMap::new(),
            num_vars: 0,
            num_branches: 0,
            models: AHashMap::new(),
            global_params: AHashMap::new(),
            ac_stimuli: Vec::new(),
            bsource_exprs: AHashMap::new(),
            initial_conditions: Vec::new(),
            node_sets: Vec::new(),
            temperatures: Vec::new(),
            mutual_couplings: Vec::new(),
            globals: Vec::new(),
            subckt_defs: AHashMap::new(),
            subckt_calls: Vec::new(),
            tline_histories: AHashMap::new(),
            ltra_histories: AHashMap::new(),
            digital_spec: None,
        };
        // Always add ground node at index 0.
        let ground = Node::ground();
        c.node_names.insert("0".into(), NodeId::GROUND);
        c.node_names.insert("gnd".into(), NodeId::GROUND);
        c.nodes.push(ground);
        c
    }

    // --- Read-only accessors ---

    pub fn nodes(&self) -> &[Node] {
        &self.nodes
    }

    pub fn devices(&self) -> &[DeviceInstance] {
        &self.devices
    }

    /// Mutable access to the device slice. Used by post-parse passes (e.g.
    /// model-parameter merging) that need to update device params/kinds.
    pub fn devices_mut(&mut self) -> &mut [DeviceInstance] {
        &mut self.devices
    }

    pub fn topology(&self) -> Option<&CompressedGraph> {
        self.topology.as_ref()
    }

    pub fn param_deps(&self) -> &AHashMap<ParamKey, SmallVec<[DeviceId; 4]>> {
        &self.param_deps
    }

    pub fn num_vars(&self) -> u32 {
        self.num_vars
    }

    pub fn num_branches(&self) -> u32 {
        self.num_branches
    }

    /// Total MNA matrix dimension: node voltages + branch currents.
    pub fn mna_dimension(&self) -> usize {
        (self.num_vars + self.num_branches) as usize
    }

    /// AC stimuli registered for this circuit.
    pub fn ac_stimuli(&self) -> &[AcStimulus] {
        &self.ac_stimuli
    }

    /// Register an AC stimulus. Called by the parser after building devices.
    pub fn add_ac_stimulus(&mut self, stim: AcStimulus) {
        self.ac_stimuli.push(stim);
    }

    /// Store a behavioral expression for a B-source device.
    pub fn add_bsource_expr(&mut self, id: DeviceId, expr: BsourceExpr) {
        self.bsource_exprs.insert(id, expr);
    }

    /// Look up the behavioral expression for a B-source device.
    pub fn bsource_expr(&self, id: DeviceId) -> Option<&BsourceExpr> {
        self.bsource_exprs.get(&id)
    }

    /// All B-source expression entries.
    pub fn bsource_exprs(&self) -> &AHashMap<DeviceId, BsourceExpr> {
        &self.bsource_exprs
    }

    /// Initial conditions from `.IC`.
    pub fn initial_conditions(&self) -> &[VoltageConstraint] {
        &self.initial_conditions
    }

    /// Add a ground-referenced initial condition for a node.
    pub fn add_initial_condition(&mut self, node: NodeId, voltage: f64) {
        self.initial_conditions
            .push(VoltageConstraint::single_ended(node, voltage));
    }

    /// Add an initial condition between two nodes.
    pub fn add_differential_initial_condition(
        &mut self,
        pos_node: NodeId,
        neg_node: NodeId,
        voltage: f64,
    ) {
        self.initial_conditions
            .push(VoltageConstraint::new(pos_node, neg_node, voltage));
    }

    /// Remove all initial conditions (`.IC` entries).
    pub fn clear_initial_conditions(&mut self) {
        self.initial_conditions.clear();
    }

    /// Set (overwrite or add) a ground-referenced initial condition for a node.
    pub fn set_initial_condition(&mut self, node: NodeId, voltage: f64) {
        self.set_differential_initial_condition(node, NodeId::GROUND, voltage);
    }

    /// Set (overwrite or add) an initial condition between two nodes.
    pub fn set_differential_initial_condition(
        &mut self,
        pos_node: NodeId,
        neg_node: NodeId,
        voltage: f64,
    ) {
        if let Some(entry) = self
            .initial_conditions
            .iter_mut()
            .find(|entry| entry.pos_node == pos_node && entry.neg_node == neg_node)
        {
            entry.voltage = voltage;
        } else {
            self.initial_conditions
                .push(VoltageConstraint::new(pos_node, neg_node, voltage));
        }
    }

    /// Node-set biases from `.NODESET`.
    pub fn node_sets(&self) -> &[VoltageConstraint] {
        &self.node_sets
    }

    /// Add a ground-referenced node-set bias for a node.
    pub fn add_node_set(&mut self, node: NodeId, voltage: f64) {
        self.node_sets
            .push(VoltageConstraint::single_ended(node, voltage));
    }

    /// Add a node-set bias between two nodes.
    pub fn add_differential_node_set(&mut self, pos_node: NodeId, neg_node: NodeId, voltage: f64) {
        self.node_sets
            .push(VoltageConstraint::new(pos_node, neg_node, voltage));
    }

    /// Operating temperatures in Kelvin from `.TEMP`.
    pub fn temperatures(&self) -> &[f64] {
        &self.temperatures
    }

    /// Add an operating temperature in Kelvin.
    pub fn add_temperature(&mut self, kelvin: f64) {
        self.temperatures.push(kelvin);
    }

    /// Set the active global operating temperature in Kelvin.
    ///
    /// Replaces the first (and typically only) temperature entry, or pushes
    /// one if the list is empty.  Used by `.DC TEMP` sweeps to update the
    /// circuit temperature without referencing a named device.
    pub fn set_global_temperature(&mut self, kelvin: f64) {
        if self.temperatures.is_empty() {
            self.temperatures.push(kelvin);
        } else {
            self.temperatures[0] = kelvin;
        }
    }

    /// Return the configured temperature list, or a single fallback temperature.
    pub fn temperature_sweep_points(&self, fallback_kelvin: f64) -> SmallVec<[f64; 4]> {
        if self.temperatures.is_empty() {
            let mut out = SmallVec::new();
            out.push(fallback_kelvin);
            out
        } else {
            self.temperatures.iter().copied().collect()
        }
    }

    /// Clone the circuit with one active global temperature in Kelvin.
    pub fn clone_for_temperature(&self, kelvin: f64) -> Self {
        let mut cloned = self.clone();
        cloned.temperatures.clear();
        cloned.temperatures.push(kelvin);
        cloned.propagate_global_temperature();
        cloned
    }

    /// Mutual inductance couplings: `(id_L1, id_L2, coupling_coefficient)`.
    pub fn mutual_couplings(&self) -> &[(DeviceId, DeviceId, f64)] {
        &self.mutual_couplings
    }

    /// Register a mutual inductance coupling between two inductors.
    ///
    /// `k` must be in `(0, 1]`.
    pub fn add_mutual_coupling(&mut self, l1: DeviceId, l2: DeviceId, k: f64) {
        self.mutual_couplings.push((l1, l2, k));
    }

    /// Global node names from `.GLOBAL` directives.
    ///
    /// These names are not mangled during subcircuit expansion and are visible
    /// at the top level of the hierarchy.
    pub fn globals(&self) -> &[String] {
        &self.globals
    }

    /// Register a global node name (lowercased).
    pub fn add_global(&mut self, name: &str) {
        self.globals.push(name.to_lowercase());
    }

    /// Register a `.SUBCKT` definition.
    pub fn add_subckt_def(&mut self, def: SubcktDef) {
        self.subckt_defs.insert(def.name.clone(), def);
    }

    /// Look up a subcircuit definition by name (case-insensitive).
    pub fn find_subckt_def(&self, name: &str) -> Option<&SubcktDef> {
        self.subckt_defs.get(&name.to_lowercase())
    }

    /// Record a pending subcircuit call (X-instance) for later flattening.
    pub fn add_subckt_call(&mut self, call: SubcktCall) {
        self.subckt_calls.push(call);
    }

    /// Remove the device with the given `DeviceId` from the circuit.
    ///
    /// Also removes it from the name lookup map.  Does not renumber other
    /// device IDs — the gap in the `devices` array is left as a tombstone
    /// (the slot still exists, but the device name lookup is removed so it
    /// cannot be found by name).  Branch indices of surviving devices are
    /// unaffected.
    ///
    /// NOTE: `build_topology` must be called again after removals.
    pub fn remove_device(&mut self, id: DeviceId) {
        let idx = id.index();
        if idx >= self.devices.len() {
            return;
        }
        let name = self.devices[idx].name.to_lowercase();
        self.device_names.remove(&name);
        self.devices.remove(idx);
        // Re-number all device IDs and name map to keep them consistent.
        for (new_idx, dev) in self.devices.iter_mut().enumerate() {
            let old_id = dev.id;
            let new_id = DeviceId::new(new_idx as u32);
            if old_id != new_id {
                // Update device_names entry if it points to old_id.
                let dname = dev.name.to_lowercase();
                self.device_names.insert(dname, new_id);
                dev.id = new_id;
                // Fix branch indices in param_deps — rebuild lazily.
            }
        }
        // Rebuild param_deps from scratch since DeviceIds shifted.
        self.param_deps.clear();
        for dev in &self.devices {
            for (key, _) in dev.params.iter() {
                self.param_deps
                    .entry(ParamKey::new(key))
                    .or_default()
                    .push(dev.id);
            }
        }
    }

    /// Register a `.MODEL` entry.
    pub fn add_model(&mut self, name: &str, kind: ModelKind, params: ParamMap) {
        self.models.insert(name.to_lowercase(), (kind, params));
    }

    /// Look up a model by name.
    pub fn find_model(&self, name: &str) -> Option<&(ModelKind, ParamMap)> {
        self.models.get(&name.to_lowercase())
    }

    /// Set a global parameter (from `.PARAM`).
    pub fn set_global_param(&mut self, name: &str, value: f64) {
        self.global_params.insert(name.to_lowercase(), value);
    }

    /// Get a global parameter by name.
    pub fn get_global_param(&self, name: &str) -> Option<f64> {
        self.global_params.get(&name.to_lowercase()).copied()
    }

    /// All T-line history buffers, keyed by DeviceId.
    pub fn tline_histories(&self) -> &ahash::AHashMap<DeviceId, TlineHistory> {
        &self.tline_histories
    }

    /// Mutable access to all T-line history buffers.
    pub fn tline_histories_mut(&mut self) -> &mut ahash::AHashMap<DeviceId, TlineHistory> {
        &mut self.tline_histories
    }

    /// Register a T-line history buffer for the given device.
    pub fn add_tline_history(&mut self, id: DeviceId, history: TlineHistory) {
        self.tline_histories.insert(id, history);
    }

    /// Look up the T-line history for a device.
    pub fn tline_history(&self, id: DeviceId) -> Option<&TlineHistory> {
        self.tline_histories.get(&id)
    }

    /// Mutable look up of the T-line history for a device.
    pub fn tline_history_mut(&mut self, id: DeviceId) -> Option<&mut TlineHistory> {
        self.tline_histories.get_mut(&id)
    }

    // --- LTRA history accessors ---

    /// Register an LTRA history store for the given device.
    pub fn add_ltra_history(&mut self, id: DeviceId, store: LtraHistoryStore) {
        self.ltra_histories.insert(id, store);
    }

    /// Look up the LTRA history for a device (immutable).
    pub fn ltra_history(&self, id: DeviceId) -> Option<&LtraHistoryStore> {
        self.ltra_histories.get(&id)
    }

    /// Look up the LTRA history for a device (mutable).
    pub fn ltra_history_mut(&mut self, id: DeviceId) -> Option<&mut LtraHistoryStore> {
        self.ltra_histories.get_mut(&id)
    }

    // --- Digital spec accessors ---

    /// Set the digital (XSPICE) sub-system specification.
    pub fn set_digital_spec(&mut self, spec: DigitalNetSpec) {
        self.digital_spec = Some(spec);
    }

    /// Borrow the digital sub-system specification, if any.
    pub fn digital_spec(&self) -> Option<&DigitalNetSpec> {
        self.digital_spec.as_ref()
    }

    /// Take the digital spec out (consumes it from the circuit).
    pub fn take_digital_spec(&mut self) -> Option<DigitalNetSpec> {
        self.digital_spec.take()
    }

    /// Add an internal (synthetic) node for a device, named `<device_id>.<suffix>`.
    ///
    /// Used by device models that need to insert internal nodes for extrinsic
    /// elements (e.g. BJT base/emitter/collector series resistances RB/RE/RC,
    /// VBIC rcx/rci/rbx/rbi/re/rs/rbp).  The name is deterministic so that
    /// calling this twice with the same arguments returns the same NodeId.
    pub fn add_internal_node(&mut self, device_name: &str, suffix: &str) -> NodeId {
        let name = format!("_{device_name}_{suffix}");
        self.add_node(&name)
    }

    /// Add or get a node by name. Returns the NodeId.
    pub fn add_node(&mut self, name: &str) -> NodeId {
        let lower = name.to_lowercase();
        if lower == "0" || lower == "gnd" {
            return NodeId::GROUND;
        }
        if let Some(&id) = self.node_names.get(&lower) {
            return id;
        }
        let id = NodeId::new(self.nodes.len() as u32);
        let node = Node::new(id, &lower);
        self.node_names.insert(lower, id);
        self.nodes.push(node);
        self.num_vars = (self.nodes.len() as u32) - 1; // exclude ground
        id
    }

    /// Add a device to the circuit.
    pub fn add_device(&mut self, mut device: DeviceInstance) -> DeviceId {
        let id = DeviceId::new(self.devices.len() as u32);
        device.id = id;

        // Assign branch index if needed.
        // T-lines need TWO branch variables (one per port); branch_index points
        // to the first (port-1), and port-2 uses branch_index + 1 implicitly.
        if device.needs_branch() {
            device.branch_index = Some(self.num_branches);
            if device.kind == DeviceKind::Tline {
                self.num_branches += 2;
            } else {
                self.num_branches += 1;
            }
        }

        // Register name.
        self.device_names.insert(device.name.to_lowercase(), id);

        // Track parameter dependencies.
        for (key, _) in device.params.iter() {
            self.param_deps
                .entry(ParamKey::new(key))
                .or_default()
                .push(id);
        }

        self.devices.push(device);
        id
    }

    /// Look up a node by name.
    pub fn find_node(&self, name: &str) -> Option<NodeId> {
        self.node_names.get(&name.to_lowercase()).copied()
    }

    /// Look up a device by name.
    pub fn find_device(&self, name: &str) -> Option<&DeviceInstance> {
        self.device_names
            .get(&name.to_lowercase())
            .map(|id| &self.devices[id.index()])
    }

    /// Look up a device by name (case-insensitive), returning a mutable reference.
    pub fn find_device_mut(&mut self, name: &str) -> Option<&mut DeviceInstance> {
        self.device_names
            .get(&name.to_lowercase())
            .copied()
            .map(|id| &mut self.devices[id.index()])
    }

    /// Look up a DeviceId by device name (case-insensitive).
    ///
    /// Returns `None` if no device with that name exists.  Intended for use by
    /// post-parse passes (e.g. subcircuit flattening) that need the raw ID.
    pub fn find_device_id(&self, name: &str) -> Option<DeviceId> {
        self.device_names.get(&name.to_lowercase()).copied()
    }

    /// Build the compressed topology graph from current devices.
    pub fn build_topology(&mut self) {
        let mut connections = Vec::new();
        for dev in &self.devices {
            for term in &dev.terminals {
                connections.push((term.node, dev.id));
            }
        }
        self.topology = Some(CompressedGraph::from_connections(
            self.nodes.len() as u32,
            self.devices.len() as u32,
            &connections,
        ));
    }

    /// Get all devices of a specific kind.
    pub fn devices_of_kind(&self, kind: DeviceKind) -> impl Iterator<Item = &DeviceInstance> {
        self.devices.iter().filter(move |d| d.kind == kind)
    }

    /// Merge `net_b` into `net_a`: all devices that reference `net_b` are
    /// updated to use `net_a` instead.  The `net_b` node entry is removed.
    /// Does nothing if either name is not found or they are already the same.
    pub fn connect_nets(&mut self, net_a: &str, net_b: &str) {
        let id_a = match self
            .nodes
            .iter()
            .find(|n| n.name.eq_ignore_ascii_case(net_a))
        {
            Some(n) => n.id,
            None => return,
        };
        let id_b = match self
            .nodes
            .iter()
            .find(|n| n.name.eq_ignore_ascii_case(net_b))
        {
            Some(n) => n.id,
            None => return,
        };
        if id_a == id_b {
            return;
        }
        // Replace all terminal references to id_b with id_a in every device.
        for dev in &mut self.devices {
            for term in &mut dev.terminals {
                if term.node == id_b {
                    term.node = id_a;
                }
            }
        }
        // Remove the now-unused node from the name lookup and node list.
        self.node_names.retain(|_, v| *v != id_b);
        self.nodes.retain(|n| n.id != id_b);
        // Recompute num_vars (exclude ground node at index 0).
        self.num_vars = (self.nodes.len() as u32).saturating_sub(1);
    }

    /// Propagate the global operating temperature to all devices that do not
    /// have an explicit instance-level `"temp"` parameter.
    ///
    /// The global temperature is taken from the first entry of `temperatures`
    /// (set by `.TEMP` or `.OPTIONS TEMP`, converted to Kelvin at parse time).
    /// Devices that already carry their own `"temp"` param are left untouched
    /// so that per-instance temperature overrides are honoured.
    ///
    /// This must be called after parsing and before stamping, once per analysis
    /// run.  Call it again after each temperature sweep step if the global
    /// temperature is updated.
    pub fn propagate_global_temperature(&mut self) {
        let global_temp_k = match self.temperatures.first() {
            Some(&t) => t,
            None => return, // No global temperature set; leave device defaults intact.
        };
        for dev in &mut self.devices {
            if !dev.params.contains("temp") {
                dev.params.set("temp", global_temp_k);
            }
        }
    }

    /// Validate that all devices which require a branch index have one assigned.
    ///
    /// Call this after building the circuit and before stamping to catch
    /// devices that were constructed without going through `add_device`
    /// (which is the only path that assigns branch indices).
    ///
    /// Returns `Err(SimError::MissingBranchIndex)` for the first device found
    /// that needs a branch variable but has `branch_index = None`.
    pub fn validate(&self) -> Result<(), SimError> {
        for device in self.devices() {
            if device.needs_branch() && device.branch_index.is_none() {
                return Err(SimError::MissingBranchIndex {
                    device: device.name.clone(),
                });
            }
        }
        Ok(())
    }

    /// Find nodes that lack a DC path to ground.
    ///
    /// A node has a DC path to ground if it can reach ground through devices
    /// that conduct at DC (resistors, voltage sources, inductors, active
    /// devices, switches, transmission lines, etc.).  Capacitors do **not**
    /// provide a DC path.
    ///
    /// Returns the list of `NodeId`s that are isolated from ground at DC.
    /// For DC analysis the caller should add GMIN shunt conductances on these
    /// nodes (matching ngspice behaviour) and emit a warning.  For AC and
    /// transient analyses capacitor-only paths are valid — the caller should
    /// skip this check.
    pub fn nodes_without_dc_path(&self) -> Vec<NodeId> {
        // BFS from ground through DC-conducting devices.
        let num = self.nodes.len();
        let mut visited = vec![false; num];
        visited[NodeId::GROUND.index()] = true;
        let mut queue = std::collections::VecDeque::new();
        queue.push_back(NodeId::GROUND);

        while let Some(node) = queue.pop_front() {
            // Iterate over all devices; for each device that is DC-conducting
            // and touches `node`, mark the other terminal nodes reachable.
            for dev in &self.devices {
                if !Self::is_dc_conducting(dev.kind) {
                    continue;
                }
                let touches = dev.terminals.iter().any(|t| t.node == node);
                if !touches {
                    continue;
                }
                for t in &dev.terminals {
                    if !t.node.is_ground() && !visited[t.node.index()] {
                        visited[t.node.index()] = true;
                        queue.push_back(t.node);
                    }
                }
            }
        }

        // Collect non-ground nodes that were never reached.
        self.nodes
            .iter()
            .filter(|n| !n.id.is_ground() && !visited[n.id.index()])
            .map(|n| n.id)
            .collect()
    }

    /// Whether a device kind conducts at DC (i.e. provides a resistive /
    /// short-circuit path rather than an open circuit like a capacitor).
    fn is_dc_conducting(kind: DeviceKind) -> bool {
        !matches!(kind, DeviceKind::Capacitor)
    }

    /// Set a parameter on a device by name and rebuild param deps.
    pub fn set_device_param(&mut self, device_name: &str, param: &str, value: f64) -> bool {
        let lower = device_name.to_lowercase();
        if let Some(&id) = self.device_names.get(&lower) {
            let dev = &mut self.devices[id.index()];
            dev.params.set(param, value);
            self.param_deps
                .entry(ParamKey::new(param))
                .or_default()
                .push(id);
            true
        } else {
            false
        }
    }
}

impl Default for Circuit {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::DeviceKind;

    fn simple_resistor_circuit() -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");

        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        )
        .with_param("resistance", 1e3);

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);

        ckt.add_device(r1);
        ckt.add_device(v1);
        ckt.build_topology();
        ckt
    }

    #[test]
    fn circuit_creation() {
        let ckt = simple_resistor_circuit();
        assert_eq!(ckt.nodes().len(), 3); // GND + n1 + n2
        assert_eq!(ckt.devices().len(), 2);
        assert_eq!(ckt.num_vars(), 2);
        assert_eq!(ckt.num_branches(), 1); // V1
        assert_eq!(ckt.mna_dimension(), 3); // 2 nodes + 1 branch
    }

    #[test]
    fn find_node_and_device() {
        let ckt = simple_resistor_circuit();
        assert_eq!(ckt.find_node("1"), Some(NodeId::new(1)));
        assert_eq!(ckt.find_node("gnd"), Some(NodeId::GROUND));
        assert!(ckt.find_device("R1").is_some());
        assert!(ckt.find_device("V1").is_some());
        assert!(ckt.find_device("R99").is_none());
    }

    #[test]
    fn topology_graph() {
        let ckt = simple_resistor_circuit();
        let topo = ckt.topology().unwrap();
        assert!(topo.nnz() > 0);
        // Node 1 is connected to R1 and V1
        assert_eq!(topo.devices_at(NodeId::new(1)).len(), 2);
    }

    #[test]
    fn mna_dimension_with_branches() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        // Two voltage sources = 2 branches
        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        );
        let v2 = DeviceInstance::new(
            DeviceId::new(0),
            "V2",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        );
        ckt.add_device(v1);
        ckt.add_device(v2);
        assert_eq!(ckt.mna_dimension(), 3); // 1 node + 2 branches
    }

    #[test]
    fn set_param_updates() {
        let mut ckt = simple_resistor_circuit();
        assert!(ckt.set_device_param("R1", "resistance", 2e3));
        assert_eq!(
            ckt.find_device("R1").unwrap().params.get("resistance"),
            Some(2e3)
        );
    }

    #[test]
    fn validate_ok_when_branch_indices_assigned() {
        // simple_resistor_circuit uses add_device which assigns branch indices.
        let ckt = simple_resistor_circuit();
        assert!(ckt.validate().is_ok());
    }

    #[test]
    fn validate_err_when_branch_index_missing() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V_missing",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        );
        // Add via add_device (assigns branch_index), then manually clear it
        // to simulate a device that somehow lost its branch_index assignment.
        let id = ckt.add_device(v1);
        // Now manually clear the branch_index to simulate the error condition.
        if let Some(dev) = ckt.devices.iter_mut().find(|d| d.id == id) {
            dev.branch_index = None;
        }
        let result = ckt.validate();
        assert!(result.is_err());
        let err_msg = format!("{}", result.unwrap_err());
        assert!(err_msg.contains("V_missing"), "error should name the device");
    }

    // -----------------------------------------------------------------------
    // connect_nets tests (TODO §11)
    // -----------------------------------------------------------------------

    #[test]
    fn test_connect_nets_basic() {
        // Build: two nodes n1, n2, one resistor across them.
        // After connect_nets("1", "2") the resistor terminals should both be n1.
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        let r = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        )
        .with_param("resistance", 1e3);
        ckt.add_device(r);
        assert_eq!(ckt.num_vars(), 2); // n1 and n2

        ckt.connect_nets("1", "2");

        // n2 should have been merged into n1 (or vice versa).
        // The surviving node for the terminal at position 1 should now equal the
        // surviving node at position 0 — both terminals point to the same node.
        let dev = ckt.find_device("R1").unwrap();
        assert_eq!(dev.terminals[0].node, dev.terminals[1].node,
            "after merging nets both terminals should reference the same NodeId");

        // num_vars should drop by 1.
        assert_eq!(ckt.num_vars(), 1, "merging two nodes should reduce num_vars by 1");
    }

    #[test]
    fn test_connect_nets_self_merge() {
        // Connecting a net to itself should be a no-op.
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        let r = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        )
        .with_param("resistance", 1e3);
        ckt.add_device(r);
        let vars_before = ckt.num_vars();

        ckt.connect_nets("1", "1"); // same net — should be a no-op

        assert_eq!(ckt.num_vars(), vars_before,
            "self-merge must not change num_vars");
        let dev = ckt.find_device("R1").unwrap();
        assert_eq!(dev.terminals[0].node, n1);
        assert_eq!(dev.terminals[1].node, n2);
    }

    #[test]
    fn test_connect_nets_num_vars_updated() {
        // After merging, num_vars must be recomputed.
        let mut ckt = Circuit::new();
        let na = ckt.add_node("a");
        let nb = ckt.add_node("b");
        let nc = ckt.add_node("c");

        // Resistor chain: R1(a–b), R2(b–c).
        let r1 = DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, na), (1, nb)]).with_param("resistance", 1e3);
        let r2 = DeviceInstance::new(DeviceId::new(1), "R2", DeviceKind::Resistor,
            &[(0, nb), (1, nc)]).with_param("resistance", 1e3);
        ckt.add_device(r1);
        ckt.add_device(r2);
        assert_eq!(ckt.num_vars(), 3); // a, b, c

        ckt.connect_nets("b", "c"); // merge b and c

        assert_eq!(ckt.num_vars(), 2,
            "merging b and c should leave num_vars=2 (a + surviving node)");
    }

    // -----------------------------------------------------------------------
    // T-line interpolation tests (TODO §12)
    // -----------------------------------------------------------------------

    #[test]
    fn test_tline_interpolate_empty() {
        // An empty sample slice must return 0.0 (quiescent assumption).
        let result = TlineHistory::interpolate(&[], 1.0);
        assert_eq!(result, 0.0, "empty samples → 0.0");
    }

    #[test]
    fn test_tline_interpolate_exact_match() {
        // A single stored sample at t=1.0 with E=3.7; querying exactly t=1.0
        // should return 3.7.
        let samples = vec![(1.0_f64, 3.7_f64)];
        let result = TlineHistory::interpolate(&samples, 1.0);
        // t == samples[0].0 is treated as "before" the first sample per the
        // causal boundary (target_time <= pts[0].0 → 0.0).  Querying beyond it:
        let result_after = TlineHistory::interpolate(&samples, 1.5);
        assert_eq!(result_after, 3.7, "past last sample returns last sample value");
        // Also verify the causal boundary at/before the first sample:
        assert_eq!(result, 0.0, "at exactly the first sample time returns 0.0 (causal)");
    }

    #[test]
    fn test_tline_interpolate_linear() {
        // Two samples: (0.0, 0.0) and (1.0, 10.0).
        // At t=0.5 the interpolation should give 5.0.
        let samples = vec![(0.0_f64, 0.0_f64), (1.0_f64, 10.0_f64)];
        let result = TlineHistory::interpolate(&samples, 0.5);
        assert!((result - 5.0).abs() < 1e-10, "linear interp at t=0.5 → 5.0, got {result}");
    }

    #[test]
    fn test_tline_history_ring_buffer_wraparound() {
        // Push 1000 samples into a buffer with capacity 16; the ring should
        // wrap without panic, and the stored samples should all have timestamps
        // from the tail of the sequence (we don't assert exact values, just
        // that no out-of-bounds access occurs).
        let mut hist = TlineHistory::new(50.0, 1e-9, 16);
        for i in 0..1000_u32 {
            let t = i as f64 * 1e-12;
            let e = i as f64 * 0.001;
            hist.push_p1(t, e);
            hist.push_p2(t, -e);
        }
        // Buffer capacity should still equal its original size.
        assert_eq!(hist.samples_p1.len(), 16);
        assert_eq!(hist.samples_p2.len(), 16);
        // Head pointer should have wrapped around — it lives in [0, cap).
        assert!(hist.head_p1 < hist.samples_p1.len());
        assert!(hist.head_p2 < hist.samples_p2.len());
    }

    #[test]
    fn test_add_node_dedup() {
        let mut c = Circuit::new();
        let n1 = c.add_node("vdd");
        let n2 = c.add_node("vdd"); // same name
        assert_eq!(n1, n2, "same name should return same NodeId");
    }

    #[test]
    fn test_global_param_set_get() {
        let mut c = Circuit::new();
        c.set_global_param("vdd", 3.3);
        let v = c.global_params.get("vdd").copied();
        assert_eq!(v, Some(3.3));
    }

    #[test]
    fn test_initial_condition_add_retrieve() {
        let mut c = Circuit::new();
        let n = c.add_node("out");
        c.add_initial_condition(n, 1.8);
        let ics = c.initial_conditions();
        assert_eq!(ics.len(), 1);
        assert!((ics[0].voltage - 1.8).abs() < 1e-10);
    }

    #[test]
    fn test_nodeset_add_retrieve() {
        let mut c = Circuit::new();
        let n = c.add_node("bias");
        c.add_node_set(n, 2.5);
        let sets = c.node_sets();
        assert_eq!(sets.len(), 1);
        assert!((sets[0].voltage - 2.5).abs() < 1e-10);
    }

    #[test]
    fn test_find_node_by_name() {
        let mut c = Circuit::new();
        let n = c.add_node("internal");
        let found = c.find_node("internal");
        assert_eq!(found, Some(n));
        assert!(c.find_node("missing").is_none());
    }

    #[test]
    fn test_add_node_returns_ground_for_zero_and_gnd() {
        let mut c = Circuit::new();
        assert_eq!(c.add_node("0"), NodeId::GROUND);
        assert_eq!(c.add_node("gnd"), NodeId::GROUND);
        assert_eq!(c.add_node("GND"), NodeId::GROUND);
    }

    #[test]
    fn test_num_vars_increments_per_unique_node() {
        let mut c = Circuit::new();
        assert_eq!(c.num_vars(), 0);
        c.add_node("a");
        assert_eq!(c.num_vars(), 1);
        c.add_node("b");
        assert_eq!(c.num_vars(), 2);
        // Duplicate does not increment.
        c.add_node("a");
        assert_eq!(c.num_vars(), 2);
    }

    #[test]
    fn test_add_device_assigns_branch_for_vsource() {
        let mut c = Circuit::new();
        let n1 = c.add_node("n1");
        let v = DeviceInstance::new(
            DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        );
        c.add_device(v);
        assert_eq!(c.num_branches(), 1);
        // branch_index of the added device must be 0.
        assert_eq!(c.devices()[0].branch_index, Some(0));
    }

    #[test]
    fn test_add_device_no_branch_for_resistor() {
        let mut c = Circuit::new();
        let n1 = c.add_node("n1");
        let r = DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        );
        c.add_device(r);
        assert_eq!(c.num_branches(), 0);
        assert_eq!(c.devices()[0].branch_index, None);
    }

    #[test]
    fn test_tline_two_branches() {
        let mut c = Circuit::new();
        let n1 = c.add_node("n1");
        let n2 = c.add_node("n2");
        let t = DeviceInstance::new(
            DeviceId::new(0), "T1", DeviceKind::Tline,
            &[(0, n1), (1, NodeId::GROUND), (2, n2), (3, NodeId::GROUND)],
        );
        c.add_device(t);
        // T-lines consume 2 branch variables.
        assert_eq!(c.num_branches(), 2);
    }

    #[test]
    fn test_mna_dimension_equals_vars_plus_branches() {
        let ckt = simple_resistor_circuit();
        assert_eq!(
            ckt.mna_dimension(),
            (ckt.num_vars() + ckt.num_branches()) as usize
        );
    }

    #[test]
    fn test_find_device_case_insensitive() {
        let ckt = simple_resistor_circuit();
        assert!(ckt.find_device("r1").is_some());
        assert!(ckt.find_device("R1").is_some());
        assert!(ckt.find_device("v1").is_some());
    }

    #[test]
    fn test_find_device_id_by_name() {
        let ckt = simple_resistor_circuit();
        let id = ckt.find_device_id("R1");
        assert!(id.is_some());
        let dev = ckt.find_device("R1").unwrap();
        assert_eq!(dev.id, id.unwrap());
    }

    #[test]
    fn test_devices_of_kind_filters_correctly() {
        let ckt = simple_resistor_circuit();
        let resistors: Vec<_> = ckt.devices_of_kind(DeviceKind::Resistor).collect();
        let vsources: Vec<_> = ckt.devices_of_kind(DeviceKind::VoltageSource).collect();
        let capacitors: Vec<_> = ckt.devices_of_kind(DeviceKind::Capacitor).collect();
        assert_eq!(resistors.len(), 1);
        assert_eq!(vsources.len(), 1);
        assert_eq!(capacitors.len(), 0);
    }

    #[test]
    fn test_global_params_case_insensitive() {
        let mut c = Circuit::new();
        c.set_global_param("VDD", 3.3);
        assert_eq!(c.get_global_param("vdd"), Some(3.3));
        assert_eq!(c.get_global_param("VDD"), Some(3.3));
        assert!(c.get_global_param("VSS").is_none());
    }

    #[test]
    fn test_add_temperature_and_sweep() {
        let mut c = Circuit::new();
        c.add_temperature(300.0);
        c.add_temperature(350.0);
        assert_eq!(c.temperatures(), &[300.0, 350.0]);
        let pts = c.temperature_sweep_points(27.0);
        assert_eq!(pts.as_slice(), &[300.0, 350.0]);
    }

    #[test]
    fn test_temperature_sweep_fallback_when_empty() {
        let c = Circuit::new();
        let pts = c.temperature_sweep_points(300.15);
        assert_eq!(pts.as_slice(), &[300.15]);
    }

    #[test]
    fn test_set_global_temperature_updates_first_entry() {
        let mut c = Circuit::new();
        c.add_temperature(300.0);
        c.set_global_temperature(350.0);
        assert_eq!(c.temperatures()[0], 350.0);
        assert_eq!(c.temperatures().len(), 1);
    }

    #[test]
    fn test_set_global_temperature_pushes_when_empty() {
        let mut c = Circuit::new();
        c.set_global_temperature(400.0);
        assert_eq!(c.temperatures(), &[400.0]);
    }

    #[test]
    fn test_add_and_clear_initial_conditions() {
        let mut c = Circuit::new();
        let n = c.add_node("out");
        c.add_initial_condition(n, 1.8);
        assert_eq!(c.initial_conditions().len(), 1);
        c.clear_initial_conditions();
        assert!(c.initial_conditions().is_empty());
    }

    #[test]
    fn test_set_initial_condition_overwrites_existing() {
        let mut c = Circuit::new();
        let n = c.add_node("x");
        c.add_initial_condition(n, 1.0);
        c.set_initial_condition(n, 2.5);
        let ics = c.initial_conditions();
        assert_eq!(ics.len(), 1, "set must overwrite, not append");
        assert!((ics[0].voltage - 2.5).abs() < 1e-12);
    }

    #[test]
    fn test_differential_initial_condition() {
        let mut c = Circuit::new();
        let pos = c.add_node("pos");
        let neg = c.add_node("neg");
        c.add_differential_initial_condition(pos, neg, 0.7);
        let ics = c.initial_conditions();
        assert_eq!(ics.len(), 1);
        assert_eq!(ics[0].pos_node, pos);
        assert_eq!(ics[0].neg_node, neg);
        assert!((ics[0].voltage - 0.7).abs() < 1e-12);
    }

    #[test]
    fn test_differential_node_set() {
        let mut c = Circuit::new();
        let pos = c.add_node("pos");
        let neg = c.add_node("neg");
        c.add_differential_node_set(pos, neg, 1.2);
        let ns = c.node_sets();
        assert_eq!(ns.len(), 1);
        assert_eq!(ns[0].pos_node, pos);
        assert_eq!(ns[0].neg_node, neg);
    }

    #[test]
    fn test_add_model_and_find() {
        let mut c = Circuit::new();
        let mut pm = crate::param::ParamMap::new();
        pm.set("is", 1e-14);
        c.add_model("dm1", ModelKind::Diode, pm);
        let found = c.find_model("DM1");
        assert!(found.is_some());
        let (kind, params) = found.unwrap();
        assert_eq!(*kind, ModelKind::Diode);
        assert_eq!(params.get("is"), Some(1e-14));
    }

    #[test]
    fn test_model_kind_from_str_all_variants() {
        assert_eq!(ModelKind::from_str("nmos"), ModelKind::Nmos);
        assert_eq!(ModelKind::from_str("PMOS"), ModelKind::Pmos);
        assert_eq!(ModelKind::from_str("NPN"), ModelKind::Npn);
        assert_eq!(ModelKind::from_str("pnp"), ModelKind::Pnp);
        assert_eq!(ModelKind::from_str("D"), ModelKind::Diode);
        assert_eq!(ModelKind::from_str("R"), ModelKind::Resistor);
        assert_eq!(ModelKind::from_str("C"), ModelKind::Capacitor);
        assert_eq!(ModelKind::from_str("unknown"),
            ModelKind::Other("unknown".into()));
    }

    #[test]
    fn test_mutual_coupling_stored() {
        let mut c = Circuit::new();
        let n = c.add_node("n");
        let l1 = c.add_device(DeviceInstance::new(
            DeviceId::new(0), "L1", DeviceKind::Inductor,
            &[(0, n), (1, NodeId::GROUND)],
        ));
        let l2 = c.add_device(DeviceInstance::new(
            DeviceId::new(1), "L2", DeviceKind::Inductor,
            &[(0, n), (1, NodeId::GROUND)],
        ));
        c.add_mutual_coupling(l1, l2, 0.8);
        let mc = c.mutual_couplings();
        assert_eq!(mc.len(), 1);
        assert_eq!(mc[0].0, l1);
        assert_eq!(mc[0].1, l2);
        assert!((mc[0].2 - 0.8).abs() < 1e-12);
    }

    #[test]
    fn test_add_global_stores_lowercase() {
        let mut c = Circuit::new();
        c.add_global("VDD");
        c.add_global("gnd");
        assert!(c.globals().contains(&"vdd".to_string()));
        assert!(c.globals().contains(&"gnd".to_string()));
    }

    #[test]
    fn test_voltage_constraint_new_and_single_ended() {
        let n1 = NodeId::new(1);
        let diff = VoltageConstraint::new(n1, NodeId::new(2), 1.5);
        assert_eq!(diff.pos_node, n1);
        assert_eq!(diff.neg_node, NodeId::new(2));
        assert!((diff.voltage - 1.5).abs() < 1e-12);

        let se = VoltageConstraint::single_ended(n1, 3.3);
        assert_eq!(se.pos_node, n1);
        assert_eq!(se.neg_node, NodeId::GROUND);
        assert!((se.voltage - 3.3).abs() < 1e-12);
    }

    #[test]
    fn test_ltra_history_store_push_and_len() {
        let mut store = LtraHistoryStore::with_capacity(16);
        assert!(store.is_empty());
        store.push(1e-9, 1.0, 2.0, 0.1, 0.2);
        store.push(2e-9, 1.5, 2.5, 0.15, 0.25);
        assert_eq!(store.len(), 2);
        assert!(!store.is_empty());
        assert_eq!(store.times[0], 1e-9);
        assert_eq!(store.v1[1], 1.5);
    }

    #[test]
    fn test_tline_history_min_capacity_is_four() {
        // Even with capacity=0 requested, the buffer enforces a minimum of 4.
        let hist = TlineHistory::new(50.0, 1e-9, 0);
        assert_eq!(hist.samples_p1.len(), 4);
        assert_eq!(hist.samples_p2.len(), 4);
    }

    #[test]
    fn test_remove_device_reduces_count() {
        let mut c = Circuit::new();
        let n1 = c.add_node("n1");
        let n2 = c.add_node("n2");
        let id_r = c.add_device(DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        ));
        c.add_device(DeviceInstance::new(
            DeviceId::new(1), "R2", DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        ));
        assert_eq!(c.devices().len(), 2);
        c.remove_device(id_r);
        assert_eq!(c.devices().len(), 1);
        assert!(c.find_device("R1").is_none());
        assert!(c.find_device("R2").is_some());
    }

    #[test]
    fn test_set_device_param_returns_false_for_missing_device() {
        let mut c = Circuit::new();
        let updated = c.set_device_param("doesnotexist", "r", 1.0);
        assert!(!updated);
    }

    #[test]
    fn test_build_topology_sets_topology() {
        let ckt = simple_resistor_circuit();
        assert!(ckt.topology().is_some());
    }

    #[test]
    fn test_circuit_default_has_ground_node() {
        let c = Circuit::default();
        assert_eq!(c.nodes().len(), 1); // just ground
        assert_eq!(c.find_node("0"), Some(NodeId::GROUND));
    }

    #[test]
    fn test_propagate_global_temperature_sets_device_temp() {
        let mut c = Circuit::new();
        let n = c.add_node("n");
        c.add_device(DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n), (1, NodeId::GROUND)],
        ));
        c.add_temperature(350.0);
        c.propagate_global_temperature();
        let r = c.find_device("R1").unwrap();
        assert_eq!(r.params.get("temp"), Some(350.0));
    }

    #[test]
    fn test_propagate_global_temperature_respects_per_instance_temp() {
        let mut c = Circuit::new();
        let n = c.add_node("n");
        let mut r = DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n), (1, NodeId::GROUND)],
        );
        r.params.set("temp", 400.0); // per-instance override
        c.add_device(r);
        c.add_temperature(350.0);
        c.propagate_global_temperature();
        // The per-instance temp should remain 400 K.
        let r1 = c.find_device("R1").unwrap();
        assert_eq!(r1.params.get("temp"), Some(400.0));
    }

    #[test]
    fn test_add_internal_node_deterministic() {
        let mut c = Circuit::new();
        let n1 = c.add_internal_node("q1", "base");
        let n2 = c.add_internal_node("q1", "base");
        assert_eq!(n1, n2, "same device/suffix must return same node");
    }

    #[test]
    fn test_digital_spec_set_and_take() {
        let mut c = Circuit::new();
        assert!(c.digital_spec().is_none());
        let spec = DigitalNetSpec {
            num_dig_nodes: 4,
            ..Default::default()
        };
        c.set_digital_spec(spec);
        assert!(c.digital_spec().is_some());
        let taken = c.take_digital_spec();
        assert!(taken.is_some());
        assert_eq!(taken.unwrap().num_dig_nodes, 4);
        assert!(c.digital_spec().is_none());
    }

    #[test]
    fn nodes_without_dc_path_all_connected() {
        // R1: n1-GND, V1: n1-n2 → both nodes have DC path to ground.
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        ckt.add_device(DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        ));
        ckt.add_device(DeviceInstance::new(
            DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, n2)],
        ));
        assert!(ckt.nodes_without_dc_path().is_empty());
    }

    #[test]
    fn nodes_without_dc_path_cap_only() {
        // C1: n1-GND, R1: n2-GND → n1 has no DC path (only cap to ground).
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        ckt.add_device(DeviceInstance::new(
            DeviceId::new(0), "C1", DeviceKind::Capacitor,
            &[(0, n1), (1, NodeId::GROUND)],
        ));
        ckt.add_device(DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n2), (1, NodeId::GROUND)],
        ));
        let floating = ckt.nodes_without_dc_path();
        assert_eq!(floating.len(), 1);
        assert_eq!(floating[0], n1);
    }

    #[test]
    fn nodes_without_dc_path_cap_chain() {
        // V1: n1-GND, C1: n1-n2 → n2 has no DC path (connected via cap only).
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        ckt.add_device(DeviceInstance::new(
            DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        ));
        ckt.add_device(DeviceInstance::new(
            DeviceId::new(0), "C1", DeviceKind::Capacitor,
            &[(0, n1), (1, n2)],
        ));
        let floating = ckt.nodes_without_dc_path();
        assert_eq!(floating.len(), 1);
        assert_eq!(floating[0], n2);
    }

    #[test]
    fn nodes_without_dc_path_cap_plus_resistor_ok() {
        // C1: n1-n2, R1: n1-GND, R2: n2-GND → both have DC path.
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        ckt.add_device(DeviceInstance::new(
            DeviceId::new(0), "C1", DeviceKind::Capacitor,
            &[(0, n1), (1, n2)],
        ));
        ckt.add_device(DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        ));
        ckt.add_device(DeviceInstance::new(
            DeviceId::new(0), "R2", DeviceKind::Resistor,
            &[(0, n2), (1, NodeId::GROUND)],
        ));
        assert!(ckt.nodes_without_dc_path().is_empty());
    }
}
