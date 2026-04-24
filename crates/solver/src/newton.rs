use std::cell::{Cell, RefCell};
use std::time::{Duration, Instant};

use incspice_core::{Circuit, DeviceKind, SimError, VoltageConstraint};
use crate::device::DeviceRegistry;
use crate::linalg::{
    DenseVec, TripletMatrix, lu_factorize, lu_refactorize, lu_solve, lu_symbolic,
};

use crate::anderson::AndersonAcceleration;
use crate::convergence::ConvergenceCriteria;
use crate::damping::DampingStrategy;
use crate::gmin_stepping::GminStepping;
use crate::pseudo_transient::{PseudoTransientConfig, PtcResult, solve_pseudo_transient};
use crate::source_stepping::{SourceStepping, SourceSteppingConfig};
use crate::stamper;

/// Scratch buffers reused across Newton-Raphson iterations.
///
/// Allocating a fresh `Vec<f64>` per NR iteration costs ~100 ns each on
/// modern allocators *plus* triggers L1/L2 cache pollution that the actual
/// numerical work then has to fight.  With 8-15 iterations per `solve()`
/// call and several solves per transient timestep, this adds up fast.
///
/// The scratch struct is sized once per `solve()` call (via `prepare`) and
/// then reused without reallocating for the rest of the iteration loop.
#[derive(Debug, Clone, Default)]
struct NrScratch {
    /// Trial solution after damping (`x_new = damp(x, dx)`).
    x_new: Vec<f64>,
    /// Previous iteration's solution (used for voltage limiting on the next
    /// device evaluation pass).
    x_prev: Vec<f64>,
    /// Negated residual buffer fed to `lu_solve`.
    neg_res: DenseVec,
    /// Jacobian triplet matrix; cleared at the start of every stamp.
    jac_triplet: TripletMatrix,
    /// Residual vector built by the stamper.
    residual: DenseVec,
}

/// A resolved startup-state constraint in matrix-index space.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VoltagePin {
    pub pos_idx: Option<usize>,
    pub neg_idx: Option<usize>,
    pub voltage: f64,
}

impl VoltagePin {
    pub fn single_ended(pos_idx: usize, voltage: f64) -> Self {
        Self {
            pos_idx: Some(pos_idx),
            neg_idx: None,
            voltage,
        }
    }
}

impl NrScratch {
    /// Resize every buffer to `dim`, reusing existing capacity wherever
    /// possible.  This is the only point at which the scratch struct may
    /// allocate during a `solve()` call.
    #[inline]
    fn prepare(&mut self, dim: usize) {
        self.x_new.resize(dim, 0.0);
        self.x_new.fill(0.0);
        self.x_prev.resize(dim, 0.0);
        self.x_prev.fill(0.0);

        if self.neg_res.len() != dim {
            self.neg_res = DenseVec::zeros(dim);
        } else {
            self.neg_res.fill_zero();
        }
        if self.residual.len() != dim {
            self.residual = DenseVec::zeros(dim);
        } else {
            self.residual.fill_zero();
        }

        self.jac_triplet.clear();
        if self.jac_triplet.capacity() < dim * 4 {
            self.jac_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
        }
    }
}

/// Minimum Jacobian diagonal for Newton step conditioning.
const DEFAULT_GMIN_FLOOR: f64 = 1e-9;

#[inline]
fn state_update_within_tolerance(x_old: &[f64], x_new: &[f64], abs_tol: f64, rel_tol: f64) -> bool {
    x_old.iter().zip(x_new.iter()).all(|(&old, &new)| {
        let tol = abs_tol + rel_tol * old.abs().max(new.abs());
        (new - old).abs() <= tol
    })
}

/// Clamp each element of `dx` so that `|dx[i]| <= max_voltage_step`.
#[inline]
fn limit_step(dx: &mut [f64], max_voltage_step: f64) {
    for v in dx.iter_mut() {
        if *v > max_voltage_step {
            *v = max_voltage_step;
        } else if *v < -max_voltage_step {
            *v = -max_voltage_step;
        }
    }
}

/// Regularize weak Jacobian diagonals (Levenberg-Marquardt style).
fn regularize_weak_diagonals(
    jac: &mut crate::linalg::TripletMatrix,
    num_nodes: usize,
    gmin_floor: f64,
) {
    let mut diag_sum: smallvec::SmallVec<[f64; 64]> = smallvec::smallvec![0.0; num_nodes];
    let rows = jac.row_idx();
    let cols = jac.col_idx();
    let vals = jac.vals();
    for ((&r, &c), &v) in rows.iter().zip(cols.iter()).zip(vals.iter()) {
        let r = r as usize;
        if r < num_nodes && r == c as usize {
            diag_sum[r] += v;
        }
    }
    for i in 0..num_nodes {
        if diag_sum[i].abs() < gmin_floor {
            jac.add(i, i, gmin_floor - diag_sum[i].abs());
        }
    }
}

/// Configuration for the Newton-Raphson solver.
#[derive(Debug, Clone)]
pub struct NrConfig {
    pub convergence: ConvergenceCriteria,
    pub damping: DampingStrategy,
    pub use_gmin_stepping: bool,
    pub use_source_stepping: bool,
    /// Maximum per-iteration voltage step (SPICE `vnstep` / `vntol`-style limiting).
    pub max_voltage_step: f64,
    /// Minimum Jacobian diagonal before regularization kicks in (Levenberg-Marquardt floor).
    pub gmin_floor: f64,
    /// When true, wrap each Newton iterate with Anderson acceleration (window m=5, beta=1).
    pub enable_anderson: bool,
    /// When true, run pseudo-transient continuation as a last-resort fallback.
    pub enable_pseudo_transient: bool,
    /// ITL2: maximum NR iterations per source-stepping sub-solve.
    pub itl2: u32,
    /// ITL4: maximum NR iterations for transient analysis.
    pub itl4: u32,
    /// ITL6 / SRCSTEPS: number of uniform source-stepping intervals.
    pub itl6: usize,
    /// GMINSTEPS: number of geometric GMIN-stepping intervals.
    /// 0 means use the built-in schedule.
    pub gminsteps: usize,
    /// PTRANMAX: pseudo-transient continuation maximum pseudo-time [s].
    /// When > 0, enables PTC and caps the accumulated pseudo-time.
    pub ptranmax: f64,
    /// When true, attempt pseudo-arc-length homotopy continuation as a last-resort fallback.
    pub use_homotopy: bool,
    /// Minimum BSIM4 device count required to consider GPU dispatch.
    pub gpu_device_threshold: usize,
    /// Explicit override for the GPU dispatch decision.
    pub use_gpu: Option<bool>,
    /// Optional wall-clock watchdog for long-running Newton/fallback loops.
    pub watchdog_timeout: Option<Duration>,
}

/// Default minimum BSIM4 device count for the auto CPU↔GPU dispatch policy.
pub const DEFAULT_GPU_DEVICE_THRESHOLD: usize = 1024;

#[derive(Debug)]
struct ElapsedWatchdog {
    timeout: Option<Duration>,
    start: Instant,
    tripped: Cell<bool>,
}

impl ElapsedWatchdog {
    fn new(timeout: Option<Duration>) -> Self {
        Self {
            timeout,
            start: Instant::now(),
            tripped: Cell::new(false),
        }
    }

    fn check(&self) -> bool {
        let Some(timeout) = self.timeout else {
            return false;
        };
        if timeout.is_zero() || self.start.elapsed() >= timeout {
            self.tripped.set(true);
            return true;
        }
        false
    }

    fn error_if_tripped(&self, context: &'static str) -> Result<(), SimError> {
        if self.tripped.get() {
            let timeout = self.timeout.unwrap_or_default();
            return Err(SimError::Analysis(format!(
                "watchdog: {context} exceeded wall-clock limit of {:.3}s",
                timeout.as_secs_f64()
            )));
        }
        Ok(())
    }
}

impl NrConfig {
    /// Build solver configuration from simulation options.
    pub fn from_options(opts: &incspice_core::SimOptions) -> Self {
        Self {
            convergence: ConvergenceCriteria::from_options(opts),
            damping: DampingStrategy::BankRose,
            use_gmin_stepping: true,
            use_source_stepping: true,
            max_voltage_step: opts.vnstep,
            gmin_floor: opts.gmin.max(DEFAULT_GMIN_FLOOR),
            enable_anderson: false,
            enable_pseudo_transient: opts.ptranmax > 0.0,
            itl2: opts.itl2 as u32,
            itl4: opts.itl4 as u32,
            itl6: opts.itl6,
            gminsteps: opts.gminsteps,
            ptranmax: opts.ptranmax,
            use_homotopy: opts.homotopy,
            gpu_device_threshold: DEFAULT_GPU_DEVICE_THRESHOLD,
            use_gpu: None,
            watchdog_timeout: opts.watchdog_timeout,
        }
    }
}

impl Default for NrConfig {
    fn default() -> Self {
        Self::from_options(&incspice_core::SimOptions::default())
    }
}

impl From<&incspice_core::SimOptions> for NrConfig {
    fn from(opts: &incspice_core::SimOptions) -> Self {
        Self::from_options(opts)
    }
}

/// Result of a Newton-Raphson solve.
#[derive(Debug, Clone)]
pub struct NrResult {
    pub solution: Vec<f64>,
    pub iterations: u32,
    pub converged: bool,
    pub residual: f64,
}

