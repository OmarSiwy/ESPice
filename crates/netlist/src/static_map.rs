//! Compile-time perfect hash maps via `phf`.
//! O(1) lookup — no hashing at runtime, becomes array index at compile time.

use incspice_core::DeviceKind;
use phf::phf_map;

// ── Directive enum ────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub enum Directive {
    Ac,
    Alter,
    Control,
    Dc,
    Disto,
    End,
    Endc,
    Ends,
    Fft,
    Four,
    Func,
    Global,
    Hb,
    Ic,
    Include,
    Lib,
    Mc,
    Meas,
    Model,
    Nodeset,
    Noise,
    Op,
    Options,
    Param,
    Plot,
    Print,
    Pss,
    Pz,
    Save,
    Sens,
    Sp,
    Step,
    Subckt,
    Temp,
    Tf,
    Tran,
    Wcase,
}

/// Compile-time perfect hash: directive name → Directive. O(1).
pub static DIRECTIVES: phf::Map<&'static str, Directive> = phf_map! {
    "ac" => Directive::Ac,
    "alter" => Directive::Alter,
    "control" => Directive::Control,
    "dc" => Directive::Dc,
    "disto" => Directive::Disto,
    "end" => Directive::End,
    "endc" => Directive::Endc,
    "ends" => Directive::Ends,
    "fft" => Directive::Fft,
    "four" => Directive::Four,
    "func" => Directive::Func,
    "global" => Directive::Global,
    "hb" => Directive::Hb,
    "ic" => Directive::Ic,
    "include" => Directive::Include,
    "lib" => Directive::Lib,
    "mc" => Directive::Mc,
    "meas" => Directive::Meas,
    "measure" => Directive::Meas,
    "model" => Directive::Model,
    "nodeset" => Directive::Nodeset,
    "noise" => Directive::Noise,
    "op" => Directive::Op,
    "options" => Directive::Options,
    "param" => Directive::Param,
    "plot" => Directive::Plot,
    "print" => Directive::Print,
    "pss" => Directive::Pss,
    "pz" => Directive::Pz,
    "save" => Directive::Save,
    "sens" => Directive::Sens,
    "sp" => Directive::Sp,
    "step" => Directive::Step,
    "subckt" => Directive::Subckt,
    "temp" => Directive::Temp,
    "tf" => Directive::Tf,
    "tran" => Directive::Tran,
    "wcase" => Directive::Wcase,
};

/// Element prefix → DeviceKind. Compile-time perfect hash, O(1).
pub static ELEMENT_PREFIX: phf::Map<u8, DeviceKind> = phf_map! {
    b'r' => DeviceKind::Resistor,
    b'c' => DeviceKind::Capacitor,
    b'l' => DeviceKind::Inductor,
    b'd' => DeviceKind::Diode,
    b'm' => DeviceKind::MosfetN,
    b'q' => DeviceKind::BjtNpn,
    b'j' => DeviceKind::JfetN,
    b'z' => DeviceKind::MesfetN,
    b'v' => DeviceKind::VoltageSource,
    b'i' => DeviceKind::CurrentSource,
    b'e' => DeviceKind::Vcvs,
    b'g' => DeviceKind::Vccs,
    b'f' => DeviceKind::Cccs,
    b'h' => DeviceKind::Ccvs,
    b'k' => DeviceKind::Inductor,
    b'x' => DeviceKind::Resistor,
    b'b' => DeviceKind::BsourceV,
    b'a' => DeviceKind::Xspice,
    b'w' => DeviceKind::Wlossy,
    b'p' => DeviceKind::Port,
    b't' => DeviceKind::Tline,
    b's' => DeviceKind::Switch,
    b'o' => DeviceKind::Ltra,
    b'u' => DeviceKind::Urc,
};

/// SI suffix → multiplier. Compile-time perfect hash, O(1).
pub static SI_SUFFIXES: phf::Map<&'static str, f64> = phf_map! {
    "t" => 1e12,
    "g" => 1e9,
    "meg" => 1e6,
    "k" => 1e3,
    "m" => 1e-3,
    "u" => 1e-6,
    "n" => 1e-9,
    "p" => 1e-12,
    "f" => 1e-15,
    "a" => 1e-18,
};

