/// `.MEASURE` / `.MEAS` post-processing evaluator.
///
/// Evaluates named measurements over transient, AC, and DC sweep results after
/// a simulation run completes.  All reductions use trapezoidal integration to
/// match ngspice behaviour.
use pisim_core::SimError;

use crate::result::{AcResult, DcSweepResult, ResultData, TransientResult};

// ---------------------------------------------------------------------------
// Public AST types
// ---------------------------------------------------------------------------

/// Which analysis type a `.MEAS` statement targets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeasureTarget {
    Transient,
    Ac,
    Dc,
}

/// AC-specific quantity selector for `VAc` signals.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcQuantity {
    /// Magnitude |V| — same as plain `V()` in AC context.
    Magnitude,
    /// Magnitude in dB: 20·log₁₀(|V|).
    Db,
    /// Real part Re(V).
    Real,
    /// Imaginary part Im(V).
    Imag,
    /// Phase in degrees: atan2(Im, Re)·180/π.
    Phase,
}

/// A signal that can be probed.
#[derive(Debug, Clone, PartialEq)]
pub enum Signal {
    /// Single-node voltage `V(node)`.
    V(String),
    /// Differential voltage `V(n1,n2)`.
    VDiff(String, String),
    /// Branch current `I(device)`.
    I(String),
    /// AC-specific node voltage with quantity selector.
    /// Covers `VM(n)`, `VDB(n)`, `VR(n)`, `VI(n)`, `VP(n)`.
    VAc(String, AcQuantity),
    /// Instantaneous power `P(device)` / `W(device)`.
    /// For voltage sources: V_pos * I_branch.
    /// The device name is used to look up the branch current; the positive
    /// terminal node name is assumed to match the device name (or the branch
    /// current sign convention gives power delivered to the circuit).
    Power(String),
    /// Binary expression between two signals: lhs OP rhs.
    /// Operator is one of `+`, `-`, `*`, `/`.
    BinaryExpr(Box<Signal>, char, Box<Signal>),
}

/// How to count crossings for RISE/FALL/CROSS.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CrossKind {
    Rise(u32),
    Fall(u32),
    Cross(u32),
}

/// Condition for WHEN-style measurements.
#[derive(Debug, Clone, PartialEq)]
pub enum WhenCond {
    /// Signal crosses a constant: `WHEN v(out)=0.5`.
    Eq(Signal, f64),
    /// Signal equals another signal: `WHEN v(a)=v(b)`.
    EqExpr(Signal, Signal),
}

/// A trigger or target edge definition for TRIG/TARG measurements.
#[derive(Debug, Clone, PartialEq)]
pub struct Trigger {
    pub signal: Signal,
    pub value: f64,
    pub rise_fall_cross: CrossKind,
    /// Optional time delay — the search starts no earlier than `td`.
    pub td: Option<f64>,
}

/// The measurement kind — what to compute.
#[derive(Debug, Clone, PartialEq)]
pub enum MeasureKind {
    // ---- point measurements ------------------------------------------------
    /// `FIND v(out) AT=1e-3` — interpolate signal at a fixed x-axis point.
    FindAt { signal: Signal, x: f64 },
    /// `FIND v(out) WHEN v(in)=0.5` — interpolate signal at a crossing.
    FindWhen { signal: Signal, cond: WhenCond },
    /// `WHEN v(out)=VAL RISE=N` — x-axis value at N-th crossing.
    WhenCross {
        signal: Signal,
        value: f64,
        rise: Option<u32>,
        fall: Option<u32>,
        cross: Option<u32>,
    },
    // ---- window measurements (TRIG/TARG define the window) -----------------
    /// Delay measurement: `TRIG … TARG …`.
    TrigTarg { trig: Trigger, targ: Trigger },
    // ---- reductions over a window ------------------------------------------
    Avg {
        signal: Signal,
        from: Option<f64>,
        to: Option<f64>,
    },
    Rms {
        signal: Signal,
        from: Option<f64>,
        to: Option<f64>,
    },
    Max {
        signal: Signal,
        from: Option<f64>,
        to: Option<f64>,
    },
    Min {
        signal: Signal,
        from: Option<f64>,
        to: Option<f64>,
    },
    /// Peak-to-peak.
    Pp {
        signal: Signal,
        from: Option<f64>,
        to: Option<f64>,
    },
    Integ {
        signal: Signal,
        from: Option<f64>,
        to: Option<f64>,
    },
    Deriv {
        signal: Signal,
        at: f64,
    },
    // ---- derived -----------------------------------------------------------
    /// `.MEAS … PARAM = {expr}` — post-process expression (stored as string).
    Param { expr: String },
    /// `.MEAS … EQN {expr}`.
    Eqn { expr: String },
}

/// A complete `.MEAS` statement.
#[derive(Debug, Clone)]
pub struct MeasureStatement {
    pub name: String,
    pub target: MeasureTarget,
    pub kind: MeasureKind,
}

// ---------------------------------------------------------------------------
// Core numeric helpers (operate on &[f64] slices)
// ---------------------------------------------------------------------------

/// Linear interpolation: given (x0,y0)→(x1,y1), find y at x.
#[inline]
fn lerp(x0: f64, y0: f64, x1: f64, y1: f64, x: f64) -> f64 {
    if (x1 - x0).abs() < f64::EPSILON {
        return y0;
    }
    y0 + (y1 - y0) * (x - x0) / (x1 - x0)
}

/// Interpolate `values` at position `x` using linear interpolation over `xs`.
/// Returns an error if `x` is outside the range.
pub fn interp_at(xs: &[f64], values: &[f64], x: f64) -> Result<f64, SimError> {
    if xs.is_empty() {
        return Err(SimError::Analysis("empty waveform".into()));
    }
    if x < xs[0] || x > xs[xs.len() - 1] {
        return Err(SimError::Analysis(format!(
            "x={x:.4e} is outside waveform range [{:.4e}, {:.4e}]",
            xs[0],
            xs[xs.len() - 1]
        )));
    }
    let idx = xs.partition_point(|&t| t <= x).saturating_sub(1);
    let idx = idx.min(xs.len() - 2);
    Ok(lerp(xs[idx], values[idx], xs[idx + 1], values[idx + 1], x))
}

/// Find the x-axis position of the N-th crossing of `threshold` with
/// direction `kind`.  Returns an interpolated x value.
///
/// - `CrossKind::Rise(n)` — n-th upward crossing (below → above threshold).
/// - `CrossKind::Fall(n)` — n-th downward crossing.
/// - `CrossKind::Cross(n)` — n-th crossing in either direction.
///
/// `after_x` restricts the search to `x > after_x`.
pub fn crossing_x(
    xs: &[f64],
    values: &[f64],
    threshold: f64,
    kind: CrossKind,
    after_x: Option<f64>,
) -> Result<f64, SimError> {
    let start = after_x
        .map(|t| xs.partition_point(|&v| v < t))
        .unwrap_or(0);

    let (target_n, want_rise, want_fall) = match kind {
        CrossKind::Rise(n) => (n as usize, true, false),
        CrossKind::Fall(n) => (n as usize, false, true),
        CrossKind::Cross(n) => (n as usize, true, true),
    };

    let mut count = 0usize;

    for i in start..values.len().saturating_sub(1) {
        let y0 = values[i] - threshold;
        let y1 = values[i + 1] - threshold;
        let is_rise = y0 < 0.0 && y1 >= 0.0;
        let is_fall = y0 > 0.0 && y1 <= 0.0;

        if (want_rise && is_rise) || (want_fall && is_fall) {
            count += 1;
            if count == target_n {
                // Linear interpolation to find exact x of the crossing.
                let frac = if (y1 - y0).abs() < f64::EPSILON {
                    0.0
                } else {
                    -y0 / (y1 - y0)
                };
                return Ok(xs[i] + frac * (xs[i + 1] - xs[i]));
            }
        }
    }

    Err(SimError::Analysis(format!(
        "crossing #{target_n} not found (threshold={threshold:.4e}, kind={kind:?})"
    )))
}