/// Newton-Raphson nonlinear solver for circuit simulation.
#[derive(Debug, Clone)]
pub struct NewtonRaphson {
    pub config: NrConfig,
    scratch: RefCell<NrScratch>,
}

impl NewtonRaphson {
    pub fn new(config: NrConfig) -> Self {
        Self {
            config,
            scratch: RefCell::new(NrScratch::default()),
        }
    }

    pub fn with_defaults() -> Self {
        Self::new(NrConfig::default())
    }

    fn node_matrix_index(node: incspice_core::NodeId, num_nodes: usize) -> Option<usize> {
        (!node.is_ground())
            .then(|| (node.0 - 1) as usize)
            .filter(|idx| *idx < num_nodes)
    }

    fn voltage_pin_from_constraint(constraint: &VoltageConstraint, num_nodes: usize) -> VoltagePin {
        VoltagePin {
            pos_idx: Self::node_matrix_index(constraint.pos_node, num_nodes),
            neg_idx: Self::node_matrix_index(constraint.neg_node, num_nodes),
            voltage: constraint.voltage,
        }
    }

    fn apply_voltage_pin_guess(state: &mut [f64], pin: VoltagePin) {
        let pos_idx = pin.pos_idx.filter(|idx| *idx < state.len());
        let neg_idx = pin.neg_idx.filter(|idx| *idx < state.len());

        match (pos_idx, neg_idx) {
            (Some(pos), Some(neg)) => {
                let common_mode = (state[pos] + state[neg]) * 0.5;
                state[pos] = common_mode + pin.voltage * 0.5;
                state[neg] = common_mode - pin.voltage * 0.5;
            }
            (Some(pos), None) => state[pos] = pin.voltage,
            (None, Some(neg)) => state[neg] = -pin.voltage,
            (None, None) => {}
        }
    }

    fn stamp_voltage_pin(
        jac_triplet: &mut TripletMatrix,
        residual: &mut DenseVec,
        x: &[f64],
        pin: VoltagePin,
        g_pin: f64,
    ) {
        let pos_idx = pin.pos_idx.filter(|idx| *idx < x.len());
        let neg_idx = pin.neg_idx.filter(|idx| *idx < x.len());
        if pos_idx.is_none() && neg_idx.is_none() {
            return;
        }

        let pos_v = pos_idx.and_then(|idx| x.get(idx)).copied().unwrap_or(0.0);
        let neg_v = neg_idx.and_then(|idx| x.get(idx)).copied().unwrap_or(0.0);
        let residual_term = pos_v - neg_v - pin.voltage;

        if let Some(pos) = pos_idx {
            jac_triplet.add(pos, pos, g_pin);
            residual[pos] += g_pin * residual_term;
            if let Some(neg) = neg_idx {
                jac_triplet.add(pos, neg, -g_pin);
            }
        }

        if let Some(neg) = neg_idx {
            jac_triplet.add(neg, neg, g_pin);
            residual[neg] -= g_pin * residual_term;
            if let Some(pos) = pos_idx {
                jac_triplet.add(neg, pos, -g_pin);
            }
        }
    }

    /// Compute a DC initial guess from the circuit topology.
    fn compute_dc_initial_guess(circuit: &Circuit, dim: usize) -> Vec<f64> {
        let num_nodes = circuit.num_vars() as usize;
        let mut guess = vec![0.0; dim];
        let mut known = vec![false; num_nodes];

        // Pass 1: Set nodes connected to voltage source terminals.
        for dev in circuit.devices() {
            if dev.kind != DeviceKind::VoltageSource {
                continue;
            }
            let vdc = dev.params.get_or("dc", 0.0);
            let pos_node = dev.node(0);
            let neg_node = dev.node(1);

            let v_neg = match neg_node {
                Some(n) if n.is_ground() => 0.0,
                Some(n) => {
                    let idx = (n.0 - 1) as usize;
                    if idx < num_nodes && known[idx] {
                        guess[idx]
                    } else {
                        0.0
                    }
                }
                None => 0.0,
            };

            if let Some(pos) = pos_node.filter(|p| !p.is_ground()) {
                let idx = (pos.0 - 1) as usize;
                if idx < num_nodes {
                    guess[idx] = v_neg + vdc;
                    known[idx] = true;
                }
            }

            if let Some(neg) = neg_node.filter(|n| !n.is_ground()) {
                let idx = (neg.0 - 1) as usize;
                if idx < num_nodes && !known[idx] {
                    guess[idx] = v_neg;
                    known[idx] = true;
                }
            }
        }

        // Pass 2: For unknown internal nodes, set to VDD/2.
        let mut v_min = 0.0_f64;
        let mut v_max = 0.0_f64;
        for i in 0..num_nodes {
            if known[i] {
                v_min = v_min.min(guess[i]);
                v_max = v_max.max(guess[i]);
            }
        }
        let v_mid = (v_min + v_max) / 2.0;

        for i in 0..num_nodes {
            if !known[i] {
                guess[i] = v_mid;
            }
        }

        // Pass 3: Adjust MOSFET source/drain nodes so that Vgs > Vth.
        let mut drain_claim_type = vec![0u8; num_nodes];
        let mut drain_claim_gate = vec![None::<incspice_core::NodeId>; num_nodes];

        for dev in circuit.devices() {
            let is_nmos = dev.kind == DeviceKind::MosfetN;
            let is_pmos = dev.kind == DeviceKind::MosfetP;
            if !is_nmos && !is_pmos {
                continue;
            }

            let vth = dev
                .params
                .get("vto")
                .or_else(|| dev.params.get("vth0"))
                .or_else(|| dev.params.get("vth"))
                .unwrap_or(0.7);

            let gate_node = dev.node(1);
            let source_node = dev.node(2);
            let drain_node = dev.node(0);

            let v_gate = match gate_node {
                Some(n) if !n.is_ground() => {
                    let idx = (n.0 - 1) as usize;
                    if idx < num_nodes { guess[idx] } else { 0.0 }
                }
                _ => 0.0,
            };

            let my_type: u8 = if is_nmos { 1 } else { 2 };

            if is_nmos {
                let v_source_target = (v_gate - 2.0 * vth.abs()).max(0.0);
                if let Some(s) = source_node.filter(|s| !s.is_ground()) {
                    let idx = (s.0 - 1) as usize;
                    if idx < num_nodes && !known[idx] {
                        guess[idx] = v_source_target;
                    }
                }
            } else {
                let v_source_target = (v_gate + 2.0 * vth.abs()).min(v_max);
                if let Some(s) = source_node.filter(|s| !s.is_ground()) {
                    let idx = (s.0 - 1) as usize;
                    if idx < num_nodes && !known[idx] {
                        guess[idx] = v_source_target;
                    }
                }
            }

            if let Some(d) = drain_node.filter(|d| !d.is_ground()) {
                let idx = (d.0 - 1) as usize;
                if idx < num_nodes && !known[idx] {
                    let v_drain = (v_max + v_gate) / 2.0;

                    if drain_claim_type[idx] == 0 {
                        guess[idx] = v_drain;
                        drain_claim_type[idx] = my_type;
                        drain_claim_gate[idx] = gate_node;
                    } else if drain_claim_type[idx] != my_type && drain_claim_gate[idx] == gate_node
                    {
                        guess[idx] = v_gate;
                    } else {
                        guess[idx] = (guess[idx] + v_drain) / 2.0;
                    }
                }
            }
        }

        // Pass 4: Topology-aware BJT initial guess.
        fn bjt_node_info(
            node: Option<incspice_core::NodeId>,
            guess: &[f64],
            known: &[bool],
            num_nodes: usize,
        ) -> (f64, bool) {
            match node {
                None => (0.0, true),
                Some(n) if n.is_ground() => (0.0, true),
                Some(n) => {
                    let idx = (n.0 - 1) as usize;
                    if idx < num_nodes {
                        (guess[idx], known[idx])
                    } else {
                        (0.0, false)
                    }
                }
            }
        }

        fn bjt_set_node(
            node: Option<incspice_core::NodeId>,
            v: f64,
            guess: &mut [f64],
            known: &[bool],
            num_nodes: usize,
        ) {
            if let Some(n) = node.filter(|n| !n.is_ground()) {
                let idx = (n.0 - 1) as usize;
                if idx < num_nodes && !known[idx] {
                    guess[idx] = v;
                }
            }
        }

        for dev in circuit.devices() {
            let is_npn = dev.kind == DeviceKind::BjtNpn;
            let is_pnp = dev.kind == DeviceKind::BjtPnp;
            if !is_npn && !is_pnp {
                continue;
            }

            let col_node = dev.node(0);
            let base_node = dev.node(1);
            let emit_node = dev.node(2);

            let (v_col, col_known) = bjt_node_info(col_node, &guess, &known, num_nodes);
            let (v_emit, emit_known) = bjt_node_info(emit_node, &guess, &known, num_nodes);
            let (_v_base, base_known) = bjt_node_info(base_node, &guess, &known, num_nodes);

            if is_npn {
                if emit_known && col_known {
                    if !base_known {
                        let v_base = v_emit + 0.7_f64.min((v_col - v_emit) * 0.4);
                        bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                    }
                } else if emit_known {
                    let v_base = v_emit + 0.7;
                    let v_coll = v_emit + (v_max - v_emit) * 0.8;
                    bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                    bjt_set_node(col_node, v_coll, &mut guess, &known, num_nodes);
                } else if col_known {
                    let v_emit_g = v_col * 0.1;
                    let v_base = v_emit_g + 0.7;
                    bjt_set_node(emit_node, v_emit_g, &mut guess, &known, num_nodes);
                    bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                } else {
                    bjt_set_node(emit_node, v_max * 0.1, &mut guess, &known, num_nodes);
                    bjt_set_node(base_node, v_max * 0.1 + 0.7, &mut guess, &known, num_nodes);
                    bjt_set_node(col_node, v_max * 0.8, &mut guess, &known, num_nodes);
                }
            } else {
                if emit_known && col_known {
                    if !base_known {
                        let v_base = v_emit - 0.7_f64.min((v_emit - v_col) * 0.4);
                        bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                    }
                } else if emit_known {
                    let v_base = v_emit - 0.7;
                    let v_coll = v_emit - (v_emit - v_min) * 0.8;
                    bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                    bjt_set_node(col_node, v_coll, &mut guess, &known, num_nodes);
                } else if col_known {
                    let v_emit_g = v_col + (v_max - v_col) * 0.9;
                    let v_base = v_emit_g - 0.7;
                    bjt_set_node(emit_node, v_emit_g, &mut guess, &known, num_nodes);
                    bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                } else {
                    let v_emit_guess = if v_max.abs() >= v_min.abs() {
                        v_max * 0.9
                    } else {
                        v_min * 0.1
                    };
                    let v_col_guess = if v_max.abs() >= v_min.abs() {
                        v_max * 0.2
                    } else {
                        v_min * 0.8
                    };
                    let v_base_guess = v_emit_guess - 0.7 - (v_max - v_min) * 0.4;
                    bjt_set_node(emit_node, v_emit_guess, &mut guess, &known, num_nodes);
                    bjt_set_node(base_node, v_base_guess, &mut guess, &known, num_nodes);
                    bjt_set_node(col_node, v_col_guess, &mut guess, &known, num_nodes);
                }
            }
        }

        // Pass 5: Apply .NODESET overrides.
        let nodeset_nodes: Vec<usize> = circuit
            .node_sets()
            .iter()
            .filter_map(|c| {
                if c.neg_node.is_ground() {
                    let idx = c.pos_node.0 as usize;
                    if idx > 0 && idx <= num_nodes { Some(idx - 1) } else { None }
                } else {
                    None
                }
            })
            .collect();
        for constraint in circuit.node_sets() {
            let pin = Self::voltage_pin_from_constraint(constraint, num_nodes);
            Self::apply_voltage_pin_guess(&mut guess, pin);
        }

        // Pass 6: Propagate nodeset values through resistor chains to internal BJT nodes.
        // Internal nodes from extrinsic expansion (e.g. _q1cx) should inherit the voltage
        // of the nodeset-constrained node they're connected to via parasitic resistors.
        // We iterate until no more propagation occurs, handling multi-hop chains.
        {
            let nodes = circuit.nodes();
            let mut propagated: Vec<bool> = vec![false; num_nodes];
            for &idx in &nodeset_nodes {
                propagated[idx] = true;
            }
            let mut changed = true;
            while changed {
                changed = false;
                for dev in circuit.devices() {
                    if dev.kind != DeviceKind::Resistor || dev.terminals.len() < 2 {
                        continue;
                    }
                    let n1 = dev.terminals[0].node.0 as usize;
                    let n2 = dev.terminals[1].node.0 as usize;
                    if n1 == 0 || n2 == 0 || n1 > num_nodes || n2 > num_nodes {
                        continue;
                    }
                    let n1_idx = n1 - 1;
                    let n2_idx = n2 - 1;
                    if propagated[n1_idx] && !propagated[n2_idx] {
                        if n2 < nodes.len() && nodes[n2].name.starts_with('_') {
                            guess[n2_idx] = guess[n1_idx];
                            propagated[n2_idx] = true;
                            changed = true;
                        }
                    } else if propagated[n2_idx] && !propagated[n1_idx] {
                        if n1 < nodes.len() && nodes[n1].name.starts_with('_') {
                            guess[n1_idx] = guess[n2_idx];
                            propagated[n1_idx] = true;
                            changed = true;
                        }
                    }
                }
            }
        }

        guess
    }

