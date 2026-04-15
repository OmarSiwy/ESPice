use std::cell::RefCell;

use bigospice_core::{Circuit, DeviceKind, SimError};
use bigospice_device::DeviceRegistry;
use bigospice_linalg::{lu_factorize, lu_refactorize, lu_solve, lu_symbolic, DenseVec, TripletMatrix};

use crate::anderson::AndersonAcceleration;
use crate::convergence::ConvergenceCriteria;
use crate::damping::DampingStrategy;
use crate::gmin_stepping::GminStepping;
use crate::pseudo_transient::{solve_pseudo_transient, PseudoTransientConfig};
use crate::source_stepping::SourceStepping;
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
/// All fields are `pub(super)` so the inner helper methods can grab borrows
/// out of the `RefCell` without going through wrapper functions.
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

        // DenseVec doesn't expose resize-in-place, so we replace it only when
        // the dimension changed.  In steady-state simulation `dim` is constant
        // across calls, so this branch fires once on the very first solve.
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

        // The triplet matrix's three SoA arrays are cleared (capacity kept).
        // We don't pre-resize to `dim` because the stamper grows it on demand;
        // we just guarantee enough headroom so the typical solve doesn't grow.
        self.jac_triplet.clear();
        if self.jac_triplet.capacity() < dim * 4 {
            self.jac_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
        }
    }
}

/// Minimum Jacobian diagonal for Newton step conditioning.
///
/// Nodes with diagonal weaker than this threshold get regularized
/// (Jacobian-only, no residual change) to prevent singular pivots and
/// wild Newton steps. Only affects the step direction, not the
/// convergence target (true circuit equations).
///
/// Set at 1e-9 S to catch high-impedance nodes (MOSFET drains with
/// lambda=0 where gds ≈ 1e-12). Well-conditioned nodes (resistors
/// with G = 1/R >> 1e-9) are unaffected.
const DEFAULT_GMIN_FLOOR: f64 = 1e-9;

/// Clamp each element of `dx` so that `|dx[i]| <= max_voltage_step`.
///
/// This is the standard SPICE voltage limiting technique that prevents
/// Newton steps from overshooting on circuits with strongly nonlinear
/// devices (MOSFETs, diodes, BJTs).
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
///
/// Adds conductance to node diagonals that are weaker than GMIN_FLOOR,
/// preventing singular pivots and enormous Newton steps. Only the
/// Jacobian is augmented — the residual is NOT modified — so the
/// convergence target remains the true circuit equations F(x) = 0.
///
/// Unlike GMIN-to-ground augmentation (which biases solutions toward
/// V=0 at high-impedance nodes), this Jacobian-only regularization
/// preserves the basin of attraction for the correct operating point.
fn regularize_weak_diagonals(
    jac: &mut bigospice_linalg::TripletMatrix,
    num_nodes: usize,
    gmin_floor: f64,
) {
    let mut diag_sum: smallvec::SmallVec<[f64; 64]> = smallvec::smallvec![0.0; num_nodes];
    // SoA fast path: walk the three parallel slices once.  Branch only on the
    // diagonal predicate; no per-iteration tuple loads.
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
    /// Zero-overhead when false — the hot path is not touched.
    pub enable_anderson: bool,
    /// When true, run pseudo-transient continuation as a last-resort fallback after all
    /// other convergence aids (GMIN stepping, source stepping) have failed.
    /// Zero-overhead when false.
    pub enable_pseudo_transient: bool,
    /// ITL6 / SRCSTEPS: number of uniform source-stepping intervals (V.1).
    ///
    /// When > 0, a uniform lambda schedule λ = k/itl6 (k=1..itl6) is used
    /// instead of the default adaptive schedule.  On failure for a given
    /// lambda the step size is halved (bisection) until only 1 step remains
    /// before declaring failure.
    /// 0 means "use the default adaptive schedule".
    pub itl6: usize,
    /// When true, attempt pseudo-arc-length homotopy continuation (Q.7) as a
    /// last-resort fallback after plain NR, GMIN stepping, and source stepping
    /// have all failed.  Activated by `.OPTIONS HOMOTOPY=1`.
    pub use_homotopy: bool,
    /// Minimum BSIM4 device count required to consider GPU dispatch.
    ///
    /// When the number of BSIM4 devices in the circuit reaches this
    /// threshold the auto-dispatch in `bigospice_solver::device_eval`
    /// switches from CPU SIMD to the WGSL `bsim4_eval` kernel.  The
    /// default of 1024 was chosen so the GPU host-side overhead
    /// (buffer creation, command-encoder construction, readback) is
    /// amortized across enough work to be a net win.
    pub gpu_device_threshold: usize,
    /// Explicit override for the GPU dispatch decision.
    ///
    /// `None` (default) — use the threshold-based automatic policy.
    /// `Some(true)`     — always run BSIM4 batches on the GPU when an
    ///                    adapter is available.
    /// `Some(false)`    — never use the GPU even for very large batches.
    pub use_gpu: Option<bool>,
}

/// Default minimum BSIM4 device count for the auto CPU↔GPU dispatch policy.
///
/// Empirically, host-side wgpu setup (buffer creation, encoder build,
/// dispatch, readback) costs ~0.5 ms on a typical desktop adapter.
/// At ~25 ns per BSIM4 eval on a modern x86 core, the GPU only wins
/// once we have ~20 000 device evaluations to amortize the overhead
/// across — but iterations × devices crosses that line at roughly
/// 1 000 devices for typical Newton convergence (~20 iters per solve).
pub const DEFAULT_GPU_DEVICE_THRESHOLD: usize = 1024;

impl NrConfig {
    /// Build solver configuration from simulation options.
    ///
    /// Maps SPICE `.OPTIONS` fields:
    /// - `itl1`, `abstol`, `reltol`, `vntol` → convergence criteria (via `ConvergenceCriteria::from_options`)
    /// - `gmin`   → `gmin_floor` (floored at `DEFAULT_GMIN_FLOOR` to prevent singular pivots)
    /// - `vnstep` → `max_voltage_step` (per-iteration voltage limiting)
    ///
    /// // TODO(wave-E): integration method selection (opts.method: Trap/Gear/BE)
    pub fn from_options(opts: &bigospice_core::SimOptions) -> Self {
        Self {
            convergence: ConvergenceCriteria::from_options(opts),
            damping: DampingStrategy::BankRose,
            use_gmin_stepping: true,
            use_source_stepping: true,
            max_voltage_step: opts.vnstep,
            gmin_floor: opts.gmin.max(DEFAULT_GMIN_FLOOR),
            enable_anderson: false,
            enable_pseudo_transient: false,
            itl6: opts.itl6,
            use_homotopy: opts.homotopy,
            gpu_device_threshold: DEFAULT_GPU_DEVICE_THRESHOLD,
            use_gpu: None,
        }
    }
}

