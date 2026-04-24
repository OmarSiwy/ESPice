use crate::node::NodeId;
use crate::param::ParamMap;
use serde::{Deserialize, Serialize};
use std::fmt;

/// Index into the device array.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[repr(transparent)]
pub struct DeviceId(pub u32);

impl DeviceId {
    #[inline]
    pub fn new(index: u32) -> Self {
        Self(index)
    }

    #[inline]
    pub fn index(self) -> usize {
        self.0 as usize
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "D{}", self.0)
    }
}

impl From<u32> for DeviceId {
    fn from(v: u32) -> Self {
        Self(v)
    }
}

/// A terminal connection: which pin of a device connects to which node.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Terminal {
    pub pin: u8,
    pub node: NodeId,
}

impl Terminal {
    pub fn new(pin: u8, node: NodeId) -> Self {
        Self { pin, node }
    }
}

/// Enumeration of all supported device types.
///
/// `repr(u8)` guarantees sequential discriminants 0..N for use as dense
/// array indices in the `DeviceRegistry` (hot-path O(1) lookup).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum DeviceKind {
    Resistor = 0,
    Capacitor = 1,
    Inductor = 2,
    Diode = 3,
    MosfetN = 4,
    MosfetP = 5,
    VoltageSource = 6,
    CurrentSource = 7,
    Vcvs = 8,
    Vccs = 9,
    Ccvs = 10,
    Cccs = 11,
    BjtNpn = 12,
    BjtPnp = 13,
    /// Behavioral source, voltage form: `B<name> n+ n- V={expr}`
    BsourceV = 14,
    /// Behavioral source, current form: `B<name> n+ n- I={expr}`
    BsourceI = 15,
    /// Voltage-controlled switch: `S<name> n+ n- nc+ nc- model`
    Switch = 16,
    /// Current-controlled switch: `W<name> n+ n- vname model`
    CSwitch = 17,
    /// N-channel JFET (Shichman-Hodges Level 1)
    JfetN = 18,
    /// P-channel JFET (Shichman-Hodges Level 1)
    JfetP = 19,
    /// Lossless transmission line (Branin's method): `T<name> n1 0 n2 0 Z0=50 TD=1n`
    Tline = 20,
    /// VBIC NPN bipolar transistor (4-terminal: C, B, E, S)
    VbicNpn = 21,
    /// VBIC PNP bipolar transistor (4-terminal: C, B, E, S)
    VbicPnp = 22,
    /// BSIM4.8.3 N-channel MOSFET (4-terminal: D, G, S, B; LEVEL=14/54)
    Bsim4N = 23,
    /// BSIM4.8.3 P-channel MOSFET (4-terminal: D, G, S, B; LEVEL=14/54)
    Bsim4P = 24,
    /// BSIM3v3.3 N-channel MOSFET (4-terminal: D, G, S, B; LEVEL=8/49)
    Bsim3N = 28,
    /// BSIM3v3.3 P-channel MOSFET (4-terminal: D, G, S, B; LEVEL=8/49)
    Bsim3P = 29,
    /// N-channel MESFET (Curtice model; `Z` element): D=0, G=1, S=2
    MesfetN = 30,
    /// P-channel MESFET (Curtice model; `Z` element): D=0, G=1, S=2
    MesfetP = 31,
    /// N-channel MOSFET Level 2 (Grove-Frohman bulk-charge model)
    MosfetN2 = 32,
    /// P-channel MOSFET Level 2 (Grove-Frohman bulk-charge model)
    MosfetP2 = 33,
    /// N-channel MOSFET Level 3 (empirical model with DIBL, mobility degradation)
    MosfetN3 = 34,
    /// P-channel MOSFET Level 3 (empirical model with DIBL, mobility degradation)
    MosfetP3 = 35,
    /// N-channel MOSFET Level 6 (Sakurai-Newton power-law model)
    MosfetN6 = 36,
    /// P-channel MOSFET Level 6 (Sakurai-Newton power-law model)
    MosfetP6 = 37,
    /// Uniform RC transmission line (`U` element).
    ///
    /// Expanded at parse time into `LUMPS` series-R + shunt-C segments.
    Urc = 38,
    /// W-element: frequency-domain lossy transmission line (Xyce stub).
    ///
    /// Falls back to LTRA with placeholder R/L/C values until tabulated
    /// S/Y/Z-parameter interpolation is implemented.
    Wlossy = 39,
    /// XSPICE A-element: generic analog/digital behavioural device.
    ///
    /// `A<name> [port_list] model_name` — the model type (e.g. `adc_bridge`,
    /// `dac_bridge`, `d_inverter`, `d_nand`) determines behaviour.  These
    /// devices are *not* stamped into MNA; instead, the digital runtime
    /// (ADC/DAC bridges + event queue) handles them during transient analysis.
    Xspice = 41,
    /// PORT element: S-parameter excitation port (HSPICE).
    ///
    /// Thevenin equivalent — voltage source in series with Z0 resistor.
    Port = 40,
    /// LTRA lossy transmission line (`O` element, 4-terminal: in+, in-, out+, out-).
    ///
    /// Per-unit-length parameters: `R`, `L`, `G`, `C`, total length `LEN`.
    /// DC path reduces to a resistive T network; transient uses
    /// Roychowdhury-Pederson convolution against a per-instance history.
    Ltra = 25,
    /// E-source with behavioral expression: `E<name> n+ n- VALUE={expr}`.
    ///
    /// Shares the B-source voltage stamping path.  The expression may reference
    /// `V(node)`, `V(n1,n2)`, params, `time`, `temper`, `frequency`, and `I(vsrc)`.
    VcvsExpr = 26,
    /// G-source with behavioral expression: `G<name> n+ n- VALUE={expr}`.
    ///
    /// Shares the B-source current stamping path.  Same expression support as
    /// `VcvsExpr`.
    VccsExpr = 27,
}