    /// Check that all non-ground nodes have a DC path to ground.
    fn check_ground_connectivity(circuit: &Circuit) -> Result<(), SimError> {
        let n = circuit.num_vars() as usize;
        if n == 0 {
            return Ok(());
        }
        let mut visited = vec![false; n + 1]; // index 0 = ground
        visited[0] = true;
        let mut queue = std::collections::VecDeque::new();
        queue.push_back(0usize);

        while let Some(node) = queue.pop_front() {
            for dev in circuit.devices() {
                // Only devices that provide a DC path
                let has_dc_path = matches!(
                    dev.kind,
                    DeviceKind::Resistor
                        | DeviceKind::VoltageSource
                        | DeviceKind::Inductor
                        | DeviceKind::Cccs
                        | DeviceKind::Ccvs
                        | DeviceKind::Vcvs
                        | DeviceKind::Vccs
                        | DeviceKind::Diode
                        | DeviceKind::BjtNpn
                        | DeviceKind::BjtPnp
                        | DeviceKind::VbicNpn
                        | DeviceKind::VbicPnp
                        | DeviceKind::MosfetN
                        | DeviceKind::MosfetP
                        | DeviceKind::MosfetN2
                        | DeviceKind::MosfetP2
                        | DeviceKind::MosfetN3
                        | DeviceKind::MosfetP3
                        | DeviceKind::MosfetN6
                        | DeviceKind::MosfetP6
                        | DeviceKind::Bsim3N
                        | DeviceKind::Bsim3P
                        | DeviceKind::Bsim4N
                        | DeviceKind::Bsim4P
                        | DeviceKind::MesfetN
                        | DeviceKind::MesfetP
                        | DeviceKind::BsourceV
                        | DeviceKind::BsourceI
                );
                if !has_dc_path {
                    continue;
                }
                let mut connected = false;
                for t in &dev.terminals {
                    if t.node.0 as usize == node {
                        connected = true;
                        break;
                    }
                }
                if connected {
                    for t in &dev.terminals {
                        let idx = t.node.0 as usize;
                        if idx < visited.len() && !visited[idx] {
                            visited[idx] = true;
                            queue.push_back(idx);
                        }
                    }
                }
            }
        }

        for i in 1..=n {
            if !visited[i] {
                return Err(SimError::Analysis(format!(
                    "no DC path to ground for node index {i}"
                )));
            }
        }
        Ok(())
    }