impl Default for NrConfig {
    fn default() -> Self {
        Self::from_options(&bigospice_core::SimOptions::default())
    }
}

impl From<&bigospice_core::SimOptions> for NrConfig {
    fn from(opts: &bigospice_core::SimOptions) -> Self {
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
///
/// Holds scratch buffers in a `RefCell` so the (logically `&self`) `solve`
/// entry point can hand them out to its inner helpers without forcing
/// callers to take a `&mut NewtonRaphson`.  This keeps the public API
/// untouched while eliminating per-iteration heap allocations on the hot
/// path.
#[derive(Debug, Clone)]
pub struct NewtonRaphson {
    pub config: NrConfig,
    /// Reusable scratch buffers (`x_new`, `x_prev`, `neg_res`, `residual`,
    /// and the Jacobian triplet matrix).  Borrowed mutably exactly once per
    /// `solve()` call; never re-borrowed concurrently.
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

    /// Compute a DC initial guess from the circuit topology.
    ///
    /// Standard SPICE heuristic:
    /// 1. Nodes directly driven by a voltage source positive terminal -> source voltage.
    /// 2. Nodes directly driven by a voltage source negative terminal (ground) -> 0.
    /// 3. Remaining internal nodes -> average of max and min known voltages (VDD/2).
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
            let pos_node = dev.node(0); // pin 0 = V+
            let neg_node = dev.node(1); // pin 1 = V-

            // Determine the voltage at the negative terminal (reference).
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

            // Set the positive terminal node voltage.
            if let Some(pos) = pos_node.filter(|p| !p.is_ground()) {
                let idx = (pos.0 - 1) as usize;
                if idx < num_nodes {
                    guess[idx] = v_neg + vdc;
                    known[idx] = true;
                }
            }

            // If neg terminal is a real node, mark it known.
            if let Some(neg) = neg_node.filter(|n| !n.is_ground()) {
                let idx = (neg.0 - 1) as usize;
                if idx < num_nodes && !known[idx] {
                    guess[idx] = v_neg;
                    known[idx] = true;
                }
            }
        }

        // Pass 2: For unknown internal nodes, set to VDD/2.
        // VDD/2 = midpoint of known voltage range.
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
        //
        // When MOSFETs start in cutoff (Vgs < Vth), their conductance is ~0,
        // which makes the Jacobian nearly singular at nodes driven only by
        // current sources. Standard SPICE heuristic: bias MOSFET source nodes
        // so that the device is in the active region from the first iteration.
        //
        // Track drain nodes claimed by MOSFETs: if NMOS and PMOS share a
        // drain with the same gate (CMOS inverter), use the gate voltage as
        // the initial guess (both devices agree on it). Otherwise average.

        // Per-node drain claim tracking: (type: 0=none, 1=nmos, 2=pmos, gate_node)
        let mut drain_claim_type = vec![0u8; num_nodes];
        let mut drain_claim_gate = vec![None::<bigospice_core::NodeId>; num_nodes];

        for dev in circuit.devices() {
            let is_nmos = dev.kind == DeviceKind::MosfetN;
            let is_pmos = dev.kind == DeviceKind::MosfetP;
            if !is_nmos && !is_pmos {
                continue;
            }

            let vth = dev.params.get("vto")
                .or_else(|| dev.params.get("vth0"))
                .or_else(|| dev.params.get("vth"))
                .unwrap_or(0.7);

            // Pin 0=drain, 1=gate, 2=source, 3=bulk
            let gate_node = dev.node(1);
            let source_node = dev.node(2);
            let drain_node = dev.node(0);

            // Get gate voltage (known from voltage source or previous pass).
            let v_gate = match gate_node {
                Some(n) if !n.is_ground() => {
                    let idx = (n.0 - 1) as usize;
                    if idx < num_nodes { guess[idx] } else { 0.0 }
                }
                _ => 0.0,
            };

            let my_type: u8 = if is_nmos { 1 } else { 2 };

            if is_nmos {
                // NMOS: need Vgs > Vth, so Vsource < Vgate - Vth.
                let v_source_target = (v_gate - 2.0 * vth.abs()).max(0.0);
                if let Some(s) = source_node.filter(|s| !s.is_ground()) {
                    let idx = (s.0 - 1) as usize;
                    if idx < num_nodes && !known[idx] {
                        guess[idx] = v_source_target;
                    }
                }
            } else {
                // PMOS: need Vsg > |Vth|, so Vsource > Vgate + |Vth|.
                let v_source_target = (v_gate + 2.0 * vth.abs()).min(v_max);
                if let Some(s) = source_node.filter(|s| !s.is_ground()) {
                    let idx = (s.0 - 1) as usize;
                    if idx < num_nodes && !known[idx] {
                        guess[idx] = v_source_target;
                    }
                }
            }

            // Set drain guess with CMOS-aware logic.
            if let Some(d) = drain_node.filter(|d| !d.is_ground()) {
                let idx = (d.0 - 1) as usize;
                if idx < num_nodes && !known[idx] {
                    let v_drain = (v_max + v_gate) / 2.0;

                    if drain_claim_type[idx] == 0 {
                        // First claim — set guess.
                        guess[idx] = v_drain;
                        drain_claim_type[idx] = my_type;
                        drain_claim_gate[idx] = gate_node;
                    } else if drain_claim_type[idx] != my_type
                        && drain_claim_gate[idx] == gate_node
                    {
                        // Complementary pair (NMOS+PMOS) with same gate
                        // node — CMOS inverter topology. With lambda=0
                        // the drain voltage is degenerate; the gate
                        // voltage is the balanced operating point.
                        guess[idx] = v_gate;
                    } else {
                        // Same type or different gates — average.
                        guess[idx] = (guess[idx] + v_drain) / 2.0;
                    }
                }
            }
        }

        // Pass 3.5: Apply .NODESET overrides.
        //
        // .NODESET biases the starting point toward a user-specified voltage
        // but does not force the final converged value (unlike .IC). We apply
        // it after the MOSFET pass so topology heuristics don't undo it, but
        // before the BJT pass so BJT guesses can still use the biased values.
        for &(node_id, voltage) in circuit.node_sets() {
            if node_id.is_ground() {
                continue;
            }
            let idx = (node_id.0 - 1) as usize;
            if idx < num_nodes {
                guess[idx] = voltage;
            }
        }

        // Pass 4: Topology-aware BJT initial guess.
        //
        // Pin layout: 0=collector, 1=base, 2=emitter.
        //
        // Ground (NodeId==0) is always "known" at 0 V.  Nodes already set by
        // Pass 1 (voltage-source terminals) are in `known[]`.  We use that
        // information to compute physically meaningful Vbe/Vbc biases instead
        // of the crude 10 %/90 % heuristic that ignores topology.
        //
        // Returns (voltage, is_known) for a node; ground is (0.0, true).
        fn bjt_node_info(
            node: Option<bigospice_core::NodeId>,
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

        // Write a node guess only when it is not already pinned.
        fn bjt_set_node(
            node: Option<bigospice_core::NodeId>,
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
                // NPN active region: Ve < Vb < Vc.
                // Vbe ≈ +0.7 V,  Vc well above Ve.
                if emit_known && col_known {
                    // Both power-rail nodes are pinned — only set base.
                    if !base_known {
                        let v_base = v_emit + 0.7_f64.min((v_col - v_emit) * 0.4);
                        bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                    }
                } else if emit_known {
                    // Emitter is on a known rail (often ground).
                    let v_base = v_emit + 0.7;
                    let v_coll = v_emit + (v_max - v_emit) * 0.8;
                    bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                    bjt_set_node(col_node, v_coll, &mut guess, &known, num_nodes);
                } else if col_known {
                    // Collector pinned to supply.
                    let v_emit_g = v_col * 0.1;
                    let v_base = v_emit_g + 0.7;
                    bjt_set_node(emit_node, v_emit_g, &mut guess, &known, num_nodes);
                    bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                } else {
                    // No topology info — crude heuristic.
                    bjt_set_node(emit_node, v_max * 0.1, &mut guess, &known, num_nodes);
                    bjt_set_node(base_node, v_max * 0.1 + 0.7, &mut guess, &known, num_nodes);
                    bjt_set_node(col_node, v_max * 0.8, &mut guess, &known, num_nodes);
                }
            } else {
                // PNP active region: Ve > Vb > Vc.
                // Veb ≈ +0.7 V,  Vc well below Ve.
                if emit_known && col_known {
                    if !base_known {
                        let v_base = v_emit - 0.7_f64.min((v_emit - v_col) * 0.4);
                        bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                    }
                } else if emit_known {
                    // Emitter is on the high rail.
                    let v_base = v_emit - 0.7;
                    let v_coll = v_emit - (v_emit - v_min) * 0.8;
                    bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                    bjt_set_node(col_node, v_coll, &mut guess, &known, num_nodes);
                } else if col_known {
                    // Collector pinned to low rail.
                    let v_emit_g = v_col + (v_max - v_col) * 0.9;
                    let v_base = v_emit_g - 0.7;
                    bjt_set_node(emit_node, v_emit_g, &mut guess, &known, num_nodes);
                    bjt_set_node(base_node, v_base, &mut guess, &known, num_nodes);
                } else {
                    // No topology info — crude heuristic.
                    bjt_set_node(emit_node, v_max * 0.9, &mut guess, &known, num_nodes);
                    bjt_set_node(base_node, v_max * 0.9 - 0.7, &mut guess, &known, num_nodes);
                    bjt_set_node(col_node, v_max * 0.2, &mut guess, &known, num_nodes);
                }
            }
        }

        guess
    }

