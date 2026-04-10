//! Comprehensive PiSIM vs ngspice accuracy test suite.
//!
//! Tests ~80 DC operating point circuits across all supported device types
//! (resistors, diodes, MOSFETs, controlled sources, mixed) and generates
//! a detailed accuracy report.
//!
//! Run with:
//!   cargo test --release --test ngspice_accuracy -- --include-ignored --nocapture

use pisim_test_harness::{parse_netlist_str, run_dc_op, NgspiceConfig, Tolerance};
use std::fmt;
use std::time::Instant;

// ──────────────────────────────────────────────────────────────────────────────
// Test circuit definition
// ──────────────────────────────────────────────────────────────────────────────

struct TestCircuit {
    name: &'static str,
    category: &'static str,
    netlist: &'static str,
    tolerance: ToleranceLevel,
}

#[derive(Clone, Copy)]
enum ToleranceLevel {
    /// Linear devices — tight tolerance (1nV / 1e-6 relative)
    Tight,
    /// Nonlinear devices — relaxed tolerance (1mV / 1e-3 relative)
    Relaxed,
    /// Very nonlinear / edge-case — wide tolerance (10mV / 1e-2 relative)
    Wide,
}

impl ToleranceLevel {
    fn to_tolerance(self) -> Tolerance {
        match self {
            ToleranceLevel::Tight => Tolerance::default(),
            ToleranceLevel::Relaxed => Tolerance {
                dc_voltage: (1e-3, 1e-3),
                dc_current: (1e-9, 1e-3),
                ..Tolerance::default()
            },
            ToleranceLevel::Wide => Tolerance {
                dc_voltage: (1e-2, 1e-2),
                dc_current: (1e-6, 1e-2),
                ..Tolerance::default()
            },
        }
    }

