use criterion::{criterion_group, criterion_main, Criterion};
use pisim_test_harness::{parse_netlist_str, run_dc_op};

const VOLTAGE_DIVIDER: &str = "\
* Voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.op
.end
";

const CMOS_INVERTER: &str = "\
* CMOS inverter
VDD 1 0 DC 5
VIN 2 0 DC 2.5
MP 3 2 1 1 PMOS W=10u L=1u
MN 3 2 0 0 NMOS W=10u L=1u
RL 3 0 100k
.op
.end
";

fn bench_end_to_end(c: &mut Criterion) {
    let mut group = c.benchmark_group("end_to_end");

    // Parse-only benchmark
    group.bench_function("parse_voltage_divider", |b| {
        b.iter(|| parse_netlist_str(VOLTAGE_DIVIDER).unwrap());
    });

    // Full DC OP: voltage divider
    group.bench_function("dc_op_voltage_divider", |b| {
        let (ckt, _) = parse_netlist_str(VOLTAGE_DIVIDER).unwrap();
        b.iter(|| run_dc_op(&ckt).unwrap());
    });

    // Full DC OP: CMOS inverter
    group.bench_function("dc_op_cmos_inverter", |b| {
        let (ckt, _) = parse_netlist_str(CMOS_INVERTER).unwrap();
        b.iter(|| run_dc_op(&ckt).unwrap());
    });

    // Parse-only: CMOS inverter
    group.bench_function("parse_cmos_inverter", |b| {
        b.iter(|| parse_netlist_str(CMOS_INVERTER).unwrap());
    });

    group.finish();
}

criterion_group!(benches, bench_end_to_end);
criterion_main!(benches);