/// Restrict `xs`/`values` to the window `[from, to]` with boundary
/// interpolation injected at both ends.
pub fn window_slice(
    xs: &[f64],
    values: &[f64],
    from: Option<f64>,
    to: Option<f64>,
) -> (Vec<f64>, Vec<f64>) {
    if xs.is_empty() {
        return (Vec::new(), Vec::new());
    }
    let x_start = from.unwrap_or(xs[0]);
    let x_end = to.unwrap_or(xs[xs.len() - 1]);

    let mut out_x: Vec<f64> = Vec::new();
    let mut out_v: Vec<f64> = Vec::new();

    // Inject interpolated boundary at x_start.
    let first_in = xs.partition_point(|&x| x < x_start);
    if first_in > 0 && first_in < xs.len() && xs[first_in - 1] < x_start {
        let y = lerp(xs[first_in - 1], values[first_in - 1], xs[first_in], values[first_in], x_start);
        out_x.push(x_start);
        out_v.push(y);
    }

    for i in 0..xs.len() {
        if xs[i] >= x_start && xs[i] <= x_end {
            out_x.push(xs[i]);
            out_v.push(values[i]);
        }
    }

    // Inject interpolated boundary at x_end.
    let last_in = xs.partition_point(|&x| x <= x_end);
    if last_in > 0 && last_in < xs.len() {
        if out_x.last().copied().map_or(true, |v| v < x_end) {
            let y = lerp(xs[last_in - 1], values[last_in - 1], xs[last_in], values[last_in], x_end);
            out_x.push(x_end);
            out_v.push(y);
        }
    }

    (out_x, out_v)
}

/// Trapezoidal integration of `values` over `xs`.
#[inline]
fn trapz(xs: &[f64], values: &[f64]) -> f64 {
    xs.windows(2)
        .zip(values.windows(2))
        .map(|(xw, yw)| 0.5 * (yw[0] + yw[1]) * (xw[1] - xw[0]))
        .sum()
}

/// Time-weighted average using trapezoidal integration.
pub fn avg_trapz(xs: &[f64], values: &[f64]) -> Result<f64, SimError> {
    if xs.len() < 2 {
        return Err(SimError::Analysis("window too short for AVG".into()));
    }
    let span = xs[xs.len() - 1] - xs[0];
    if span == 0.0 {
        return Err(SimError::Analysis("window has zero span for AVG".into()));
    }
    Ok(trapz(xs, values) / span)
}

/// RMS via trapezoidal integration of `values²`.
pub fn rms_trapz(xs: &[f64], values: &[f64]) -> Result<f64, SimError> {
    if xs.len() < 2 {
        return Err(SimError::Analysis("window too short for RMS".into()));
    }
    let span = xs[xs.len() - 1] - xs[0];
    if span == 0.0 {
        return Err(SimError::Analysis("window has zero span for RMS".into()));
    }
    let sq: Vec<f64> = values.iter().map(|&v| v * v).collect();
    Ok((trapz(xs, &sq) / span).sqrt())
}

/// Max value in slice.
pub fn max_in(values: &[f64]) -> Result<f64, SimError> {
    values
        .iter()
        .copied()
        .reduce(f64::max)
        .ok_or_else(|| SimError::Analysis("empty window for MAX".into()))
}

/// Min value in slice.
pub fn min_in(values: &[f64]) -> Result<f64, SimError> {
    values
        .iter()
        .copied()
        .reduce(f64::min)
        .ok_or_else(|| SimError::Analysis("empty window for MIN".into()))
}

/// Trapezoidal integral (not normalised by span).
pub fn integ_trapz(xs: &[f64], values: &[f64]) -> Result<f64, SimError> {
    if xs.len() < 2 {
        return Err(SimError::Analysis("window too short for INTEG".into()));
    }
    Ok(trapz(xs, values))
}

/// Numerical derivative at `x` (forward difference over the bracketing interval).
pub fn deriv_at(xs: &[f64], values: &[f64], x: f64) -> Result<f64, SimError> {
    if xs.len() < 2 {
        return Err(SimError::Analysis("too few points for DERIV".into()));
    }
    let idx = xs.partition_point(|&t| t <= x).saturating_sub(1);
    let idx = idx.min(xs.len() - 2);
    let dx = xs[idx + 1] - xs[idx];
    if dx.abs() < f64::EPSILON {
        return Err(SimError::Analysis("zero dx in DERIV".into()));
    }
    Ok((values[idx + 1] - values[idx]) / dx)
}

// ---------------------------------------------------------------------------
// Expression helpers
// ---------------------------------------------------------------------------

/// Apply a binary operator to two f64 values.
#[inline]
fn apply_binop(op: char, l: f64, r: f64) -> Result<f64, SimError> {
    match op {
        '+' => Ok(l + r),
        '-' => Ok(l - r),
        '*' => Ok(l * r),
        '/' => {
            if r.abs() < f64::MIN_POSITIVE {
                Err(SimError::Analysis("division by zero in .MEASURE expression".into()))
            } else {
                Ok(l / r)
            }
        }
        _ => Err(SimError::Analysis(format!("unknown operator '{op}' in .MEASURE expression"))),
    }
}

// ---------------------------------------------------------------------------
// Signal resolution helpers
// ---------------------------------------------------------------------------

/// Resolve a `Signal` to a values vector from a `TransientResult`.
/// `node_names` must correspond to the column order in `result`.
fn resolve_tran(
    sig: &Signal,
    result: &TransientResult,
    node_names: &[String],
) -> Result<Vec<f64>, SimError> {
    match sig {
        Signal::V(node) => {
            let idx = node_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(node))
                .ok_or_else(|| SimError::NodeNotFound(node.clone()))?;
            Ok((0..result.num_steps())
                .map(|s| result.voltage(s, idx))
                .collect())
        }
        Signal::VDiff(n1, n2) => {
            let i1 = node_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(n1))
                .ok_or_else(|| SimError::NodeNotFound(n1.clone()))?;
            let i2 = node_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(n2))
                .ok_or_else(|| SimError::NodeNotFound(n2.clone()))?;
            Ok((0..result.num_steps())
                .map(|s| result.voltage(s, i1) - result.voltage(s, i2))
                .collect())
        }
        Signal::I(device) => {
            let br_idx = result
                .branch_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(device))
                .ok_or_else(|| {
                    SimError::Analysis(format!(
                        ".MEASURE I({device}): branch not found in transient result"
                    ))
                })?;
            Ok((0..result.num_steps())
                .map(|s| result.branch_current(s, br_idx))
                .collect())
        }
        Signal::Power(device) => {
            // P(device) = V_pos * I_branch.
            // Branch current sign: MNA convention — current flows into the positive
            // terminal of the voltage source, so power *delivered by* the source is
            // V * (-I_branch).  We return V * I_branch (absorbed power convention)
            // consistent with ngspice `P()`.
            let br_idx = result
                .branch_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(device))
                .ok_or_else(|| {
                    SimError::Analysis(format!(
                        ".MEASURE P({device}): branch not found in transient result"
                    ))
                })?;
            // Positive-terminal node: try to find a node named after the device.
            // If not found, fall back to using just the branch current magnitude
            // (power delivered = V_source * I — but V_source is unknown without
            // node info, so we require a matching node name).
            let node_idx = node_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(device));
            match node_idx {
                Some(ni) => Ok((0..result.num_steps())
                    .map(|s| result.voltage(s, ni) * result.branch_current(s, br_idx))
                    .collect()),
                None => {
                    // No node named after device: return branch current * 1.0
                    // as a proxy (caller can multiply by supply voltage externally).
                    // This matches behaviour when the device is a current source.
                    Ok((0..result.num_steps())
                        .map(|s| result.branch_current(s, br_idx))
                        .collect())
                }
            }
        }
        Signal::BinaryExpr(lhs, op, rhs) => {
            let lv = resolve_tran(lhs, result, node_names)?;
            let rv = resolve_tran(rhs, result, node_names)?;
            lv.iter()
                .zip(rv.iter())
                .map(|(&l, &r)| apply_binop(*op, l, r))
                .collect::<Result<Vec<f64>, SimError>>()
        }
        Signal::VAc(_, _) => Err(SimError::Analysis(
            "VAc/VDB/VR/VI/VP signals are only valid for AC .MEASURE".into(),
        )),
    }
}