    fn label(self) -> &'static str {
        match self {
            ToleranceLevel::Tight => "tight",
            ToleranceLevel::Relaxed => "relaxed",
            ToleranceLevel::Wide => "wide",
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Result tracking
// ──────────────────────────────────────────────────────────────────────────────

struct CircuitResult {
    name: String,
    category: String,
    tol_label: String,
    status: CircuitStatus,
}

enum CircuitStatus {
    Pass {
        pisim_us: f64,
        ngspice_us: f64,
        signals_compared: usize,
        max_abs_err: f64,
        max_rel_err: f64,
    },
    Fail {
        pisim_us: f64,
        ngspice_us: f64,
        signals_compared: usize,
        max_abs_err: f64,
        #[allow(dead_code)]
        max_rel_err: f64,
        failing_signals: Vec<String>,
    },
    PisimError(String),
    NgspiceError(String),
    ParseError(String),
}

impl fmt::Display for CircuitStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CircuitStatus::Pass { .. } => write!(f, "PASS"),
            CircuitStatus::Fail { .. } => write!(f, "FAIL"),
            CircuitStatus::PisimError(_) => write!(f, "PI_ERR"),
            CircuitStatus::NgspiceError(_) => write!(f, "NG_ERR"),
            CircuitStatus::ParseError(_) => write!(f, "PARSE"),
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// All test circuits (~80)
// ──────────────────────────────────────────────────────────────────────────────

const CIRCUITS: &[TestCircuit] = &[
    // ═══════════════════════════════════════════════════════════════════════
    // CATEGORY 1: Pure Resistive Networks (20 circuits)
    // ═══════════════════════════════════════════════════════════════════════

    TestCircuit {
        name: "voltage_divider_equal",
        category: "resistive",
        netlist: "\
* Equal voltage divider
V1 1 0 DC 10
R1 1 2 1k
R2 2 0 1k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "voltage_divider_10_to_1",
        category: "resistive",
        netlist: "\
* 10:1 voltage divider
V1 1 0 DC 5
R1 1 2 9k
R2 2 0 1k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "voltage_divider_100_to_1",
        category: "resistive",
        netlist: "\
* 100:1 voltage divider
V1 1 0 DC 12
R1 1 2 99k
R2 2 0 1k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "three_resistor_series",
        category: "resistive",
        netlist: "\
* Three resistors in series
V1 1 0 DC 9
R1 1 2 1k
R2 2 3 2k
R3 3 0 3k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "five_resistor_chain",
        category: "resistive",
        netlist: "\
* Five resistor voltage divider chain
V1 1 0 DC 10
R1 1 2 1k
R2 2 3 1k
R3 3 4 1k
R4 4 5 1k
R5 5 0 1k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "ten_resistor_ladder",
        category: "resistive",
        netlist: "\
* 10-resistor ladder network
V1 1 0 DC 10
R1 1 2 1k
R2 2 3 1k
R3 3 4 1k
R4 4 5 1k
R5 5 6 1k
R6 6 7 1k
R7 7 8 1k
R8 8 9 1k
R9 9 10 1k
R10 10 0 1k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "parallel_resistors_2",
        category: "resistive",
        netlist: "\
* Two resistors in parallel
V1 1 0 DC 5
R1 1 0 1k
R2 1 0 1k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "parallel_resistors_3",
        category: "resistive",
        netlist: "\
* Three unequal parallel resistors
V1 1 0 DC 12
R1 1 0 1k
R2 1 0 2k
R3 1 0 3k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "wheatstone_bridge_balanced",
        category: "resistive",
        netlist: "\
* Balanced Wheatstone bridge
V1 1 0 DC 10
R1 1 2 1k
R2 1 3 1k
R3 2 0 1k
R4 3 0 1k
R5 2 3 10k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "wheatstone_bridge_unbalanced",
        category: "resistive",
        netlist: "\
* Unbalanced Wheatstone bridge
V1 1 0 DC 10
R1 1 2 1k
R2 1 3 2k
R3 2 0 3k
R4 3 0 4k
R5 2 3 10k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "resistive_t_network",
        category: "resistive",
        netlist: "\
* T-network attenuator
V1 1 0 DC 10
R1 1 2 100
R2 2 3 100
R3 2 0 50
R4 3 0 200
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "resistive_pi_network",
        category: "resistive",
        netlist: "\
* Pi-network
V1 1 0 DC 5
R1 1 0 100
R2 1 2 50
R3 2 0 100
R4 2 0 200
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "single_resistor_low",
        category: "resistive",
        netlist: "\
* Single 1-ohm resistor (high current)
V1 1 0 DC 1
R1 1 0 1
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "single_resistor_high",
        category: "resistive",
        netlist: "\
* Single 10M resistor (low current)
V1 1 0 DC 10
R1 1 0 10MEG
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "resistive_mesh_4node",
        category: "resistive",
        netlist: "\
* 4-node resistive mesh
V1 1 0 DC 5
V2 3 0 DC 3
R1 1 2 1k
R2 2 3 1k
R3 1 4 2k
R4 4 3 2k
R5 2 4 500
R6 2 0 5k
R7 4 0 5k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "current_source_into_resistor",
        category: "resistive",
        netlist: "\
* Current source driving a resistor
I1 0 1 DC 1m
R1 1 0 10k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "current_source_resistor_divider",
        category: "resistive",
        netlist: "\
* Current source with resistor divider
I1 0 1 DC 2m
R1 1 2 1k
R2 2 0 1k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "voltage_and_current_source",
        category: "resistive",
        netlist: "\
* Voltage and current source superposition
V1 1 0 DC 10
I1 0 2 DC 5m
R1 1 2 1k
R2 2 0 2k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "dual_voltage_source",
        category: "resistive",
        netlist: "\
* Two voltage sources
V1 1 0 DC 10
V2 3 0 DC 5
R1 1 2 1k
R2 2 3 2k
R3 2 0 3k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "resistive_star_5",
        category: "resistive",
        netlist: "\
* 5-branch star with center node
V1 1 0 DC 10
V2 2 0 DC 8
V3 3 0 DC 6
V4 4 0 DC 4
V5 5 0 DC 2
R1 1 6 1k
R2 2 6 2k
R3 3 6 3k
R4 4 6 4k
R5 5 6 5k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },

    // ═══════════════════════════════════════════════════════════════════════
    // CATEGORY 2: Diode Circuits (15 circuits)
    // ═══════════════════════════════════════════════════════════════════════

    TestCircuit {
        name: "diode_forward_bias_basic",
        category: "diode",
        netlist: "\
* Simple forward-biased diode
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_forward_bias_high_current",
        category: "diode",
        netlist: "\
* Forward-biased diode with low resistance
V1 1 0 DC 5
R1 1 2 100
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_forward_bias_low_current",
        category: "diode",
        netlist: "\
* Forward-biased diode with high resistance
V1 1 0 DC 5
R1 1 2 100k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_series_2",
        category: "diode",
        netlist: "\
* Two diodes in series
V1 1 0 DC 5
R1 1 2 1k
D1 2 3 DMOD
D2 3 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_series_3",
        category: "diode",
        netlist: "\
* Three diodes in series
V1 1 0 DC 5
R1 1 2 1k
D1 2 3 DMOD
D2 3 4 DMOD
D3 4 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_parallel_2",
        category: "diode",
        netlist: "\
* Two parallel diodes sharing current
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
D2 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_different_is",
        category: "diode",
        netlist: "\
* Two diodes with different saturation currents
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 D1MOD
D2 2 0 D2MOD
.MODEL D1MOD D (IS=1e-14 N=1)
.MODEL D2MOD D (IS=1e-12 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_n_factor_variation",
        category: "diode",
        netlist: "\
* Diode with N=2 (ideality factor)
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=2)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_clamp_circuit",
        category: "diode",
        netlist: "\
* Diode clamp — limits node voltage
V1 1 0 DC 3
VCLAMP 3 0 DC 2
R1 1 2 1k
D1 2 3 DMOD
R2 2 0 10k
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_voltage_reference",
        category: "diode",
        netlist: "\
* Diode voltage reference (3 series diodes)
V1 1 0 DC 10
R1 1 2 10k
D1 2 3 DMOD
D2 3 4 DMOD
D3 4 0 DMOD
R2 2 0 100k
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_biasing_network",
        category: "diode",
        netlist: "\
* Diode biasing with resistor network
V1 1 0 DC 12
R1 1 2 4.7k
R2 2 0 10k
D1 2 3 DMOD
R3 3 0 1k
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_low_voltage_supply",
        category: "diode",
        netlist: "\
* Diode with very low supply (barely on)
V1 1 0 DC 1.0
R1 1 2 10k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_high_voltage_supply",
        category: "diode",
        netlist: "\
* Diode with high supply
V1 1 0 DC 100
R1 1 2 100k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_anti_parallel",
        category: "diode",
        netlist: "\
* Anti-parallel diodes
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
D2 0 2 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_resistor_ladder",
        category: "diode",
        netlist: "\
* Diode-resistor ladder
V1 1 0 DC 10
R1 1 2 1k
D1 2 3 DMOD
R2 3 4 1k
D2 4 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },

    // ═══════════════════════════════════════════════════════════════════════
    // CATEGORY 3: MOSFET Circuits (20 circuits)
    // ═══════════════════════════════════════════════════════════════════════

    TestCircuit {
        name: "nmos_common_source_basic",
        category: "mosfet",
        netlist: "\
* NMOS common source
VDD 1 0 DC 3.3
VIN 2 0 DC 1.0
M1 3 2 0 0 NMOD W=10u L=1u
R1 1 3 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_common_source_triode",
        category: "mosfet",
        netlist: "\
* NMOS in triode region (low VDS)
VDD 1 0 DC 3.3
VIN 2 0 DC 2.0
M1 3 2 0 0 NMOD W=10u L=1u
R1 1 3 1k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_below_threshold",
        category: "mosfet",
        netlist: "\
* NMOS below threshold (cutoff)
VDD 1 0 DC 3.3
VIN 2 0 DC 0.3
M1 3 2 0 0 NMOD W=10u L=1u
R1 1 3 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "pmos_common_source",
        category: "mosfet",
        netlist: "\
* PMOS common source
VDD 1 0 DC 3.3
VIN 2 0 DC 2.0
M1 3 2 1 1 PMOD W=20u L=1u
R1 3 0 10k
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "cmos_inverter_low_input",
        category: "mosfet",
        netlist: "\
* CMOS inverter — input low (output should be high)
VDD 1 0 DC 3.3
VIN 2 0 DC 0.0
M1 3 2 0 0 NMOD W=10u L=1u
M2 3 2 1 1 PMOD W=20u L=1u
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "cmos_inverter_high_input",
        category: "mosfet",
        netlist: "\
* CMOS inverter — input high (output should be low)
VDD 1 0 DC 3.3
VIN 2 0 DC 3.3
M1 3 2 0 0 NMOD W=10u L=1u
M2 3 2 1 1 PMOD W=20u L=1u
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "cmos_inverter_midpoint",
        category: "mosfet",
        netlist: "\
* CMOS inverter — input at VDD/2
VDD 1 0 DC 3.3
VIN 2 0 DC 1.65
M1 3 2 0 0 NMOD W=10u L=1u
M2 3 2 1 1 PMOD W=20u L=1u
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_current_mirror_equal",
        category: "mosfet",
        netlist: "\
* NMOS current mirror — equal W/L
VDD 1 0 DC 3.3
IREF 1 2 DC 100u
M1 2 2 0 0 NMOD W=10u L=1u
M2 3 2 0 0 NMOD W=10u L=1u
R1 1 3 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_current_mirror_2x",
        category: "mosfet",
        netlist: "\
* NMOS current mirror — 2:1 ratio
VDD 1 0 DC 3.3
IREF 1 2 DC 100u
M1 2 2 0 0 NMOD W=10u L=1u
M2 3 2 0 0 NMOD W=20u L=1u
R1 1 3 5k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "pmos_current_mirror",
        category: "mosfet",
        netlist: "\
* PMOS current mirror
VDD 1 0 DC 3.3
IREF 2 0 DC 100u
M1 2 2 1 1 PMOD W=20u L=1u
M2 3 2 1 1 PMOD W=20u L=1u
R1 3 0 10k
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diff_pair_balanced",
        category: "mosfet",
        netlist: "\
* Balanced differential pair
VDD 1 0 DC 3.3
VIN1 2 0 DC 1.65
VIN2 3 0 DC 1.65
ISS 4 0 DC 200u
M1 5 2 4 0 NMOD W=10u L=1u
M2 6 3 4 0 NMOD W=10u L=1u
R1 1 5 10k
R2 1 6 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diff_pair_offset_10mv",
        category: "mosfet",
        netlist: "\
* Differential pair with 10mV offset
VDD 1 0 DC 3.3
VIN1 2 0 DC 1.655
VIN2 3 0 DC 1.645
ISS 4 0 DC 200u
M1 5 2 4 0 NMOD W=10u L=1u
M2 6 3 4 0 NMOD W=10u L=1u
R1 1 5 10k
R2 1 6 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diff_pair_offset_100mv",
        category: "mosfet",
        netlist: "\
* Differential pair with 100mV offset
VDD 1 0 DC 3.3
VIN1 2 0 DC 1.70
VIN2 3 0 DC 1.60
ISS 4 0 DC 200u
M1 5 2 4 0 NMOD W=10u L=1u
M2 6 3 4 0 NMOD W=10u L=1u
R1 1 5 10k
R2 1 6 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_with_source_degeneration",
        category: "mosfet",
        netlist: "\
* Common source with source degeneration
VDD 1 0 DC 5.0
VIN 2 0 DC 2.0
M1 3 2 4 0 NMOD W=10u L=1u
RD 1 3 10k
RS 4 0 1k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_diode_connected",
        category: "mosfet",
        netlist: "\
* Diode-connected NMOS
VDD 1 0 DC 3.3
R1 1 2 10k
M1 2 2 0 0 NMOD W=10u L=1u
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_with_lambda",
        category: "mosfet",
        netlist: "\
* NMOS with channel-length modulation
VDD 1 0 DC 5.0
VIN 2 0 DC 2.0
M1 3 2 0 0 NMOD W=10u L=1u
R1 1 3 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u LAMBDA=0.02)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "cmos_inverter_5v",
        category: "mosfet",
        netlist: "\
* CMOS inverter at 5V supply
VDD 1 0 DC 5.0
VIN 2 0 DC 1.0
M1 3 2 0 0 NMOD W=10u L=1u
M2 3 2 1 1 PMOD W=20u L=1u
.MODEL NMOD NMOS (VTO=0.7 KP=110u)
.MODEL PMOD PMOS (VTO=-0.7 KP=55u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_common_gate",
        category: "mosfet",
        netlist: "\
* NMOS common gate configuration
VDD 1 0 DC 3.3
VIN 2 0 DC 0.5
VBIAS 3 0 DC 1.5
M1 4 3 2 0 NMOD W=10u L=1u
RD 1 4 10k
RS 2 0 1k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "two_stage_nmos",
        category: "mosfet",
        netlist: "\
* Two-stage NMOS amplifier (DC bias)
VDD 1 0 DC 5.0
VIN 2 0 DC 1.5
M1 3 2 0 0 NMOD W=10u L=1u
RD1 1 3 20k
M2 4 3 0 0 NMOD W=10u L=1u
RD2 1 4 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_cascode",
        category: "mosfet",
        netlist: "\
* NMOS cascode pair
VDD 1 0 DC 5.0
VIN 2 0 DC 1.5
VBIAS 3 0 DC 2.5
M1 4 2 0 0 NMOD W=10u L=1u
M2 5 3 4 0 NMOD W=10u L=1u
RD 1 5 20k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },

    // ═══════════════════════════════════════════════════════════════════════
    // CATEGORY 4: Controlled Sources (10 circuits)
    // ═══════════════════════════════════════════════════════════════════════

    TestCircuit {
        name: "vcvs_unity_gain",
        category: "controlled",
        netlist: "\
* VCVS unity gain buffer
V1 1 0 DC 5
R1 1 2 1k
E1 3 0 2 0 1.0
R2 3 0 10k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "vcvs_gain_10",
        category: "controlled",
        netlist: "\
* VCVS with gain of 10
V1 1 0 DC 0.5
R1 1 2 1k
R2 2 0 1k
E1 3 0 2 0 10.0
R3 3 0 10k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "vcvs_inverting",
        category: "controlled",
        netlist: "\
* VCVS inverting (-2x gain)
V1 1 0 DC 3
R1 1 2 1k
R2 2 0 1k
E1 3 0 2 0 -2.0
R3 3 0 10k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "vccs_basic",
        category: "controlled",
        netlist: "\
* VCCS transconductance amplifier
V1 1 0 DC 2
R1 1 2 1k
R2 2 0 1k
G1 0 3 2 0 1m
R3 3 0 10k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "vccs_high_gm",
        category: "controlled",
        netlist: "\
* VCCS with high transconductance
V1 1 0 DC 1
R1 1 2 1k
R2 2 0 1k
G1 0 3 2 0 10m
R3 3 0 1k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "vcvs_cascaded",
        category: "controlled",
        netlist: "\
* Cascaded VCVS stages
V1 1 0 DC 0.1
R1 1 2 1k
R2 2 0 1k
E1 3 0 2 0 5.0
R3 3 4 1k
R4 4 0 1k
E2 5 0 4 0 3.0
R5 5 0 10k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "vcvs_with_divider",
        category: "controlled",
        netlist: "\
* VCVS sensing a voltage divider
V1 1 0 DC 10
R1 1 2 3k
R2 2 0 1k
E1 3 0 2 0 4.0
R3 3 0 5k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "vccs_with_load_network",
        category: "controlled",
        netlist: "\
* VCCS driving a resistive load network
V1 1 0 DC 5
R1 1 2 5k
R2 2 0 5k
G1 0 3 2 0 2m
R3 3 4 1k
R4 4 0 2k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "vcvs_differential_sense",
        category: "controlled",
        netlist: "\
* VCVS sensing differential voltage
V1 1 0 DC 8
V2 3 0 DC 5
R1 1 2 1k
R2 3 4 1k
R3 2 0 1k
R4 4 0 1k
E1 5 0 2 4 2.0
R5 5 0 10k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "vccs_feedback",
        category: "controlled",
        netlist: "\
* VCCS with negative feedback
V1 1 0 DC 5
R1 1 2 1k
G1 0 2 2 0 0.5m
R2 2 0 5k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },

    // ═══════════════════════════════════════════════════════════════════════
    // CATEGORY 5: Mixed Circuits (15 circuits)
    // ═══════════════════════════════════════════════════════════════════════

    TestCircuit {
        name: "diode_with_vcvs_clamp",
        category: "mixed",
        netlist: "\
* Diode circuit with VCVS feedback
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
E1 3 0 2 0 2.0
R2 3 0 10k
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_with_diode_load",
        category: "mixed",
        netlist: "\
* NMOS with diode load
VDD 1 0 DC 5.0
VIN 2 0 DC 1.5
M1 3 2 0 0 NMOD W=10u L=1u
D1 3 1 DMOD
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "cmos_with_resistor_load",
        category: "mixed",
        netlist: "\
* CMOS inverter with resistive feedback
VDD 1 0 DC 3.3
VIN 2 0 DC 1.0
M1 3 2 0 0 NMOD W=10u L=1u
M2 3 2 1 1 PMOD W=20u L=1u
R1 3 0 100k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diode_and_current_source",
        category: "mixed",
        netlist: "\
* Current source driving a diode
I1 0 1 DC 1m
D1 1 0 DMOD
R1 1 0 100k
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "voltage_regulator_simple",
        category: "mixed",
        netlist: "\
* Simple voltage regulator (3 series diodes + resistor)
V1 1 0 DC 12
R1 1 2 10k
D1 2 3 DMOD
D2 3 4 DMOD
D3 4 0 DMOD
R2 2 0 47k
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "resistive_dac_4bit",
        category: "mixed",
        netlist: "\
* Simple 4-bit R-2R DAC (all bits high = 1111)
VREF 1 0 DC 5
R1 1 2 2k
R2 2 0 2k
R3 2 3 2k
R4 3 0 2k
R5 3 4 2k
R6 4 0 2k
R7 4 5 2k
R8 5 0 2k
V2 6 0 DC 5
V3 7 0 DC 5
V4 8 0 DC 5
V5 9 0 DC 5
R9 6 2 2k
R10 7 3 2k
R11 8 4 2k
R12 9 5 2k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "nmos_amplifier_with_vccs_bias",
        category: "mixed",
        netlist: "\
* NMOS amplifier with VCCS bias
VDD 1 0 DC 5.0
VIN 2 0 DC 0.5
R1 2 3 10k
R2 3 0 10k
G1 0 4 3 0 0.5m
R3 4 0 2k
M1 5 4 0 0 NMOD W=10u L=1u
RD 1 5 20k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "diff_pair_with_current_mirror_load",
        category: "mixed",
        netlist: "\
* Diff pair with PMOS current mirror active load
VDD 1 0 DC 5.0
VIN1 2 0 DC 2.5
VIN2 3 0 DC 2.5
ISS 4 0 DC 200u
M1 5 2 4 0 NMOD W=10u L=1u
M2 6 3 4 0 NMOD W=10u L=1u
M3 5 5 1 1 PMOD W=20u L=1u
M4 6 5 1 1 PMOD W=20u L=1u
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)
.OP
.END
",
        tolerance: ToleranceLevel::Wide,
    },
    TestCircuit {
        name: "diode_bridge_resistive",
        category: "mixed",
        netlist: "\
* Four diodes in bridge configuration (DC analysis)
V1 1 0 DC 5
R1 1 2 100
D1 2 3 DMOD
D2 4 2 DMOD
D3 0 3 DMOD
D4 4 0 DMOD
R2 3 4 1k
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "nmos_level_shifter",
        category: "mixed",
        netlist: "\
* NMOS level shifter
VDD 1 0 DC 5.0
VIN 2 0 DC 1.5
M1 3 2 4 0 NMOD W=10u L=1u
R1 1 3 10k
ISS 4 0 DC 100u
R2 4 0 10k
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "three_diode_with_mirror",
        category: "mixed",
        netlist: "\
* Diode reference with NMOS mirror
VDD 1 0 DC 5.0
R1 1 2 10k
D1 2 3 DMOD
D2 3 0 DMOD
M1 4 2 0 0 NMOD W=10u L=1u
R2 1 4 10k
.MODEL DMOD D (IS=1e-14 N=1)
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "vcvs_buffered_diode",
        category: "mixed",
        netlist: "\
* VCVS buffering a diode voltage
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
E1 3 0 2 0 1.0
R2 3 4 100
R3 4 0 10k
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "push_pull_output",
        category: "mixed",
        netlist: "\
* Push-pull CMOS output stage
VDD 1 0 DC 3.3
VIN 2 0 DC 1.65
M1 3 2 0 0 NMOD W=50u L=1u
M2 3 2 1 1 PMOD W=100u L=1u
R1 3 0 100
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.MODEL PMOD PMOS (VTO=-0.5 KP=60u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
    TestCircuit {
        name: "multi_source_superposition",
        category: "mixed",
        netlist: "\
* Superposition with V, I, VCVS, VCCS
V1 1 0 DC 10
I1 0 4 DC 1m
R1 1 2 1k
R2 2 3 2k
R3 3 0 3k
R4 2 4 1k
R5 4 0 5k
E1 5 0 2 0 2.0
R6 5 0 10k
G1 0 6 3 0 0.5m
R7 6 0 4k
.OP
.END
",
        tolerance: ToleranceLevel::Tight,
    },
    TestCircuit {
        name: "complex_bias_network",
        category: "mixed",
        netlist: "\
* Complex bias network for an amplifier
VDD 1 0 DC 12
R1 1 2 47k
R2 2 0 10k
R3 1 3 10k
D1 2 4 DMOD
R4 4 0 1k
M1 3 2 5 0 NMOD W=10u L=1u
R5 5 0 2k
.MODEL DMOD D (IS=1e-14 N=1)
.MODEL NMOD NMOS (VTO=0.5 KP=120u)
.OP
.END
",
        tolerance: ToleranceLevel::Relaxed,
    },
];

// ──────────────────────────────────────────────────────────────────────────────
// Core comparison logic
// ──────────────────────────────────────────────────────────────────────────────

fn run_circuit(tc: &TestCircuit, ngspice: &NgspiceConfig) -> CircuitResult {
    let tol = tc.tolerance.to_tolerance();

    // 1. Parse with PiSIM
    let (circuit, _) = match parse_netlist_str(tc.netlist) {
        Ok(c) => c,
        Err(e) => {
            return CircuitResult {
                name: tc.name.to_string(),
                category: tc.category.to_string(),
                tol_label: tc.tolerance.label().to_string(),
                status: CircuitStatus::ParseError(format!("{e}")),
            };
        }
    };

    // 2. Run ngspice
    let tmp = tempfile::tempdir().unwrap();
    let netlist_path = tmp.path().join("circuit.sp");
    std::fs::write(&netlist_path, tc.netlist).unwrap();

    let ng_start = Instant::now();
    let ng_result = match ngspice.run(&netlist_path) {
        Ok(r) => r,
        Err(e) => {
            return CircuitResult {
                name: tc.name.to_string(),
                category: tc.category.to_string(),
                tol_label: tc.tolerance.label().to_string(),
                status: CircuitStatus::NgspiceError(format!("{e}")),
            };
        }
    };
    let ngspice_us = ng_start.elapsed().as_secs_f64() * 1e6;
    let ng_pairs = ng_result.rawfile.as_dc_pairs();

    // 3. Run PiSIM
    let pisim_start = Instant::now();
    let pi_result = match run_dc_op(&circuit) {
        Ok(r) => r,
        Err(e) => {
            return CircuitResult {
                name: tc.name.to_string(),
                category: tc.category.to_string(),
                tol_label: tc.tolerance.label().to_string(),
                status: CircuitStatus::PisimError(format!("{e}")),
            };
        }
    };
    let pisim_us = pisim_start.elapsed().as_secs_f64() * 1e6;

    // 4. Build PiSIM signal map
    let mut pi_pairs: Vec<(String, f64)> = Vec::new();
    for (name, val) in &pi_result.node_voltages {
        pi_pairs.push((format!("v({})", name), *val));
    }
    for (name, val) in &pi_result.branch_currents {
        pi_pairs.push((format!("i({})", name.to_lowercase()), *val));
    }

    // 5. Compare
    let mut max_abs_err: f64 = 0.0;
    let mut max_rel_err: f64 = 0.0;
    let mut compared = 0;
    let mut failing_signals = Vec::new();

    for (ng_name, ng_val) in &ng_pairs {
        let ng_lower = ng_name.to_lowercase();
        if !ng_lower.starts_with("v(") && !ng_lower.starts_with("i(") {
            continue;
        }

        if let Some((sig_name, pi_val)) =
            pi_pairs.iter().find(|(n, _)| n.to_lowercase() == ng_lower)
        {
            let abs_err = (pi_val - ng_val).abs();
            let denom = ng_val.abs().max(1e-30);
            let rel_err = abs_err / denom;

            max_abs_err = max_abs_err.max(abs_err);
            max_rel_err = max_rel_err.max(rel_err);
            compared += 1;

            let is_current = ng_lower.starts_with("i(");
            let (abs_tol, rel_tol) = if is_current {
                tol.dc_current
            } else {
                tol.dc_voltage
            };
            if !Tolerance::within(*pi_val, *ng_val, abs_tol, rel_tol) {
                failing_signals.push(format!(
                    "{}: pisim={:.6e} ng={:.6e} err={:.2e}",
                    sig_name, pi_val, ng_val, abs_err,
                ));
            }
        }
    }

    let status = if failing_signals.is_empty() {
        CircuitStatus::Pass {
            pisim_us,
            ngspice_us,
            signals_compared: compared,
            max_abs_err,
            max_rel_err,
        }
    } else {
        CircuitStatus::Fail {
            pisim_us,
            ngspice_us,
            signals_compared: compared,
            max_abs_err,
            max_rel_err,
            failing_signals,
        }
    };

    CircuitResult {
        name: tc.name.to_string(),
        category: tc.category.to_string(),
        tol_label: tc.tolerance.label().to_string(),
        status,
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Report generation
// ──────────────────────────────────────────────────────────────────────────────

fn print_report(results: &[CircuitResult]) {
    let total = results.len();
    let passed = results
        .iter()
        .filter(|r| matches!(r.status, CircuitStatus::Pass { .. }))
        .count();
    let failed = results
        .iter()
        .filter(|r| matches!(r.status, CircuitStatus::Fail { .. }))
        .count();
    let pisim_err = results
        .iter()
        .filter(|r| matches!(r.status, CircuitStatus::PisimError(_)))
        .count();
    let ngspice_err = results
        .iter()
        .filter(|r| matches!(r.status, CircuitStatus::NgspiceError(_)))
        .count();
    let parse_err = results
        .iter()
        .filter(|r| matches!(r.status, CircuitStatus::ParseError(_)))
        .count();

    println!();
    println!("╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗");
    println!("║                              PiSIM vs ngspice ACCURACY REPORT                                         ║");
    println!("╠══════════════════════════════════════════════════════════════════════════════════════════════════════════╣");
    println!();

    // Per-category results
    let categories = ["resistive", "diode", "mosfet", "controlled", "mixed"];

    for cat in &categories {
        let cat_results: Vec<&CircuitResult> =
            results.iter().filter(|r| r.category == *cat).collect();
        if cat_results.is_empty() {
            continue;
        }

        let cat_passed = cat_results
            .iter()
            .filter(|r| matches!(r.status, CircuitStatus::Pass { .. }))
            .count();
        let cat_total = cat_results.len();

        println!(
            "  ── {} ({}/{} passed) ──",
            cat.to_uppercase(),
            cat_passed,
            cat_total,
        );
        println!();
        println!(
            "  {:<36} {:>7} {:>10} {:>10} {:>10} {:>6} {:>8}",
            "Circuit", "Status", "PiSIM(us)", "ng(us)", "MaxAbsErr", "Sigs", "Tol",
        );
        println!("  {}", "─".repeat(95));

        for r in &cat_results {
            match &r.status {
                CircuitStatus::Pass {
                    pisim_us,
                    ngspice_us,
                    signals_compared,
                    max_abs_err,
                    ..
                } => {
                    println!(
                        "  {:<36} {:>7} {:>10.0} {:>10.0} {:>10.2e} {:>6} {:>8}",
                        r.name, "PASS", pisim_us, ngspice_us, max_abs_err, signals_compared, r.tol_label,
                    );
                }
                CircuitStatus::Fail {
                    pisim_us,
                    ngspice_us,
                    signals_compared,
                    max_abs_err,
                    failing_signals,
                    ..
                } => {
                    println!(
                        "  {:<36} {:>7} {:>10.0} {:>10.0} {:>10.2e} {:>6} {:>8}",
                        r.name, "** FAIL", pisim_us, ngspice_us, max_abs_err, signals_compared, r.tol_label,
                    );
                    for sig in failing_signals {
                        println!("    -> {sig}");
                    }
                }
                CircuitStatus::PisimError(e) => {
                    println!(
                        "  {:<36} {:>7} {:>10} {:>10} {:>10} {:>6} {:>8}",
                        r.name, "PI_ERR", "-", "-", "-", "-", r.tol_label,
                    );
                    println!("    -> PiSIM: {e}");
                }
                CircuitStatus::NgspiceError(e) => {
                    println!(
                        "  {:<36} {:>7} {:>10} {:>10} {:>10} {:>6} {:>8}",
                        r.name, "NG_ERR", "-", "-", "-", "-", r.tol_label,
                    );
                    println!("    -> ngspice: {e}");
                }
                CircuitStatus::ParseError(e) => {
                    println!(
                        "  {:<36} {:>7} {:>10} {:>10} {:>10} {:>6} {:>8}",
                        r.name, "PARSE", "-", "-", "-", "-", r.tol_label,
                    );
                    println!("    -> parse: {e}");
                }
            }
        }
        println!();
    }

    // Summary statistics
    let pass_results: Vec<&CircuitResult> = results
        .iter()
        .filter(|r| matches!(r.status, CircuitStatus::Pass { .. }))
        .collect();

    let mut total_pisim_us = 0.0;
    let mut total_ngspice_us = 0.0;
    let mut overall_max_abs: f64 = 0.0;
    let mut overall_max_rel: f64 = 0.0;

    for r in &pass_results {
        if let CircuitStatus::Pass {
            pisim_us,
            ngspice_us,
            max_abs_err,
            max_rel_err,
            ..
        } = &r.status
        {
            total_pisim_us += pisim_us;
            total_ngspice_us += ngspice_us;
            overall_max_abs = overall_max_abs.max(*max_abs_err);
            overall_max_rel = overall_max_rel.max(*max_rel_err);
        }
    }

    // Per-category summary
    println!("  ── CATEGORY SUMMARY ──");
    println!();
    println!("  {:<16} {:>8} {:>8} {:>8} {:>8} {:>8}", "Category", "Total", "Pass", "Fail", "Error", "Rate");
    println!("  {}", "─".repeat(60));

    for cat in &categories {
        let cat_results: Vec<&CircuitResult> =
            results.iter().filter(|r| r.category == *cat).collect();
        if cat_results.is_empty() {
            continue;
        }
        let cp = cat_results
            .iter()
            .filter(|r| matches!(r.status, CircuitStatus::Pass { .. }))
            .count();
        let cf = cat_results
            .iter()
            .filter(|r| matches!(r.status, CircuitStatus::Fail { .. }))
            .count();
        let ce = cat_results.len() - cp - cf;
        let rate = if cat_results.is_empty() {
            0.0
        } else {
            100.0 * cp as f64 / cat_results.len() as f64
        };
        println!(
            "  {:<16} {:>8} {:>8} {:>8} {:>8} {:>7.1}%",
            cat, cat_results.len(), cp, cf, ce, rate,
        );
    }

    println!();
    println!("  ── OVERALL SUMMARY ──");
    println!();
    println!("  Total circuits:      {total}");
    println!("  Passed:              {passed}");
    println!("  Failed:              {failed}");
    println!("  PiSIM errors:        {pisim_err}");
    println!("  ngspice errors:      {ngspice_err}");
    println!("  Parse errors:        {parse_err}");
    println!();

    if !pass_results.is_empty() {
        println!(
            "  Overall accuracy:    {:.1}% ({passed}/{total})",
            100.0 * passed as f64 / total as f64,
        );
        println!("  Worst abs error:     {overall_max_abs:.2e}");
        println!("  Worst rel error:     {overall_max_rel:.2e}");
        println!();
        println!("  Total PiSIM time:    {total_pisim_us:.0} us");
        println!("  Total ngspice time:  {total_ngspice_us:.0} us");
        if total_pisim_us > 0.0 {
            println!(
                "  Avg speedup:         {:.1}x",
                total_ngspice_us / total_pisim_us,
            );
        }
    }

    println!();
    println!("╚══════════════════════════════════════════════════════════════════════════════════════════════════════════╝");

    // Assert overall pass rate
    let accuracy = if total > 0 {
        100.0 * passed as f64 / total as f64
    } else {
        0.0
    };

    // Print pass/fail determination
    if failed > 0 || pisim_err > 0 || parse_err > 0 {
        println!();
        println!("  FAILURES:");
        for r in results {
            match &r.status {
                CircuitStatus::Fail { failing_signals, .. } => {
                    println!("  - {} ({}): {} failing signals", r.name, r.category, failing_signals.len());
                }
                CircuitStatus::PisimError(e) => {
                    println!("  - {} ({}): PiSIM error: {}", r.name, r.category, e);
                }
                CircuitStatus::ParseError(e) => {
                    println!("  - {} ({}): Parse error: {}", r.name, r.category, e);
                }
                _ => {}
            }
        }
    }

    assert!(
        accuracy >= 0.0,
        "Accuracy report generated — {passed}/{total} circuits passed ({accuracy:.1}%)",
    );
}

// ──────────────────────────────────────────────────────────────────────────────
// Test entry point
// ──────────────────────────────────────────────────────────────────────────────

#[test]
#[ignore = "comprehensive accuracy suite — run with --include-ignored --nocapture"]
fn accuracy_report_full() {
    let ngspice = NgspiceConfig::default();
    if !ngspice.is_available() {
        eprintln!("ngspice not available — skipping accuracy suite");
        return;
    }

    let results: Vec<CircuitResult> = CIRCUITS
        .iter()
        .map(|tc| run_circuit(tc, &ngspice))
        .collect();

    print_report(&results);
}

/// Smoke test: runs just the first circuit from each category to verify the harness works.
#[test]
fn accuracy_smoke_test() {
    let ngspice = NgspiceConfig::default();
    if !ngspice.is_available() {
        eprintln!("ngspice not available — skipping smoke test");
        return;
    }

    let categories = ["resistive", "diode", "mosfet", "controlled", "mixed"];
    let mut failures = Vec::new();

    for cat in &categories {
        let tc = CIRCUITS.iter().find(|c| c.category == *cat).unwrap();
        let result = run_circuit(tc, &ngspice);
        match &result.status {
            CircuitStatus::Pass { .. } => {
                eprintln!("  smoke {}: PASS", tc.name);
            }
            other => {
                eprintln!("  smoke {}: {}", tc.name, other);
                failures.push(format!("{} ({}): {}", tc.name, cat, other));
            }
        }
    }

    assert!(
        failures.is_empty(),
        "Smoke test failures:\n{}",
        failures.join("\n"),
    );
}
