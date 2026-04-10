//! `.PRINT` / `.SAVE` / `.PLOT` wildcard resolution at run time.
//!
//! The parser produces an opaque list of save specifications.  At run time
//! we need to flatten those wildcards into a concrete column list against the
//! actual node + branch namespace of the simulated circuit.
//!
//! This module is intentionally decoupled from the parser crate — it works on
//! plain `&str` slices so it can be unit-tested in isolation and reused by
//! every format writer.

use thiserror::Error;

/// A single column to record / write to an output file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrintColumn {
    /// `V(node)` — single node voltage (or AC magnitude).
    NodeVoltage(String),
    /// `V(n1,n2)` — differential voltage.
    NodeVoltageDiff(String, String),
    /// `I(branch)` — branch current.
    BranchCurrent(String),
    /// `VM(node)` — AC voltage magnitude (alias for V in AC context).
    AcMagnitude(String),
    /// `VDB(node)` — AC voltage magnitude in dB: 20·log₁₀(|V|).
    AcDb(String),
    /// `VR(node)` — AC voltage real part.
    AcReal(String),
    /// `VI(node)` — AC voltage imaginary part.
    AcImag(String),
    /// `VP(node)` — AC voltage phase in degrees.
    AcPhase(String),
    /// `P(element)` / `W(element)` — instantaneous power dissipated by element (T.14).
    Power(String),
    /// `N(node)` — noise spectral density at node in V²/Hz (T.14).
    NoiseDensity(String),
}

impl PrintColumn {
    /// Canonical column header text (e.g. `"v(out)"`, `"vdb(out)"`, `"i(v1)"`, `"p(r1)"`).
    pub fn header(&self) -> String {
        match self {
            PrintColumn::NodeVoltage(n) => format!("v({n})"),
            PrintColumn::NodeVoltageDiff(a, b) => format!("v({a},{b})"),
            PrintColumn::BranchCurrent(b) => format!("i({b})"),
            PrintColumn::AcMagnitude(n) => format!("vm({n})"),
            PrintColumn::AcDb(n) => format!("vdb({n})"),
            PrintColumn::AcReal(n) => format!("vr({n})"),
            PrintColumn::AcImag(n) => format!("vi({n})"),
            PrintColumn::AcPhase(n) => format!("vp({n})"),
            PrintColumn::Power(e) => format!("p({e})"),
            PrintColumn::NoiseDensity(n) => format!("n({n})"),
        }
    }
}

/// Wildcard / literal print spec.  Mirrors the parser's `SaveSpec` but lives
/// inside the io crate so we don't take a parser dependency.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrintSpec {
    /// `V(node)` — single node voltage.
    NodeVoltage(String),
    /// `V(n1,n2)` — differential voltage.
    NodeVoltageDiff(String, String),
    /// `I(branch)` — single branch current.
    BranchCurrent(String),
    /// `VM(node)` — AC voltage magnitude.
    AcMagnitude(String),
    /// `VDB(node)` — AC voltage magnitude in dB.
    AcDb(String),
    /// `VR(node)` — AC voltage real part.
    AcReal(String),
    /// `VI(node)` — AC voltage imaginary part.
    AcImag(String),
    /// `VP(node)` — AC voltage phase in degrees.
    AcPhase(String),
    /// `P(element)` / `W(element)` — instantaneous power (T.14).
    Power(String),
    /// `N(node)` — noise spectral density at node (T.14).
    NoiseDensity(String),
    /// `V(*)` — every node voltage in the circuit.
    AllVoltages,
    /// `I(*)` — every branch current in the circuit.
    AllCurrents,
    /// `*` — every signal.
    All,
}

/// Errors during wildcard resolution.
#[derive(Debug, Error)]
pub enum PrintSelectError {
    #[error("unknown node referenced in print spec: {0}")]
    UnknownNode(String),
    #[error("unknown branch referenced in print spec: {0}")]
    UnknownBranch(String),
}

