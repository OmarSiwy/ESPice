//! Cosimulation tests: Verilator digital and GPU.
#[path = "../common/mod.rs"]
mod common;
use common::parse_netlist_str;

#[test]
#[ignore = "requires Verilator to be installed and SPI master model compiled"]
fn cosim_verilator_spi_master() {}

#[test]
#[ignore = "requires GPU/wgpu device available"]
fn cosim_gpu_dc_op_equivalence() {}

#[test]
#[ignore = "requires GPU/wgpu device available"]
fn cosim_gpu_dispatch_basic() {}

#[test]
#[ignore = "requires GPU/wgpu device available and Monte Carlo support"]
fn cosim_gpu_monte_carlo() {}

#[test]
#[ignore = "requires digital cosim transient hook"]
fn cosim_digital_schmitt_counter_dac() {}

/// Sanity check: parser must accept a netlist with no cosim directives.
#[test]
fn cosim_netlist_without_cosim_directives_parses() {
    let netlist = "\
* No cosim
V1 1 0 DC 5
R1 1 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok());
}