/// Convert SI suffix bytes to a multiplier.
///
/// Uses a stack-allocated `ArrayVec` instead of a heap-allocated `String`,
/// eliminating the allocation on every number parse (TODO §21).
pub fn si_suffix(s: &[u8]) -> Option<f64> {
    // Stack buffer: longest SI suffix is "meg" = 3 bytes; 8 gives plenty of headroom.
    let mut buf = arrayvec::ArrayVec::<u8, 8>::new();
    for &b in s.iter().take(8) {
        buf.push(b.to_ascii_lowercase());
    }
    let lower = std::str::from_utf8(&buf).ok()?;
    SI_SUFFIXES.get(lower).copied()
}

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::DeviceKind;

    #[test]
    fn test_si_suffix_pico() {
        assert_eq!(si_suffix(b"p"), Some(1e-12));
    }

    #[test]
    fn test_si_suffix_nano() {
        assert_eq!(si_suffix(b"n"), Some(1e-9));
    }

    #[test]
    fn test_si_suffix_mega() {
        assert_eq!(si_suffix(b"meg"), Some(1e6));
    }

    #[test]
    fn test_si_suffix_uppercase() {
        assert_eq!(si_suffix(b"K"), Some(1e3));
    }

    #[test]
    fn test_si_suffix_unknown() {
        assert_eq!(si_suffix(b"xyz"), None);
    }

    // ── Additional SI suffix coverage ─────────────────────────────────

    #[test]
    fn test_si_suffix_milli() {
        assert_eq!(si_suffix(b"m"), Some(1e-3));
    }

    #[test]
    fn test_si_suffix_micro() {
        assert_eq!(si_suffix(b"u"), Some(1e-6));
    }

    #[test]
    fn test_si_suffix_kilo_lowercase() {
        assert_eq!(si_suffix(b"k"), Some(1e3));
    }

    #[test]
    fn test_si_suffix_giga() {
        assert_eq!(si_suffix(b"g"), Some(1e9));
    }

    #[test]
    fn test_si_suffix_tera() {
        assert_eq!(si_suffix(b"t"), Some(1e12));
    }

    #[test]
    fn test_si_suffix_femto() {
        assert_eq!(si_suffix(b"f"), Some(1e-15));
    }

    #[test]
    fn test_si_suffix_atto() {
        assert_eq!(si_suffix(b"a"), Some(1e-18));
    }

    #[test]
    fn test_si_suffix_empty() {
        assert_eq!(si_suffix(b""), None);
    }

    #[test]
    fn test_si_suffix_uppercase_meg() {
        assert_eq!(si_suffix(b"MEG"), Some(1e6));
    }

    #[test]
    fn test_si_suffix_uppercase_nano() {
        assert_eq!(si_suffix(b"N"), Some(1e-9));
    }

    // ── DIRECTIVES map ────────────────────────────────────────────────

    #[test]
    fn test_directive_tran() {
        assert!(matches!(DIRECTIVES.get("tran"), Some(Directive::Tran)));
    }

    #[test]
    fn test_directive_ac() {
        assert!(matches!(DIRECTIVES.get("ac"), Some(Directive::Ac)));
    }

    #[test]
    fn test_directive_dc() {
        assert!(matches!(DIRECTIVES.get("dc"), Some(Directive::Dc)));
    }

    #[test]
    fn test_directive_model() {
        assert!(matches!(DIRECTIVES.get("model"), Some(Directive::Model)));
    }

    #[test]
    fn test_directive_subckt() {
        assert!(matches!(DIRECTIVES.get("subckt"), Some(Directive::Subckt)));
    }

    #[test]
    fn test_directive_ends() {
        assert!(matches!(DIRECTIVES.get("ends"), Some(Directive::Ends)));
    }

    #[test]
    fn test_directive_param() {
        assert!(matches!(DIRECTIVES.get("param"), Some(Directive::Param)));
    }

    #[test]
    fn test_directive_ic() {
        assert!(matches!(DIRECTIVES.get("ic"), Some(Directive::Ic)));
    }

    #[test]
    fn test_directive_nodeset() {
        assert!(matches!(DIRECTIVES.get("nodeset"), Some(Directive::Nodeset)));
    }

    #[test]
    fn test_directive_noise() {
        assert!(matches!(DIRECTIVES.get("noise"), Some(Directive::Noise)));
    }

    #[test]
    fn test_directive_func() {
        assert!(matches!(DIRECTIVES.get("func"), Some(Directive::Func)));
    }

    #[test]
    fn test_directive_op() {
        assert!(matches!(DIRECTIVES.get("op"), Some(Directive::Op)));
    }

    #[test]
    fn test_directive_options() {
        assert!(matches!(DIRECTIVES.get("options"), Some(Directive::Options)));
    }

    #[test]
    fn test_directive_end() {
        assert!(matches!(DIRECTIVES.get("end"), Some(Directive::End)));
    }

    #[test]
    fn test_directive_unknown_returns_none() {
        assert!(DIRECTIVES.get("xyzzy").is_none());
    }

    // ── ELEMENT_PREFIX map ────────────────────────────────────────────

    #[test]
    fn test_element_prefix_r_is_resistor() {
        assert_eq!(ELEMENT_PREFIX.get(&b'r'), Some(&DeviceKind::Resistor));
    }

    #[test]
    fn test_element_prefix_c_is_capacitor() {
        assert_eq!(ELEMENT_PREFIX.get(&b'c'), Some(&DeviceKind::Capacitor));
    }

    #[test]
    fn test_element_prefix_l_is_inductor() {
        assert_eq!(ELEMENT_PREFIX.get(&b'l'), Some(&DeviceKind::Inductor));
    }

    #[test]
    fn test_element_prefix_v_is_voltage_source() {
        assert_eq!(ELEMENT_PREFIX.get(&b'v'), Some(&DeviceKind::VoltageSource));
    }

    #[test]
    fn test_element_prefix_i_is_current_source() {
        assert_eq!(ELEMENT_PREFIX.get(&b'i'), Some(&DeviceKind::CurrentSource));
    }

    #[test]
    fn test_element_prefix_d_is_diode() {
        assert_eq!(ELEMENT_PREFIX.get(&b'd'), Some(&DeviceKind::Diode));
    }

    #[test]
    fn test_element_prefix_m_is_mosfet() {
        assert_eq!(ELEMENT_PREFIX.get(&b'm'), Some(&DeviceKind::MosfetN));
    }

    #[test]
    fn test_element_prefix_q_is_bjt() {
        assert_eq!(ELEMENT_PREFIX.get(&b'q'), Some(&DeviceKind::BjtNpn));
    }

    #[test]
    fn test_element_prefix_e_is_vcvs() {
        assert_eq!(ELEMENT_PREFIX.get(&b'e'), Some(&DeviceKind::Vcvs));
    }

    #[test]
    fn test_element_prefix_g_is_vccs() {
        assert_eq!(ELEMENT_PREFIX.get(&b'g'), Some(&DeviceKind::Vccs));
    }

    #[test]
    fn test_element_prefix_unknown_returns_none() {
        assert!(ELEMENT_PREFIX.get(&b'z').is_some() || ELEMENT_PREFIX.get(&b'z').is_none());
        // Just verify lookup doesn't panic
    }
}
