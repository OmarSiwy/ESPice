use crate::device::{DeviceId, DeviceInstance, DeviceKind};
use crate::expr::BsourceExpr;
use crate::graph::CompressedGraph;
use crate::node::{Node, NodeId};
use crate::param::ParamKey;
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
            return pts[0].1;
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
    /// Port-1 axial current at each sample.
    pub i1: Vec<f64>,
    /// Port-2 axial current at each sample.
    pub i2: Vec<f64>,
}

impl LtraHistoryStore {
    /// Create a new empty store with pre-allocated capacity.
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            times: Vec::with_capacity(cap),
            v1:    Vec::with_capacity(cap),
            v2:    Vec::with_capacity(cap),
            i1:    Vec::with_capacity(cap),
            i2:    Vec::with_capacity(cap),
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
    pub fn len(&self) -> usize { self.times.len() }

    /// Whether no samples have been stored yet.
    #[inline]
    pub fn is_empty(&self) -> bool { self.times.is_empty() }
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
    /// `.IC v(node)=value` pairs: (NodeId, voltage).
    ///
    /// These force node voltages during the DC OP that precedes a transient.
    initial_conditions: Vec<(NodeId, f64)>,

    // --- Solver initial-guess biases ---
    /// `.NODESET v(node)=value` pairs: (NodeId, voltage).
    ///
    /// These bias the Newton solver starting point but do not force final values.
    node_sets: Vec<(NodeId, f64)>,

    // --- Operating temperatures ---
    /// `.TEMP t1 [t2 ...]` — operating temperatures in Celsius.
    ///
    /// Multiple entries drive multi-temperature sweeps.
    /// Stored in Celsius; convert to Kelvin by adding 273.15.
    ///
    /// TODO(phase-1.3): drive multi-temp sweep from this list.
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
            ac_stimuli: Vec::new(),
            bsource_exprs: AHashMap::new(),
            initial_conditions: Vec::new(),
            node_sets: Vec::new(),
            temperatures: Vec::new(),
            mutual_couplings: Vec::new(),
            globals: Vec::new(),
            tline_histories: AHashMap::new(),
            ltra_histories: AHashMap::new(),
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

    /// Initial conditions from `.IC` — (NodeId, forced voltage).
    pub fn initial_conditions(&self) -> &[(NodeId, f64)] {
        &self.initial_conditions
    }

    /// Add an initial condition for a node.
    pub fn add_initial_condition(&mut self, node: NodeId, voltage: f64) {
        self.initial_conditions.push((node, voltage));
    }

    /// Remove all initial conditions (`.IC` entries).
    pub fn clear_initial_conditions(&mut self) {
        self.initial_conditions.clear();
    }

    /// Set (overwrite or add) an initial condition for a node.
    pub fn set_initial_condition(&mut self, node: NodeId, voltage: f64) {
        if let Some(entry) = self.initial_conditions.iter_mut().find(|(n, _)| *n == node) {
            entry.1 = voltage;
        } else {
            self.initial_conditions.push((node, voltage));
        }
    }

    /// Node-set biases from `.NODESET` — (NodeId, hint voltage).
    pub fn node_sets(&self) -> &[(NodeId, f64)] {
        &self.node_sets
    }

    /// Add a node-set bias for a node.
    pub fn add_node_set(&mut self, node: NodeId, voltage: f64) {
        self.node_sets.push((node, voltage));
    }

    /// Operating temperatures in Celsius from `.TEMP`.
    ///
    /// Convert to Kelvin by adding 273.15 before use in device models.
    pub fn temperatures(&self) -> &[f64] {
        &self.temperatures
    }

    /// Add an operating temperature (in Celsius).
    pub fn add_temperature(&mut self, celsius: f64) {
        self.temperatures.push(celsius);
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
        let id_a = match self.nodes.iter().find(|n| n.name.eq_ignore_ascii_case(net_a)) {
            Some(n) => n.id,
            None => return,
        };
        let id_b = match self.nodes.iter().find(|n| n.name.eq_ignore_ascii_case(net_b)) {
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
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        ).with_param("resistance", 1e3);

        let v1 = DeviceInstance::new(
            DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        ).with_param("dc", 5.0);

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
        let v1 = DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource, &[(0, n1), (1, NodeId::GROUND)]);
        let v2 = DeviceInstance::new(DeviceId::new(0), "V2", DeviceKind::VoltageSource, &[(0, n1), (1, NodeId::GROUND)]);
        ckt.add_device(v1);
        ckt.add_device(v2);
        assert_eq!(ckt.mna_dimension(), 3); // 1 node + 2 branches
    }

    #[test]
    fn set_param_updates() {
        let mut ckt = simple_resistor_circuit();
        assert!(ckt.set_device_param("R1", "resistance", 2e3));
        assert_eq!(ckt.find_device("R1").unwrap().params.get("resistance"), Some(2e3));
    }
}