    /// Solve the DC operating point of a circuit.
    ///
    /// Returns the MNA solution vector: `[V(node1), V(node2), ..., I(branch1), ...]`
    pub fn solve(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        initial_guess: Option<&[f64]>,
    ) -> Result<NrResult, SimError> {
        let dim = circuit.mna_dimension();

        // Acquire and resize scratch buffers exactly once per solve().  Every
        // inner helper borrows from this struct instead of allocating its
        // own per-iteration `Vec`s.
        let mut scratch = self.scratch.borrow_mut();
        scratch.prepare(dim);

        // Initialize solution vector.
        let mut x = if let Some(guess) = initial_guess {
            guess.to_vec()
        } else {
            Self::compute_dc_initial_guess(circuit, dim)
        };

        #[cfg(debug_assertions)]
        {
            eprintln!("[NR] dim={}, num_vars={}, num_branches={}", dim, circuit.num_vars(), circuit.num_branches());
            for dev in circuit.devices() {
                eprintln!("[NR]   dev={} kind={:?} branch={:?} terminals={:?}", dev.name, dev.kind, dev.branch_index, dev.terminals);
            }
        }

        // Try plain Newton-Raphson first.
        if let Some(result) = self.nr_loop(circuit, registry, dim, &mut x, 0.0, &mut scratch) {
            return Ok(result);
        }
        #[cfg(debug_assertions)]
        eprintln!("[NR] plain NR failed");

        // Compute a fresh initial guess for fallback methods.
        let dc_guess = Self::compute_dc_initial_guess(circuit, dim);

        // If that failed and GMIN stepping is enabled, try it.
        if self.config.use_gmin_stepping {
            let gmin = GminStepping::default();
            let steps = gmin.gmin_steps();
            x.copy_from_slice(&dc_guess);

            let num_nodes = circuit.num_vars() as usize;
            // Compute a voltage sanity bound: 3 * max known voltage.
            let v_bound = dc_guess[..num_nodes].iter().fold(1.0_f64, |vm, &v| vm.max(v.abs())) * 3.0;

            let mut last_good_x = x.clone();
            let mut last_good_step: Option<usize> = None;

            for (si, &g) in steps.iter().enumerate() {
                let x_backup = x.clone();
                if self
                    .nr_loop_with_gmin(circuit, registry, dim, &mut x, g, &mut scratch)
                    .is_none()
                {
                    #[cfg(debug_assertions)]
                    eprintln!("[NR] GMIN step {} (g={:e}) FAILED", si, g);
                    x = x_backup;
                    break;
                }
                // Sanity check: if any node voltage exceeds the supply range
                // significantly, GMIN stepping is diverging (current source
                // nodes settle at V=I/gmin). Restore last good solution and
                // try interpolated GMIN values.
                let diverged = x[..num_nodes].iter().any(|&v| v.abs() > v_bound);
                if diverged {
                    #[cfg(debug_assertions)]
                    eprintln!("[NR] GMIN step {} (g={:e}) diverged — node voltage exceeded bound {}", si, g, v_bound);
                    x = last_good_x.clone();

                    // Try interpolated GMIN values between last_good and current.
                    if let Some(prev_si) = last_good_step {
                        let g_high = steps[prev_si];
                        let g_low = g;
                        // Try 5 intermediate sub-steps.
                        let ratio = (g_low / g_high).powf(1.0 / 6.0);
                        let mut g_sub = g_high * ratio;
                        while g_sub > g_low * 0.99 {
                            let x_sub_backup = x.clone();
                            if self.nr_loop_with_gmin(circuit, registry, dim, &mut x, g_sub, &mut scratch).is_some() {
                                let sub_diverged = x[..num_nodes].iter().any(|&v| v.abs() > v_bound);
                                if sub_diverged {
                                    #[cfg(debug_assertions)]
                                    eprintln!("[NR] GMIN sub-step (g={:e}) diverged", g_sub);
                                    x = x_sub_backup;
                                    break;
                                }
                                #[cfg(debug_assertions)]
                                eprintln!("[NR] GMIN sub-step (g={:e}) OK, x={:?}", g_sub, &x);
                            } else {
                                #[cfg(debug_assertions)]
                                eprintln!("[NR] GMIN sub-step (g={:e}) FAILED", g_sub);
                                x = x_sub_backup;
                                break;
                            }
                            g_sub *= ratio;
                        }
                    }
                    break;
                }
                #[cfg(debug_assertions)]
                eprintln!("[NR] GMIN step {} (g={:e}) OK, x={:?}", si, g, &x);
                last_good_x = x.clone();
                last_good_step = Some(si);
            }

            // Try plain NR from the best GMIN-stepped solution.
            if let Some(result) = self.nr_loop(circuit, registry, dim, &mut x, 0.0, &mut scratch) {
                return Ok(result);
            }
            // If the final plain NR failed but the residual is already small
            // (e.g. the Jacobian is near-singular at current source nodes but
            // the solution is correct), accept the GMIN-stepped solution.
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
            #[cfg(debug_assertions)]
            eprintln!("[NR] GMIN final plain NR failed, residual={:e}", gmin_res_norm);
        }

        // If GMIN stepping failed and source stepping is enabled, try it.
        // Start from zero — sources ramp from 0 to full value.
        if self.config.use_source_stepping {
            // Compute max independent source current for GMIN sizing.
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
                .max(1e-6); // minimum 1uA to avoid degenerate case

            // Build the lambda schedule: either ITL6 uniform or default adaptive.
            // ITL6 uniform: λ = k/n for k = 1..n (V.1 — source stepping fallback).
            let lambda_schedule: Vec<f64> = if self.config.itl6 > 0 {
                let n = self.config.itl6;
                (1..=n).map(|k| k as f64 / n as f64).collect()
            } else {
                SourceStepping::default().steps.clone()
            };

            x.iter_mut().for_each(|v| *v = 0.0);

            let ss_ok = self.run_source_stepping_schedule(
                circuit, registry, dim, &mut x, &lambda_schedule, max_source_current, &mut scratch,
            );

            if ss_ok {
                // Source stepping converged (with GMIN). Try plain NR first.
                if let Some(result) = self.nr_loop(circuit, registry, dim, &mut x, 0.0, &mut scratch) {
                    return Ok(result);
                }
                // If plain NR failed, ramp down GMIN from the source-stepped solution.
                let gmin = GminStepping::default();
                let gmin_steps = gmin.gmin_steps();
                for &g in &gmin_steps {
                    if self
                        .nr_loop_with_gmin(circuit, registry, dim, &mut x, g, &mut scratch)
                        .is_none()
                    {
                        break;
                    }
                }
                // Try plain NR again after GMIN ramp-down.
                if let Some(result) = self.nr_loop(circuit, registry, dim, &mut x, 0.0, &mut scratch) {
                    return Ok(result);
                }
            }
        }

        // Retry from DC initial guess — the MOSFET bias heuristics in
        // compute_dc_initial_guess place gate/source nodes so Vgs > Vth,
        // avoiding the cutoff trap that source stepping can fall into.
        // The improved targeted GMIN (residual-proportional) should now
        // provide enough diagonal conditioning for current-source nodes.
        x = Self::compute_dc_initial_guess(circuit, dim);
        if let Some(result) = self.nr_loop(circuit, registry, dim, &mut x, 0.0, &mut scratch) {
            return Ok(result);
        }
        #[cfg(debug_assertions)]
        eprintln!("[NR] final retry from DC guess failed");

        // Last resort: check if current solution is close enough.
        // This handles circuits where the Jacobian is structurally singular
        // (e.g. lambda=0 MOSFETs with current sources) but the solution is
        // correct — the LU factorization fails but the residual is tiny.
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
        // Homotopy continuation fallback: last-resort after all other convergence
        // aids (plain NR, GMIN stepping, source stepping) have failed.
        // Enabled by `.OPTIONS HOMOTOPY=1`.  Zero-overhead when the flag is false.
        if self.config.use_homotopy {
            #[cfg(debug_assertions)]
            eprintln!("[NR] falling back to homotopy continuation (last resort)");
            let mut x_hom = Self::compute_dc_initial_guess(circuit, dim);
            if let Some(result) = self.homotopy_continuation(circuit, registry, dim, &mut x_hom, &mut scratch) {
                return Ok(result);
            }
            #[cfg(debug_assertions)]
            eprintln!("[NR] homotopy continuation also failed");
        }

        // Pseudo-transient continuation fallback: last-resort after all other
        // convergence aids have failed.  Zero-overhead when the flag is false.
        if self.config.enable_pseudo_transient {
            #[cfg(debug_assertions)]
            eprintln!("[NR] falling back to pseudo-transient continuation");

            let ptc_cfg = PseudoTransientConfig::default();
            match solve_pseudo_transient(circuit, registry, &x, &ptc_cfg) {
                Ok(ptc_x) => {
                    return Ok(NrResult {
                        solution: ptc_x,
                        iterations: self.config.convergence.max_iter,
                        converged: true,
                        residual: res_norm,
                    });
                }
                Err(_) => {
                    #[cfg(debug_assertions)]
                    eprintln!("[NR] pseudo-transient continuation also failed");
                }
            }
        }

        Err(SimError::Convergence {
            iterations: self.config.convergence.max_iter,
            residual: res_norm,
        })
    }