impl fmt::Display for DeviceKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Self::Resistor => "R",
            Self::Capacitor => "C",
            Self::Inductor => "L",
            Self::Diode => "D",
            Self::MosfetN => "NMOS",
            Self::MosfetP => "PMOS",
            Self::VoltageSource => "V",
            Self::CurrentSource => "I",
            Self::Vcvs => "E",
            Self::Vccs => "G",
            Self::Ccvs => "H",
            Self::Cccs => "F",
            Self::BjtNpn => "NPN",
            Self::BjtPnp => "PNP",
            Self::BsourceV => "BV",
            Self::BsourceI => "BI",
            Self::Switch => "S",
            Self::CSwitch => "W",
            Self::JfetN => "NJFET",
            Self::JfetP => "PJFET",
            Self::Tline => "T",
            Self::VbicNpn => "VBIC_NPN",
            Self::VbicPnp => "VBIC_PNP",
            Self::Bsim4N => "BSIM4N",
            Self::Bsim4P => "BSIM4P",
            Self::Bsim3N => "BSIM3N",
            Self::Bsim3P => "BSIM3P",
            Self::Ltra => "O",
            Self::VcvsExpr => "E_EXPR",
            Self::VccsExpr => "G_EXPR",
            Self::MesfetN => "NMESFET",
            Self::MesfetP => "PMESFET",
            Self::MosfetN2 => "NMOS2",
            Self::MosfetP2 => "PMOS2",
            Self::MosfetN3 => "NMOS3",
            Self::MosfetP3 => "PMOS3",
            Self::MosfetN6 => "NMOS6",
            Self::MosfetP6 => "PMOS6",
            Self::Urc => "U",
            Self::Wlossy => "W",
            Self::Port => "PORT",
            Self::Xspice => "A",
        };
        write!(f, "{s}")
    }
}

