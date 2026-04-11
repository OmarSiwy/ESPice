//! AC analysis output helpers.
//!
//! Bridges the gap between an `AcResult`'s raw complex-valued node voltages and
//! the column-major `f64` slices that every format writer (`RawfileWriter`,
//! `CsvWriter`, `HspicePostWriter`) expects.
//!
//! # Design
//!
//! The io crate deliberately has **no** dependency on `bigospice-analysis`.  This
//! module therefore accepts the four per-node arrays that `AcResult` provides
//! as plain `&[Vec<f64>]` slices, together with a node-name list and a list of
//! `PrintColumn` specs.  The caller (analysis crate or CLI) owns the `AcResult`
//! and passes references in.
//!
//! # Layout convention
//!
//! All input arrays are indexed `[freq_point][node_index]`.  Output columns are
//! indexed `[freq_point]` (column-major over points), matching the layout that
//! `RawfileWriter::set_real_columns` and `CsvWriter::set_columns` consume.

use crate::print_select::PrintColumn;

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

/// Extract a column-major `Vec<f64>` for a single `PrintColumn` spec from AC
/// data.
///
/// Returns `Err(UnknownNode)` when the requested node is not present in
/// `data.node_names`.
///
/// For `NodeVoltage` columns in an AC context the magnitude is returned,
/// matching ngspice behaviour where `V(out)` in an AC `.PRINT` line gives
/// `|V(out)|`.
pub fn extract_ac_column(
    col: &PrintColumn,
    data: &AcData<'_>,
) -> Result<Vec<f64>, UnknownNode> {
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
///
/// Returns a tuple of:
/// * `headers` — one header string per column (e.g. `"frequency"`, `"vdb(out)"`)
/// * `columns` — column-major `Vec<Vec<f64>>`, one inner `Vec` per column,
///   each of length `num_freq_points`.
///
/// Any unknown-node error is surfaced as `Err(UnknownNode)`.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::print_select::PrintColumn;
    use std::f64::consts::PI;

    fn make_data() -> (Vec<f64>, Vec<Vec<f64>>, Vec<Vec<f64>>, Vec<Vec<f64>>, Vec<Vec<f64>>, Vec<String>) {
        // Two frequencies, two nodes: "in" (idx 0) and "out" (idx 1).
        // Freq 0: in = 1+0j, out = 0.707+(-0.707j)
        // Freq 1: in = 1+0j, out = 0.1+(-0.9950j)
        let freqs = vec![1e3, 10e3];
        let re = vec![vec![1.0, 0.707], vec![1.0, 0.1]];
        let im = vec![vec![0.0, -0.707], vec![0.0, -0.9950]];
        let mag: Vec<Vec<f64>> = re
            .iter()
            .zip(im.iter())
            .map(|(re_row, im_row)| {
                re_row
                    .iter()
                    .zip(im_row.iter())
                    .map(|(r, i)| (r * r + i * i).sqrt())
                    .collect()
            })
            .collect();
        let phase: Vec<Vec<f64>> = re
            .iter()
            .zip(im.iter())
            .map(|(re_row, im_row)| {
                re_row
                    .iter()
                    .zip(im_row.iter())
                    .map(|(r, i)| i.atan2(*r))
                    .collect()
            })
            .collect();
        let names = vec!["in".to_string(), "out".to_string()];
        (freqs, re, im, mag, phase, names)
    }

    #[test]
    fn ac_magnitude_column() {
        let (freqs, re, im, mag, phase, names) = make_data();
        let data = AcData { frequencies: &freqs, node_reals: &re, node_imags: &im, node_magnitudes: &mag, node_phases: &phase, node_names: &names };
        let col = extract_ac_column(&PrintColumn::AcMagnitude("out".into()), &data).unwrap();
        assert_eq!(col.len(), 2);
        // |0.707 - 0.707j| ≈ 1.0
        assert!((col[0] - 1.0_f64).abs() < 1e-3, "mag[0]={}", col[0]);
        // |0.1 - 0.9950j| ≈ 1.0
        assert!((col[1] - 1.0_f64).abs() < 1e-2, "mag[1]={}", col[1]);
    }

    #[test]
    fn ac_db_column() {
        let (freqs, re, im, mag, phase, names) = make_data();
        let data = AcData { frequencies: &freqs, node_reals: &re, node_imags: &im, node_magnitudes: &mag, node_phases: &phase, node_names: &names };
        // "in" node: mag=1 at both freqs → 0 dB.
        let col = extract_ac_column(&PrintColumn::AcDb("in".into()), &data).unwrap();
        assert!((col[0]).abs() < 1e-10, "db[0]={}", col[0]);
        assert!((col[1]).abs() < 1e-10, "db[1]={}", col[1]);
    }

    #[test]
    fn ac_real_column() {
        let (freqs, re, im, mag, phase, names) = make_data();
        let data = AcData { frequencies: &freqs, node_reals: &re, node_imags: &im, node_magnitudes: &mag, node_phases: &phase, node_names: &names };
        let col = extract_ac_column(&PrintColumn::AcReal("out".into()), &data).unwrap();
        assert!((col[0] - 0.707).abs() < 1e-10);
        assert!((col[1] - 0.1).abs() < 1e-10);
    }

    #[test]
    fn ac_imag_column() {
        let (freqs, re, im, mag, phase, names) = make_data();
        let data = AcData { frequencies: &freqs, node_reals: &re, node_imags: &im, node_magnitudes: &mag, node_phases: &phase, node_names: &names };
        let col = extract_ac_column(&PrintColumn::AcImag("out".into()), &data).unwrap();
        assert!((col[0] - (-0.707)).abs() < 1e-10);
        assert!((col[1] - (-0.9950)).abs() < 1e-10);
    }

    #[test]
    fn ac_phase_degrees() {
        let (freqs, re, im, mag, phase, names) = make_data();
        let data = AcData { frequencies: &freqs, node_reals: &re, node_imags: &im, node_magnitudes: &mag, node_phases: &phase, node_names: &names };
        let col = extract_ac_column(&PrintColumn::AcPhase("out".into()), &data).unwrap();
        // atan2(-0.707, 0.707) = -45°
        assert!((col[0] - (-45.0)).abs() < 1e-3, "phase[0]={}", col[0]);
    }

    #[test]
    fn ac_node_voltage_returns_magnitude() {
        let (freqs, re, im, mag, phase, names) = make_data();
        let data = AcData { frequencies: &freqs, node_reals: &re, node_imags: &im, node_magnitudes: &mag, node_phases: &phase, node_names: &names };
        let col_v = extract_ac_column(&PrintColumn::NodeVoltage("in".into()), &data).unwrap();
        let col_m = extract_ac_column(&PrintColumn::AcMagnitude("in".into()), &data).unwrap();
        assert_eq!(col_v, col_m);
    }

    #[test]
    fn unknown_node_returns_error() {
        let (freqs, re, im, mag, phase, names) = make_data();
        let data = AcData { frequencies: &freqs, node_reals: &re, node_imags: &im, node_magnitudes: &mag, node_phases: &phase, node_names: &names };
        let err = extract_ac_column(&PrintColumn::AcMagnitude("ghost".into()), &data);
        assert!(err.is_err());
        assert_eq!(err.unwrap_err().0, "ghost");
    }

    #[test]
    fn build_ac_columns_prepends_frequency() {
        let (freqs, re, im, mag, phase, names) = make_data();
        let data = AcData { frequencies: &freqs, node_reals: &re, node_imags: &im, node_magnitudes: &mag, node_phases: &phase, node_names: &names };
        let specs = vec![
            PrintColumn::AcDb("out".into()),
            PrintColumn::AcPhase("out".into()),
        ];
        let (headers, cols) = build_ac_columns(&specs, &data).unwrap();
        assert_eq!(headers.len(), 3); // frequency + 2 specs
        assert_eq!(headers[0], "frequency");
        assert_eq!(headers[1], "vdb(out)");
        assert_eq!(headers[2], "vp(out)");
        assert_eq!(cols[0], freqs); // frequency column
        assert_eq!(cols.len(), 3);
    }
}
