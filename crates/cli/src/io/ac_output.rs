//! AC analysis output helpers.
//!
//! Bridges the gap between an `AcResult`'s raw complex-valued node voltages and
//! the column-major `f64` slices that every format writer expects.

use crate::io::print_select::PrintColumn;

/// Error returned when a requested node cannot be found in the node list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnknownNode(pub String);

impl std::fmt::Display for UnknownNode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "unknown node in AC print spec: {}", self.0)
    }
}

impl std::error::Error for UnknownNode {}

/// Raw AC data passed in by the caller.  All slices are `[freq_point][node]`.
pub struct AcData<'a> {
    /// Frequency sweep points (Hz).
    pub frequencies: &'a [f64],
    /// Real part of the complex node voltage.
    pub node_reals: &'a [Vec<f64>],
    /// Imaginary part of the complex node voltage.
    pub node_imags: &'a [Vec<f64>],
    /// Voltage magnitude (pre-computed = `sqrt(re² + im²)`).
    pub node_magnitudes: &'a [Vec<f64>],
    /// Voltage phase in **radians** (pre-computed = `atan2(im, re)`).
    pub node_phases: &'a [Vec<f64>],
    /// Node names in MNA order (index 0 == MNA variable 0).
    pub node_names: &'a [String],
}

impl<'a> AcData<'a> {
    /// Look up the MNA index for a node name (case-insensitive).
    fn node_index(&self, name: &str) -> Option<usize> {
        self.node_names
            .iter()
            .position(|n| n.eq_ignore_ascii_case(name))
    }

    /// Number of frequency points.
    fn num_points(&self) -> usize {
        self.frequencies.len()
    }
}

/// Extract a column-major `Vec<f64>` for a single `PrintColumn` spec from AC data.
pub fn extract_ac_column(col: &PrintColumn, data: &AcData<'_>) -> Result<Vec<f64>, UnknownNode> {
    match col {
        // V(node) in AC context → magnitude (ngspice convention).
        PrintColumn::NodeVoltage(node) => {
            let idx = data
                .node_index(node)
                .ok_or_else(|| UnknownNode(node.clone()))?;
            Ok(data
                .node_magnitudes
                .iter()
                .map(|row| row.get(idx).copied().unwrap_or(0.0))
                .collect())
        }
        // VM(node) → magnitude.
        PrintColumn::AcMagnitude(node) => {
            let idx = data
                .node_index(node)
                .ok_or_else(|| UnknownNode(node.clone()))?;
            Ok(data
                .node_magnitudes
                .iter()
                .map(|row| row.get(idx).copied().unwrap_or(0.0))
                .collect())
        }
        // VDB(node) → 20·log₁₀(|V|).
        PrintColumn::AcDb(node) => {
            let idx = data
                .node_index(node)
                .ok_or_else(|| UnknownNode(node.clone()))?;
            Ok(data
                .node_magnitudes
                .iter()
                .map(|row| {
                    let mag = row.get(idx).copied().unwrap_or(0.0);
                    20.0 * mag.max(f64::MIN_POSITIVE).log10()
                })
                .collect())
        }
        // VR(node) → real part.
        PrintColumn::AcReal(node) => {
            let idx = data
                .node_index(node)
                .ok_or_else(|| UnknownNode(node.clone()))?;
            Ok(data
                .node_reals
                .iter()
                .map(|row| row.get(idx).copied().unwrap_or(0.0))
                .collect())
        }
        // VI(node) → imaginary part.
        PrintColumn::AcImag(node) => {
            let idx = data
                .node_index(node)
                .ok_or_else(|| UnknownNode(node.clone()))?;
            Ok(data
                .node_imags
                .iter()
                .map(|row| row.get(idx).copied().unwrap_or(0.0))
                .collect())
        }
        // VP(node) → phase in degrees (stored in radians → convert).
        PrintColumn::AcPhase(node) => {
            let idx = data
                .node_index(node)
                .ok_or_else(|| UnknownNode(node.clone()))?;
            Ok(data
                .node_phases
                .iter()
                .map(|row| {
                    let rad = row.get(idx).copied().unwrap_or(0.0);
                    rad.to_degrees()
                })
                .collect())
        }
        // Non-AC columns: not meaningful for AC output; return zeros.
        PrintColumn::NodeVoltageDiff(_, _)
        | PrintColumn::BranchCurrent(_)
        | PrintColumn::Power(_)
        | PrintColumn::NoiseDensity(_) => Ok(vec![0.0; data.num_points()]),
    }
}

/// Build the full set of column-major data vectors for a list of `PrintColumn`
/// specs from AC results, plus the frequency column prepended as column 0.
pub fn build_ac_columns(
    specs: &[PrintColumn],
    data: &AcData<'_>,
) -> Result<(Vec<String>, Vec<Vec<f64>>), UnknownNode> {
    let mut headers: Vec<String> = Vec::with_capacity(specs.len() + 1);
    let mut columns: Vec<Vec<f64>> = Vec::with_capacity(specs.len() + 1);

    // Frequency is always the first (independent) column.
    headers.push("frequency".to_string());
    columns.push(data.frequencies.to_vec());

    for spec in specs {
        headers.push(spec.header());
        columns.push(extract_ac_column(spec, data)?);
    }

    Ok((headers, columns))
}
