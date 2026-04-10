use pisim_core::{DeviceKind, ParamMap};

use crate::bsource::{BsourceIModel, BsourceVModel};
use crate::eval::{DeviceEval, DeviceModel};
use crate::vcvs::VcvsExpr;
use crate::vccs::VccsExpr;
use crate::{
    Bjt, Capacitor, Cccs, Ccvs, CurrentSource, Diode, Inductor, MosfetLevel1, Resistor, Vccs,
    Vcvs, VoltageSource, Switch, CSwitch, JfetLevel1, Vbic, Bsim3, Bsim4, Mesfet,
};
use crate::mosfet::{MosfetLevel2, MosfetLevel3, MosfetLevel6};
use crate::tline::Tline;
use crate::ltra::Ltra;

/// Enum-based dispatch for all built-in device models.
///
/// Replaces vtable dispatch (`dyn DeviceModel`) on the hot path with a
/// flat `match` — no indirection, no cache misses, and the compiler can
/// inline each arm. The `DeviceModel` trait is still implemented by each
/// concrete type; this enum simply delegates to it.
#[derive(Debug, Clone, Copy)]
pub enum DeviceDispatch {
    Resistor(Resistor),
    Capacitor(Capacitor),
    Inductor(Inductor),
    Diode(Diode),
    MosfetLevel1(MosfetLevel1),
    MosfetLevel2(MosfetLevel2),
    MosfetLevel3(MosfetLevel3),
    MosfetLevel6(MosfetLevel6),
    VoltageSource(VoltageSource),
    CurrentSource(CurrentSource),
    Vcvs(Vcvs),
    Vccs(Vccs),
    Ccvs(Ccvs),
    Cccs(Cccs),
    Bjt(Bjt),
    BsourceV(BsourceVModel),
    BsourceI(BsourceIModel),
    Switch(Switch),
    CSwitch(CSwitch),
    JfetN(JfetLevel1),
    JfetP(JfetLevel1),
    Tline(Tline),
    Ltra(Ltra),
    VbicNpn(Vbic),
    VbicPnp(Vbic),
    Bsim4N(Bsim4),
    Bsim4P(Bsim4),
    Bsim3N(Bsim3),
    Bsim3P(Bsim3),
    MesfetN(Mesfet),
    MesfetP(Mesfet),
    /// E-source VALUE={expr} / TABLE form. Stamper takes the B-source expression path.
    VcvsExpr(VcvsExpr),
    /// G-source VALUE={expr} / TABLE form. Stamper takes the B-source expression path.
    VccsExpr(VccsExpr),
    /// Externally-loaded OSDI / OpenVAF compiled model.
    ///
    /// The variant payload is just an `OsdiHandle` (8 bytes of POD): an
    /// instance index plus cached terminal/flags. The actual evaluation
    /// is performed by `pisim_osdi::OsdiRegistry`, which the stamper
    /// borrows alongside the dispatch enum. Keeping the payload as POD
    /// avoids a crate-graph cycle (`pisim-osdi` depends on
    /// `pisim-device`, not the other way around).
    Osdi(crate::osdi_shim::OsdiHandle),
}

