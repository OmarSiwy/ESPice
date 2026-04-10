use pisim_core::DeviceKind;

use crate::bsource::{BsourceIModel, BsourceVModel};
use crate::dispatch::DeviceDispatch;
use crate::{
    Bjt, Bsim3, Capacitor, CurrentSource, Diode, Inductor, JfetLevel1, Mesfet, MosfetLevel1,
    Resistor, Vccs, Vcvs, VoltageSource, Switch, CSwitch, Vbic,
};
use crate::mosfet::{MosfetLevel2, MosfetLevel3, MosfetLevel6};
use crate::tline::Tline;
use crate::ltra::Ltra;

/// Maximum number of device kinds. Must be >= the number of DeviceKind variants.
const MAX_DEVICE_KINDS: usize = 64;

/// Map DeviceKind discriminant to array index.
///
/// Using a dense array instead of a HashMap eliminates hashing overhead
/// on the hot path (per-device, per-NR-iteration). The DeviceKind enum
/// has ~14 variants, so a 16-slot array is negligible in memory.
#[inline]
fn kind_to_index(kind: DeviceKind) -> usize {
    kind as usize
}

/// Registry mapping `DeviceKind` to its model implementation.
///
/// Uses a dense array indexed by `DeviceKind` discriminant instead of a
/// HashMap. This gives O(1) lookup with zero hashing overhead on the hot
/// path — a single array index instead of hash + probe + compare.
///
/// Uses enum-based dispatch (`DeviceDispatch`) instead of vtable dispatch
/// (`dyn DeviceModel`) for cache-friendly evaluation on the hot path.
pub struct DeviceRegistry {
    models: [Option<DeviceDispatch>; MAX_DEVICE_KINDS],
    len: usize,
}

