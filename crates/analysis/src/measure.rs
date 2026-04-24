//! `.MEASURE` / `.MEAS` post-processing evaluator.
//!
//! Evaluates named measurements over transient, AC, and DC sweep results after
//! a simulation run completes. All reductions use trapezoidal integration to
//! match ngspice behaviour.
use incspice_core::SimError;

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
    Magnitude,
    Db,
    Real,
    Imag,
    Phase,
}

/// A signal that can be probed.
#[derive(Debug, Clone, PartialEq)]
pub enum Signal {
    V(String),
    VDiff(String, String),
    I(String),
    VAc(String, AcQuantity),
    Power(String),
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
    Eq(Signal, f64),
    EqExpr(Signal, Signal),
}

/// A trigger or target edge definition for TRIG/TARG measurements.
#[derive(Debug, Clone, PartialEq)]
pub struct Trigger {
    pub signal: Signal,
    pub value: f64,
    pub rise_fall_cross: CrossKind,
    pub td: Option<f64>,
}

/// The measurement kind — what to compute.
#[derive(Debug, Clone, PartialEq)]
pub enum MeasureKind {
    FindAt { signal: Signal, x: f64 },
    FindWhen { signal: Signal, cond: WhenCond },
    WhenCross { signal: Signal, value: f64, rise: Option<u32>, fall: Option<u32>, cross: Option<u32> },
    TrigTarg { trig: Trigger, targ: Trigger },
    Avg { signal: Signal, from: Option<f64>, to: Option<f64> },
    Rms { signal: Signal, from: Option<f64>, to: Option<f64> },
    Max { signal: Signal, from: Option<f64>, to: Option<f64> },
    Min { signal: Signal, from: Option<f64>, to: Option<f64> },
    Pp { signal: Signal, from: Option<f64>, to: Option<f64> },
    Integ { signal: Signal, from: Option<f64>, to: Option<f64> },
    Deriv { signal: Signal, at: f64 },
    Param { expr: String },
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
pub fn lerp(x0: f64, y0: f64, x1: f64, y1: f64, x: f64) -> f64 {
    if (x1 - x0).abs() < f64::EPSILON {
        return y0;
    }
    y0 + (y1 - y0) * (x - x0) / (x1 - x0)
}

/// Interpolate `values` at position `x` using linear interpolation over `xs`.
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

/// Find the x-axis position of the N-th crossing of `threshold`.
pub fn crossing_x(
    xs: &[f64],
    values: &[f64],
    threshold: f64,
    kind: CrossKind,
    after_x: Option<f64>,
) -> Result<f64, SimError> {
    let start = after_x.map(|t| xs.partition_point(|&v| v < t)).unwrap_or(0);

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

/// Restrict `xs`/`values` to the window `[from, to]` with boundary interpolation.
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

    let first_in = xs.partition_point(|&x| x < x_start);
    if first_in > 0 && first_in < xs.len() && xs[first_in - 1] < x_start {
        let y = lerp(
            xs[first_in - 1],
            values[first_in - 1],
            xs[first_in],
            values[first_in],
            x_start,
        );
        out_x.push(x_start);
        out_v.push(y);
    }

    for i in 0..xs.len() {
        if xs[i] >= x_start && xs[i] <= x_end {
            out_x.push(xs[i]);
            out_v.push(values[i]);
        }
    }

    let last_in = xs.partition_point(|&x| x <= x_end);
    if last_in > 0 && last_in < xs.len() {
        if out_x.last().copied().map_or(true, |v| v < x_end) {
            let y = lerp(
                xs[last_in - 1],
                values[last_in - 1],
                xs[last_in],
                values[last_in],
                x_end,
            );
            out_x.push(x_end);
            out_v.push(y);
        }
    }

    (out_x, out_v)
}

/// Trapezoidal integration of `values` over `xs`.
#[inline]
pub fn trapz(xs: &[f64], values: &[f64]) -> f64 {
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

#[inline]
pub fn apply_binop(op: char, l: f64, r: f64) -> Result<f64, SimError> {
    match op {
        '+' => Ok(l + r),
        '-' => Ok(l - r),
        '*' => Ok(l * r),
        '/' => {
            if r.abs() < f64::MIN_POSITIVE {
                Err(SimError::Analysis(
                    "division by zero in .MEASURE expression".into(),
                ))
            } else {
                Ok(l / r)
            }
        }
        _ => Err(SimError::Analysis(format!(
            "unknown operator '{op}' in .MEASURE expression"
        ))),
    }
}

// ---------------------------------------------------------------------------
// Signal resolution helpers
// ---------------------------------------------------------------------------

pub fn resolve_tran(
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
            let br_idx = result
                .branch_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(device))
                .ok_or_else(|| {
                    SimError::Analysis(format!(
                        ".MEASURE P({device}): branch not found in transient result"
                    ))
                })?;
            let node_idx = node_names
                .iter()
                .position(|n| n.eq_ignore_ascii_case(device));
            match node_idx {
                Some(ni) => Ok((0..result.num_steps())
                    .map(|s| result.voltage(s, ni) * result.branch_current(s, br_idx))
                    .collect()),
                None => Ok((0..result.num_steps())
                    .map(|s| result.branch_current(s, br_idx))
                    .collect()),
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

pub fn resolve_ac(
    sig: &Signal,
    result: &AcResult,
    node_names: &[String],
) -> Result<Vec<f64>, SimError> {
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
            "I() branch currents are not available in AC .MEASURE".into(),
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

pub fn resolve_dc(
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
            "I() branch currents are not available in DC sweep .MEASURE".into(),
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
                    ));
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
                    ));
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
                    ));
                }
            };
            eval_dc(stmt, dc, node_names)
        }
    }
}

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