    /// Solve the DC operating point of a circuit.
    pub fn solve(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        initial_guess: Option<&[f64]>,
    ) -> Result<NrResult, SimError> {
        Self::check_ground_connectivity(circuit)?;
        let dim = circuit.mna_dimension();

        let mut scratch = self.scratch.borrow_mut();
        scratch.prepare(dim);

        let mut x = if let Some(guess) = initial_guess {
            guess.to_vec()
        } else {
            Self::compute_dc_initial_guess(circuit, dim)
        };
        let watchdog = ElapsedWatchdog::new(self.config.watchdog_timeout);

        #[cfg(debug_assertions)]
        {
            eprintln!(
                "[NR] dim={}, num_vars={}, num_branches={}",
                dim,
                circuit.num_vars(),
                circuit.num_branches()
            );
        }

        // Try plain Newton-Raphson first.
        if let Some(result) =
            self.nr_loop(circuit, registry, dim, &mut x, 0.0, &mut scratch, &watchdog)
        {
            return Ok(result);
        }
        watchdog.error_if_tripped("newton solver")?;
        #[cfg(debug_assertions)]
        eprintln!("[NR] plain NR failed");

        let dc_guess = Self::compute_dc_initial_guess(circuit, dim);

        // GMIN stepping fallback.
        if self.config.use_gmin_stepping {
            let gmin_cfg = GminStepping::default();
            let steps = if self.config.gminsteps > 0 {
                // User overrode GMINSTEPS — generate that many steps between
                // the same initial and final values.
                let n = self.config.gminsteps;
                let ratio = (gmin_cfg.final_gmin / gmin_cfg.initial_gmin)
                    .powf(1.0 / n as f64);
                let mut s = Vec::with_capacity(n + 1);
                let mut g = gmin_cfg.initial_gmin;
                for _ in 0..n {
                    s.push(g);
                    g *= ratio;
                }
                s.push(gmin_cfg.final_gmin);
                s
            } else {
                gmin_cfg.gmin_steps()
            };
            x.copy_from_slice(&dc_guess);

            let num_nodes = circuit.num_vars() as usize;
            let v_bound = dc_guess[..num_nodes]
                .iter()
                .fold(1.0_f64, |vm, &v| vm.max(v.abs()))
                * 3.0;

            let mut last_good_x = x.clone();
            let mut last_good_step: Option<usize> = None;

            for (si, &g) in steps.iter().enumerate() {
                if watchdog.check() {
                    break;
                }
                let x_backup = x.clone();
                let nr_ok = self
                    .nr_loop_with_gmin(circuit, registry, dim, &mut x, g, &mut scratch, &watchdog)
                    .is_some();
                let diverged = nr_ok && x[..num_nodes].iter().any(|&v| v.abs() > v_bound);
                let step_failed = !nr_ok || diverged;

                if step_failed {
                    #[cfg(debug_assertions)]
                    {
                        if !nr_ok {
                            eprintln!("[NR] GMIN step {} (g={:e}) FAILED", si, g);
                        } else {
                            eprintln!(
                                "[NR] GMIN step {} (g={:e}) diverged — node voltage exceeded bound {}",
                                si, g, v_bound
                            );
                        }
                    }
                    x = if diverged { last_good_x.clone() } else { x_backup };

                    // Bisect between last good GMIN and failed GMIN.
                    if let Some(prev_si) = last_good_step {
                        let g_high = steps[prev_si];
                        let g_low = g;
                        let ratio = (g_low / g_high).powf(1.0 / 6.0);
                        let mut g_sub = g_high * ratio;
                        while g_sub > g_low * 0.99 {
                            if watchdog.check() {
                                break;
                            }
                            let x_sub_backup = x.clone();
                            if self
                                .nr_loop_with_gmin(
                                    circuit,
                                    registry,
                                    dim,
                                    &mut x,
                                    g_sub,
                                    &mut scratch,
                                    &watchdog,
                                )
                                .is_some()
                            {
                                let sub_diverged =
                                    x[..num_nodes].iter().any(|&v| v.abs() > v_bound);
                                if sub_diverged {
                                    x = x_sub_backup;
                                    break;
                                }
                            } else {
                                x = x_sub_backup;
                                break;
                            }
                            g_sub *= ratio;
                        }
                    }
                    break;
                }
                last_good_x = x.clone();
                last_good_step = Some(si);
            }
            watchdog.error_if_tripped("newton solver")?;

            if let Some(result) =
                self.nr_loop(circuit, registry, dim, &mut x, 0.0, &mut scratch, &watchdog)
            {
                return Ok(result);
            }
            watchdog.error_if_tripped("newton solver")?;
            let (_, gmin_residual) = stamper::stamp_circuit(dim, circuit, &x, registry);
            let gmin_res_norm = gmin_residual.norm_inf();
            if gmin_res_norm < self.config.convergence.i_tol * 10.0 {
                return Ok(NrResult {
                    solution: x.clone(),
                    iterations: self.config.convergence.max_iter,
                    converged: true,
                    residual: gmin_res_norm,
                });
            }
        }

        // Source stepping fallback (Gillespie algorithm, matching ngspice).
        if self.config.use_source_stepping {
            let ss_config = {
                let mut cfg = if self.config.itl6 > 0 {
                    SourceSteppingConfig::new(1.0 / self.config.itl6 as f64, 1e-7)
                } else {
                    SourceSteppingConfig::default()
                };
                cfg.itl2 = self.config.itl2;
                cfg.max_steps = if self.config.itl6 > 0 {
                    self.config.itl6
                } else {
                    cfg.max_steps
                };
                cfg
            };

            // Zero all node voltages before source stepping (ngspice zeros
            // all state before gillespie_src). Preserve nodeset hints.
            {
                let num_nodes = circuit.num_vars() as usize;
                let nodeset_indices: Vec<usize> = circuit
                    .node_sets()
                    .iter()
                    .filter_map(|c| {
                        if c.neg_node.is_ground() {
                            let idx = c.pos_node.0 as usize;
                            if idx > 0 && idx <= num_nodes {
                                Some(idx - 1)
                            } else {
                                None
                            }
                        } else {
                            None
                        }
                    })
                    .collect();
                let saved: Vec<(usize, f64)> = nodeset_indices
                    .iter()
                    .map(|&i| (i, x[i]))
                    .collect();
                x.iter_mut().for_each(|v| *v = 0.0);
                for (i, v) in saved {
                    x[i] = v;
                }
            }

            let ss_ok = self.run_adaptive_source_stepping(
                circuit,
                registry,
                dim,
                &mut x,
                &ss_config,
                &mut scratch,
                &watchdog,
            );

            watchdog.error_if_tripped("newton solver")?;

            if ss_ok {
                // ngspice: solution at srcFact=1.0 IS the final answer — it was
                // solved with full sources and normal gmin. Just do a final
                // validation NR pass to confirm convergence.
                if let Some(result) =
                    self.nr_loop(circuit, registry, dim, &mut x, 0.0, &mut scratch, &watchdog)
                {
                    return Ok(result);
                }
                watchdog.error_if_tripped("newton solver")?;

                // If final NR didn't converge but residual is very close, accept.
                let (_, ss_residual) = stamper::stamp_circuit(dim, circuit, &x, registry);
                let ss_res_norm = ss_residual.norm_inf();
                if ss_res_norm < self.config.convergence.i_tol * 10.0 {
                    return Ok(NrResult {
                        solution: x.clone(),
                        iterations: self.config.convergence.max_iter,
                        converged: true,
                        residual: ss_res_norm,
                    });
                }
            }
        }

        // Retry from DC initial guess.
        x = Self::compute_dc_initial_guess(circuit, dim);
        if let Some(result) =
            self.nr_loop(circuit, registry, dim, &mut x, 0.0, &mut scratch, &watchdog)
        {
            return Ok(result);
        }
        watchdog.error_if_tripped("newton solver")?;

        // Last resort: check if current solution is close enough.
        let (_, residual) = stamper::stamp_circuit(dim, circuit, &x, registry);
        let res_norm = residual.norm_inf();
        if res_norm < self.config.convergence.i_tol * 100.0 {
            return Ok(NrResult {
                solution: x.clone(),
                iterations: self.config.convergence.max_iter,
                converged: true,
                residual: res_norm,
            });
        }

        // Homotopy continuation fallback.
        if self.config.use_homotopy {
            let mut x_hom = Self::compute_dc_initial_guess(circuit, dim);
            if let Some(result) = self.homotopy_continuation(
                circuit,
                registry,
                dim,
                &mut x_hom,
                &mut scratch,
                &watchdog,
            ) {
                return Ok(result);
            }
            watchdog.error_if_tripped("newton solver")?;
        }

        // Pseudo-transient continuation fallback.
        if self.config.enable_pseudo_transient {
            let ptc_cfg = PseudoTransientConfig {
                ptranmax: self.config.ptranmax,
                ..PseudoTransientConfig::default()
            };
            match solve_pseudo_transient(circuit, registry, &x, &ptc_cfg) {
                Ok(ptc_result) => {
                    return Ok(NrResult {
                        solution: ptc_result.solution,
                        iterations: self.config.convergence.max_iter,
                        converged: true,
                        residual: ptc_result.residual_norm,
                    });
                }
                Err(_) => {}
            }
        }

        Err(SimError::Convergence {
            iterations: self.config.convergence.max_iter,
            residual: res_norm,
        })
    }

    /// Solve DC operating point with `.IC` nodes pinned via stiff conductance.
    pub fn solve_with_ic_pins(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        ic_pins: &[(usize, f64)],
    ) -> Result<NrResult, SimError> {
        let pins: Vec<VoltagePin> = ic_pins
            .iter()
            .map(|&(idx, voltage)| VoltagePin::single_ended(idx, voltage))
            .collect();
        self.solve_with_voltage_pins(circuit, registry, &pins)
    }

    /// Solve DC operating point with voltage constraints pinned via stiff conductance.
    pub fn solve_with_voltage_pins(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        pins: &[VoltagePin],
    ) -> Result<NrResult, SimError> {
        const G_PIN: f64 = 1e6;

        if pins.is_empty() {
            return self.solve(circuit, registry, None);
        }

        let dim = circuit.mna_dimension();
        let num_nodes = circuit.num_vars() as usize;
        let mut scratch = self.scratch.borrow_mut();
        scratch.prepare(dim);
        let watchdog = ElapsedWatchdog::new(self.config.watchdog_timeout);

        let mut x = Self::compute_dc_initial_guess(circuit, dim);
        for &pin in pins {
            Self::apply_voltage_pin_guess(&mut x, pin);
        }

        let max_iter = self.config.convergence.max_iter;

        let NrScratch {
            x_new,
            x_prev,
            neg_res,
            jac_triplet,
            residual,
        } = &mut *scratch;
        x_new.fill(0.0);
        x_prev.fill(0.0);
        neg_res.fill_zero();
        residual.fill_zero();
        jac_triplet.clear();

        let mut cached_symbolic: Option<crate::linalg::LuSymbolic> = None;
        let mut prev_res_norm = f64::MAX;
        let mut consecutive_growth: u32 = 0;

        for iter in 0..max_iter {
            if watchdog.check() {
                watchdog.error_if_tripped("newton solver")?;
            }
            let prev = if iter > 0 {
                Some(x_prev.as_slice())
            } else {
                None
            };
            stamper::stamp_circuit_into(dim, circuit, &x, registry, jac_triplet, residual, prev);

            for &pin in pins {
                Self::stamp_voltage_pin(jac_triplet, residual, &x, pin, G_PIN);
            }

            let res_norm = residual.norm_inf();
            if res_norm < self.config.convergence.i_tol {
                return Ok(NrResult {
                    solution: x.to_vec(),
                    iterations: iter,
                    converged: true,
                    residual: res_norm,
                });
            }

            regularize_weak_diagonals(jac_triplet, num_nodes, self.config.gmin_floor);

            let jac_csc = jac_triplet.to_csc();
            let factors = if let Some(ref sym) = cached_symbolic {
                match lu_refactorize(&jac_csc, sym) {
                    Ok(f) => f,
                    Err(_) => {
                        cached_symbolic = None;
                        match lu_factorize(&jac_csc) {
                            Ok(f) => f,
                            Err(_) => break,
                        }
                    }
                }
            } else {
                let sym = lu_symbolic(&jac_csc);
                let result = match lu_refactorize(&jac_csc, &sym) {
                    Ok(f) => f,
                    Err(_) => break,
                };
                cached_symbolic = Some(sym);
                result
            };

            for i in 0..dim {
                neg_res[i] = -residual[i];
            }
            let mut dx = match lu_solve(&factors, neg_res) {
                Ok(d) => d,
                Err(_) => break,
            };

            limit_step(dx.as_mut_slice(), self.config.max_voltage_step);

            if res_norm > prev_res_norm * 1.01 {
                consecutive_growth += 1;
            } else {
                consecutive_growth = 0;
            }
            self.config
                .damping
                .apply(&x, dx.as_slice(), x_new, consecutive_growth);

            if state_update_within_tolerance(
                &x,
                x_new,
                self.config.convergence.abs_tol,
                self.config.convergence.rel_tol,
            ) && residual
                .as_slice()
                .iter()
                .all(|&ri| ri.abs() < self.config.convergence.i_tol)
            {
                x.copy_from_slice(x_new);
                return Ok(NrResult {
                    solution: x.to_vec(),
                    iterations: iter + 1,
                    converged: true,
                    residual: res_norm,
                });
            }

            prev_res_norm = res_norm;
            x_prev.copy_from_slice(&x);
            x.copy_from_slice(x_new);
        }

        Err(SimError::Convergence {
            iterations: max_iter,
            residual: prev_res_norm,
        })
    }