/// Resolve a list of wildcard specs against a circuit's actual node and branch
/// namespaces, in the order they appear.  De-duplicates: if the same column is
/// requested twice (e.g. `V(*)` and then `V(out)`), it appears once.
///
/// `nodes` and `branches` should be in canonical order (the order the
/// simulator iterates them); this becomes the column order in the output file.
pub fn resolve(
    specs: &[PrintSpec],
    nodes: &[&str],
    branches: &[&str],
    strict: bool,
) -> Result<Vec<PrintColumn>, PrintSelectError> {
    let mut out: Vec<PrintColumn> = Vec::new();

    // Helper closure to push without dups.
    let push_unique = |out: &mut Vec<PrintColumn>, col: PrintColumn| {
        if !out.contains(&col) {
            out.push(col);
        }
    };

    for spec in specs {
        match spec {
            PrintSpec::NodeVoltage(n) => {
                if strict && !nodes.iter().any(|x| x.eq_ignore_ascii_case(n)) {
                    return Err(PrintSelectError::UnknownNode(n.clone()));
                }
                push_unique(&mut out, PrintColumn::NodeVoltage(n.clone()));
            }
            PrintSpec::NodeVoltageDiff(a, b) => {
                if strict {
                    if !nodes.iter().any(|x| x.eq_ignore_ascii_case(a)) {
                        return Err(PrintSelectError::UnknownNode(a.clone()));
                    }
                    if !nodes.iter().any(|x| x.eq_ignore_ascii_case(b)) {
                        return Err(PrintSelectError::UnknownNode(b.clone()));
                    }
                }
                push_unique(&mut out, PrintColumn::NodeVoltageDiff(a.clone(), b.clone()));
            }
            PrintSpec::BranchCurrent(br) => {
                if strict && !branches.iter().any(|x| x.eq_ignore_ascii_case(br)) {
                    return Err(PrintSelectError::UnknownBranch(br.clone()));
                }
                push_unique(&mut out, PrintColumn::BranchCurrent(br.clone()));
            }
            PrintSpec::AcMagnitude(n) => {
                if strict && !nodes.iter().any(|x| x.eq_ignore_ascii_case(n)) {
                    return Err(PrintSelectError::UnknownNode(n.clone()));
                }
                push_unique(&mut out, PrintColumn::AcMagnitude(n.clone()));
            }
            PrintSpec::AcDb(n) => {
                if strict && !nodes.iter().any(|x| x.eq_ignore_ascii_case(n)) {
                    return Err(PrintSelectError::UnknownNode(n.clone()));
                }
                push_unique(&mut out, PrintColumn::AcDb(n.clone()));
            }
            PrintSpec::AcReal(n) => {
                if strict && !nodes.iter().any(|x| x.eq_ignore_ascii_case(n)) {
                    return Err(PrintSelectError::UnknownNode(n.clone()));
                }
                push_unique(&mut out, PrintColumn::AcReal(n.clone()));
            }
            PrintSpec::AcImag(n) => {
                if strict && !nodes.iter().any(|x| x.eq_ignore_ascii_case(n)) {
                    return Err(PrintSelectError::UnknownNode(n.clone()));
                }
                push_unique(&mut out, PrintColumn::AcImag(n.clone()));
            }
            PrintSpec::AcPhase(n) => {
                if strict && !nodes.iter().any(|x| x.eq_ignore_ascii_case(n)) {
                    return Err(PrintSelectError::UnknownNode(n.clone()));
                }
                push_unique(&mut out, PrintColumn::AcPhase(n.clone()));
            }
            // T.14: Power — P(elem) / W(elem). Element name passed through.
            PrintSpec::Power(e) => {
                push_unique(&mut out, PrintColumn::Power(e.clone()));
            }
            // T.14: NoiseDensity — N(node).
            PrintSpec::NoiseDensity(n) => {
                push_unique(&mut out, PrintColumn::NoiseDensity(n.clone()));
            }
            PrintSpec::AllVoltages => {
                for n in nodes.iter().filter(|n| !n.eq_ignore_ascii_case("0")) {
                    push_unique(&mut out, PrintColumn::NodeVoltage((*n).to_string()));
                }
            }
            PrintSpec::AllCurrents => {
                for br in branches {
                    push_unique(&mut out, PrintColumn::BranchCurrent((*br).to_string()));
                }
            }
            PrintSpec::All => {
                for n in nodes.iter().filter(|n| !n.eq_ignore_ascii_case("0")) {
                    push_unique(&mut out, PrintColumn::NodeVoltage((*n).to_string()));
                }
                for br in branches {
                    push_unique(&mut out, PrintColumn::BranchCurrent((*br).to_string()));
                }
            }
        }
    }

    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nodes() -> Vec<&'static str> {
        vec!["0", "in", "out", "n1"]
    }

    fn branches() -> Vec<&'static str> {
        vec!["v1", "vmeas"]
    }

    #[test]
    fn literal_resolution() {
        let specs = vec![
            PrintSpec::NodeVoltage("out".into()),
            PrintSpec::BranchCurrent("v1".into()),
        ];
        let cols = resolve(&specs, &nodes(), &branches(), true).unwrap();
        assert_eq!(cols.len(), 2);
        assert_eq!(cols[0].header(), "v(out)");
        assert_eq!(cols[1].header(), "i(v1)");
    }

    #[test]
    fn wildcard_voltages_skips_ground() {
        let cols = resolve(&[PrintSpec::AllVoltages][..], &nodes(), &branches(), true).unwrap();
        let headers: Vec<String> = cols.iter().map(|c| c.header()).collect();
        assert_eq!(headers, vec!["v(in)", "v(out)", "v(n1)"]);
    }

    #[test]
    fn wildcard_all() {
        let cols = resolve(&[PrintSpec::All][..], &nodes(), &branches(), true).unwrap();
        let headers: Vec<String> = cols.iter().map(|c| c.header()).collect();
        assert_eq!(
            headers,
            vec!["v(in)", "v(out)", "v(n1)", "i(v1)", "i(vmeas)"]
        );
    }

    #[test]
    fn deduplication() {
        let specs = vec![
            PrintSpec::AllVoltages,
            PrintSpec::NodeVoltage("out".into()),
        ];
        let cols = resolve(&specs, &nodes(), &branches(), true).unwrap();
        // V(*) added in,out,n1 already; V(out) is duplicate.
        assert_eq!(cols.len(), 3);
    }

    #[test]
    fn diff_voltage() {
        let specs = vec![PrintSpec::NodeVoltageDiff("in".into(), "out".into())];
        let cols = resolve(&specs, &nodes(), &branches(), true).unwrap();
        assert_eq!(cols[0].header(), "v(in,out)");
    }

    #[test]
    fn strict_unknown_node_errors() {
        let specs = vec![PrintSpec::NodeVoltage("ghost".into())];
        let err = resolve(&specs, &nodes(), &branches(), true).unwrap_err();
        assert!(matches!(err, PrintSelectError::UnknownNode(_)));
    }

    #[test]
    fn nonstrict_allows_unknown() {
        let specs = vec![PrintSpec::NodeVoltage("ghost".into())];
        let cols = resolve(&specs, &nodes(), &branches(), false).unwrap();
        assert_eq!(cols.len(), 1);
    }
}
