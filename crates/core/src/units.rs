use serde::{Deserialize, Serialize};
use std::fmt;

/// SI multiplier prefixes used in SPICE netlists.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Si(pub f64);

impl Si {
    pub const FEMTO: f64 = 1e-15;
    pub const PICO: f64 = 1e-12;
    pub const NANO: f64 = 1e-9;
    pub const MICRO: f64 = 1e-6;
    pub const MILLI: f64 = 1e-3;
    pub const KILO: f64 = 1e3;
    pub const MEGA: f64 = 1e6;
    pub const GIGA: f64 = 1e9;
    pub const TERA: f64 = 1e12;

    /// Parse an SI suffix character into a multiplier.
    pub fn parse_suffix(c: char) -> Option<f64> {
        match c {
            'f' => Some(Self::FEMTO),
            'p' => Some(Self::PICO),
            'n' => Some(Self::NANO),
            'u' | 'µ' => Some(Self::MICRO),
            'm' => Some(Self::MILLI),
            'k' | 'K' => Some(Self::KILO),
            'M' => Some(Self::MEGA),
            'G' => Some(Self::GIGA),
            'T' => Some(Self::TERA),
            _ => None,
        }
    }

    /// Parse a SPICE-style value string (e.g., "1.5k", "100n", "2.2meg").
    pub fn parse_spice_value(s: &str) -> Option<f64> {
        let s = s.trim();
        if s.is_empty() {
            return None;
        }

        // Try direct parse first.
        if let Ok(v) = s.parse::<f64>() {
            return Some(v);
        }

        // Handle SPICE suffixes: meg, mil
        let lower = s.to_lowercase();
        if let Some(prefix) = lower.strip_suffix("meg") {
            return prefix.parse::<f64>().ok().map(|v| v * Self::MEGA);
        }
        if let Some(prefix) = lower.strip_suffix("mil") {
            return prefix.parse::<f64>().ok().map(|v| v * 25.4e-6);
        }

        // Single-character suffix.
        let (num_part, suffix) = s.split_at(s.len() - 1);
        let multiplier = Self::parse_suffix(suffix.chars().next()?)?;
        num_part.parse::<f64>().ok().map(|v| v * multiplier)
    }
}

impl fmt::Display for Si {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let v = self.0.abs();
        let (scaled, suffix) = if v >= 1e12 {
            (self.0 / 1e12, "T")
        } else if v >= 1e9 {
            (self.0 / 1e9, "G")
        } else if v >= 1e6 {
            (self.0 / 1e6, "M")
        } else if v >= 1e3 {
            (self.0 / 1e3, "k")
        } else if v >= 1.0 {
            (self.0, "")
        } else if v >= 1e-3 {
            (self.0 / 1e-3, "m")
        } else if v >= 1e-6 {
            (self.0 / 1e-6, "u")
        } else if v >= 1e-9 {
            (self.0 / 1e-9, "n")
        } else if v >= 1e-12 {
            (self.0 / 1e-12, "p")
        } else {
            (self.0 / 1e-15, "f")
        };
        write!(f, "{scaled:.4}{suffix}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_spice_values() {
        fn approx(a: Option<f64>, b: f64) {
            let a = a.unwrap();
            assert!((a - b).abs() < b.abs() * 1e-12 + 1e-30, "{a} != {b}");
        }
        approx(Si::parse_spice_value("1k"), 1e3);
        approx(Si::parse_spice_value("2.2k"), 2.2e3);
        approx(Si::parse_spice_value("100n"), 1e-7);
        approx(Si::parse_spice_value("1.5meg"), 1.5e6);
        approx(Si::parse_spice_value("10u"), 10e-6);
        approx(Si::parse_spice_value("47p"), 47e-12);
        assert_eq!(Si::parse_spice_value("3.3"), Some(3.3));
    }

    #[test]
    fn si_display() {
        assert_eq!(format!("{}", Si(1e3)), "1.0000k");
        assert_eq!(format!("{}", Si(100e-9)), "100.0000n");
    }

    #[test]
    fn parse_invalid() {
        assert_eq!(Si::parse_spice_value(""), None);
        assert_eq!(Si::parse_spice_value("abc"), None);
    }
}