pub fn eval_tran(
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

pub fn eval_ac(
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

pub fn eval_dc(
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

pub fn resolve_cross_kind(rise: Option<u32>, fall: Option<u32>, cross: Option<u32>) -> CrossKind {
    if let Some(n) = rise {
        CrossKind::Rise(n)
    } else if let Some(n) = fall {
        CrossKind::Fall(n)
    } else {
        CrossKind::Cross(cross.unwrap_or(1))
    }
}

pub fn eval_when_cond_tran(
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

pub fn parse_measure_kind(rest: &[&str]) -> Option<MeasureKind> {
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

pub fn parse_find_kind(rest: &[&str]) -> Option<MeasureKind> {
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

pub fn parse_when_kind(rest: &[&str]) -> Option<MeasureKind> {
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

pub fn parse_trig_targ_kind(rest: &[&str]) -> Option<MeasureKind> {
    let targ_pos = rest.iter().position(|t| t.to_ascii_lowercase() == "targ")?;
    let trig_tokens = &rest[1..targ_pos];
    let targ_tokens = &rest[targ_pos + 1..];

    let trig = parse_trigger(trig_tokens)?;
    let targ = parse_trigger(targ_tokens)?;
    Some(MeasureKind::TrigTarg { trig, targ })
}

pub fn parse_trigger(tokens: &[&str]) -> Option<Trigger> {
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

pub fn parse_when_cond(tokens: &[&str]) -> Option<WhenCond> {
    if tokens.is_empty() {
        return None;
    }
    let tok = tokens[0];
    if let Some((signal, value)) = parse_signal_eq_value(tok) {
        return Some(WhenCond::Eq(signal, value));
    }
    if let Some(eq_pos) = tok.find('=') {
        let lhs = parse_signal(&tok[..eq_pos])?;
        let rhs = parse_signal(&tok[eq_pos + 1..])?;
        return Some(WhenCond::EqExpr(lhs, rhs));
    }
    None
}

pub fn parse_signal(tok: &str) -> Option<Signal> {
    let lower = tok.to_ascii_lowercase();

    {
        let bytes = tok.as_bytes();
        let mut depth: i32 = 0;
        let mut split: Option<(usize, char)> = None;
        for i in (0..bytes.len()).rev() {
            match bytes[i] {
                b')' => depth += 1,
                b'(' => depth -= 1,
                b'+' | b'-' | b'*' | b'/' if depth == 0 && i > 0 => {
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

    let ac_prefixes: &[(&str, AcQuantity)] = &[
        ("vdb(", AcQuantity::Db),
        ("vm(", AcQuantity::Magnitude),
        ("vr(", AcQuantity::Real),
        ("vi(", AcQuantity::Imag),
        ("vp(", AcQuantity::Phase),
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

pub fn parse_signal_eq_value(tok: &str) -> Option<(Signal, f64)> {
    let eq_pos = tok.find('=')?;
    let sig_str = &tok[..eq_pos];
    let val_str = &tok[eq_pos + 1..];
    let signal = parse_signal(sig_str)?;
    let value = parse_spice_value(val_str).ok()?;
    Some((signal, value))
}

pub fn parse_from_to(tokens: &[&str]) -> (Option<f64>, Option<f64>) {
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

pub fn parse_spice_value(s: &str) -> Result<f64, SimError> {
    let s = s.trim();
    if s.is_empty() {
        return Err(SimError::Parse("empty value".into()));
    }
    let num_end = s
        .find(|c: char| {
            !c.is_ascii_digit() && c != '.' && c != '-' && c != '+' && c != 'e' && c != 'E'
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

pub fn parse_hspice_signal(s: &str) -> Option<Signal> {
    let s = s.trim();
    let paren = s.find('(')?;
    let func = s[..paren].trim().to_lowercase();
    let close = s.rfind(')')?;
    let inner = s[paren + 1..close].trim();
    match func.as_str() {
        "v" => {
            if let Some(comma) = inner.find(',') {
                Some(Signal::VDiff(
                    inner[..comma].trim().to_string(),
                    inner[comma + 1..].trim().to_string(),
                ))
            } else {
                Some(Signal::V(inner.to_string()))
            }
        }
        "i" => Some(Signal::I(inner.to_string())),
        "vm" => Some(Signal::VAc(inner.to_string(), AcQuantity::Magnitude)),
        "vdb" => Some(Signal::VAc(inner.to_string(), AcQuantity::Db)),
        "vr" => Some(Signal::VAc(inner.to_string(), AcQuantity::Real)),
        "vi" => Some(Signal::VAc(inner.to_string(), AcQuantity::Imag)),
        "vp" => Some(Signal::VAc(inner.to_string(), AcQuantity::Phase)),
        _ => None,
    }
}

pub fn resolve_for_data(
    sig: &Signal,
    data: &ResultData,
    node_names: &[String],
) -> Result<Vec<f64>, SimError> {
    match data {
        ResultData::Transient(r) => resolve_tran(sig, r, node_names),
        ResultData::Ac(r) => resolve_ac(sig, r, node_names),
        ResultData::DcSweep(r) => resolve_dc(sig, r, node_names),
        ResultData::DcOp(_) | ResultData::PoleZero(_) | ResultData::Sensitivity(_)
        | ResultData::Sp(_) | ResultData::Hb(_) | ResultData::Pss(_) => Err(SimError::Analysis(
            ".EXTRACT signal resolution not supported for this result type".into(),
        )),
    }
}

pub fn result_xaxis(data: &ResultData) -> Result<&[f64], SimError> {
    match data {
        ResultData::Transient(r) => Ok(&r.times),
        ResultData::Ac(r) => Ok(&r.frequencies),
        ResultData::DcSweep(r) => Ok(&r.sweep_values),
        ResultData::Sp(r) => Ok(&r.frequencies),
        ResultData::DcOp(_) | ResultData::PoleZero(_) | ResultData::Sensitivity(_)
        | ResultData::Hb(_) | ResultData::Pss(_) => Err(SimError::Analysis(
            ".EXTRACT x-axis not available for this result type".into(),
        )),
    }
}

// ---------------------------------------------------------------------------
// Unit tests (TODO §14)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::result::TransientResult;
    use std::f64::consts::PI;

    /// Build a `TransientResult` with a single node waveform for testing.
    fn make_tran(times: Vec<f64>, voltages: Vec<f64>) -> TransientResult {
        let n = voltages.len();
        TransientResult {
            times,
            node_voltages: voltages.iter().map(|&v| vec![v]).collect(),
            node_voltages_flat: voltages,
            num_nodes: 1,
            branch_names: vec![],
            branch_currents_flat: vec![],
        }
    }

    #[test]
    fn test_measure_tran_avg() {
        // AVG of a constant 3 V signal over [0, 1 s] = 3.0 V.
        let times: Vec<f64> = (0..=10).map(|i| i as f64 * 0.1).collect();
        let values: Vec<f64> = vec![3.0; times.len()];
        let result = make_tran(times, values);

        let stmt = MeasureStatement {
            name: "vavg".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::Avg {
                signal: Signal::V("n1".into()),
                from: None,
                to: None,
            },
        };
        let ans = eval_tran(&stmt, &result, &["n1".to_string()])
            .expect("AVG should succeed");
        assert!((ans - 3.0).abs() < 1e-10, "AVG of constant 3 V = {ans}");
    }

    #[test]
    fn test_measure_tran_rms() {
        // RMS of a full-period sine wave over [0, 2π] = amplitude / √2.
        // Use 1000 evenly spaced samples for precision.
        let n = 1000usize;
        let amplitude = 2.0_f64;
        let times: Vec<f64> = (0..n).map(|i| i as f64 * 2.0 * PI / (n as f64)).collect();
        let values: Vec<f64> = times.iter().map(|&t| amplitude * t.sin()).collect();
        let result = make_tran(times, values);

        let stmt = MeasureStatement {
            name: "vrms".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::Rms {
                signal: Signal::V("n1".into()),
                from: None,
                to: None,
            },
        };
        let ans = eval_tran(&stmt, &result, &["n1".to_string()])
            .expect("RMS should succeed");
        let expected = amplitude / 2.0_f64.sqrt();
        assert!((ans - expected).abs() < 1e-2,
            "RMS of sine(amplitude={amplitude}) ≈ {expected:.4}, got {ans:.4}");
    }

    #[test]
    fn test_measure_tran_max_min() {
        // A waveform that starts at 0, peaks at 5, then goes to -3.
        let times = vec![0.0, 1.0, 2.0, 3.0];
        let values = vec![0.0, 5.0, 2.0, -3.0];
        let result = make_tran(times, values);
        let node_names = &["n1".to_string()];

        let max_stmt = MeasureStatement {
            name: "vmax".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::Max { signal: Signal::V("n1".into()), from: None, to: None },
        };
        let min_stmt = MeasureStatement {
            name: "vmin".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::Min { signal: Signal::V("n1".into()), from: None, to: None },
        };

        let max_v = eval_tran(&max_stmt, &result, node_names).expect("MAX");
        let min_v = eval_tran(&min_stmt, &result, node_names).expect("MIN");
        assert!((max_v - 5.0).abs() < 1e-10, "MAX = {max_v}");
        assert!((min_v - (-3.0)).abs() < 1e-10, "MIN = {min_v}");
    }

    #[test]
    fn test_measure_tran_crossing_rise() {
        // Ramp from 0 to 2 V: crosses 1 V exactly at t = 0.5.
        let times = vec![0.0, 0.5, 1.0];
        let values = vec![0.0, 1.0, 2.0];
        let result = make_tran(times, values);

        let stmt = MeasureStatement {
            name: "t_cross".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::WhenCross {
                signal: Signal::V("n1".into()),
                value: 1.0,
                rise: Some(1),
                fall: None,
                cross: None,
            },
        };
        let t = eval_tran(&stmt, &result, &["n1".to_string()])
            .expect("WhenCross should succeed");
        assert!((t - 0.5).abs() < 1e-10, "crossing at t={t} expected 0.5");
    }

    #[test]
    fn test_lerp_midpoint() {
        let v = lerp(0.0, 0.0, 1.0, 10.0, 0.5);
        assert!((v - 5.0).abs() < 1e-10, "lerp midpoint={v}");
    }

    #[test]
    fn test_lerp_at_x0() {
        let v = lerp(2.0, 3.0, 4.0, 7.0, 2.0);
        assert!((v - 3.0).abs() < 1e-10);
    }

    #[test]
    fn test_lerp_at_x1() {
        let v = lerp(2.0, 3.0, 4.0, 7.0, 4.0);
        assert!((v - 7.0).abs() < 1e-10);
    }

    #[test]
    fn test_lerp_zero_span_returns_y0() {
        let v = lerp(1.0, 5.0, 1.0, 9.0, 1.0);
        assert!((v - 5.0).abs() < 1e-10, "zero-span lerp should return y0={v}");
    }

    #[test]
    fn test_trapz_unit_ramp() {
        // Integral of f(x)=x from 0 to 1: 0.5
        let xs = vec![0.0, 0.5, 1.0];
        let ys = vec![0.0, 0.5, 1.0];
        let v = trapz(&xs, &ys);
        assert!((v - 0.5).abs() < 1e-10, "trapz(ramp)={v}");
    }

    #[test]
    fn test_trapz_constant() {
        let xs = vec![0.0, 1.0, 2.0, 3.0];
        let ys = vec![4.0, 4.0, 4.0, 4.0];
        let v = trapz(&xs, &ys);
        assert!((v - 12.0).abs() < 1e-10, "trapz(const)={v}");
    }

    #[test]
    fn test_avg_trapz_constant() {
        let xs = vec![0.0, 1.0, 2.0];
        let ys = vec![7.0, 7.0, 7.0];
        let v = avg_trapz(&xs, &ys).unwrap();
        assert!((v - 7.0).abs() < 1e-10);
    }

    #[test]
    fn test_rms_trapz_constant() {
        // RMS of constant 5 = 5
        let xs = vec![0.0, 1.0, 2.0];
        let ys = vec![5.0, 5.0, 5.0];
        let v = rms_trapz(&xs, &ys).unwrap();
        assert!((v - 5.0).abs() < 1e-10);
    }

    #[test]
    fn test_max_in_basic() {
        let vals = vec![1.0_f64, 3.0, 2.0, -1.0];
        assert!((max_in(&vals).unwrap() - 3.0).abs() < 1e-10);
    }

    #[test]
    fn test_min_in_basic() {
        let vals = vec![1.0_f64, 3.0, 2.0, -1.0];
        assert!((min_in(&vals).unwrap() - (-1.0)).abs() < 1e-10);
    }

    #[test]
    fn test_max_in_empty_errors() {
        let vals: Vec<f64> = vec![];
        assert!(max_in(&vals).is_err());
    }

    #[test]
    fn test_min_in_empty_errors() {
        let vals: Vec<f64> = vec![];
        assert!(min_in(&vals).is_err());
    }

    #[test]
    fn test_integ_trapz() {
        // Integrate constant 2 from 0 to 3 → 6
        let xs = vec![0.0, 1.0, 2.0, 3.0];
        let ys = vec![2.0, 2.0, 2.0, 2.0];
        let v = integ_trapz(&xs, &ys).unwrap();
        assert!((v - 6.0).abs() < 1e-10);
    }

    #[test]
    fn test_deriv_at_linear_ramp() {
        // d/dt(2t) = 2 at any point
        let xs = vec![0.0, 1.0, 2.0, 3.0];
        let ys = vec![0.0, 2.0, 4.0, 6.0];
        let d = deriv_at(&xs, &ys, 1.5).unwrap();
        assert!((d - 2.0).abs() < 1e-10, "deriv={d}");
    }

    #[test]
    fn test_interp_at_boundary_start() {
        let xs = vec![0.0, 1.0, 2.0];
        let ys = vec![10.0, 20.0, 30.0];
        let v = interp_at(&xs, &ys, 0.0).unwrap();
        assert!((v - 10.0).abs() < 1e-10);
    }

    #[test]
    fn test_interp_at_boundary_end() {
        let xs = vec![0.0, 1.0, 2.0];
        let ys = vec![10.0, 20.0, 30.0];
        let v = interp_at(&xs, &ys, 2.0).unwrap();
        assert!((v - 30.0).abs() < 1e-10);
    }

    #[test]
    fn test_interp_at_middle() {
        let xs = vec![0.0, 2.0, 4.0];
        let ys = vec![0.0, 10.0, 20.0];
        let v = interp_at(&xs, &ys, 3.0).unwrap();
        assert!((v - 15.0).abs() < 1e-10);
    }

    #[test]
    fn test_interp_outside_range_errors() {
        let xs = vec![1.0, 2.0, 3.0];
        let ys = vec![1.0, 2.0, 3.0];
        assert!(interp_at(&xs, &ys, 0.0).is_err(), "below range should error");
        assert!(interp_at(&xs, &ys, 4.0).is_err(), "above range should error");
    }

    #[test]
    fn test_crossing_fall() {
        // Falls from 2 to 0 crossing 1 at t=0.5
        let xs = vec![0.0, 0.5, 1.0];
        let ys = vec![2.0, 1.0, 0.0];
        let t = crossing_x(&xs, &ys, 1.0, CrossKind::Fall(1), None).unwrap();
        assert!((t - 0.5).abs() < 1e-10, "fall crossing t={t}");
    }

    #[test]
    fn test_crossing_cross_counts_both() {
        // Rise then fall through threshold 1.0
        let xs = vec![0.0, 1.0, 2.0, 3.0];
        let ys = vec![0.0, 2.0, 2.0, 0.0];
        // First cross (rise) should be at t~0.5
        let t_rise = crossing_x(&xs, &ys, 1.0, CrossKind::Cross(1), None).unwrap();
        assert!(t_rise < 1.5, "first cross should be before t=1.5, got {t_rise}");
        // Second cross (fall) should be around t~2.5
        let t_fall = crossing_x(&xs, &ys, 1.0, CrossKind::Cross(2), None).unwrap();
        assert!(t_fall > 1.5, "second cross should be after t=1.5, got {t_fall}");
    }

    #[test]
    fn test_crossing_not_found_errors() {
        let xs = vec![0.0, 1.0, 2.0];
        let ys = vec![0.0, 0.5, 0.8]; // never crosses 1.0
        let result = crossing_x(&xs, &ys, 1.0, CrossKind::Rise(1), None);
        assert!(result.is_err());
    }

    #[test]
    fn test_measure_tran_pp() {
        // Peak-to-peak of [0, 5, 2, -3] = 5 - (-3) = 8
        let times = vec![0.0, 1.0, 2.0, 3.0];
        let values = vec![0.0, 5.0, 2.0, -3.0];
        let result = make_tran(times, values);

        let stmt = MeasureStatement {
            name: "vpp".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::Pp { signal: Signal::V("n1".into()), from: None, to: None },
        };
        let pp = eval_tran(&stmt, &result, &["n1".into()]).expect("PP");
        assert!((pp - 8.0).abs() < 1e-10, "PP={pp}");
    }

    #[test]
    fn test_measure_find_at() {
        // Find signal value at t=1.0 (should be 5.0 by interpolation/exact)
        let times = vec![0.0, 1.0, 2.0];
        let values = vec![0.0, 5.0, 10.0];
        let result = make_tran(times, values);

        let stmt = MeasureStatement {
            name: "vat1".into(),
            target: MeasureTarget::Transient,
            kind: MeasureKind::FindAt { signal: Signal::V("n1".into()), x: 1.0 },
        };
        let v = eval_tran(&stmt, &result, &["n1".into()]).expect("FindAt");
        assert!((v - 5.0).abs() < 1e-10, "V at t=1 = {v}");
    }

    #[test]
    fn test_window_slice_full_range() {
        let xs = vec![0.0, 1.0, 2.0, 3.0];
        let ys = vec![1.0, 2.0, 3.0, 4.0];
        let (ox, ov) = window_slice(&xs, &ys, None, None);
        assert_eq!(ox.len(), 4);
        assert!((ov[0] - 1.0).abs() < 1e-10);
        assert!((ov[3] - 4.0).abs() < 1e-10);
    }

    #[test]
    fn test_window_slice_sub_range() {
        let xs = vec![0.0, 1.0, 2.0, 3.0, 4.0];
        let ys = vec![0.0, 1.0, 2.0, 3.0, 4.0];
        let (ox, ov) = window_slice(&xs, &ys, Some(1.0), Some(3.0));
        // Should include [1.0, 3.0] with interpolated endpoints if needed
        assert!(!ox.is_empty());
        assert!(*ox.first().unwrap() >= 1.0 - 1e-12);
        assert!(*ox.last().unwrap() <= 3.0 + 1e-12);
    }
}
