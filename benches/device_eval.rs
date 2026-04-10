use criterion::{criterion_group, criterion_main, Criterion};
use pisim_core::{DeviceKind, ParamMap};
use pisim_device::DeviceRegistry;

fn bench_device_eval(c: &mut Criterion) {
    let mut group = c.benchmark_group("device_eval");
    let reg = DeviceRegistry::new_default();

    // --- Resistor eval ---
    {
        let model = reg.get(DeviceKind::Resistor).unwrap();
        let mut params = ParamMap::new();
        params.set("resistance", 1000.0);
        let voltages = [5.0, 2.0];
        group.bench_function("resistor", |b| {
            b.iter(|| model.eval(&voltages, &params));
        });
    }

    // --- Diode eval (forward bias) ---
    {
        let model = reg.get(DeviceKind::Diode).unwrap();
        let mut params = ParamMap::new();
        params.set("is", 1e-14);
        params.set("n", 1.0);
        let voltages = [0.7, 0.0];
        group.bench_function("diode_forward", |b| {
            b.iter(|| model.eval(&voltages, &params));
        });
    }

    // --- Diode eval (reverse bias) ---
    {
        let model = reg.get(DeviceKind::Diode).unwrap();
        let mut params = ParamMap::new();
        params.set("is", 1e-14);
        params.set("n", 1.0);
        let voltages = [-1.0, 0.0];
        group.bench_function("diode_reverse", |b| {
            b.iter(|| model.eval(&voltages, &params));
        });
    }

    // --- MOSFET N eval (saturation region) ---
    {
        let model = reg.get(DeviceKind::MosfetN).unwrap();
        let mut params = ParamMap::new();
        params.set("vth", 0.7);
        params.set("kp", 110e-6);
        params.set("w", 10e-6);
        params.set("l", 1e-6);
        // Gate=3V, Drain=5V, Source=0V, Bulk=0V -> saturation
        let voltages = [3.0, 5.0, 0.0, 0.0];
        group.bench_function("mosfet_n_sat", |b| {
            b.iter(|| model.eval(&voltages, &params));
        });
    }

    // --- Voltage source eval ---
    {
        let model = reg.get(DeviceKind::VoltageSource).unwrap();
        let mut params = ParamMap::new();
        params.set("dc", 5.0);
        let voltages = [5.0, 0.0];
        group.bench_function("vsource", |b| {
            b.iter(|| model.eval(&voltages, &params));
        });
    }

    group.finish();
}

criterion_group!(benches, bench_device_eval);
criterion_main!(benches);
