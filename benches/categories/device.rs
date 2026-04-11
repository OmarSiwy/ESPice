//! Device evaluation benchmarks: MOSFET, diode, BJT stamp performance.

use criterion::{BenchmarkId, Criterion};
use bigospice_parser::SpiceParser;
use bigospice_device::DeviceRegistry;

pub fn bench_device(c: &mut Criterion) {
    let mut group = c.benchmark_group("device/eval");

    // MOSFET basic DC OP
    let mosfet_netlist = "\
* CMOS Inverter device eval
VDD vdd 0 DC 3.3
VIN in 0 DC 1.65
M1 out in 0 0 NMOD W=10u L=1u
M2 out in vdd vdd PMOD W=20u L=1u
.MODEL NMOD NMOS (VTH0=0.5 KP=120u)
.MODEL PMOD PMOS (VTH0=-0.5 KP=60u)
.OP
.END
";
    group.bench_function("cmos_inverter_dc_op", |b| {
        let (circuit, _, _) = SpiceParser::parse(mosfet_netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap());
    });

    // Diode DC OP
    let diode_netlist = "\
* Diode DC OP
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";
    group.bench_function("diode_dc_op", |b| {
        let (circuit, _, _) = SpiceParser::parse(diode_netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap());
    });

    group.finish();
}