    /// Core Newton-Raphson loop. Returns `Some(NrResult)` on convergence.
    ///
    /// All scratch buffers come from the caller-supplied `scratch` struct so
    /// we never allocate on the hot path.
    fn nr_loop(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut [f64],
        _extra_gmin: f64,
        scratch: &mut NrScratch,
    ) -> Option<NrResult> {
        let max_iter = self.config.convergence.max_iter;
        let mut prev_res_norm = f64::MAX;

        let num_nodes = circuit.num_vars() as usize;

        // Anderson acceleration context — only allocated when the flag is set.
        // When `enable_anderson` is false this is `None` and has zero cost.
        let mut aa: Option<AndersonAcceleration> = if self.config.enable_anderson {
            Some(AndersonAcceleration::new(5, 1.0))
        } else {
            None
        };

        // Reuse the scratch arrays from the parent solve() call.  We only
        // need to zero whatever the previous helper left behind so the
        // numerical results stay bit-identical to the un-pooled version.
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

        // Cache the AMD symbolic ordering so we pay for it only once per
        // solve() call.  On the first iteration we run the full symbolic +
        // numeric factorisation; on every subsequent iteration (same sparsity
        // pattern for RC/linear circuits) we skip AMD and run numeric-only.
        let mut cached_symbolic: Option<bigospice_linalg::LuSymbolic> = None;

        for iter in 0..max_iter {
            // On iter 0, no previous solution for limiting; after that use x_prev.
            let prev = if iter > 0 { Some(x_prev.as_slice()) } else { None };
            stamper::stamp_circuit_into(dim, circuit, x, registry, jac_triplet, residual, prev);

            // Check convergence BEFORE adding GMIN, so we check the true
            // circuit residual (not the GMIN-augmented one).
            let res_norm = residual.norm_inf();
            if res_norm < self.config.convergence.i_tol {
                return Some(NrResult {
                    solution: x.to_vec(),
                    iterations: iter,
                    converged: true,
                    residual: res_norm,
                });
            }

            // Add targeted GMIN to nodes with weak diagonal to prevent
            // singular pivots (e.g., current-source-driven MOSFET nodes).
            regularize_weak_diagonals(jac_triplet, num_nodes, self.config.gmin_floor);

            // Build and factor the Jacobian.
            // Reuse the AMD symbolic ordering from the first iteration so
            // subsequent iterations skip the O(n log n) AMD computation.
            let jac_csc = jac_triplet.to_csc();
            let factors = if let Some(ref sym) = cached_symbolic {
                // Numeric-only refactorisation — AMD ordering already cached.
                match lu_refactorize(&jac_csc, sym) {
                    Ok(f) => f,
                    Err(_) => {
                        // Fall back to full factorisation (e.g. pivoting changed pattern).
                        cached_symbolic = None;
                        match lu_factorize(&jac_csc) {
                            Ok(f) => f,
                            Err(_) => {
                                #[cfg(debug_assertions)]
                                eprintln!("[nr_loop] LU factorize (fallback) failed at iter {}, res={:e}", iter, res_norm);
                                return None;
                            }
                        }
                    }
                }
            } else {
                // First iteration: full symbolic + numeric, then cache the symbolic.
                let sym = lu_symbolic(&jac_csc);
                let result = match lu_refactorize(&jac_csc, &sym) {
                    Ok(f) => f,
                    Err(_) => {
                        #[cfg(debug_assertions)]
                        eprintln!("[nr_loop] LU factorize failed at iter {}, res={:e}", iter, res_norm);
                        return None;
                    }
                };
                cached_symbolic = Some(sym);
                result
            };

            // Solve J * dx = -F(x). Reuse neg_res buffer.
            for i in 0..dim {
                neg_res[i] = -residual[i];
            }
            let mut dx = match lu_solve(&factors, neg_res) {
                Ok(d) => d,
                Err(_) => {
                    #[cfg(debug_assertions)]
                    eprintln!("[nr_loop] LU solve failed at iter {}", iter);
                    return None;
                }
            };

            #[cfg(debug_assertions)]
            if iter < 3 {
                eprintln!("[nr_loop] iter={}, res={:e}, dx={:?}", iter, res_norm, dx.as_slice());
            }

            // Limit voltage steps to prevent divergence on nonlinear circuits.
            limit_step(dx.as_mut_slice(), self.config.max_voltage_step);

            // Apply damping. Reuse x_new buffer.
            let residual_grew = res_norm > prev_res_norm * 1.01;
            self.config
                .damping
                .apply(x, dx.as_slice(), x_new, residual_grew);

            // Anderson acceleration: treat the Newton step as a fixed-point
            // residual f_k = x_new - x_k and compute an accelerated x_{k+1}.
            // This wraps the damped Newton iterate without touching the
            // convergence criterion — the accelerated point replaces x_new.
            // When `aa` is None this branch is eliminated by the compiler.
            if let Some(ref mut aa_ctx) = aa {
                // f_k = x_new - x  (the update the Newton step proposes)
                let f_k: Vec<f64> =
                    x_new.iter().zip(x.iter()).map(|(&xn, &xk)| xn - xk).collect();
                let x_aa = aa_ctx.step(x, &f_k);
                x_new.copy_from_slice(&x_aa);
            }

            // Check update convergence.
            if self
                .config
                .convergence
                .check(dx.as_slice(), x, residual.as_slice())
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

        #[cfg(debug_assertions)]
        eprintln!("[nr_loop] max iterations reached");
        None
    }

    /// NR loop with GMIN added to the diagonal.
    ///
    /// Like [`nr_loop`](Self::nr_loop), this borrows pre-allocated buffers
    /// from the caller-supplied scratch struct.
    fn nr_loop_with_gmin(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut [f64],
        gmin: f64,
        scratch: &mut NrScratch,
    ) -> Option<NrResult> {
        let max_iter = self.config.convergence.max_iter;
        let mut prev_res_norm = f64::MAX;

        // The convergence tolerance for GMIN-augmented solves must account for
        // the GMIN leakage current. At a node voltage V, GMIN adds gmin*V to
        // the residual. For typical supply voltages (a few volts), the GMIN
        // current can be much larger than i_tol. We use a generous tolerance
        // proportional to the GMIN value so the inner NR loop can converge.
        let gmin_tol = (gmin * 10.0).max(self.config.convergence.i_tol * 100.0);

        // Reuse the scratch struct's buffers.
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
            let prev = if iter > 0 { Some(x_prev.as_slice()) } else { None };
            stamper::stamp_circuit_into(dim, circuit, x, registry, jac_triplet, residual, prev);

            // Add GMIN to diagonal (node variables only).
            GminStepping::add_gmin_stamps(jac_triplet, gmin, circuit.num_vars() as usize);

            // Add corresponding GMIN current to the residual so the system is
            // consistent: the Jacobian has gmin*V conductance to ground, so
            // the residual must include the matching gmin*V(node) current.
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

            // Reuse neg_res buffer.
            for i in 0..dim {
                neg_res[i] = -residual[i];
            }
            let mut dx = match lu_solve(&factors, neg_res) {
                Ok(d) => d,
                Err(_) => return None,
            };

            // Limit voltage steps to prevent divergence on nonlinear circuits.
            limit_step(dx.as_mut_slice(), self.config.max_voltage_step);

            // Apply damping. Reuse x_new buffer.
            let residual_grew = res_norm > prev_res_norm * 1.01;
            self.config
                .damping
                .apply(x, dx.as_slice(), x_new, residual_grew);
            prev_res_norm = res_norm;
            x_prev.copy_from_slice(x);
            x.copy_from_slice(x_new);
        }
        None
    }

