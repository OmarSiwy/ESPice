/// PHF-backed SI suffix map for SPICE numeric parsing.
///
/// Keys are lowercase ASCII suffix strings. Values are the corresponding
/// multiplicative factor to convert a raw mantissa to SI base units.
pub static SI_SUFFIX_MAP: phf::Map<&'static str, f64> = phf::phf_map! {
    "f"   => 1e-15,
    "p"   => 1e-12,
    "n"   => 1e-9,
    "u"   => 1e-6,
    "m"   => 1e-3,
    "k"   => 1e3,
    "meg" => 1e6,
    "g"   => 1e9,
    "t"   => 1e12,
};

/// Look up the SI multiplier for a byte-slice suffix (case-insensitive, pre-lowercased).
///
/// Tries the 3-character prefix first (to catch `"meg"` before `"m"`), then the
/// 1-character prefix.  Returns `None` if the suffix is not a known SI suffix.
pub fn si_multiplier(suffix: &[u8]) -> Option<f64> {
    if suffix.len() >= 3 {
        if let Ok(s) = std::str::from_utf8(&suffix[..3]) {
            if let Some(&m) = SI_SUFFIX_MAP.get(s) {
                return Some(m);
            }
        }
    }
    if !suffix.is_empty() {
        if let Ok(s) = std::str::from_utf8(&suffix[..1]) {
            if let Some(&m) = SI_SUFFIX_MAP.get(s) {
                return Some(m);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn si_multiplier_single_char() {
        assert_eq!(si_multiplier(b"k"), Some(1e3));
        assert_eq!(si_multiplier(b"m"), Some(1e-3));
        assert_eq!(si_multiplier(b"n"), Some(1e-9));
        assert_eq!(si_multiplier(b"p"), Some(1e-12));
        assert_eq!(si_multiplier(b"f"), Some(1e-15));
        assert_eq!(si_multiplier(b"u"), Some(1e-6));
        assert_eq!(si_multiplier(b"g"), Some(1e9));
        assert_eq!(si_multiplier(b"t"), Some(1e12));
    }

    #[test]
    fn si_multiplier_meg() {
        // "meg" must match before "m".
        assert_eq!(si_multiplier(b"meg"), Some(1e6));
        assert_eq!(si_multiplier(b"megohm"), Some(1e6));
    }

    #[test]
    fn si_multiplier_unknown() {
        assert_eq!(si_multiplier(b"hz"), None);
        assert_eq!(si_multiplier(b"ohm"), None);
        assert_eq!(si_multiplier(b""), None);
    }
}