    /// Core Newton-Raphson loop. Returns `Some(NrResult)` on convergence.
    fn nr_loop(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut [f64],
        _extra_gmin: f64,
        scratch: &mut NrScratch,
        watchdog: &ElapsedWatchdog,
    ) -> Option<NrResult> {
        let max_iter = self.config.convergence.max_iter;
        let mut prev_res_norm = f64::MAX;
        let mut consecutive_growth: u32 = 0;

        let num_nodes = circuit.num_vars() as usize;

        let mut aa: Option<AndersonAcceleration> = if self.config.enable_anderson {
            Some(AndersonAcceleration::new(5, 1.0))
        } else {
            None
        };

        let NrScratch {
            x_new,
            x_prev,
            neg_res,
            jac_triplet,
            residual,
        } = scratch;
        x_new.fill(0.0);
        x_prev.fill(0.0);
        neg_res.fill_zero();
        residual.fill_zero();
        jac_triplet.clear();

        let mut cached_symbolic: Option<crate::linalg::LuSymbolic> = None;

        // Dirty Newton (Jacobian reuse) state: track previous step norm
        // and cached LU factors so we can skip refactorization when
        // convergence is progressing well (quadratic convergence ratio < 0.5).
        let mut prev_dx_norm: f64 = f64::MAX;
        let mut cached_factors: Option<crate::linalg::LuFactors> = None;

        for iter in 0..max_iter {
            if watchdog.check() {
                return None;
            }
            let prev = if iter > 0 {
                Some(x_prev.as_slice())
            } else {
                None
            };
            stamper::stamp_circuit_into(dim, circuit, x, registry, jac_triplet, residual, prev);

            let res_norm = residual.norm_inf();
            if res_norm < self.config.convergence.i_tol {
                return Some(NrResult {
                    solution: x.to_vec(),
                    iterations: iter,
                    converged: true,
                    residual: res_norm,
                });
            }

            // Dirty Newton (Jacobian reuse): try solving with the old LU
            // factors first.  If ||dx_trial|| / ||dx_prev|| < 0.5 the old
            // Jacobian is still a good approximation — accept the cheap solve
            // and skip the expensive CSC conversion + LU refactorization.
            let mut dx_opt: Option<DenseVec> = None;
            if iter > 0 {
                if let Some(ref factors) = cached_factors {
                    for i in 0..dim {
                        neg_res[i] = -residual[i];
                    }
                    if let Ok(trial_dx) = lu_solve(factors, neg_res) {
                        let trial_dx_norm = trial_dx.norm_inf();
                        let ratio = if prev_dx_norm > 0.0 {
                            trial_dx_norm / prev_dx_norm
                        } else {
                            f64::MAX
                        };
                        if ratio < 0.5 && trial_dx_norm.is_finite() {
                            // Convergence progressing well — reuse old Jacobian.
                            prev_dx_norm = trial_dx_norm;
                            dx_opt = Some(trial_dx);
                        }
                    }
                }
            }

            // If dirty Newton didn't apply, do a full Jacobian update.
            if dx_opt.is_none() {
                regularize_weak_diagonals(jac_triplet, num_nodes, self.config.gmin_floor);

                let jac_csc = jac_triplet.to_csc();
                let new_factors = if let Some(ref sym) = cached_symbolic {
                    match lu_refactorize(&jac_csc, sym) {
                        Ok(f) => f,
                        Err(_) => {
                            cached_symbolic = None;
                            match lu_factorize(&jac_csc) {
                                Ok(f) => f,
                                Err(_) => {
                                    return None;
                                }
                            }
                        }
                    }
                } else {
                    let sym = lu_symbolic(&jac_csc);
                    let result = match lu_refactorize(&jac_csc, &sym) {
                        Ok(f) => f,
                        Err(_) => {
                            return None;
                        }
                    };
                    cached_symbolic = Some(sym);
                    result
                };
                cached_factors = Some(new_factors);

                for i in 0..dim {
                    neg_res[i] = -residual[i];
                }
                match lu_solve(cached_factors.as_ref().unwrap(), neg_res) {
                    Ok(d) => {
                        prev_dx_norm = d.norm_inf();
                        dx_opt = Some(d);
                    }
                    Err(_) => {
                        return None;
                    }
                }
            }

            let mut dx = dx_opt.unwrap();

            limit_step(dx.as_mut_slice(), self.config.max_voltage_step);

            if res_norm > prev_res_norm * 1.01 {
                consecutive_growth += 1;
            } else {
                consecutive_growth = 0;
            }
            self.config
                .damping
                .apply(x, dx.as_slice(), x_new, consecutive_growth);

            if let Some(ref mut aa_ctx) = aa {
                let f_k: Vec<f64> = x_new
                    .iter()
                    .zip(x.iter())
                    .map(|(&xn, &xk)| xn - xk)
                    .collect();
                let x_aa = aa_ctx.step(x, &f_k);
                x_new.copy_from_slice(&x_aa);
            }

            if state_update_within_tolerance(
                x,
                x_new,
                self.config.convergence.abs_tol,
                self.config.convergence.rel_tol,
            ) && residual
                .as_slice()
                .iter()
                .all(|&ri| ri.abs() < self.config.convergence.i_tol)
            {
                x.copy_from_slice(x_new);
                return Some(NrResult {
                    solution: x.to_vec(),
                    iterations: iter + 1,
                    converged: true,
                    residual: res_norm,
                });
            }

            prev_res_norm = res_norm;
            x_prev.copy_from_slice(x);
            x.copy_from_slice(x_new);
        }

        None
    }

    /// NR loop with GMIN added to the diagonal.
    fn nr_loop_with_gmin(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut [f64],
        gmin: f64,
        scratch: &mut NrScratch,
        watchdog: &ElapsedWatchdog,
    ) -> Option<NrResult> {
        let max_iter = self.config.convergence.max_iter;
        let mut prev_res_norm = f64::MAX;
        let mut consecutive_growth: u32 = 0;

        let gmin_tol = (gmin * 10.0).max(self.config.convergence.i_tol * 100.0);

        let NrScratch {
            x_new,
            x_prev,
            neg_res,
            jac_triplet,
            residual,
        } = scratch;
        x_new.fill(0.0);
        x_prev.fill(0.0);
        neg_res.fill_zero();
        residual.fill_zero();
        jac_triplet.clear();

        for iter in 0..max_iter {
            if watchdog.check() {
                return None;
            }
            let prev = if iter > 0 {
                Some(x_prev.as_slice())
            } else {
                None
            };
            stamper::stamp_circuit_into(dim, circuit, x, registry, jac_triplet, residual, prev);

            GminStepping::add_gmin_stamps(jac_triplet, gmin, circuit.num_vars() as usize);

            for i in 0..circuit.num_vars() as usize {
                residual[i] += gmin * x[i];
            }
            let res_norm = residual.norm_inf();

            if iter > 0 && res_norm < gmin_tol {
                return Some(NrResult {
                    solution: x.to_vec(),
                    iterations: iter,
                    converged: true,
                    residual: res_norm,
                });
            }

            let jac_csc = jac_triplet.to_csc();
            let factors = match lu_factorize(&jac_csc) {
                Ok(f) => f,
                Err(_) => return None,
            };

            for i in 0..dim {
                neg_res[i] = -residual[i];
            }
            let mut dx = match lu_solve(&factors, neg_res) {
                Ok(d) => d,
                Err(_) => return None,
            };

            limit_step(dx.as_mut_slice(), self.config.max_voltage_step);

            if res_norm > prev_res_norm * 1.01 {
                consecutive_growth += 1;
            } else {
                consecutive_growth = 0;
            }
            self.config
                .damping
                .apply(x, dx.as_slice(), x_new, consecutive_growth);
            if state_update_within_tolerance(
                x,
                x_new,
                self.config.convergence.abs_tol,
                self.config.convergence.rel_tol,
            ) && res_norm < gmin_tol
            {
                x.copy_from_slice(x_new);
                return Some(NrResult {
                    solution: x.to_vec(),
                    iterations: iter + 1,
                    converged: true,
                    residual: res_norm,
                });
            }
            prev_res_norm = res_norm;
            x_prev.copy_from_slice(x);
            x.copy_from_slice(x_new);
        }
        None
    }