impl DeviceRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            models: [None; MAX_DEVICE_KINDS],
            len: 0,
        }
    }

    /// Create a registry pre-populated with all built-in device models.
    pub fn new_default() -> Self {
        let mut reg = Self::new();
        reg.register(DeviceKind::Resistor, DeviceDispatch::Resistor(Resistor));
        reg.register(DeviceKind::Capacitor, DeviceDispatch::Capacitor(Capacitor));
        reg.register(DeviceKind::Inductor, DeviceDispatch::Inductor(Inductor));
        reg.register(DeviceKind::Diode, DeviceDispatch::Diode(Diode));
        reg.register(DeviceKind::MosfetN, DeviceDispatch::MosfetLevel1(MosfetLevel1));
        reg.register(DeviceKind::MosfetP, DeviceDispatch::MosfetLevel1(MosfetLevel1));
        reg.register(DeviceKind::VoltageSource, DeviceDispatch::VoltageSource(VoltageSource));
        reg.register(DeviceKind::CurrentSource, DeviceDispatch::CurrentSource(CurrentSource));
        reg.register(DeviceKind::Vcvs, DeviceDispatch::Vcvs(Vcvs));
        reg.register(DeviceKind::Vccs, DeviceDispatch::Vccs(Vccs));
        reg.register(DeviceKind::BsourceV, DeviceDispatch::BsourceV(BsourceVModel));
        reg.register(DeviceKind::BsourceI, DeviceDispatch::BsourceI(BsourceIModel));
        reg.register(DeviceKind::Switch, DeviceDispatch::Switch(Switch));
        reg.register(DeviceKind::CSwitch, DeviceDispatch::CSwitch(CSwitch));
        reg.register(DeviceKind::JfetN, DeviceDispatch::JfetN(JfetLevel1));
        reg.register(DeviceKind::JfetP, DeviceDispatch::JfetP(JfetLevel1));
        reg.register(DeviceKind::Tline, DeviceDispatch::Tline(Tline));
        reg.register(DeviceKind::Ltra, DeviceDispatch::Ltra(Ltra));
        reg.register(DeviceKind::VbicNpn, DeviceDispatch::VbicNpn(Vbic::npn()));
        reg.register(DeviceKind::VbicPnp, DeviceDispatch::VbicPnp(Vbic::pnp()));
        reg.register(DeviceKind::BjtNpn, DeviceDispatch::Bjt(Bjt::npn()));
        reg.register(DeviceKind::BjtPnp, DeviceDispatch::Bjt(Bjt::pnp()));
        reg.register(DeviceKind::Bsim3N, DeviceDispatch::Bsim3N(Bsim3::nmos()));
        reg.register(DeviceKind::Bsim3P, DeviceDispatch::Bsim3P(Bsim3::pmos()));
        reg.register(DeviceKind::Bsim4N, DeviceDispatch::Bsim4N(crate::Bsim4::nmos()));
        reg.register(DeviceKind::Bsim4P, DeviceDispatch::Bsim4P(crate::Bsim4::pmos()));
        reg.register(DeviceKind::MesfetN, DeviceDispatch::MesfetN(Mesfet::nmos()));
        reg.register(DeviceKind::MesfetP, DeviceDispatch::MesfetP(Mesfet::pmos()));
        reg.register(DeviceKind::MosfetN2, DeviceDispatch::MosfetLevel2(MosfetLevel2));
        reg.register(DeviceKind::MosfetP2, DeviceDispatch::MosfetLevel2(MosfetLevel2));
        reg.register(DeviceKind::MosfetN3, DeviceDispatch::MosfetLevel3(MosfetLevel3));
        reg.register(DeviceKind::MosfetP3, DeviceDispatch::MosfetLevel3(MosfetLevel3));
        reg.register(DeviceKind::MosfetN6, DeviceDispatch::MosfetLevel6(MosfetLevel6));
        reg.register(DeviceKind::MosfetP6, DeviceDispatch::MosfetLevel6(MosfetLevel6));
        reg
    }

    /// Register a device model for a given kind.
    pub fn register(&mut self, kind: DeviceKind, model: DeviceDispatch) {
        let idx = kind_to_index(kind);
        debug_assert!(idx < MAX_DEVICE_KINDS, "DeviceKind discriminant {idx} exceeds registry capacity");
        if self.models[idx].is_none() {
            self.len += 1;
        }
        self.models[idx] = Some(model);
    }

    /// Look up the model for a device kind.
    /// O(1) — single array index, no hashing.
    #[inline]
    pub fn get(&self, kind: DeviceKind) -> Option<&DeviceDispatch> {
        let idx = kind_to_index(kind);
        if idx < MAX_DEVICE_KINDS {
            self.models[idx].as_ref()
        } else {
            None
        }
    }

    /// Number of registered models.
    pub fn len(&self) -> usize {
        self.len
    }

    /// Whether the registry is empty.
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }
}