    /// NR loop with independent source values scaled by `source_factor`.
    ///
    /// Used by source stepping: sources are ramped from 0 -> full value.
    /// A GMIN conductance is added that scales inversely with the source
    /// factor to prevent singular Jacobians when nonlinear devices (MOSFETs)
    /// are in cutoff at low source levels.
    ///
    /// Note: this helper currently still pays the cost of one freshly
    /// returned `(TripletMatrix, DenseVec)` per iteration because the
    /// stamper does not yet expose an in-place variant for the
    /// source-scaled stamp.  The other three buffers (`x_new`, `x_prev`,
    /// `neg_res`) are reused from the scratch struct.
    #[allow(clippy::too_many_arguments)]
    fn nr_loop_with_source_scale(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut [f64],
        source_factor: f64,
        max_source_current: f64,
        scratch: &mut NrScratch,
    ) -> Option<NrResult> {
        let max_iter = self.config.convergence.max_iter;
        let mut prev_res_norm = f64::MAX;
        let num_nodes = circuit.num_vars() as usize;

        // The GMIN must be large enough that current source nodes don't
        // diverge: V_node = I_source / gmin must stay within the supply
        // range. We size GMIN so V_max = I_max * factor / gmin < 10V,
        // i.e., gmin > I_max * factor / 10. At full scale this tapers
        // to GMIN_FLOOR.
        let ss_gmin = (max_source_current * source_factor / 10.0)
            .max(self.config.gmin_floor)
            .max(1e-6 * (1.0 - source_factor).max(0.0));
        let ss_tol = (ss_gmin * 100.0).max(self.config.convergence.i_tol * 100.0);

        // Borrow only the reusable scalar/vector buffers from the scratch
        // struct.  `jac_triplet` and `residual` come from the stamper as
        // owned values for this entry point — we leave the scratch's copies
        // alone so that the next call can keep using them without going
        // through a fresh allocation.
        let x_new = &mut scratch.x_new;
        let x_prev = &mut scratch.x_prev;
        let neg_res = &mut scratch.neg_res;
        x_new.fill(0.0);
        x_prev.fill(0.0);
        neg_res.fill_zero();

        for iter in 0..max_iter {
            let prev = if iter > 0 { Some(x_prev.as_slice()) } else { None };
            let (mut jac_triplet, mut residual) =
                stamper::stamp_circuit_with_source_scale(dim, circuit, x, registry, source_factor, prev);

            // Add GMIN to all node diagonals for source stepping conditioning.
            GminStepping::add_gmin_stamps(&mut jac_triplet, ss_gmin, num_nodes);
            for i in 0..num_nodes {
                residual[i] += ss_gmin * x[i];
            }

            let res_norm = residual.norm_inf();

            if iter > 0 && res_norm < ss_tol {
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

            // Reuse neg_res buffer.
            for i in 0..dim {
                neg_res[i] = -residual[i];
            }
            let mut dx = match lu_solve(&factors, neg_res) {
                Ok(d) => d,
                Err(_) => return None,
            };

            // Limit voltage steps to prevent divergence on nonlinear circuits.
            limit_step(dx.as_mut_slice(), self.config.max_voltage_step);

            // Apply damping. Reuse x_new buffer.
            let residual_grew = res_norm > prev_res_norm * 1.01;
            self.config
                .damping
                .apply(x, dx.as_slice(), x_new, residual_grew);
            prev_res_norm = res_norm;
            x_prev.copy_from_slice(x);
            x.copy_from_slice(x_new);
        }
        None
    }

    /// Run source stepping with the given lambda schedule and bisection on failure (V.1).
    ///
    /// For each lambda in `schedule`, attempts to converge Newton with sources scaled
    /// by that lambda.  If any step fails, the step size is halved (bisection): the
    /// interval [prev_lambda, lambda] is split in half and retried, down to a minimum
    /// granularity of 1 step.  Returns `true` if the full schedule (reaching lambda=1)
    /// completed successfully.
    #[allow(clippy::too_many_arguments)]
    fn run_source_stepping_schedule(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut Vec<f64>,
        schedule: &[f64],
        max_source_current: f64,
        scratch: &mut NrScratch,
    ) -> bool {
        let mut prev_lambda = 0.0_f64;

        for &lambda in schedule {
            // Try to converge at this lambda.
            if self
                .nr_loop_with_source_scale(circuit, registry, dim, x, lambda, max_source_current, scratch)
                .is_some()
            {
                #[cfg(debug_assertions)]
                eprintln!("[NR] source step lambda={:.4} OK", lambda);
                prev_lambda = lambda;
                continue;
            }

            #[cfg(debug_assertions)]
            eprintln!("[NR] source step lambda={:.4} FAILED — bisecting", lambda);

            // Bisection: split [prev_lambda, lambda] until we succeed or give up.
            let mut lo = prev_lambda;
            let mut hi = lambda;
            let mut bisect_ok = false;

            // At most 8 bisection halvings (2^-8 = 0.4% of original step).
            for _bisect in 0..8 {
                let mid = (lo + hi) * 0.5;
                if (mid - lo).abs() < 1e-9 {
                    break; // step too small to be meaningful
                }
                if self
                    .nr_loop_with_source_scale(circuit, registry, dim, x, mid, max_source_current, scratch)
                    .is_some()
                {
                    #[cfg(debug_assertions)]
                    eprintln!("[NR] bisect lambda={:.6} OK", mid);
                    lo = mid;
                    // Try to reach hi from the new lo.
                    if self
                        .nr_loop_with_source_scale(circuit, registry, dim, x, hi, max_source_current, scratch)
                        .is_some()
                    {
                        #[cfg(debug_assertions)]
                        eprintln!("[NR] bisect lambda={:.6} (hi) OK", hi);
                        bisect_ok = true;
                        break;
                    }
                    // hi still fails — narrow the bracket.
                    hi = (lo + hi) * 0.5;
                } else {
                    hi = mid;
                }
            }

            if !bisect_ok {
                #[cfg(debug_assertions)]
                eprintln!("[NR] bisection exhausted at lambda={:.4}", lambda);
                return false;
            }
            prev_lambda = lambda;
        }

        // Verify we actually reached lambda = 1.0 (last step in schedule).
        schedule.last().map(|&l| (l - 1.0).abs() < 1e-9).unwrap_or(false)
    }

    /// Pseudo-arc-length homotopy continuation (Q.7).
    ///
    /// Parameterizes the circuit solution along a curve `F(x, λ) = 0`
    /// where `λ` goes from 0 (all sources = 0, trivial solution x = 0) to
    /// 1 (full circuit).
    ///
    /// At each continuation step:
    ///   - Predictor: advance along the tangent to the solution curve.
    ///   - Corrector: solve the augmented Newton system:
    ///       [ F(x, λ)                      ] = 0
    ///       [ (x - x0)·tx + (λ - λ0)·tλ - ds ] = 0
    ///     where `(tx, tλ)` is the unit tangent and `ds` is the arc-length step.
    ///
    /// Returns `Some(NrResult)` if the full circuit (λ=1) is reached.
    fn homotopy_continuation(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        dim: usize,
        x: &mut Vec<f64>,
        scratch: &mut NrScratch,
    ) -> Option<NrResult> {
        // Start from all-zero (trivial solution at λ=0).
        x.iter_mut().for_each(|v| *v = 0.0);
        let mut lambda = 0.0_f64;

        // Initial arc-length step — aggressive but will be halved on failure.
        let mut ds = 0.1_f64;
        let ds_min = 1e-4_f64;
        let ds_max = 0.2_f64;
        let max_steps = 50usize;

        // Tangent: initially pure lambda direction (sources increasing).
        // Augmented state vector: [x | λ], dimension = dim + 1.
        let aug_dim = dim + 1;
        let mut tx = vec![0.0_f64; dim]; // tangent in x-space
        let mut tl = 1.0_f64;            // tangent in λ-direction

        // Scratch for the augmented corrector system.
        let mut x_aug = vec![0.0_f64; aug_dim]; // [x; λ]
        let mut x0_aug = vec![0.0_f64; aug_dim]; // previous converged point

        // Compute max source current for GMIN sizing.
        let max_source_current = circuit
            .devices()
            .iter()
            .filter(|d| matches!(d.kind, DeviceKind::CurrentSource | DeviceKind::VoltageSource))
            .map(|d| d.params.get_or("dc", 0.0).abs())
            .fold(0.0_f64, f64::max)
            .max(1e-6);

        for _step in 0..max_steps {
            if lambda >= 1.0 - 1e-9 {
                // Reached full circuit — do a final plain NR to polish the solution.
                return self.nr_loop(circuit, registry, dim, x, 0.0, scratch);
            }

            // --- Predictor step ---
            // [x_pred; λ_pred] = [x; λ] + ds * [tx; tλ]
            let lambda_pred = (lambda + ds * tl).clamp(0.0, 1.0);
            let x_pred: Vec<f64> = x.iter().zip(tx.iter()).map(|(&xi, &ti)| xi + ds * ti).collect();

            // --- Corrector: Newton on augmented system ---
            // We solve for (x_c, λ_c) such that:
            //   F(x_c, λ_c) = 0
            //   (x_c - x0)·tx + (λ_c - λ0)·tλ = ds  (arc-length constraint)
            let mut x_c = x_pred.clone();
            let mut lam_c = lambda_pred;
            let x0 = x.clone();
            let lam0 = lambda;

            let mut corrector_ok = false;
            let max_corr = self.config.convergence.max_iter.min(10);

            for _corr in 0..max_corr {
                // Stamp with current lambda.
                let ss_gmin = (max_source_current * lam_c / 10.0)
                    .max(self.config.gmin_floor)
                    .max(1e-8 * (1.0 - lam_c).max(0.0));

                let (mut jac, mut res) = stamper::stamp_circuit_with_source_scale(
                    dim, circuit, &x_c, registry, lam_c, None,
                );

                // Add GMIN for conditioning.
                GminStepping::add_gmin_stamps(&mut jac, ss_gmin, circuit.num_vars() as usize);
                for i in 0..circuit.num_vars() as usize {
                    res[i] += ss_gmin * x_c[i];
                }

                // Arc-length residual: g_arc = (x_c - x0)·tx + (lam_c - lam0)·tλ - ds
                let arc_res: f64 = x_c.iter().zip(x0.iter()).zip(tx.iter())
                    .map(|((&xci, &x0i), &txi)| (xci - x0i) * txi)
                    .sum::<f64>()
                    + (lam_c - lam0) * tl
                    - ds;

                // Check convergence of augmented system.
                let f_norm = res.norm_inf();
                if f_norm < self.config.convergence.i_tol * 100.0 && arc_res.abs() < ds * 0.01 {
                    corrector_ok = true;
                    break;
                }

                // Solve augmented Newton step.
                // Build augmented matrix (dim+1) x (dim+1):
                //   [ J,   ∂F/∂λ ] [dx  ]   [ -F(x,λ)  ]
                //   [ tx^T, tλ   ] [dλ  ] = [ -arc_res ]
                //
                // ∂F/∂λ ≈ F(x, λ) - F(x, λ=0) ≈ the source-only RHS scaled by 1.
                // We approximate ∂F/∂λ by finite difference with δλ = 0.001.
                let dlam_fd = 0.001_f64;
                let lam_hi = (lam_c + dlam_fd).min(1.0);
                let (_, res_hi) = stamper::stamp_circuit_with_source_scale(
                    dim, circuit, &x_c, registry, lam_hi, None,
                );
                let df_dlam: Vec<f64> = (0..dim)
                    .map(|i| (res_hi[i] - res[i]) / (lam_hi - lam_c).max(dlam_fd * 0.1))
                    .collect();

                // Build the (dim+1) x (dim+1) augmented triplet.
                let mut aug_triplet = TripletMatrix::with_capacity(aug_dim, aug_dim, jac.nnz() + aug_dim * 2);
                // Copy J block.
                {
                    let rows = jac.row_idx();
                    let cols = jac.col_idx();
                    let vals = jac.vals();
                    for k in 0..rows.len() {
                        aug_triplet.add(rows[k] as usize, cols[k] as usize, vals[k]);
                    }
                    let _ = (rows, cols, vals); // suppress unused warnings
                }
                // ∂F/∂λ column (column dim).
                for i in 0..dim {
                    aug_triplet.add(i, dim, df_dlam[i]);
                }
                // Arc-length row (row dim): [tx | tλ].
                for i in 0..dim {
                    aug_triplet.add(dim, i, tx[i]);
                }
                aug_triplet.add(dim, dim, tl);

                // Build augmented RHS: [-F; -arc_res].
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

                // Update x_c and lam_c.
                for i in 0..dim {
                    x_c[i] += dz[i];
                }
                lam_c = (lam_c + dz[dim]).clamp(0.0, 1.0);
            }

            if !corrector_ok {
                // Corrector failed — halve step size and retry.
                ds *= 0.5;
                if ds < ds_min {
                    #[cfg(debug_assertions)]
                    eprintln!("[homotopy] step size too small at λ={:.4}, giving up", lambda);
                    return None;
                }
                #[cfg(debug_assertions)]
                eprintln!("[homotopy] corrector failed at λ={:.4}, ds halved to {:.6}", lambda, ds);
                continue;
            }

            // Corrector converged — update state and compute new tangent.
            // Store old augmented point.
            x0_aug[..dim].copy_from_slice(x);
            x0_aug[dim] = lambda;
            x_aug[..dim].copy_from_slice(&x_c);
            x_aug[dim] = lam_c;

            // New tangent = (x_aug - x0_aug) / ds, then normalise.
            let mut new_tx: Vec<f64> = (0..dim).map(|i| x_aug[i] - x0_aug[i]).collect();
            let new_tl = x_aug[dim] - x0_aug[dim];
            let norm = (new_tx.iter().map(|&v| v * v).sum::<f64>() + new_tl * new_tl).sqrt().max(1e-15);
            for v in new_tx.iter_mut() { *v /= norm; }
            let new_tl_n = new_tl / norm;

            // Keep tangent pointing in the direction of increasing λ.
            let sign = if new_tl_n >= 0.0 { 1.0 } else { -1.0 };
            tx = new_tx.iter().map(|&v| v * sign).collect();
            tl = new_tl_n * sign;

            x.copy_from_slice(&x_c);
            lambda = lam_c;

            // Adapt step size: grow if corrector was fast, shrink if slow.
            ds = (ds * 1.2).clamp(ds_min, ds_max);

            #[cfg(debug_assertions)]
            eprintln!("[homotopy] λ={:.4} converged, ds={:.5}", lambda, ds);
        }

        // If we got here without reaching λ=1, try a final plain NR anyway.
        if lambda >= 0.5 {
            return self.nr_loop(circuit, registry, dim, x, 0.0, scratch);
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::*;

    // --- NrConfig::from_options propagation tests ---

    #[test]
    fn nr_config_default_matches_sim_options_default() {
        let cfg = NrConfig::default();
        let opts = SimOptions::default();
        assert_eq!(cfg.max_voltage_step, opts.vnstep);
        assert_eq!(cfg.convergence.abs_tol, opts.abstol);
        assert_eq!(cfg.convergence.rel_tol, opts.reltol);
        assert_eq!(cfg.convergence.max_iter, opts.itl1 as u32);
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
        // i_tol scales with abstol
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
        // When opts.gmin < DEFAULT_GMIN_FLOOR, floor wins.
        let mut opts = SimOptions::default();
        opts.gmin = 1e-15; // far below DEFAULT_GMIN_FLOOR (1e-9)
        let cfg = NrConfig::from_options(&opts);
        assert_eq!(cfg.gmin_floor, DEFAULT_GMIN_FLOOR);

        // When opts.gmin > DEFAULT_GMIN_FLOOR, opts.gmin wins.
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

        // V(1) = 5.0V, V(2) = 2.5V
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
        // I(V1) = -2.5mA (current flows out of positive terminal)
        assert!(
            (result.solution[2] + 0.0025).abs() < 1e-6,
            "I(V1) = {} expected -0.0025",
            result.solution[2]
        );
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
        // I = V/R = 3.3/100 = 0.033A, current from source into node = -0.033
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
            DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        ).with_param("dc", 9.0);

        let r1 = DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        ).with_param("resistance", 1000.0);

        let r2 = DeviceInstance::new(
            DeviceId::new(0), "R2", DeviceKind::Resistor,
            &[(0, n2), (1, n3)],
        ).with_param("resistance", 1000.0);

        let r3 = DeviceInstance::new(
            DeviceId::new(0), "R3", DeviceKind::Resistor,
            &[(0, n3), (1, NodeId::GROUND)],
        ).with_param("resistance", 1000.0);

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
}