    /// NR loop with independent source values scaled by `source_factor`.
    ///
    /// Matches ngspice behavior: no extra GMIN during source ramping,
    /// uses ITL2 iterations per step. Convergence is based on voltage
    /// change (state_update_within_tolerance) — matching ngspice's
    /// CKTconvTest which checks node voltage convergence, not absolute
    /// residual. The final plain-NR pass enforces strict residual tolerance.
    #[allow(clippy::too_many_arguments)]
    fn nr_loop_with_source_scale(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut [f64],
        source_factor: f64,
        itl2: u32,
        scratch: &mut NrScratch,
        watchdog: &ElapsedWatchdog,
    ) -> Option<NrResult> {
        let max_iter = itl2;
        let mut prev_res_norm = f64::MAX;
        let mut consecutive_growth: u32 = 0;
        let num_nodes = circuit.num_vars() as usize;

        let x_new = &mut scratch.x_new;
        let x_prev = &mut scratch.x_prev;
        let neg_res = &mut scratch.neg_res;
        x_new.fill(0.0);
        x_prev.fill(0.0);
        neg_res.fill_zero();

        for iter in 0..max_iter {
            if watchdog.check() {
                return None;
            }
            let prev = if iter > 0 {
                Some(x_prev.as_slice())
            } else {
                None
            };
            let (mut jac_triplet, mut residual) = stamper::stamp_circuit_with_source_scale(
                dim,
                circuit,
                x,
                registry,
                source_factor,
                prev,
            );

            // Add gmin_floor as node-to-ground shunt (matching ngspice's CKTgmin
            // which provides minimum junction conductance across all devices).
            // This is consistent: added to both Jacobian diagonal AND residual.
            GminStepping::add_gmin_stamps(&mut jac_triplet, self.config.gmin_floor, num_nodes);
            for i in 0..num_nodes {
                residual[i] += self.config.gmin_floor * x[i];
            }

            let res_norm = residual.norm_inf();

            #[cfg(debug_assertions)]
            if iter < 3 || iter % 20 == 0 || iter == max_iter - 1 {
                eprintln!(
                    "[NR-SS] lambda={:.4} iter={} res={:.3e}",
                    source_factor, iter, res_norm,
                );
            }

            let jac_csc = jac_triplet.to_csc();
            let factors = match lu_factorize(&jac_csc) {
                Ok(f) => f,
                Err(_) => return None,
            };

            for i in 0..dim {
                neg_res[i] = -residual[i];
            }
            let mut dx = match lu_solve(&factors, neg_res) {
                Ok(d) => d,
                Err(_) => return None,
            };

            limit_step(dx.as_mut_slice(), self.config.max_voltage_step);

            if res_norm > prev_res_norm * 1.01 {
                consecutive_growth += 1;
            } else {
                consecutive_growth = 0;
            }
            self.config
                .damping
                .apply(x, dx.as_slice(), x_new, consecutive_growth);

            // Convergence: voltage solution settled. For intermediate source
            // steps we only check state tolerance (matching ngspice's CKTconvTest
            // which checks node voltage convergence). The final plain-NR pass
            // at lambda=1.0 enforces strict residual tolerance.
            if iter > 0
                && state_update_within_tolerance(
                    x,
                    x_new,
                    self.config.convergence.abs_tol,
                    self.config.convergence.rel_tol,
                )
            {
                x.copy_from_slice(x_new);
                return Some(NrResult {
                    solution: x.to_vec(),
                    iterations: iter,
                    converged: true,
                    residual: res_norm,
                });
            }

            prev_res_norm = res_norm;
            x_prev.copy_from_slice(x);
            x.copy_from_slice(x_new);
        }
        None
    }

    /// Gillespie adaptive source stepping (matching ngspice `gillespie_src`).
    ///
    /// Phase 1: Solve with all sources at zero. If that fails, try mini-GMIN
    ///          stepping at srcFact=0 to get a valid zero-source solution.
    /// Phase 2: Ramp sources 0→1 adaptively using [`SourceStepping`]'s
    ///          `advance()`/`retreat()` methods which implement ngspice-style
    ///          adaptive step control (cktop.c:480-658):
    ///          - Fast convergence (≤ITL2/4 iters): raise *= 1.5
    ///          - Slow convergence (>3*ITL2/4 iters): raise *= 0.5
    ///          - Failure: raise /= 10, restore previous solution
    ///          - Give up if raise < min_step or srcFact can't advance by 1e-8
    #[allow(clippy::too_many_arguments)]
    fn run_adaptive_source_stepping(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut Vec<f64>,
        config: &SourceSteppingConfig,
        scratch: &mut NrScratch,
        watchdog: &ElapsedWatchdog,
    ) -> bool {
        let mut stepper = SourceStepping::new(config.clone());
        let itl2 = stepper.itl2();

        // Phase 1: solve with all sources at zero (src_fact = 0).
        let x_zero_backup = x.clone();
        let phase1_ok = self
            .nr_loop_with_source_scale(
                circuit, registry, dim, x, stepper.src_fact(), itl2, scratch, watchdog,
            )
            .is_some();

        if !phase1_ok {
            // Mini-GMIN stepping at srcFact=0 (ngspice does 10 steps from
            // gmin*10^10 down by factor of 10).
            *x = x_zero_backup;
            x.iter_mut().for_each(|v| *v = 0.0);

            let gmin_base = self.config.gmin_floor;
            let num_mini_steps = 10;
            let mut mini_ok = true;
            for i in (0..=num_mini_steps).rev() {
                if watchdog.check() {
                    return false;
                }
                let g = gmin_base * 10.0_f64.powi(i);
                if self
                    .nr_loop_with_gmin(circuit, registry, dim, x, g, scratch, watchdog)
                    .is_none()
                {
                    mini_ok = false;
                    break;
                }
            }
            if !mini_ok {
                #[cfg(debug_assertions)]
                eprintln!("[NR] source stepping: phase 1 (srcFact=0) failed even with mini-GMIN");
                return false;
            }
        }

        #[cfg(debug_assertions)]
        eprintln!("[NR] source stepping: phase 1 (srcFact=0) OK");

        // Phase 2: ramp sources from 0 to 1 adaptively via SourceStepping.
        while !stepper.is_complete() && !stepper.budget_exhausted() {
            if watchdog.check() {
                return false;
            }

            let target = stepper.target();
            let x_backup = x.clone();

            if let Some(result) = self.nr_loop_with_source_scale(
                circuit, registry, dim, x, target, itl2, scratch, watchdog,
            ) {
                let iters = result.iterations;
                #[cfg(debug_assertions)]
                eprintln!(
                    "[NR] source step lambda={:.6} (raise={:.4e}) OK in {} iters",
                    target, stepper.raise(), iters
                );

                // Advance src_fact and adapt raise (1.5x fast / 0.5x slow).
                stepper.advance(iters);
            } else {
                // Restore previous solution and shrink step by 10x (ngspice).
                *x = x_backup;
                #[cfg(debug_assertions)]
                {
                    let old_raise = stepper.raise();
                    eprintln!(
                        "[NR] source step lambda={:.6} FAILED — shrink from raise={:.4e}",
                        target, old_raise
                    );
                }

                if !stepper.retreat() {
                    #[cfg(debug_assertions)]
                    eprintln!(
                        "[NR] source stepping: raise {:.4e} < min, giving up at lambda={:.6}",
                        stepper.raise(), stepper.src_fact()
                    );
                    return false;
                }
            }
        }

        stepper.is_complete()
    }