impl Default for DeviceRegistry {
    fn default() -> Self {
        Self::new_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pisim_core::ParamMap;

    #[test]
    fn registry_default_has_all_builtins() {
        let reg = DeviceRegistry::new_default();
        assert!(reg.get(DeviceKind::Resistor).is_some());
        assert!(reg.get(DeviceKind::Capacitor).is_some());
        assert!(reg.get(DeviceKind::Inductor).is_some());
        assert!(reg.get(DeviceKind::Diode).is_some());
        assert!(reg.get(DeviceKind::MosfetN).is_some());
        assert!(reg.get(DeviceKind::MosfetP).is_some());
        assert!(reg.get(DeviceKind::VoltageSource).is_some());
        assert!(reg.get(DeviceKind::CurrentSource).is_some());
        assert!(reg.get(DeviceKind::Vcvs).is_some());
        assert!(reg.get(DeviceKind::Vccs).is_some());
        assert!(reg.get(DeviceKind::BsourceV).is_some());
        assert!(reg.get(DeviceKind::BsourceI).is_some());
        assert!(reg.get(DeviceKind::Ltra).is_some());
        assert!(reg.get(DeviceKind::BjtNpn).is_some());
        assert!(reg.get(DeviceKind::BjtPnp).is_some());
        assert!(reg.get(DeviceKind::Bsim3N).is_some());
        assert!(reg.get(DeviceKind::Bsim3P).is_some());
        assert!(reg.get(DeviceKind::Bsim4N).is_some());
        assert!(reg.get(DeviceKind::Bsim4P).is_some());
        assert_eq!(reg.len(), 28);
    }

    #[test]
    fn registry_missing_kind() {
        // Empty registry has nothing.
        let reg = DeviceRegistry::new();
        assert!(reg.get(DeviceKind::BjtNpn).is_none());
    }

    #[test]
    fn registry_lookup_and_eval() {
        let reg = DeviceRegistry::new_default();
        let model = reg.get(DeviceKind::Resistor).unwrap();

        let mut params = ParamMap::new();
        params.set("resistance", 1000.0);
        let eval = model.eval(&[5.0, 2.0], &params);

        let expected = 3.0 / 1000.0;
        assert!((eval.g[0] - expected).abs() < 1e-15);
    }

    #[test]
    fn registry_empty() {
        let reg = DeviceRegistry::new();
        assert!(reg.is_empty());
        assert_eq!(reg.len(), 0);
    }

    #[test]
    fn registry_custom_model() {
        let mut reg = DeviceRegistry::new();
        reg.register(DeviceKind::Resistor, DeviceDispatch::Resistor(Resistor));
        assert!(reg.get(DeviceKind::Resistor).is_some());
        assert_eq!(reg.len(), 1);
    }

    #[test]
    fn registry_overwrite_model() {
        let mut reg = DeviceRegistry::new_default();
        let original_count = reg.len();
        reg.register(DeviceKind::Resistor, DeviceDispatch::Resistor(Resistor));
        assert_eq!(reg.len(), original_count);
    }

    #[test]
    fn registry_num_terminals() {
        let reg = DeviceRegistry::new_default();

        assert_eq!(reg.get(DeviceKind::Resistor).unwrap().num_terminals(), 2);
        assert_eq!(reg.get(DeviceKind::Capacitor).unwrap().num_terminals(), 2);
        assert_eq!(reg.get(DeviceKind::Inductor).unwrap().num_terminals(), 2);
        assert_eq!(reg.get(DeviceKind::Diode).unwrap().num_terminals(), 2);
        assert_eq!(reg.get(DeviceKind::MosfetN).unwrap().num_terminals(), 4);
        assert_eq!(reg.get(DeviceKind::VoltageSource).unwrap().num_terminals(), 2);
        assert_eq!(reg.get(DeviceKind::CurrentSource).unwrap().num_terminals(), 2);
        assert_eq!(reg.get(DeviceKind::Vcvs).unwrap().num_terminals(), 4);
        assert_eq!(reg.get(DeviceKind::Vccs).unwrap().num_terminals(), 4);
    }

    #[test]
    fn registry_needs_branch() {
        let reg = DeviceRegistry::new_default();

        assert!(!reg.get(DeviceKind::Resistor).unwrap().needs_branch());
        assert!(!reg.get(DeviceKind::Capacitor).unwrap().needs_branch());
        assert!(reg.get(DeviceKind::Inductor).unwrap().needs_branch());
        assert!(!reg.get(DeviceKind::Diode).unwrap().needs_branch());
        assert!(!reg.get(DeviceKind::MosfetN).unwrap().needs_branch());
        assert!(reg.get(DeviceKind::VoltageSource).unwrap().needs_branch());
        assert!(!reg.get(DeviceKind::CurrentSource).unwrap().needs_branch());
        assert!(reg.get(DeviceKind::Vcvs).unwrap().needs_branch());
        assert!(!reg.get(DeviceKind::Vccs).unwrap().needs_branch());
    }
}