/// Resolve a `Signal` to a values vector from an `AcResult`.
///
/// `V(n)` and `VM(n)` return magnitude.  `VDB(n)` returns 20·log₁₀(mag).
/// `VR(n)` returns real part, `VI(n)` imaginary, `VP(n)` phase in degrees.
fn resolve_ac(
    sig: &Signal,
    result: &AcResult,
    node_names: &[String],
) -> Result<Vec<f64>, SimError> {
    /// Look up a node index, returning NodeNotFound on failure.
    fn node_idx(node_names: &[String], name: &str) -> Result<usize, SimError> {
        node_names
            .iter()
            .position(|n| n.eq_ignore_ascii_case(name))
            .ok_or_else(|| SimError::NodeNotFound(name.to_string()))
    }

    match sig {
        Signal::V(node) => {
            let idx = node_idx(node_names, node)?;
            Ok(result.node_magnitudes.iter().map(|row| row[idx]).collect())
        }
        Signal::VDiff(n1, n2) => {
            let i1 = node_idx(node_names, n1)?;
            let i2 = node_idx(node_names, n2)?;
            Ok(result
                .node_magnitudes
                .iter()
                .map(|row| row[i1] - row[i2])
                .collect())
        }
        Signal::VAc(node, qty) => {
            let idx = node_idx(node_names, node)?;
            match qty {
                AcQuantity::Magnitude => {
                    Ok(result.node_magnitudes.iter().map(|row| row[idx]).collect())
                }
                AcQuantity::Db => Ok(result
                    .node_magnitudes
                    .iter()
                    .map(|row| 20.0 * row[idx].max(f64::MIN_POSITIVE).log10())
                    .collect()),
                AcQuantity::Real => {
                    Ok(result.node_reals.iter().map(|row| row[idx]).collect())
                }
                AcQuantity::Imag => {
                    Ok(result.node_imags.iter().map(|row| row[idx]).collect())
                }
                AcQuantity::Phase => Ok(result
                    .node_imags
                    .iter()
                    .zip(result.node_reals.iter())
                    .map(|(im_row, re_row)| {
                        im_row[idx].atan2(re_row[idx]) * (180.0 / std::f64::consts::PI)
                    })
                    .collect()),
            }
        }
        Signal::I(_) => Err(SimError::Analysis(
            "I() branch currents are not available in AC .MEASURE (no branch current storage in AcResult)".into(),
        )),
        Signal::Power(_) => Err(SimError::Analysis(
            "P()/W() power not available in AC .MEASURE".into(),
        )),
        Signal::BinaryExpr(lhs, op, rhs) => {
            let lv = resolve_ac(lhs, result, node_names)?;
            let rv = resolve_ac(rhs, result, node_names)?;
            lv.iter()
                .zip(rv.iter())
                .map(|(&l, &r)| apply_binop(*op, l, r))
                .collect::<Result<Vec<f64>, SimError>>()
        }
    }
}

/// Resolve a `Signal` to a values vector from a `DcSweepResult`.
fn resolve_dc(
    sig: &Signal,
    result: &DcSweepResult,
    node_names: &[String],
) -> Result<Vec<f64>, SimError> {
    match sig {
        Signal::V(node) => {
            let idx = node_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(node))
                .ok_or_else(|| SimError::NodeNotFound(node.clone()))?;
            Ok(result.node_voltages.iter().map(|row| row[idx]).collect())
        }
        Signal::VDiff(n1, n2) => {
            let i1 = node_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(n1))
                .ok_or_else(|| SimError::NodeNotFound(n1.clone()))?;
            let i2 = node_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(n2))
                .ok_or_else(|| SimError::NodeNotFound(n2.clone()))?;
            Ok(result
                .node_voltages
                .iter()
                .map(|row| row[i1] - row[i2])
                .collect())
        }
        Signal::I(_) => Err(SimError::Analysis(
            "I() branch currents are not available in DC sweep .MEASURE (no branch current storage in DcSweepResult)".into(),
        )),
        Signal::Power(_) => Err(SimError::Analysis(
            "P()/W() power not available in DC sweep .MEASURE".into(),
        )),
        Signal::BinaryExpr(lhs, op, rhs) => {
            let lv = resolve_dc(lhs, result, node_names)?;
            let rv = resolve_dc(rhs, result, node_names)?;
            lv.iter()
                .zip(rv.iter())
                .map(|(&l, &r)| apply_binop(*op, l, r))
                .collect::<Result<Vec<f64>, SimError>>()
        }
        Signal::VAc(_, _) => Err(SimError::Analysis(
            "VAc/VDB/VR/VI/VP signals are only valid for AC .MEASURE".into(),
        )),
    }
}

// ---------------------------------------------------------------------------
// Evaluator entry points
// ---------------------------------------------------------------------------

/// Evaluate a single `.MEAS` statement against a simulation result.
///
/// `node_names` must be in the same order as the columns in `data`.
pub fn eval_measure(
    stmt: &MeasureStatement,
    data: &ResultData,
    node_names: &[String],
) -> Result<f64, SimError> {
    match stmt.target {
        MeasureTarget::Transient => {
            let tran = match data {
                ResultData::Transient(r) => r,
                _ => {
                    return Err(SimError::Analysis(
                        ".MEAS TRAN applied to non-transient result".into(),
                    ))
                }
            };
            eval_tran(stmt, tran, node_names)
        }
        MeasureTarget::Ac => {
            let ac = match data {
                ResultData::Ac(r) => r,
                _ => {
                    return Err(SimError::Analysis(
                        ".MEAS AC applied to non-AC result".into(),
                    ))
                }
            };
            eval_ac(stmt, ac, node_names)
        }
        MeasureTarget::Dc => {
            let dc = match data {
                ResultData::DcSweep(r) => r,
                _ => {
                    return Err(SimError::Analysis(
                        ".MEAS DC applied to non-DC-sweep result".into(),
                    ))
                }
            };
            eval_dc(stmt, dc, node_names)
        }
    }
}

/// Evaluate all `.MEAS` statements, returning `(name, result)` pairs in order.
pub fn eval_all(
    stmts: &[MeasureStatement],
    data: &ResultData,
    node_names: &[String],
) -> Vec<(String, Result<f64, SimError>)> {
    stmts
        .iter()
        .map(|s| (s.name.clone(), eval_measure(s, data, node_names)))
        .collect()
}

// ---------------------------------------------------------------------------
// Per-analysis evaluators
// ---------------------------------------------------------------------------

fn eval_tran(
    stmt: &MeasureStatement,
    result: &TransientResult,
    node_names: &[String],
) -> Result<f64, SimError> {
    let times = &result.times;
    let sig = |s: &Signal| resolve_tran(s, result, node_names);

    match &stmt.kind {
        MeasureKind::FindAt { signal, x } => {
            let values = sig(signal)?;
            interp_at(times, &values, *x)
        }

        MeasureKind::FindWhen { signal, cond } => {
            let values = sig(signal)?;
            let cross_t = eval_when_cond_tran(cond, times, result, node_names)?;
            interp_at(times, &values, cross_t)
        }

        MeasureKind::WhenCross { signal, value, rise, fall, cross } => {
            let values = sig(signal)?;
            let kind = resolve_cross_kind(*rise, *fall, *cross);
            crossing_x(times, &values, *value, kind, None)
        }

        MeasureKind::TrigTarg { trig, targ } => {
            let trig_vals = sig(&trig.signal)?;
            let targ_vals = sig(&targ.signal)?;
            let trig_t = crossing_x(times, &trig_vals, trig.value, trig.rise_fall_cross, trig.td)?;
            let targ_t = crossing_x(times, &targ_vals, targ.value, targ.rise_fall_cross, Some(trig_t))?;
            Ok(targ_t - trig_t)
        }

        MeasureKind::Avg { signal, from, to } => {
            let values = sig(signal)?;
            let (xs, vs) = window_slice(times, &values, *from, *to);
            avg_trapz(&xs, &vs)
        }

        MeasureKind::Rms { signal, from, to } => {
            let values = sig(signal)?;
            let (xs, vs) = window_slice(times, &values, *from, *to);
            rms_trapz(&xs, &vs)
        }

        MeasureKind::Max { signal, from, to } => {
            let values = sig(signal)?;
            let (_xs, vs) = window_slice(times, &values, *from, *to);
            max_in(&vs)
        }

        MeasureKind::Min { signal, from, to } => {
            let values = sig(signal)?;
            let (_xs, vs) = window_slice(times, &values, *from, *to);
            min_in(&vs)
        }

        MeasureKind::Pp { signal, from, to } => {
            let values = sig(signal)?;
            let (_xs, vs) = window_slice(times, &values, *from, *to);
            Ok(max_in(&vs)? - min_in(&vs)?)
        }

        MeasureKind::Integ { signal, from, to } => {
            let values = sig(signal)?;
            let (xs, vs) = window_slice(times, &values, *from, *to);
            integ_trapz(&xs, &vs)
        }

        MeasureKind::Deriv { signal, at } => {
            let values = sig(signal)?;
            deriv_at(times, &values, *at)
        }

        MeasureKind::Param { expr } | MeasureKind::Eqn { expr } => Err(SimError::Analysis(
            format!(".MEAS PARAM/EQN expression evaluation not yet supported: {expr}"),
        )),
    }
}