    /// Pseudo-arc-length homotopy continuation.
    fn homotopy_continuation(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut Vec<f64>,
        scratch: &mut NrScratch,
        watchdog: &ElapsedWatchdog,
    ) -> Option<NrResult> {
        x.iter_mut().for_each(|v| *v = 0.0);
        let mut lambda = 0.0_f64;

        let mut ds = 0.1_f64;
        let ds_min = 1e-4_f64;
        let ds_max = 0.2_f64;
        let max_steps = 50usize;

        let aug_dim = dim + 1;
        let mut tx = vec![0.0_f64; dim];
        let mut tl = 1.0_f64;

        let mut x_aug = vec![0.0_f64; aug_dim];
        let mut x0_aug = vec![0.0_f64; aug_dim];

        let max_source_current = circuit
            .devices()
            .iter()
            .filter(|d| {
                matches!(
                    d.kind,
                    DeviceKind::CurrentSource | DeviceKind::VoltageSource
                )
            })
            .map(|d| d.params.get_or("dc", 0.0).abs())
            .fold(0.0_f64, f64::max)
            .max(1e-6);

        for _step in 0..max_steps {
            if watchdog.check() {
                return None;
            }
            if lambda >= 1.0 - 1e-9 {
                return self.nr_loop(circuit, registry, dim, x, 0.0, scratch, watchdog);
            }

            let lambda_pred = (lambda + ds * tl).clamp(0.0, 1.0);
            let x_pred: Vec<f64> = x
                .iter()
                .zip(tx.iter())
                .map(|(&xi, &ti)| xi + ds * ti)
                .collect();

            let mut x_c = x_pred.clone();
            let mut lam_c = lambda_pred;
            let x0 = x.clone();
            let lam0 = lambda;

            let mut corrector_ok = false;
            let max_corr = self.config.convergence.max_iter.min(10);

            for _corr in 0..max_corr {
                if watchdog.check() {
                    return None;
                }
                let ss_gmin = (max_source_current * lam_c / 10.0)
                    .max(self.config.gmin_floor)
                    .max(1e-8 * (1.0 - lam_c).max(0.0));

                let (mut jac, mut res) = stamper::stamp_circuit_with_source_scale(
                    dim, circuit, &x_c, registry, lam_c, None,
                );

                GminStepping::add_gmin_stamps(&mut jac, ss_gmin, circuit.num_vars() as usize);
                for i in 0..circuit.num_vars() as usize {
                    res[i] += ss_gmin * x_c[i];
                }

                let arc_res: f64 = x_c
                    .iter()
                    .zip(x0.iter())
                    .zip(tx.iter())
                    .map(|((&xci, &x0i), &txi)| (xci - x0i) * txi)
                    .sum::<f64>()
                    + (lam_c - lam0) * tl
                    - ds;

                let f_norm = res.norm_inf();
                if f_norm < self.config.convergence.i_tol * 100.0 && arc_res.abs() < ds * 0.01 {
                    corrector_ok = true;
                    break;
                }

                let dlam_fd = 0.001_f64;
                let lam_hi = (lam_c + dlam_fd).min(1.0);
                let (_, res_hi) = stamper::stamp_circuit_with_source_scale(
                    dim, circuit, &x_c, registry, lam_hi, None,
                );
                let df_dlam: Vec<f64> = (0..dim)
                    .map(|i| (res_hi[i] - res[i]) / (lam_hi - lam_c).max(dlam_fd * 0.1))
                    .collect();

                let mut aug_triplet =
                    TripletMatrix::with_capacity(aug_dim, aug_dim, jac.nnz() + aug_dim * 2);
                {
                    let rows = jac.row_idx();
                    let cols = jac.col_idx();
                    let vals = jac.vals();
                    for k in 0..rows.len() {
                        aug_triplet.add(rows[k] as usize, cols[k] as usize, vals[k]);
                    }
                }
                for i in 0..dim {
                    aug_triplet.add(i, dim, df_dlam[i]);
                }
                for i in 0..dim {
                    aug_triplet.add(dim, i, tx[i]);
                }
                aug_triplet.add(dim, dim, tl);

                let mut aug_rhs = DenseVec::zeros(aug_dim);
                for i in 0..dim {
                    aug_rhs[i] = -res[i];
                }
                aug_rhs[dim] = -arc_res;

                let aug_csc = aug_triplet.to_csc();
                let factors = match lu_factorize(&aug_csc) {
                    Ok(f) => f,
                    Err(_) => break,
                };
                let dz = match lu_solve(&factors, &aug_rhs) {
                    Ok(d) => d,
                    Err(_) => break,
                };

                for i in 0..dim {
                    x_c[i] += dz[i];
                }
                lam_c = (lam_c + dz[dim]).clamp(0.0, 1.0);
            }

            if !corrector_ok {
                ds *= 0.5;
                if ds < ds_min {
                    return None;
                }
                continue;
            }

            x0_aug[..dim].copy_from_slice(x);
            x0_aug[dim] = lambda;
            x_aug[..dim].copy_from_slice(&x_c);
            x_aug[dim] = lam_c;

            let mut new_tx: Vec<f64> = (0..dim).map(|i| x_aug[i] - x0_aug[i]).collect();
            let new_tl = x_aug[dim] - x0_aug[dim];
            let norm = (new_tx.iter().map(|&v| v * v).sum::<f64>() + new_tl * new_tl)
                .sqrt()
                .max(1e-15);
            for v in new_tx.iter_mut() {
                *v /= norm;
            }
            let new_tl_n = new_tl / norm;

            let sign = if new_tl_n >= 0.0 { 1.0 } else { -1.0 };
            tx = new_tx.iter().map(|&v| v * sign).collect();
            tl = new_tl_n * sign;

            x.copy_from_slice(&x_c);
            lambda = lam_c;

            ds = (ds * 1.2).clamp(ds_min, ds_max);
        }

        if lambda >= 0.5 {
            return self.nr_loop(circuit, registry, dim, x, 0.0, scratch, watchdog);
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::*;

    #[test]
    fn nr_config_default_matches_sim_options_default() {
        let cfg = NrConfig::default();
        let opts = SimOptions::default();
        assert_eq!(cfg.max_voltage_step, opts.vnstep);
        assert_eq!(cfg.convergence.abs_tol, opts.abstol);
        assert_eq!(cfg.convergence.rel_tol, opts.reltol);
        assert_eq!(cfg.convergence.max_iter, opts.itl1 as u32);
        assert_eq!(cfg.watchdog_timeout, opts.watchdog_timeout);
    }

    #[test]
    fn nr_config_from_options_custom_itl1_propagates() {
        let mut opts = SimOptions::default();
        opts.itl1 = 200;
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.convergence.max_iter, 200);
    }

    #[test]
    fn nr_config_from_options_custom_abstol_propagates() {
        let mut opts = SimOptions::default();
        opts.abstol = 1e-6;
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.convergence.abs_tol, 1e-6);
        assert_eq!(cfg.convergence.i_tol, 1e-3);
    }

