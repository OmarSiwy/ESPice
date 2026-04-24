//! `.PRINT` / `.SAVE` / `.PLOT` wildcard resolution at run time.
//!
//! The parser produces an opaque list of save specifications.  At run time
//! we need to flatten those wildcards into a concrete column list against the
//! actual node + branch namespace of the simulated circuit.

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
    /// `P(element)` / `W(element)` — instantaneous power dissipated by element.
    Power(String),
    /// `N(node)` — noise spectral density at node in V²/Hz.
    NoiseDensity(String),
}

impl PrintColumn {
    /// Canonical column header text.
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

/// Wildcard / literal print spec.
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
    /// `P(element)` / `W(element)` — instantaneous power.
    Power(String),
    /// `N(node)` — noise spectral density at node.
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
/// namespaces, in the order they appear.  De-duplicates.
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
            PrintSpec::Power(e) => {
                push_unique(&mut out, PrintColumn::Power(e.clone()));
            }
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
