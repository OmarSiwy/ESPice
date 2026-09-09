const std = @import("std");
const devices = @import("devices");
const Hfet2 = devices.byName("hfet2");
const n_u = @typeInfo(Hfet2.U).@"enum".fields.len;
const S = devices.engine.Dual(n_u, f64);

fn drainCurrent(model: Hfet2.Model, temperature: f64) f64 {
    var inst: Hfet2.Instance = .{ .temperature = temperature };
    if (@hasDecl(Hfet2, "precompute")) Hfet2.precompute(&inst, &model);
    var x = [_]S{S.con(0)} ** n_u;
    x[@intFromEnum(Hfet2.U.d)] = S.con(1);
    x[@intFromEnum(Hfet2.U.dp)] = S.con(1);
    x[@intFromEnum(Hfet2.U.g)] = S.con(0.4);
    return Hfet2.eval(S, x, &model, &inst, 0)[@intFromEnum(Hfet2.U.dp)].v;
}

test "HFET2: ambient temperature, dtemp, and explicit override match ngspice" {
    // ngspice 44.2: NHFET LEVEL=6 KVTO=.001 KMU=.0001, W=20u L=1u,
    // Vds=1 Vgs=.4, .dc TEMP 27 100 73. Device Model.temp uses kelvin;
    // the reference's instance TEMP=50 is 323.15 K and overrides DTEMP=20.
    const ambient = [_]f64{ 300.15, 373.15 };
    const currents = [_]f64{ 0.0007910625026771714, 0.0011028847308300555 };
    const offset_currents = [_]f64{ 0.0008740013579734093, 0.001192949869979537 };
    for (ambient, currents, offset_currents) |temperature, expected, offset_expected| {
        var model: Hfet2.Model = .{ .kvto = 0.001, .kmu = 0.0001 };
        try std.testing.expectApproxEqRel(expected, drainCurrent(model, temperature), 1e-4);
        model.dtemp = 20;
        try std.testing.expectApproxEqRel(offset_expected, drainCurrent(model, temperature), 1e-4);
        model.temp = 323.15;
        try std.testing.expectApproxEqRel(@as(f64, 0.0008866012815815287), drainCurrent(model, temperature), 1e-4);
    }
}