    #[test]
    fn nr_config_from_options_custom_vnstep_propagates() {
        let mut opts = SimOptions::default();
        opts.vnstep = 2.0;
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.max_voltage_step, 2.0);
    }

    #[test]
    fn nr_config_gmin_floor_uses_max_of_gmin_and_default() {
        let mut opts = SimOptions::default();
        opts.gmin = 1e-15;
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.gmin_floor, DEFAULT_GMIN_FLOOR);

        opts.gmin = 1e-6;
        let cfg2 = NrConfig::from_options(&opts);
        assert_eq!(cfg2.gmin_floor, 1e-6);
    }

    #[test]
    fn nr_config_from_trait_and_from_options_agree() {
        let mut opts = SimOptions::default();
        opts.itl1 = 75;
        opts.vnstep = 3.0;
        let via_fn = NrConfig::from_options(&opts);
        let via_trait = NrConfig::from(&opts);
        assert_eq!(via_fn.convergence.max_iter, via_trait.convergence.max_iter);
        assert_eq!(via_fn.max_voltage_step, via_trait.max_voltage_step);
    }

    #[test]
    fn nr_config_from_options_propagates_watchdog_timeout() {
        let mut opts = SimOptions::default();
        opts.watchdog_timeout = Some(Duration::from_millis(25));
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.watchdog_timeout, opts.watchdog_timeout);
    }

    #[test]
    fn nr_config_from_options_propagates_itl2() {
        let mut opts = SimOptions::default();
        opts.itl2 = 80;
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.itl2, 80);
    }

    #[test]
    fn nr_config_from_options_propagates_itl4() {
        let mut opts = SimOptions::default();
        opts.itl4 = 20;
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.itl4, 20);
    }

    #[test]
    fn nr_config_from_options_propagates_gminsteps() {
        let mut opts = SimOptions::default();
        opts.gminsteps = 50;
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.gminsteps, 50);
    }

    #[test]
    fn nr_config_from_options_propagates_ptranmax() {
        let mut opts = SimOptions::default();
        opts.ptranmax = 1e-3;
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.ptranmax, 1e-3);
        assert!(cfg.enable_pseudo_transient);
    }

    #[test]
    fn nr_config_default_itl2_matches_sim_options() {
        let cfg = NrConfig::default();
        let opts = SimOptions::default();
        assert_eq!(cfg.itl2, opts.itl2 as u32);
        assert_eq!(cfg.itl4, opts.itl4 as u32);
        assert_eq!(cfg.gminsteps, opts.gminsteps);
        assert_eq!(cfg.ptranmax, opts.ptranmax);
    }

    #[test]
    fn state_update_uses_larger_of_old_and_new_magnitude() {
        assert!(state_update_within_tolerance(
            &[1000.0],
            &[1000.5],
            1e-6,
            1e-3
        ));
        assert!(!state_update_within_tolerance(&[0.0], &[1e-2], 1e-6, 1e-6));
    }

    fn voltage_divider() -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);
        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        )
        .with_param("resistance", 1000.0);
        let r2 = DeviceInstance::new(
            DeviceId::new(0),
            "R2",
            DeviceKind::Resistor,
            &[(0, n2), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(r2);
        ckt.build_topology();
        ckt
    }

    #[test]
    fn solve_voltage_divider() {
        let ckt = voltage_divider();
        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();

        let result = nr.solve(&ckt, &reg, None).unwrap();
        assert!(result.converged, "NR should converge");

        assert!(
            (result.solution[0] - 5.0).abs() < 1e-6,
            "V(1) = {} expected 5.0",
            result.solution[0]
        );
        assert!(
            (result.solution[1] - 2.5).abs() < 1e-6,
            "V(2) = {} expected 2.5",
            result.solution[1]
        );
        assert!(
            (result.solution[2] + 0.0025).abs() < 1e-6,
            "I(V1) = {} expected -0.0025",
            result.solution[2]
        );
    }

    #[test]
    fn zero_watchdog_timeout_aborts_newton_solver() {
        let ckt = voltage_divider();
        let reg = DeviceRegistry::new_default();
        let mut cfg = NrConfig::default();
        cfg.watchdog_timeout = Some(Duration::ZERO);
        let nr = NewtonRaphson::new(cfg);

        let err = nr.solve(&ckt, &reg, None).unwrap_err();
        match err {
            SimError::Analysis(message) => {
                assert!(message.contains("watchdog: newton solver"));
                assert!(message.contains("0.000s"));
            }
            other => panic!("expected watchdog analysis error, got {other:?}"),
        }
    }

    #[test]
    fn solve_single_resistor() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 3.3);
        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 100.0);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();
        let result = nr.solve(&ckt, &reg, None).unwrap();

        assert!(result.converged);
        assert!(
            (result.solution[0] - 3.3).abs() < 1e-6,
            "V(1) = {} expected 3.3",
            result.solution[0]
        );
        assert!(
            (result.solution[1] + 0.033).abs() < 1e-6,
            "I(V1) = {} expected -0.033",
            result.solution[1]
        );
    }

    #[test]
    fn solve_with_warm_start() {
        let ckt = voltage_divider();
        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();

        let guess = vec![4.0, 2.0, -0.002];
        let result = nr.solve(&ckt, &reg, Some(&guess)).unwrap();

        assert!(result.converged);
        assert!(result.iterations <= 5, "warm start should converge fast");
        assert!((result.solution[1] - 2.5).abs() < 1e-6);
    }

    #[test]
    fn solve_three_resistor_chain() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        let n3 = ckt.add_node("3");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 9.0);

        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        )
        .with_param("resistance", 1000.0);

        let r2 = DeviceInstance::new(
            DeviceId::new(0),
            "R2",
            DeviceKind::Resistor,
            &[(0, n2), (1, n3)],
        )
        .with_param("resistance", 1000.0);

        let r3 = DeviceInstance::new(
            DeviceId::new(0),
            "R3",
            DeviceKind::Resistor,
            &[(0, n3), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(r2);
        ckt.add_device(r3);
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();
        let result = nr.solve(&ckt, &reg, None).unwrap();

        assert!(result.converged);
        assert!((result.solution[0] - 9.0).abs() < 1e-6);
        assert!((result.solution[1] - 6.0).abs() < 1e-6);
        assert!((result.solution[2] - 3.0).abs() < 1e-6);
    }

    #[test]
    fn test_nodeset_applied_to_initial_guess() {
        // Build a voltage divider with nodeset biases and verify that solve()
        // still converges to the correct solution (nodesets affect starting
        // point but do not constrain the final answer).
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("n1");
        let n2 = ckt.add_node("n2");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 3.3);

        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        )
        .with_param("resistance", 1000.0);

        let r2 = DeviceInstance::new(
            DeviceId::new(0),
            "R2",
            DeviceKind::Resistor,
            &[(0, n2), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(r2);
        ckt.build_topology();

        // Add nodeset hints: bias n1 to 3.3V and n2 to 1.65V.
        ckt.add_node_set(n1, 3.3);
        ckt.add_node_set(n2, 1.65);

        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();
        let result = nr.solve(&ckt, &reg, None).unwrap();

        assert!(result.converged, "solver should converge with nodeset hints");
        assert!(
            (result.solution[0] - 3.3).abs() < 1e-6,
            "V(n1) = {} expected 3.3",
            result.solution[0]
        );
        assert!(
            (result.solution[1] - 1.65).abs() < 1e-6,
            "V(n2) = {} expected 1.65",
            result.solution[1]
        );
    }

    #[test]
    fn test_dc_initial_guess_vsource() {
        // Verify that a voltage source correctly sets the initial guess and
        // that solve() converges to the expected node voltage.
        let mut ckt = Circuit::new();
        let vdd = ckt.add_node("vdd");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, vdd), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);

        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, vdd), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();
        let result = nr.solve(&ckt, &reg, None).unwrap();

        assert!(result.converged);
        assert!(
            (result.solution[0] - 5.0).abs() < 1e-6,
            "VDD = {} expected 5.0",
            result.solution[0]
        );
    }

    /// RC DC OP: V=10V, R=1kΩ, C=1µF.
    ///
    /// At DC steady state the capacitor is an open circuit, so no current flows
    /// through R. Both the "top" node and the capacitor node should sit at 10V.
    #[test]
    fn test_solve_rc_dc_op_capacitor_open_circuit() {
        let mut ckt = Circuit::new();
        let top = ckt.add_node("top");
        let cap_node = ckt.add_node("cap_node");

        // V1: 10V source
        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, top), (1, NodeId::GROUND)],
        )
        .with_param("dc", 10.0);

        // R1: 1kΩ between top and cap_node
        let r1 = DeviceInstance::new(
            DeviceId::new(1),
            "R1",
            DeviceKind::Resistor,
            &[(0, top), (1, cap_node)],
        )
        .with_param("resistance", 1000.0);

        // C1: 1µF from cap_node to GND (open circuit at DC)
        let c1 = DeviceInstance::new(
            DeviceId::new(2),
            "C1",
            DeviceKind::Capacitor,
            &[(0, cap_node), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 1e-6);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(c1);
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();
        let result = nr.solve(&ckt, &reg, None).unwrap();

        assert!(result.converged, "RC DC OP should converge");

        // top node = 10V (index 0 in solution)
        assert!(
            (result.solution[0] - 10.0).abs() < 1e-4,
            "top node should be 10V, got {}",
            result.solution[0]
        );
        // cap_node = 10V (index 1 in solution) — no voltage drop across R at DC
        assert!(
            (result.solution[1] - 10.0).abs() < 1e-4,
            "cap_node at DC OP should be 10V (cap open), got {}",
            result.solution[1]
        );
    }

    /// Warm-start convergence test: providing an initial guess at the answer
    /// should converge in very few iterations.
    #[test]
    fn test_solve_with_warm_start_at_answer_converges_fast() {
        let mut ckt = Circuit::new();
        let n = ckt.add_node("vdd");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n), (1, NodeId::GROUND)],
        )
        .with_param("dc", 3.3);

        let r1 = DeviceInstance::new(
            DeviceId::new(1),
            "R1",
            DeviceKind::Resistor,
            &[(0, n), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();

        // dim = 2: [V(vdd), I(V1)]
        let initial = vec![3.3, -0.0033];
        let result = nr.solve(&ckt, &reg, Some(&initial)).unwrap();

        assert!(result.converged, "warm start should converge");
        assert!(
            (result.solution[0] - 3.3).abs() < 1e-6,
            "V(vdd)={} expected 3.3",
            result.solution[0]
        );
        // A warm start at the correct answer should converge in ≤ 3 iterations.
        assert!(
            result.iterations <= 3,
            "warm start should converge in ≤3 iters, got {}",
            result.iterations
        );
    }

    /// Parallel resistors: two 1kΩ in parallel from a 6V source → 3mA total,
    /// equivalent resistance 500Ω.
    #[test]
    fn test_solve_parallel_resistors() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("n1");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 6.0);

        let ra = DeviceInstance::new(
            DeviceId::new(1),
            "RA",
            DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);

        let rb = DeviceInstance::new(
            DeviceId::new(2),
            "RB",
            DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);

        ckt.add_device(v1);
        ckt.add_device(ra);
        ckt.add_device(rb);
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();
        let result = nr.solve(&ckt, &reg, None).unwrap();

        assert!(result.converged, "parallel resistors should converge");
        assert!(
            (result.solution[0] - 6.0).abs() < 1e-6,
            "V(n1)={} expected 6.0V",
            result.solution[0]
        );
        // Branch current I(V1) = -6V/500Ω = -12mA (negative: source delivers current)
        assert!(
            (result.solution[1] + 0.012).abs() < 1e-6,
            "I(V1)={} expected -0.012A",
            result.solution[1]
        );
    }

    /// Voltage divider with capacitor: at DC the output = Vin (cap is open,
    /// no current flows through R so no voltage drop).
    ///
    /// This tests that the capacitor's open-circuit DC behavior is correct at
    /// circuit level (complement to the unit-level capacitor tests).
    #[test]
    fn test_solve_voltage_divider_with_cap_dc_op() {
        let mut ckt = Circuit::new();
        let vin = ckt.add_node("vin");
        let vout = ckt.add_node("vout");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, vin), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);

        let r1 = DeviceInstance::new(
            DeviceId::new(1),
            "R1",
            DeviceKind::Resistor,
            &[(0, vin), (1, vout)],
        )
        .with_param("resistance", 10e3);

        // Cap from vout to GND — open circuit at DC
        let c1 = DeviceInstance::new(
            DeviceId::new(2),
            "C1",
            DeviceKind::Capacitor,
            &[(0, vout), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 100e-9);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(c1);
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let nr = NewtonRaphson::with_defaults();
        let result = nr.solve(&ckt, &reg, None).unwrap();

        assert!(result.converged);
        // vout == vin == 5V because cap is open at DC
        assert!(
            (result.solution[1] - 5.0).abs() < 1e-4,
            "vout at DC with cap should equal vin=5V, got {}",
            result.solution[1]
        );
    }
}