fn eval_ac(
    stmt: &MeasureStatement,
    result: &AcResult,
    node_names: &[String],
) -> Result<f64, SimError> {
    let freqs = &result.frequencies;
    let sig = |s: &Signal| resolve_ac(s, result, node_names);

    match &stmt.kind {
        MeasureKind::FindAt { signal, x } => {
            let values = sig(signal)?;
            interp_at(freqs, &values, *x)
        }
        MeasureKind::Max { signal, from, to } => {
            let values = sig(signal)?;
            let (_xs, vs) = window_slice(freqs, &values, *from, *to);
            max_in(&vs)
        }
        MeasureKind::Min { signal, from, to } => {
            let values = sig(signal)?;
            let (_xs, vs) = window_slice(freqs, &values, *from, *to);
            min_in(&vs)
        }
        MeasureKind::Avg { signal, from, to } => {
            let values = sig(signal)?;
            let (xs, vs) = window_slice(freqs, &values, *from, *to);
            avg_trapz(&xs, &vs)
        }
        MeasureKind::Rms { signal, from, to } => {
            let values = sig(signal)?;
            let (xs, vs) = window_slice(freqs, &values, *from, *to);
            rms_trapz(&xs, &vs)
        }
        MeasureKind::Pp { signal, from, to } => {
            let values = sig(signal)?;
            let (_xs, vs) = window_slice(freqs, &values, *from, *to);
            Ok(max_in(&vs)? - min_in(&vs)?)
        }
        MeasureKind::Integ { signal, from, to } => {
            let values = sig(signal)?;
            let (xs, vs) = window_slice(freqs, &values, *from, *to);
            integ_trapz(&xs, &vs)
        }
        MeasureKind::FindWhen { signal, cond } => {
            let values = sig(signal)?;
            // Resolve the crossing frequency from the WHEN condition.
            let cross_f = match cond {
                WhenCond::Eq(csig, threshold) => {
                    let cv = resolve_ac(csig, result, node_names)?;
                    crossing_x(freqs, &cv, *threshold, CrossKind::Rise(1), None)
                }
                WhenCond::EqExpr(sig_a, sig_b) => {
                    let va = resolve_ac(sig_a, result, node_names)?;
                    let vb = resolve_ac(sig_b, result, node_names)?;
                    let diff: Vec<f64> = va.iter().zip(vb.iter()).map(|(a, b)| a - b).collect();
                    crossing_x(freqs, &diff, 0.0, CrossKind::Rise(1), None)
                }
            }?;
            interp_at(freqs, &values, cross_f)
        }
        MeasureKind::WhenCross { signal, value, rise, fall, cross } => {
            let values = sig(signal)?;
            let kind = resolve_cross_kind(*rise, *fall, *cross);
            crossing_x(freqs, &values, *value, kind, None)
        }
        MeasureKind::TrigTarg { trig, targ } => {
            let trig_vals = sig(&trig.signal)?;
            let targ_vals = sig(&targ.signal)?;
            let trig_f = crossing_x(freqs, &trig_vals, trig.value, trig.rise_fall_cross, trig.td)?;
            let targ_f = crossing_x(freqs, &targ_vals, targ.value, targ.rise_fall_cross, Some(trig_f))?;
            Ok(targ_f - trig_f)
        }
        MeasureKind::Deriv { signal, at } => {
            let values = sig(signal)?;
            deriv_at(freqs, &values, *at)
        }
        _ => Err(SimError::Analysis(
            "unsupported .MEAS kind for AC analysis".into(),
        )),
    }
}