/// A single device instance in the circuit.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInstance {
    pub id: DeviceId,
    pub name: String,
    pub kind: DeviceKind,
    pub terminals: smallvec::SmallVec<[Terminal; 4]>,
    pub params: ParamMap,
    /// Index of the branch current variable in MNA (for V-sources, inductors).
    pub branch_index: Option<u32>,
}

impl DeviceInstance {
    pub fn new(
        id: DeviceId,
        name: impl Into<String>,
        kind: DeviceKind,
        terminals: &[(u8, NodeId)],
    ) -> Self {
        Self {
            id,
            name: name.into(),
            kind,
            terminals: terminals
                .iter()
                .map(|&(p, n)| Terminal::new(p, n))
                .collect(),
            params: ParamMap::new(),
            branch_index: None,
        }
    }

    pub fn with_param(mut self, key: &str, value: f64) -> Self {
        self.params.set(key, value);
        self
    }

    pub fn with_branch(mut self, index: u32) -> Self {
        self.branch_index = Some(index);
        self
    }

    /// Get the node connected to pin `pin`.
    pub fn node(&self, pin: u8) -> Option<NodeId> {
        self.terminals.iter().find(|t| t.pin == pin).map(|t| t.node)
    }

    /// Number of terminals.
    pub fn terminal_count(&self) -> usize {
        self.terminals.len()
    }

    /// Whether this device contributes a branch current variable to MNA.
    pub fn needs_branch(&self) -> bool {
        matches!(
            self.kind,
            DeviceKind::VoltageSource
                | DeviceKind::Inductor
                | DeviceKind::Vcvs
                | DeviceKind::Ccvs
                | DeviceKind::Cccs
                | DeviceKind::BsourceV
                | DeviceKind::VcvsExpr
                | DeviceKind::Tline
        )
    }
}