impl DeviceDispatch {
    /// Evaluate g(x), q(x), G, C at the given terminal voltages.
    pub fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        match self {
            DeviceDispatch::Resistor(m) => m.eval(voltages, params),
            DeviceDispatch::Capacitor(m) => m.eval(voltages, params),
            DeviceDispatch::Inductor(m) => m.eval(voltages, params),
            DeviceDispatch::Diode(m) => m.eval(voltages, params),
            DeviceDispatch::MosfetLevel1(m) => m.eval(voltages, params),
            DeviceDispatch::MosfetLevel2(m) => m.eval(voltages, params),
            DeviceDispatch::MosfetLevel3(m) => m.eval(voltages, params),
            DeviceDispatch::MosfetLevel6(m) => m.eval(voltages, params),
            DeviceDispatch::VoltageSource(m) => m.eval(voltages, params),
            DeviceDispatch::CurrentSource(m) => m.eval(voltages, params),
            DeviceDispatch::Vcvs(m) => m.eval(voltages, params),
            DeviceDispatch::Vccs(m) => m.eval(voltages, params),
            DeviceDispatch::Ccvs(m) => m.eval(voltages, params),
            DeviceDispatch::Cccs(m) => m.eval(voltages, params),
            DeviceDispatch::Bjt(m) => m.eval(voltages, params),
            DeviceDispatch::BsourceV(m) => m.eval(voltages, params),
            DeviceDispatch::BsourceI(m) => m.eval(voltages, params),
            DeviceDispatch::Switch(m) => m.eval(voltages, params),
            DeviceDispatch::CSwitch(m) => m.eval(voltages, params),
            DeviceDispatch::JfetN(m) => m.eval(voltages, params),
            DeviceDispatch::JfetP(m) => m.eval(voltages, params),
            DeviceDispatch::Tline(m) => m.eval(voltages, params),
            DeviceDispatch::Ltra(m) => m.eval(voltages, params),
            DeviceDispatch::VbicNpn(m) => m.eval(voltages, params),
            DeviceDispatch::VbicPnp(m) => m.eval(voltages, params),
            DeviceDispatch::Bsim4N(m) => m.eval(voltages, params),
            DeviceDispatch::Bsim4P(m) => m.eval(voltages, params),
            DeviceDispatch::Bsim3N(m) => m.eval(voltages, params),
            DeviceDispatch::Bsim3P(m) => m.eval(voltages, params),
            DeviceDispatch::MesfetN(m) => m.eval(voltages, params),
            DeviceDispatch::MesfetP(m) => m.eval(voltages, params),
            DeviceDispatch::VcvsExpr(m) => m.eval(voltages, params),
            DeviceDispatch::VccsExpr(m) => m.eval(voltages, params),
            // Sentinel: real OSDI eval is performed externally by
            // `pisim_osdi::OsdiRegistry::evaluate`. Returning an empty
            // `DeviceEval` here is intentional — callers that route
            // OSDI handles through this enum MUST also call into the
            // OSDI registry for the actual conductance/residual values.
            DeviceDispatch::Osdi(h) => h.eval(voltages, params),
        }
    }

    /// Number of external terminals.
    pub fn num_terminals(&self) -> usize {
        match self {
            DeviceDispatch::Resistor(m) => m.num_terminals(),
            DeviceDispatch::Capacitor(m) => m.num_terminals(),
            DeviceDispatch::Inductor(m) => m.num_terminals(),
            DeviceDispatch::Diode(m) => m.num_terminals(),
            DeviceDispatch::MosfetLevel1(m) => m.num_terminals(),
            DeviceDispatch::MosfetLevel2(m) => m.num_terminals(),
            DeviceDispatch::MosfetLevel3(m) => m.num_terminals(),
            DeviceDispatch::MosfetLevel6(m) => m.num_terminals(),
            DeviceDispatch::VoltageSource(m) => m.num_terminals(),
            DeviceDispatch::CurrentSource(m) => m.num_terminals(),
            DeviceDispatch::Vcvs(m) => m.num_terminals(),
            DeviceDispatch::Vccs(m) => m.num_terminals(),
            DeviceDispatch::Ccvs(m) => m.num_terminals(),
            DeviceDispatch::Cccs(m) => m.num_terminals(),
            DeviceDispatch::Bjt(m) => m.num_terminals(),
            DeviceDispatch::BsourceV(m) => m.num_terminals(),
            DeviceDispatch::BsourceI(m) => m.num_terminals(),
            DeviceDispatch::Switch(m) => m.num_terminals(),
            DeviceDispatch::CSwitch(m) => m.num_terminals(),
            DeviceDispatch::JfetN(m) => m.num_terminals(),
            DeviceDispatch::JfetP(m) => m.num_terminals(),
            DeviceDispatch::Tline(m) => m.num_terminals(),
            DeviceDispatch::Ltra(m) => m.num_terminals(),
            DeviceDispatch::VbicNpn(m) => m.num_terminals(),
            DeviceDispatch::VbicPnp(m) => m.num_terminals(),
            DeviceDispatch::Bsim4N(m) => m.num_terminals(),
            DeviceDispatch::Bsim4P(m) => m.num_terminals(),
            DeviceDispatch::Bsim3N(m) => m.num_terminals(),
            DeviceDispatch::Bsim3P(m) => m.num_terminals(),
            DeviceDispatch::MesfetN(m) => m.num_terminals(),
            DeviceDispatch::MesfetP(m) => m.num_terminals(),
            DeviceDispatch::VcvsExpr(m) => m.num_terminals(),
            DeviceDispatch::VccsExpr(m) => m.num_terminals(),
            DeviceDispatch::Osdi(h) => h.num_terminals(),
        }
    }

    /// Whether this device needs a branch current variable in MNA.
    pub fn needs_branch(&self) -> bool {
        match self {
            DeviceDispatch::Resistor(m) => m.needs_branch(),
            DeviceDispatch::Capacitor(m) => m.needs_branch(),
            DeviceDispatch::Inductor(m) => m.needs_branch(),
            DeviceDispatch::Diode(m) => m.needs_branch(),
            DeviceDispatch::MosfetLevel1(m) => m.needs_branch(),
            DeviceDispatch::MosfetLevel2(m) => m.needs_branch(),
            DeviceDispatch::MosfetLevel3(m) => m.needs_branch(),
            DeviceDispatch::MosfetLevel6(m) => m.needs_branch(),
            DeviceDispatch::VoltageSource(m) => m.needs_branch(),
            DeviceDispatch::CurrentSource(m) => m.needs_branch(),
            DeviceDispatch::Vcvs(m) => m.needs_branch(),
            DeviceDispatch::Vccs(m) => m.needs_branch(),
            DeviceDispatch::Ccvs(m) => m.needs_branch(),
            DeviceDispatch::Cccs(m) => m.needs_branch(),
            DeviceDispatch::Bjt(m) => m.needs_branch(),
            DeviceDispatch::BsourceV(m) => m.needs_branch(),
            DeviceDispatch::BsourceI(m) => m.needs_branch(),
            DeviceDispatch::Switch(m) => m.needs_branch(),
            DeviceDispatch::CSwitch(m) => m.needs_branch(),
            DeviceDispatch::JfetN(m) => m.needs_branch(),
            DeviceDispatch::JfetP(m) => m.needs_branch(),
            DeviceDispatch::Tline(m) => m.needs_branch(),
            DeviceDispatch::Ltra(m) => m.needs_branch(),
            DeviceDispatch::VbicNpn(m) => m.needs_branch(),
            DeviceDispatch::VbicPnp(m) => m.needs_branch(),
            DeviceDispatch::Bsim4N(m) => m.needs_branch(),
            DeviceDispatch::Bsim4P(m) => m.needs_branch(),
            DeviceDispatch::Bsim3N(m) => m.needs_branch(),
            DeviceDispatch::Bsim3P(m) => m.needs_branch(),
            DeviceDispatch::MesfetN(m) => m.needs_branch(),
            DeviceDispatch::MesfetP(m) => m.needs_branch(),
            DeviceDispatch::VcvsExpr(m) => m.needs_branch(),
            DeviceDispatch::VccsExpr(m) => m.needs_branch(),
            DeviceDispatch::Osdi(h) => h.needs_branch(),
        }
    }

    /// Device kind.
    pub fn kind(&self) -> DeviceKind {
        match self {
            DeviceDispatch::Resistor(m) => m.kind(),
            DeviceDispatch::Capacitor(m) => m.kind(),
            DeviceDispatch::Inductor(m) => m.kind(),
            DeviceDispatch::Diode(m) => m.kind(),
            DeviceDispatch::MosfetLevel1(m) => m.kind(),
            DeviceDispatch::MosfetLevel2(m) => m.kind(),
            DeviceDispatch::MosfetLevel3(m) => m.kind(),
            DeviceDispatch::MosfetLevel6(m) => m.kind(),
            DeviceDispatch::VoltageSource(m) => m.kind(),
            DeviceDispatch::CurrentSource(m) => m.kind(),
            DeviceDispatch::Vcvs(m) => m.kind(),
            DeviceDispatch::Vccs(m) => m.kind(),
            DeviceDispatch::Ccvs(m) => m.kind(),
            DeviceDispatch::Cccs(m) => m.kind(),
            DeviceDispatch::Bjt(m) => m.kind(),
            DeviceDispatch::BsourceV(m) => m.kind(),
            DeviceDispatch::BsourceI(m) => m.kind(),
            DeviceDispatch::Switch(m) => m.kind(),
            DeviceDispatch::CSwitch(m) => m.kind(),
            DeviceDispatch::JfetN(_) => DeviceKind::JfetN,
            DeviceDispatch::JfetP(_) => DeviceKind::JfetP,
            DeviceDispatch::Tline(m) => m.kind(),
            DeviceDispatch::Ltra(m) => m.kind(),
            DeviceDispatch::VbicNpn(_) => DeviceKind::VbicNpn,
            DeviceDispatch::VbicPnp(_) => DeviceKind::VbicPnp,
            DeviceDispatch::Bsim4N(m) => m.kind(),
            DeviceDispatch::Bsim4P(m) => m.kind(),
            DeviceDispatch::Bsim3N(m) => m.kind(),
            DeviceDispatch::Bsim3P(m) => m.kind(),
            DeviceDispatch::MesfetN(m) => m.kind(),
            DeviceDispatch::MesfetP(m) => m.kind(),
            DeviceDispatch::VcvsExpr(m) => m.kind(),
            DeviceDispatch::VccsExpr(m) => m.kind(),
            DeviceDispatch::Osdi(_) => crate::osdi_shim::OSDI_KIND_SENTINEL,
        }
    }

    /// Evaluate with branch current (for V-sources, inductors, VCVS).
    pub fn eval_with_branch(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        match self {
            DeviceDispatch::Resistor(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Capacitor(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Inductor(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Diode(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::MosfetLevel1(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::MosfetLevel2(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::MosfetLevel3(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::MosfetLevel6(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::VoltageSource(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::CurrentSource(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Vcvs(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Vccs(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Ccvs(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Cccs(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Bjt(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::BsourceV(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::BsourceI(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Switch(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::CSwitch(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::JfetN(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::JfetP(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Tline(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Ltra(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::VbicNpn(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::VbicPnp(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Bsim4N(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Bsim4P(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Bsim3N(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Bsim3P(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::MesfetN(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::MesfetP(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::VcvsExpr(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::VccsExpr(m) => m.eval_with_branch(voltages, branch_current, params),
            DeviceDispatch::Osdi(h) => h.eval_with_branch(voltages, branch_current, params),
        }
    }

    /// Time-aware evaluation. Default falls back to `eval_with_branch`,
    /// but for V/I sources the time parameter is used to evaluate the
    /// configured waveform via `Waveform::evaluate_at`.
    ///
    /// The stamper does not currently call this method, so transient
    /// analysis must opt in by calling it explicitly. DC analyses still
    /// see the t=0 value via the existing `eval_with_branch` path.
    pub fn eval_at_time(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
        time: f64,
    ) -> DeviceEval {
        match self {
            DeviceDispatch::VoltageSource(m) => {
                let mut e = m.eval_with_branch(voltages, branch_current, params);
                if !e.rhs.is_empty() {
                    e.rhs[0] = VoltageSource::value_at(params, time);
                }
                e
            }
            DeviceDispatch::CurrentSource(m) => {
                let mut e = m.eval(voltages, params);
                let i = CurrentSource::value_at(params, time);
                if e.rhs.len() >= 2 {
                    e.rhs[0] = i;
                    e.rhs[1] = -i;
                }
                e
            }
            other => other.eval_with_branch(voltages, branch_current, params),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dispatch_resistor_eval() {
        let d = DeviceDispatch::Resistor(Resistor);
        let mut params = ParamMap::new();
        params.set("resistance", 1000.0);
        let eval = d.eval(&[5.0, 2.0], &params);
        let expected = 3.0 / 1000.0;
        assert!((eval.g[0] - expected).abs() < 1e-15);
    }

    #[test]
    fn dispatch_num_terminals() {
        assert_eq!(DeviceDispatch::Resistor(Resistor).num_terminals(), 2);
        assert_eq!(DeviceDispatch::Capacitor(Capacitor).num_terminals(), 2);
        assert_eq!(DeviceDispatch::Inductor(Inductor).num_terminals(), 2);
        assert_eq!(DeviceDispatch::Diode(Diode).num_terminals(), 2);
        assert_eq!(DeviceDispatch::MosfetLevel1(MosfetLevel1).num_terminals(), 4);
        assert_eq!(DeviceDispatch::VoltageSource(VoltageSource).num_terminals(), 2);
        assert_eq!(DeviceDispatch::CurrentSource(CurrentSource).num_terminals(), 2);
        assert_eq!(DeviceDispatch::Vcvs(Vcvs).num_terminals(), 4);
        assert_eq!(DeviceDispatch::Vccs(Vccs).num_terminals(), 4);
        assert_eq!(DeviceDispatch::Ccvs(Ccvs).num_terminals(), 2);
        assert_eq!(DeviceDispatch::Cccs(Cccs).num_terminals(), 2);
        assert_eq!(DeviceDispatch::Bjt(Bjt::npn()).num_terminals(), 3);
    }

    #[test]
    fn dispatch_needs_branch() {
        assert!(!DeviceDispatch::Resistor(Resistor).needs_branch());
        assert!(!DeviceDispatch::Capacitor(Capacitor).needs_branch());
        assert!(DeviceDispatch::Inductor(Inductor).needs_branch());
        assert!(!DeviceDispatch::Diode(Diode).needs_branch());
        assert!(!DeviceDispatch::MosfetLevel1(MosfetLevel1).needs_branch());
        assert!(DeviceDispatch::VoltageSource(VoltageSource).needs_branch());
        assert!(!DeviceDispatch::CurrentSource(CurrentSource).needs_branch());
        assert!(DeviceDispatch::Vcvs(Vcvs).needs_branch());
        assert!(!DeviceDispatch::Vccs(Vccs).needs_branch());
        assert!(DeviceDispatch::Ccvs(Ccvs).needs_branch());
        assert!(!DeviceDispatch::Cccs(Cccs).needs_branch());
        assert!(!DeviceDispatch::Bjt(Bjt::npn()).needs_branch());
    }

    #[test]
    fn dispatch_kind() {
        assert_eq!(DeviceDispatch::Resistor(Resistor).kind(), DeviceKind::Resistor);
        assert_eq!(DeviceDispatch::VoltageSource(VoltageSource).kind(), DeviceKind::VoltageSource);
        assert_eq!(DeviceDispatch::Vcvs(Vcvs).kind(), DeviceKind::Vcvs);
        assert_eq!(DeviceDispatch::Ccvs(Ccvs).kind(), DeviceKind::Ccvs);
        assert_eq!(DeviceDispatch::Cccs(Cccs).kind(), DeviceKind::Cccs);
        assert_eq!(DeviceDispatch::Bjt(Bjt::npn()).kind(), DeviceKind::BjtNpn);
        assert_eq!(DeviceDispatch::Bjt(Bjt::pnp()).kind(), DeviceKind::BjtPnp);
    }

    #[test]
    fn dispatch_eval_with_branch() {
        let d = DeviceDispatch::VoltageSource(VoltageSource);
        let mut params = ParamMap::new();
        params.set("dc", 5.0);
        let eval = d.eval_with_branch(&[5.0, 0.0], 0.001, &params);
        assert!((eval.g[0] - 0.001).abs() < 1e-15);
        assert!((eval.g[2] - 5.0).abs() < 1e-15);
        assert!((eval.rhs[0] - 5.0).abs() < 1e-15);
    }

    #[test]
    fn dispatch_eval_at_time_pulse() {
        // Voltage source with PULSE waveform: at t=0 returns v1, at the
        // plateau returns v2.
        let d = DeviceDispatch::VoltageSource(VoltageSource);
        let mut p = ParamMap::new();
        p.set("waveform_kind", 1.0);
        p.set("pulse_v1", 0.0);
        p.set("pulse_v2", 5.0);
        p.set("pulse_td", 0.0);
        p.set("pulse_tr", 1e-9);
        p.set("pulse_tf", 1e-9);
        p.set("pulse_pw", 10e-6);
        p.set("pulse_per", 20e-6);

        let e0 = d.eval_at_time(&[0.0, 0.0], 0.0, &p, 0.0);
        // At t=0, we are at the start of the rising ramp, value = v1.
        assert!(e0.rhs[0].abs() < 1e-12);

        let e1 = d.eval_at_time(&[0.0, 0.0], 0.0, &p, 5e-6);
        // Mid-plateau.
        assert!((e1.rhs[0] - 5.0).abs() < 1e-12);
    }
}