fn eval_dc(
    stmt: &MeasureStatement,
    result: &DcSweepResult,
    node_names: &[String],
) -> Result<f64, SimError> {
    let xs = &result.sweep_values;
    let sig = |s: &Signal| resolve_dc(s, result, node_names);

    match &stmt.kind {
        MeasureKind::FindAt { signal, x } => {
            let values = sig(signal)?;
            interp_at(xs, &values, *x)
        }
        MeasureKind::Max { signal, from, to } => {
            let values = sig(signal)?;
            let (_xw, vs) = window_slice(xs, &values, *from, *to);
            max_in(&vs)
        }
        MeasureKind::Min { signal, from, to } => {
            let values = sig(signal)?;
            let (_xw, vs) = window_slice(xs, &values, *from, *to);
            min_in(&vs)
        }
        MeasureKind::Avg { signal, from, to } => {
            let values = sig(signal)?;
            let (xw, vs) = window_slice(xs, &values, *from, *to);
            avg_trapz(&xw, &vs)
        }
        MeasureKind::Rms { signal, from, to } => {
            let values = sig(signal)?;
            let (xw, vs) = window_slice(xs, &values, *from, *to);
            rms_trapz(&xw, &vs)
        }
        MeasureKind::Pp { signal, from, to } => {
            let values = sig(signal)?;
            let (_xw, vs) = window_slice(xs, &values, *from, *to);
            Ok(max_in(&vs)? - min_in(&vs)?)
        }
        MeasureKind::Integ { signal, from, to } => {
            let values = sig(signal)?;
            let (xw, vs) = window_slice(xs, &values, *from, *to);
            integ_trapz(&xw, &vs)
        }
        MeasureKind::WhenCross { signal, value, rise, fall, cross } => {
            let values = sig(signal)?;
            let kind = resolve_cross_kind(*rise, *fall, *cross);
            crossing_x(xs, &values, *value, kind, None)
        }
        MeasureKind::FindWhen { signal, cond } => {
            let values = sig(signal)?;
            let cross_x = match cond {
                WhenCond::Eq(csig, threshold) => {
                    let cv = resolve_dc(csig, result, node_names)?;
                    crossing_x(xs, &cv, *threshold, CrossKind::Rise(1), None)
                }
                WhenCond::EqExpr(sig_a, sig_b) => {
                    let va = resolve_dc(sig_a, result, node_names)?;
                    let vb = resolve_dc(sig_b, result, node_names)?;
                    let diff: Vec<f64> = va.iter().zip(vb.iter()).map(|(a, b)| a - b).collect();
                    crossing_x(xs, &diff, 0.0, CrossKind::Rise(1), None)
                }
            }?;
            interp_at(xs, &values, cross_x)
        }
        MeasureKind::TrigTarg { trig, targ } => {
            let trig_vals = sig(&trig.signal)?;
            let targ_vals = sig(&targ.signal)?;
            let trig_x = crossing_x(xs, &trig_vals, trig.value, trig.rise_fall_cross, trig.td)?;
            let targ_x = crossing_x(xs, &targ_vals, targ.value, targ.rise_fall_cross, Some(trig_x))?;
            Ok(targ_x - trig_x)
        }
        MeasureKind::Deriv { signal, at } => {
            let values = sig(signal)?;
            deriv_at(xs, &values, *at)
        }
        _ => Err(SimError::Analysis(
            "unsupported .MEAS kind for DC analysis".into(),
        )),
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Resolve RISE/FALL/CROSS priority for WhenCross: RISE > FALL > CROSS.
fn resolve_cross_kind(rise: Option<u32>, fall: Option<u32>, cross: Option<u32>) -> CrossKind {
    if let Some(n) = rise {
        CrossKind::Rise(n)
    } else if let Some(n) = fall {
        CrossKind::Fall(n)
    } else {
        CrossKind::Cross(cross.unwrap_or(1))
    }
}

/// Evaluate a WHEN condition for transient analysis; returns the x (time) at
/// which the condition is first satisfied.
fn eval_when_cond_tran(
    cond: &WhenCond,
    times: &[f64],
    result: &TransientResult,
    node_names: &[String],
) -> Result<f64, SimError> {
    match cond {
        WhenCond::Eq(sig, threshold) => {
            let values = resolve_tran(sig, result, node_names)?;
            crossing_x(times, &values, *threshold, CrossKind::Rise(1), None)
        }
        WhenCond::EqExpr(sig_a, sig_b) => {
            let va = resolve_tran(sig_a, result, node_names)?;
            let vb = resolve_tran(sig_b, result, node_names)?;
            let diff: Vec<f64> = va.iter().zip(vb.iter()).map(|(a, b)| a - b).collect();
            crossing_x(times, &diff, 0.0, CrossKind::Rise(1), None)
        }
    }
}

// ---------------------------------------------------------------------------
// Parser helpers
// ---------------------------------------------------------------------------

/// Parse a `.MEAS` / `.MEASURE` line from whitespace-split tokens.
///
/// Expected token layout:
/// ```text
/// [0]      [1]        [2..]
/// TRAN     name       KIND signal [options...]
/// ```
///
/// Returns `None` for unrecognised forms; callers should skip silently.
pub fn parse_measure_line(tokens: &[&str]) -> Option<MeasureStatement> {
    if tokens.len() < 3 {
        return None;
    }

    let target = match tokens[0].to_ascii_lowercase().as_str() {
        "tran" => MeasureTarget::Transient,
        "ac" => MeasureTarget::Ac,
        "dc" => MeasureTarget::Dc,
        _ => return None,
    };

    let name = tokens[1].to_ascii_lowercase();
    let kind = parse_measure_kind(&tokens[2..])?;
    Some(MeasureStatement { name, target, kind })
}

fn parse_measure_kind(rest: &[&str]) -> Option<MeasureKind> {
    if rest.is_empty() {
        return None;
    }

    match rest[0].to_ascii_lowercase().as_str() {
        "avg" => {
            let signal = parse_signal(rest.get(1)?)?;
            let (from, to) = parse_from_to(&rest[2..]);
            Some(MeasureKind::Avg { signal, from, to })
        }
        "rms" => {
            let signal = parse_signal(rest.get(1)?)?;
            let (from, to) = parse_from_to(&rest[2..]);
            Some(MeasureKind::Rms { signal, from, to })
        }
        "max" => {
            let signal = parse_signal(rest.get(1)?)?;
            let (from, to) = parse_from_to(&rest[2..]);
            Some(MeasureKind::Max { signal, from, to })
        }
        "min" => {
            let signal = parse_signal(rest.get(1)?)?;
            let (from, to) = parse_from_to(&rest[2..]);
            Some(MeasureKind::Min { signal, from, to })
        }
        "pp" => {
            let signal = parse_signal(rest.get(1)?)?;
            let (from, to) = parse_from_to(&rest[2..]);
            Some(MeasureKind::Pp { signal, from, to })
        }
        "integ" => {
            let signal = parse_signal(rest.get(1)?)?;
            let (from, to) = parse_from_to(&rest[2..]);
            Some(MeasureKind::Integ { signal, from, to })
        }
        "find" => parse_find_kind(&rest[1..]),
        "when" => parse_when_kind(&rest[1..]),
        "trig" => parse_trig_targ_kind(rest),
        "param" => {
            let expr = rest[1..].join(" ");
            Some(MeasureKind::Param { expr })
        }
        "eqn" => {
            let expr = rest[1..].join(" ");
            Some(MeasureKind::Eqn { expr })
        }
        _ => None,
    }
}

fn parse_find_kind(rest: &[&str]) -> Option<MeasureKind> {
    if rest.is_empty() {
        return None;
    }
    let signal = parse_signal(rest[0])?;

    for (i, tok) in rest.iter().enumerate().skip(1) {
        let lower = tok.to_ascii_lowercase();
        if let Some(val_str) = lower.strip_prefix("at=") {
            if let Ok(x) = parse_spice_value(val_str) {
                return Some(MeasureKind::FindAt { signal, x });
            }
        }
        if lower == "when" {
            let cond = parse_when_cond(&rest[i + 1..])?;
            return Some(MeasureKind::FindWhen { signal, cond });
        }
    }
    None
}

fn parse_when_kind(rest: &[&str]) -> Option<MeasureKind> {
    // WHEN v(out)=0.5 [RISE=1 | FALL=1 | CROSS=1]
    if rest.is_empty() {
        return None;
    }
    let (signal, value) = parse_signal_eq_value(rest[0])?;
    let mut rise = None;
    let mut fall = None;
    let mut cross = None;
    for tok in &rest[1..] {
        let lower = tok.to_ascii_lowercase();
        if let Some(v) = lower.strip_prefix("rise=") {
            rise = v.parse::<u32>().ok();
        } else if let Some(v) = lower.strip_prefix("fall=") {
            fall = v.parse::<u32>().ok();
        } else if let Some(v) = lower.strip_prefix("cross=") {
            cross = v.parse::<u32>().ok();
        }
    }
    Some(MeasureKind::WhenCross { signal, value, rise, fall, cross })
}

fn parse_trig_targ_kind(rest: &[&str]) -> Option<MeasureKind> {
    // TRIG v(out) VAL=0.1 RISE=1 TARG v(out) VAL=0.9 RISE=1
    // `rest[0]` is "trig"; split on "targ".
    let targ_pos = rest.iter().position(|t| t.to_ascii_lowercase() == "targ")?;
    let trig_tokens = &rest[1..targ_pos];
    let targ_tokens = &rest[targ_pos + 1..];

    let trig = parse_trigger(trig_tokens)?;
    let targ = parse_trigger(targ_tokens)?;
    Some(MeasureKind::TrigTarg { trig, targ })
}

fn parse_trigger(tokens: &[&str]) -> Option<Trigger> {
    if tokens.is_empty() {
        return None;
    }
    let signal = parse_signal(tokens[0])?;
    let mut value = 0.0_f64;
    let mut rise_fall_cross = CrossKind::Rise(1);
    let mut td = None;

    for tok in &tokens[1..] {
        let lower = tok.to_ascii_lowercase();
        if let Some(v) = lower.strip_prefix("val=") {
            value = parse_spice_value(v).ok()?;
        } else if let Some(v) = lower.strip_prefix("rise=") {
            if let Ok(n) = v.parse::<u32>() {
                rise_fall_cross = CrossKind::Rise(n);
            }
        } else if let Some(v) = lower.strip_prefix("fall=") {
            if let Ok(n) = v.parse::<u32>() {
                rise_fall_cross = CrossKind::Fall(n);
            }
        } else if let Some(v) = lower.strip_prefix("cross=") {
            if let Ok(n) = v.parse::<u32>() {
                rise_fall_cross = CrossKind::Cross(n);
            }
        } else if let Some(v) = lower.strip_prefix("td=") {
            td = parse_spice_value(v).ok();
        }
    }

    Some(Trigger { signal, value, rise_fall_cross, td })
}

fn parse_when_cond(tokens: &[&str]) -> Option<WhenCond> {
    if tokens.is_empty() {
        return None;
    }
    let tok = tokens[0];
    // Try `signal=value` first.
    if let Some((signal, value)) = parse_signal_eq_value(tok) {
        return Some(WhenCond::Eq(signal, value));
    }
    // Try `signal=signal`.
    if let Some(eq_pos) = tok.find('=') {
        let lhs = parse_signal(&tok[..eq_pos])?;
        let rhs = parse_signal(&tok[eq_pos + 1..])?;
        return Some(WhenCond::EqExpr(lhs, rhs));
    }
    None
}

/// Parse a signal token: `v(node)`, `v(n1,n2)`, `i(device)`,
/// `vm(n)`, `vdb(n)`, `vr(n)`, `vi(n)`, `vp(n)`,
/// `p(device)`, `w(device)`,
/// or a binary expression like `v(a)-v(b)` / `v(a)+v(b)`.
pub fn parse_signal(tok: &str) -> Option<Signal> {
    let lower = tok.to_ascii_lowercase();

    // Binary expression: scan for an operator (+, -, *, /) that sits outside
    // all parentheses.  We scan right-to-left so that `v(a)-v(b)-v(c)` is
    // parsed left-associatively as `(v(a)-v(b))-v(c)`.
    {
        let bytes = tok.as_bytes();
        let mut depth: i32 = 0;
        let mut split: Option<(usize, char)> = None;
        for i in (0..bytes.len()).rev() {
            match bytes[i] {
                b')' => depth += 1,
                b'(' => depth -= 1,
                b'+' | b'-' | b'*' | b'/' if depth == 0 && i > 0 => {
                    // Do not treat a leading `-` as a binary op.
                    split = Some((i, bytes[i] as char));
                    break;
                }
                _ => {}
            }
        }
        if let Some((pos, op)) = split {
            let lhs_str = tok[..pos].trim();
            let rhs_str = tok[pos + 1..].trim();
            if !lhs_str.is_empty() && !rhs_str.is_empty() {
                if let (Some(lhs), Some(rhs)) = (parse_signal(lhs_str), parse_signal(rhs_str)) {
                    return Some(Signal::BinaryExpr(Box::new(lhs), op, Box::new(rhs)));
                }
            }
        }
    }

    // AC quantity prefixes — must be checked before plain "v(" to avoid
    // ambiguity with `vr(` vs `v(r…)`.
    let ac_prefixes: &[(&str, AcQuantity)] = &[
        ("vdb(", AcQuantity::Db),
        ("vm(",  AcQuantity::Magnitude),
        ("vr(",  AcQuantity::Real),
        ("vi(",  AcQuantity::Imag),
        ("vp(",  AcQuantity::Phase),
    ];
    for &(prefix, qty) in ac_prefixes {
        if lower.starts_with(prefix) && lower.ends_with(')') {
            let inner = tok[prefix.len()..tok.len() - 1].trim().to_string();
            if !inner.is_empty() {
                return Some(Signal::VAc(inner, qty));
            }
        }
    }

    if lower.starts_with("v(") && lower.ends_with(')') {
        let inner = &tok[2..tok.len() - 1];
        if let Some((n1, n2)) = inner.split_once(',') {
            Some(Signal::VDiff(n1.trim().to_string(), n2.trim().to_string()))
        } else {
            Some(Signal::V(inner.trim().to_string()))
        }
    } else if lower.starts_with("i(") && lower.ends_with(')') {
        let inner = &tok[2..tok.len() - 1];
        Some(Signal::I(inner.trim().to_string()))
    } else if (lower.starts_with("p(") || lower.starts_with("w(")) && lower.ends_with(')') {
        let inner = &tok[2..tok.len() - 1];
        Some(Signal::Power(inner.trim().to_string()))
    } else {
        None
    }
}

/// Parse `v(out)=0.5` into `(Signal, f64)`.
fn parse_signal_eq_value(tok: &str) -> Option<(Signal, f64)> {
    let eq_pos = tok.find('=')?;
    let sig_str = &tok[..eq_pos];
    let val_str = &tok[eq_pos + 1..];
    let signal = parse_signal(sig_str)?;
    let value = parse_spice_value(val_str).ok()?;
    Some((signal, value))
}

/// Parse FROM= and TO= from a token slice.
fn parse_from_to(tokens: &[&str]) -> (Option<f64>, Option<f64>) {
    let mut from = None;
    let mut to = None;
    for tok in tokens {
        let lower = tok.to_ascii_lowercase();
        if let Some(v) = lower.strip_prefix("from=") {
            from = parse_spice_value(v).ok();
        } else if let Some(v) = lower.strip_prefix("to=") {
            to = parse_spice_value(v).ok();
        }
    }
    (from, to)
}

/// Parse a SPICE engineering-notation value string.
/// Supported suffixes: T G MEG K (none) M U N P F.
pub fn parse_spice_value(s: &str) -> Result<f64, SimError> {
    let s = s.trim();
    if s.is_empty() {
        return Err(SimError::Parse("empty value".into()));
    }
    // Locate end of the numeric part: digits, '.', sign chars, and 'e'/'E' for sci-notation.
    let num_end = s
        .find(|c: char| {
            !c.is_ascii_digit()
                && c != '.'
                && c != '-'
                && c != '+'
                && c != 'e'
                && c != 'E'
        })
        .unwrap_or(s.len());
    let (num_str, suffix) = s.split_at(num_end);
    let base: f64 = num_str
        .parse()
        .map_err(|_| SimError::Parse(format!("cannot parse number '{s}'")))?;
    let mult = match suffix.to_ascii_lowercase().as_str() {
        "t" => 1e12,
        "g" => 1e9,
        "meg" | "x" => 1e6,
        "k" => 1e3,
        "" => 1.0,
        "m" => 1e-3,
        "u" | "µ" => 1e-6,
        "n" => 1e-9,
        "p" => 1e-12,
        "f" => 1e-15,
        _ => 1.0,
    };
    Ok(base * mult)
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::result::{ResultData, TransientResult};

    // ---- Waveform factories ------------------------------------------------

    /// Ramp: v(out) goes from 0 to 1 linearly over `tstop`.
    fn ramp_result(tstop: f64, npts: usize) -> (TransientResult, Vec<String>) {
        let times: Vec<f64> =
            (0..npts).map(|i| i as f64 * tstop / (npts - 1) as f64).collect();
        let node_voltages_flat: Vec<f64> = times.iter().map(|&t| t / tstop).collect();
        let result = TransientResult {
            times: times.clone(),
            node_voltages: node_voltages_flat.iter().map(|&v| vec![v]).collect(),
            node_voltages_flat,
            num_nodes: 1,
            branch_names: vec![],
            branch_currents_flat: vec![],
        };
        (result, vec!["out".to_string()])
    }

    /// Sine wave: v(out) = sin(2π freq t).
    fn sine_result(freq: f64, tstop: f64, npts: usize) -> (TransientResult, Vec<String>) {
        let times: Vec<f64> =
            (0..npts).map(|i| i as f64 * tstop / (npts - 1) as f64).collect();
        let node_voltages_flat: Vec<f64> = times
            .iter()
            .map(|&t| (2.0 * std::f64::consts::PI * freq * t).sin())
            .collect();
        let result = TransientResult {
            times: times.clone(),
            node_voltages: node_voltages_flat.iter().map(|&v| vec![v]).collect(),
            node_voltages_flat,
            num_nodes: 1,
            branch_names: vec![],
            branch_currents_flat: vec![],
        };
        (result, vec!["out".to_string()])
    }

    // ---- avg_trapz ---------------------------------------------------------

    #[test]
    fn avg_trapz_constant() {
        let xs = vec![0.0, 1.0, 2.0];
        let vs = vec![3.0, 3.0, 3.0];
        let v = avg_trapz(&xs, &vs).unwrap();
        assert!((v - 3.0).abs() < 1e-12, "expected 3.0, got {v}");
    }

    #[test]
    fn avg_trapz_ramp() {
        // Average of linear ramp 0..1 = 0.5.
        let xs = vec![0.0, 0.5, 1.0];
        let vs = vec![0.0, 0.5, 1.0];
        let v = avg_trapz(&xs, &vs).unwrap();
        assert!((v - 0.5).abs() < 1e-12, "expected 0.5, got {v}");
    }

    // ---- rms_trapz ---------------------------------------------------------

    #[test]
    fn rms_trapz_constant() {
        let xs = vec![0.0, 1.0, 2.0];
        let vs = vec![2.0, 2.0, 2.0];
        let v = rms_trapz(&xs, &vs).unwrap();
        assert!((v - 2.0).abs() < 1e-12, "expected 2.0, got {v}");
    }

    // ---- max / min / pp ----------------------------------------------------

    #[test]
    fn max_in_basic() {
        assert_eq!(max_in(&[1.0, 5.0, 3.0, -2.0]).unwrap(), 5.0);
    }

    #[test]
    fn min_in_basic() {
        assert_eq!(min_in(&[1.0, 5.0, 3.0, -2.0]).unwrap(), -2.0);
    }

    #[test]
    fn pp_is_max_minus_min() {
        let vs = vec![1.0, 5.0, 3.0, -2.0];
        assert!((max_in(&vs).unwrap() - min_in(&vs).unwrap() - 7.0).abs() < 1e-12);
    }

    // ---- integ_trapz -------------------------------------------------------

    #[test]
    fn integ_trapz_ramp() {
        // ∫₀¹ x dx = 0.5.
        let xs = vec![0.0, 0.5, 1.0];
        let vs = vec![0.0, 0.5, 1.0];
        let v = integ_trapz(&xs, &vs).unwrap();
        assert!((v - 0.5).abs() < 1e-12, "expected 0.5, got {v}");
    }

    // ---- crossing_x --------------------------------------------------------

    #[test]
    fn crossing_rise_basic() {
        let xs = vec![0.0, 0.5, 1.0];
        let vs = vec![-1.0, 0.0, 1.0];
        let cx = crossing_x(&xs, &vs, 0.0, CrossKind::Rise(1), None).unwrap();
        assert!((cx - 0.5).abs() < 1e-12, "expected 0.5, got {cx}");
    }

    #[test]
    fn crossing_rise_second() {
        // Two pulses 0→1→0→1→0; find 2nd rise through 0.5.
        let xs = vec![0.0, 1.0, 2.0, 3.0, 4.0];
        let vs = vec![0.0, 1.0, 0.0, 1.0, 0.0];
        let cx = crossing_x(&xs, &vs, 0.5, CrossKind::Rise(2), None).unwrap();
        assert!((cx - 2.5).abs() < 1e-6, "expected 2.5, got {cx}");
    }

    #[test]
    fn crossing_fall_basic() {
        let xs = vec![0.0, 0.5, 1.0];
        let vs = vec![1.0, 0.5, 0.0];
        let cx = crossing_x(&xs, &vs, 0.5, CrossKind::Fall(1), None).unwrap();
        assert!((cx - 0.5).abs() < 1e-12, "expected 0.5, got {cx}");
    }

    // ---- interp_at ---------------------------------------------------------

    #[test]
    fn interp_at_midpoint() {
        let xs = vec![0.0, 1.0, 2.0];
        let vs = vec![0.0, 1.0, 2.0];
        let v = interp_at(&xs, &vs, 0.5).unwrap();
        assert!((v - 0.5).abs() < 1e-12, "expected 0.5, got {v}");
    }

    // ---- window_slice -------------------------------------------------------

    #[test]
    fn window_slice_full() {
        let xs = vec![0.0, 1.0, 2.0, 3.0];
        let vs = vec![0.0, 1.0, 2.0, 3.0];
        let (xw, vw) = window_slice(&xs, &vs, None, None);
        assert_eq!(xw.len(), 4);
        assert_eq!(vw.len(), 4);
    }

    #[test]
    fn window_slice_trimmed() {
        let xs: Vec<f64> = (0..=10).map(|i| i as f64).collect();
        let vs: Vec<f64> = xs.clone();
        let (xw, vw) = window_slice(&xs, &vs, Some(2.0), Some(7.0));
        assert!(xw.first().copied().unwrap() >= 2.0 - 1e-12);
        assert!(xw.last().copied().unwrap() <= 7.0 + 1e-12);
        assert_eq!(xw.len(), vw.len());
    }

    // ---- parse_spice_value -------------------------------------------------

    #[test]
    fn spice_value_k() {
        assert!((parse_spice_value("1k").unwrap() - 1000.0).abs() < 1e-9);
    }

    #[test]
    fn spice_value_m() {
        assert!((parse_spice_value("1m").unwrap() - 0.001).abs() < 1e-12);
    }

    #[test]
    fn spice_value_u() {
        assert!((parse_spice_value("1u").unwrap() - 1e-6).abs() < 1e-15);
    }

    #[test]
    fn spice_value_plain() {
        assert!((parse_spice_value("3.14").unwrap() - 3.14).abs() < 1e-12);
    }

    // ---- eval_measure (transient) ------------------------------------------

    #[test]
    fn eval_max_tran_sine() {
        let (result, node_names) = sine_result(1e3, 2e-3, 2000);
        let stmt = MeasureStatement {
            name: "maxv".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::Max {
                signal: Signal::V("out".into()),
                from: None,
                to: None,
            },
        };
        let data = ResultData::Transient(result);
        let v = eval_measure(&stmt, &data, &node_names).unwrap();
        // Peak of sin should be very close to 1.0 with 2000 points.
        assert!(v > 0.99 && v <= 1.0, "expected ~1.0, got {v}");
    }

    #[test]
    fn eval_avg_tran_ramp() {
        // Ramp 0→1 over 2ms; average from 1ms to 2ms should be ~0.75.
        let (result, node_names) = ramp_result(2e-3, 2000);
        let stmt = MeasureStatement {
            name: "avg_vout".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::Avg {
                signal: Signal::V("out".into()),
                from: Some(1e-3),
                to: Some(2e-3),
            },
        };
        let data = ResultData::Transient(result);
        let v = eval_measure(&stmt, &data, &node_names).unwrap();
        assert!((v - 0.75).abs() < 0.01, "expected ~0.75, got {v}");
    }

    #[test]
    fn eval_when_cross_tran() {
        // Sine wave: first rising crossing through 0.5 ≈ arcsin(0.5)/(2πf).
        let freq = 1e3;
        let (result, node_names) = sine_result(freq, 2e-3, 4000);
        let stmt = MeasureStatement {
            name: "crosstime".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::WhenCross {
                signal: Signal::V("out".into()),
                value: 0.5,
                rise: Some(1),
                fall: None,
                cross: None,
            },
        };
        let data = ResultData::Transient(result);
        let t = eval_measure(&stmt, &data, &node_names).unwrap();
        let expected = (0.5_f64).asin() / (2.0 * std::f64::consts::PI * freq);
        assert!(
            (t - expected).abs() < 1e-5,
            "expected ~{expected:.2e}, got {t:.2e}"
        );
    }

    #[test]
    fn eval_trig_targ_rise_time() {
        // Ramp 0→1 over 1ms: rise time 10%→90% = 0.8ms.
        let (result, node_names) = ramp_result(1e-3, 2000);
        let stmt = MeasureStatement {
            name: "risetime".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::TrigTarg {
                trig: Trigger {
                    signal: Signal::V("out".into()),
                    value: 0.1,
                    rise_fall_cross: CrossKind::Rise(1),
                    td: None,
                },
                targ: Trigger {
                    signal: Signal::V("out".into()),
                    value: 0.9,
                    rise_fall_cross: CrossKind::Rise(1),
                    td: None,
                },
            },
        };
        let data = ResultData::Transient(result);
        let dt = eval_measure(&stmt, &data, &node_names).unwrap();
        assert!((dt - 0.8e-3).abs() < 1e-5, "expected 0.8ms, got {dt:.2e}");
    }

    // ---- parse_measure_line ------------------------------------------------

    #[test]
    fn parse_avg_line() {
        let tokens = vec!["TRAN", "avg_out", "AVG", "v(out)", "FROM=1m", "TO=2m"];
        let stmt = parse_measure_line(&tokens).unwrap();
        assert_eq!(stmt.name, "avg_out");
        assert_eq!(stmt.target, MeasureTarget::Transient);
        assert!(matches!(stmt.kind, MeasureKind::Avg { .. }));
    }

    #[test]
    fn parse_max_line() {
        let tokens = vec!["TRAN", "maxv", "MAX", "v(out)"];
        let stmt = parse_measure_line(&tokens).unwrap();
        assert_eq!(stmt.name, "maxv");
        assert!(matches!(stmt.kind, MeasureKind::Max { .. }));
    }

    #[test]
    fn parse_trig_targ_line() {
        let tokens = vec![
            "TRAN", "risetime", "TRIG", "v(out)", "VAL=0.1", "RISE=1", "TARG", "v(out)",
            "VAL=0.9", "RISE=1",
        ];
        let stmt = parse_measure_line(&tokens).unwrap();
        assert_eq!(stmt.name, "risetime");
        assert!(matches!(stmt.kind, MeasureKind::TrigTarg { .. }));
    }

    #[test]
    fn parse_when_line() {
        let tokens = vec!["TRAN", "crosstime", "WHEN", "v(out)=0.5", "RISE=1"];
        let stmt = parse_measure_line(&tokens).unwrap();
        assert_eq!(stmt.name, "crosstime");
        assert!(matches!(stmt.kind, MeasureKind::WhenCross { .. }));
    }

    // ---- I() branch current in TRAN ----------------------------------------

    #[test]
    fn eval_branch_current_tran() {
        // Build a transient result with one node and one branch current.
        let times = vec![0.0, 1e-6, 2e-6];
        let node_voltages_flat = vec![5.0, 5.0, 5.0];
        let branch_currents_flat = vec![-0.005, -0.005, -0.005];
        let result = TransientResult {
            times: times.clone(),
            node_voltages: node_voltages_flat.iter().map(|&v| vec![v]).collect(),
            node_voltages_flat,
            num_nodes: 1,
            branch_names: vec!["v1".into()],
            branch_currents_flat,
        };
        let node_names = vec!["1".to_string()];
        let stmt = MeasureStatement {
            name: "ibranch".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::Avg {
                signal: Signal::I("v1".into()),
                from: None,
                to: None,
            },
        };
        let data = ResultData::Transient(result);
        let v = eval_measure(&stmt, &data, &node_names).unwrap();
        assert!((v + 0.005).abs() < 1e-10, "expected -0.005, got {v}");
    }

    // ---- VAc signals in AC measurements ------------------------------------

    #[test]
    fn eval_ac_vdb() {
        use crate::result::AcResult;
        // Single frequency point: magnitude = 10 → VDB = 20 dB.
        let result = AcResult {
            frequencies: vec![1e3],
            node_magnitudes: vec![vec![10.0]],
            node_phases: vec![vec![0.0]],
            node_reals: vec![vec![10.0]],
            node_imags: vec![vec![0.0]],
        };
        let node_names = vec!["out".to_string()];
        let stmt = MeasureStatement {
            name: "gain_db".into(),
            target: MeasureTarget::Ac,
            kind: MeasureKind::FindAt {
                signal: Signal::VAc("out".into(), AcQuantity::Db),
                x: 1e3,
            },
        };
        let data = ResultData::Ac(result);
        let v = eval_measure(&stmt, &data, &node_names).unwrap();
        assert!((v - 20.0).abs() < 1e-9, "expected 20.0 dB, got {v}");
    }

    #[test]
    fn eval_ac_vr_vi_vp() {
        use crate::result::AcResult;
        // Node voltage: real=3, imag=4 → mag=5, phase=atan2(4,3)≈53.13°.
        let result = AcResult {
            frequencies: vec![1e3],
            node_magnitudes: vec![vec![5.0]],
            node_phases: vec![vec![4_f64.atan2(3.0)]],
            node_reals: vec![vec![3.0]],
            node_imags: vec![vec![4.0]],
        };
        let node_names = vec!["out".to_string()];

        let data = ResultData::Ac(result.clone());
        let stmt_r = MeasureStatement {
            name: "vr".into(),
            target: MeasureTarget::Ac,
            kind: MeasureKind::FindAt {
                signal: Signal::VAc("out".into(), AcQuantity::Real),
                x: 1e3,
            },
        };
        let vr = eval_measure(&stmt_r, &data, &node_names).unwrap();
        assert!((vr - 3.0).abs() < 1e-9, "VR: expected 3.0, got {vr}");

        let data2 = ResultData::Ac(result.clone());
        let stmt_i = MeasureStatement {
            name: "vi".into(),
            target: MeasureTarget::Ac,
            kind: MeasureKind::FindAt {
                signal: Signal::VAc("out".into(), AcQuantity::Imag),
                x: 1e3,
            },
        };
        let vi = eval_measure(&stmt_i, &data2, &node_names).unwrap();
        assert!((vi - 4.0).abs() < 1e-9, "VI: expected 4.0, got {vi}");

        let data3 = ResultData::Ac(result);
        let stmt_p = MeasureStatement {
            name: "vp".into(),
            target: MeasureTarget::Ac,
            kind: MeasureKind::FindAt {
                signal: Signal::VAc("out".into(), AcQuantity::Phase),
                x: 1e3,
            },
        };
        let vp = eval_measure(&stmt_p, &data3, &node_names).unwrap();
        let expected_deg = 4_f64.atan2(3.0) * (180.0 / std::f64::consts::PI);
        assert!((vp - expected_deg).abs() < 1e-9, "VP: expected {expected_deg}, got {vp}");
    }

    // ---- FROM=/TO= on AC Integ ---------------------------------------------

    #[test]
    fn eval_ac_integ_with_window() {
        use crate::result::AcResult;
        // Flat magnitude=2 over freqs 1..5 kHz; integral over [2k,4k] = 2*(4k-2k)=4000.
        let freqs: Vec<f64> = (1..=5).map(|i| i as f64 * 1e3).collect();
        let mags: Vec<Vec<f64>> = freqs.iter().map(|_| vec![2.0]).collect();
        let zeros: Vec<Vec<f64>> = freqs.iter().map(|_| vec![0.0]).collect();
        let result = AcResult {
            frequencies: freqs,
            node_magnitudes: mags,
            node_phases: zeros.clone(),
            node_reals: zeros.clone(),
            node_imags: zeros,
        };
        let node_names = vec!["out".to_string()];
        let stmt = MeasureStatement {
            name: "integ_ac".into(),
            target: MeasureTarget::Ac,
            kind: MeasureKind::Integ {
                signal: Signal::V("out".into()),
                from: Some(2e3),
                to: Some(4e3),
            },
        };
        let data = ResultData::Ac(result);
        let v = eval_measure(&stmt, &data, &node_names).unwrap();
        assert!((v - 4000.0).abs() < 1.0, "expected 4000, got {v}");
    }

    // ---- FROM=/TO= on DC Rms/Pp/Integ --------------------------------------

    #[test]
    fn eval_dc_rms_with_window() {
        use crate::result::DcSweepResult;
        // Constant 3V over sweep 0..5; RMS over [1,4] = 3.
        let sweep_values: Vec<f64> = (0..=5).map(|i| i as f64).collect();
        let node_voltages: Vec<Vec<f64>> = sweep_values.iter().map(|_| vec![3.0]).collect();
        let result = DcSweepResult {
            sweep_param: "v1".into(),
            sweep_values,
            node_voltages,
        };
        let node_names = vec!["out".to_string()];
        let stmt = MeasureStatement {
            name: "rms_dc".into(),
            target: MeasureTarget::Dc,
            kind: MeasureKind::Rms {
                signal: Signal::V("out".into()),
                from: Some(1.0),
                to: Some(4.0),
            },
        };
        let data = ResultData::DcSweep(result);
        let v = eval_measure(&stmt, &data, &node_names).unwrap();
        assert!((v - 3.0).abs() < 1e-10, "expected 3.0, got {v}");
    }

    #[test]
    fn eval_dc_pp_with_window() {
        use crate::result::DcSweepResult;
        // Ramp 0..5; PP over [1,4] should be 3.
        let sweep_values: Vec<f64> = (0..=5).map(|i| i as f64).collect();
        let node_voltages: Vec<Vec<f64>> = sweep_values.iter().map(|&s| vec![s]).collect();
        let result = DcSweepResult {
            sweep_param: "v1".into(),
            sweep_values,
            node_voltages,
        };
        let node_names = vec!["out".to_string()];
        let stmt = MeasureStatement {
            name: "pp_dc".into(),
            target: MeasureTarget::Dc,
            kind: MeasureKind::Pp {
                signal: Signal::V("out".into()),
                from: Some(1.0),
                to: Some(4.0),
            },
        };
        let data = ResultData::DcSweep(result);
        let v = eval_measure(&stmt, &data, &node_names).unwrap();
        assert!((v - 3.0).abs() < 1e-10, "expected 3.0, got {v}");
    }

    #[test]
    fn eval_dc_integ_with_window() {
        use crate::result::DcSweepResult;
        // Constant 2 over sweep 0..5; integ over [1,3] = 2*(3-1)=4.
        let sweep_values: Vec<f64> = (0..=5).map(|i| i as f64).collect();
        let node_voltages: Vec<Vec<f64>> = sweep_values.iter().map(|_| vec![2.0]).collect();
        let result = DcSweepResult {
            sweep_param: "v1".into(),
            sweep_values,
            node_voltages,
        };
        let node_names = vec!["out".to_string()];
        let stmt = MeasureStatement {
            name: "integ_dc".into(),
            target: MeasureTarget::Dc,
            kind: MeasureKind::Integ {
                signal: Signal::V("out".into()),
                from: Some(1.0),
                to: Some(3.0),
            },
        };
        let data = ResultData::DcSweep(result);
        let v = eval_measure(&stmt, &data, &node_names).unwrap();
        assert!((v - 4.0).abs() < 1e-10, "expected 4.0, got {v}");
    }

    // ---- Binary expression signal ------------------------------------------

    #[test]
    fn eval_binary_expr_signal_tran() {
        // Two nodes: node "a"=1V constant, node "b"=0.5V constant.
        // V(a)-V(b) avg = 0.5.
        let times = vec![0.0, 1e-3, 2e-3];
        // node_voltages_flat: [a0, b0, a1, b1, a2, b2]
        let node_voltages_flat = vec![1.0, 0.5, 1.0, 0.5, 1.0, 0.5];
        let result = TransientResult {
            times: times.clone(),
            node_voltages: vec![vec![1.0, 0.5], vec![1.0, 0.5], vec![1.0, 0.5]],
            node_voltages_flat,
            num_nodes: 2,
            branch_names: vec![],
            branch_currents_flat: vec![],
        };
        let node_names = vec!["a".to_string(), "b".to_string()];
        let stmt = MeasureStatement {
            name: "vdiff_avg".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::Avg {
                signal: Signal::BinaryExpr(
                    Box::new(Signal::V("a".into())),
                    '-',
                    Box::new(Signal::V("b".into())),
                ),
                from: None,
                to: None,
            },
        };
        let data = ResultData::Transient(result);
        let v = eval_measure(&stmt, &data, &node_names).unwrap();
        assert!((v - 0.5).abs() < 1e-10, "expected 0.5, got {v}");
    }
}