impl PartialEq for DeviceInstance {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl Eq for DeviceInstance {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_creation() {
        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, NodeId::new(1)), (1, NodeId::new(2))],
        )
        .with_param("resistance", 1000.0);

        assert_eq!(r1.kind, DeviceKind::Resistor);
        assert_eq!(r1.node(0), Some(NodeId::new(1)));
        assert_eq!(r1.node(1), Some(NodeId::new(2)));
        assert_eq!(r1.params.get("resistance"), Some(1000.0));
        assert!(!r1.needs_branch());
    }

    #[test]
    fn vsource_needs_branch() {
        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, NodeId::new(1)), (1, NodeId::GROUND)],
        );
        assert!(v1.needs_branch());
    }

    #[test]
    fn device_kind_display() {
        assert_eq!(format!("{}", DeviceKind::Resistor), "R");
        assert_eq!(format!("{}", DeviceKind::MosfetN), "NMOS");
    }

    #[test]
    fn device_id_new_and_index() {
        let id = DeviceId::new(5);
        assert_eq!(id.0, 5);
        assert_eq!(id.index(), 5);
    }

    #[test]
    fn device_id_display() {
        assert_eq!(format!("{}", DeviceId::new(3)), "D3");
    }

    #[test]
    fn device_id_from_u32() {
        let id: DeviceId = 10u32.into();
        assert_eq!(id.index(), 10);
    }

    #[test]
    fn device_id_ordering() {
        assert!(DeviceId::new(0) < DeviceId::new(1));
        assert!(DeviceId::new(5) > DeviceId::new(4));
    }

    #[test]
    fn terminal_new_stores_pin_and_node() {
        let t = Terminal::new(2, NodeId::new(3));
        assert_eq!(t.pin, 2);
        assert_eq!(t.node, NodeId::new(3));
    }

    #[test]
    fn device_node_returns_none_for_missing_pin() {
        let r = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, NodeId::new(1)), (1, NodeId::new(2))],
        );
        assert_eq!(r.node(99), None);
    }

    #[test]
    fn device_terminal_count() {
        let r = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, NodeId::new(1)), (1, NodeId::new(2))],
        );
        assert_eq!(r.terminal_count(), 2);

        let m = DeviceInstance::new(
            DeviceId::new(1),
            "M1",
            DeviceKind::MosfetN,
            &[(0, NodeId::new(1)), (1, NodeId::new(2)), (2, NodeId::new(3)), (3, NodeId::new(4))],
        );
        assert_eq!(m.terminal_count(), 4);
    }

    #[test]
    fn device_with_branch_sets_branch_index() {
        let v = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, NodeId::new(1)), (1, NodeId::GROUND)],
        )
        .with_branch(3);
        assert_eq!(v.branch_index, Some(3));
    }

    #[test]
    fn needs_branch_false_for_resistor_and_capacitor() {
        for kind in [DeviceKind::Resistor, DeviceKind::Capacitor, DeviceKind::CurrentSource] {
            let d = DeviceInstance::new(
                DeviceId::new(0),
                "X",
                kind,
                &[(0, NodeId::new(1)), (1, NodeId::GROUND)],
            );
            assert!(!d.needs_branch(), "{kind:?} should NOT need a branch");
        }
    }

    #[test]
    fn needs_branch_true_for_inductor_vcvs_ccvs_cccs_bsourcev() {
        for kind in [
            DeviceKind::Inductor,
            DeviceKind::Vcvs,
            DeviceKind::Ccvs,
            DeviceKind::Cccs,
            DeviceKind::BsourceV,
            DeviceKind::VcvsExpr,
        ] {
            let d = DeviceInstance::new(
                DeviceId::new(0),
                "X",
                kind,
                &[(0, NodeId::new(1)), (1, NodeId::GROUND)],
            );
            assert!(d.needs_branch(), "{kind:?} should need a branch");
        }
    }

    #[test]
    fn device_instance_equality_by_id() {
        let a = DeviceInstance::new(DeviceId::new(7), "R1", DeviceKind::Resistor, &[]);
        let b = DeviceInstance::new(DeviceId::new(7), "R_other", DeviceKind::Capacitor, &[]);
        assert_eq!(a, b, "equality must be id-based");

        let c = DeviceInstance::new(DeviceId::new(8), "R1", DeviceKind::Resistor, &[]);
        assert_ne!(a, c);
    }

    #[test]
    fn all_device_kinds_have_display() {
        // Ensures no match arm was forgotten in Display impl.
        let kinds = [
            DeviceKind::Resistor, DeviceKind::Capacitor, DeviceKind::Inductor,
            DeviceKind::Diode, DeviceKind::MosfetN, DeviceKind::MosfetP,
            DeviceKind::VoltageSource, DeviceKind::CurrentSource,
            DeviceKind::Vcvs, DeviceKind::Vccs, DeviceKind::Ccvs, DeviceKind::Cccs,
            DeviceKind::BjtNpn, DeviceKind::BjtPnp, DeviceKind::BsourceV, DeviceKind::BsourceI,
            DeviceKind::Switch, DeviceKind::CSwitch, DeviceKind::JfetN, DeviceKind::JfetP,
            DeviceKind::Tline, DeviceKind::VbicNpn, DeviceKind::VbicPnp,
            DeviceKind::Bsim4N, DeviceKind::Bsim4P, DeviceKind::Bsim3N, DeviceKind::Bsim3P,
            DeviceKind::Ltra, DeviceKind::VcvsExpr, DeviceKind::VccsExpr,
            DeviceKind::MesfetN, DeviceKind::MesfetP,
            DeviceKind::MosfetN2, DeviceKind::MosfetP2, DeviceKind::MosfetN3, DeviceKind::MosfetP3,
            DeviceKind::MosfetN6, DeviceKind::MosfetP6, DeviceKind::Urc, DeviceKind::Wlossy,
            DeviceKind::Port, DeviceKind::Xspice,
        ];
        for kind in kinds {
            let s = format!("{kind}");
            assert!(!s.is_empty(), "{kind:?} produced empty display string");
        }
    }
}
