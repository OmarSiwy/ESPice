//! Output format kind enum and selection helpers.

use thiserror::Error;

/// Top-level output format selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OutputFormat {
    /// Berkeley rawfile binary (the default ngspice format, native-endian f64).
    RawfileBinary,
    /// Berkeley rawfile ASCII (`Title:` header + `Values:` block).
    RawfileAscii,
    /// HSPICE POST=2 little-endian binary (`.tr0` / `.ac0` / `.sw0` / `.mt0`).
    HspicePost,
    /// Touchstone `.sNp` RF parameter format.
    Touchstone,
    /// Generic CSV — header row + numeric rows.
    Csv,
}

/// Errors when parsing an `OutputFormat` from a string or extension.
#[derive(Debug, Error)]
pub enum FormatKindError {
    #[error("unknown output format: {0}")]
    Unknown(String),
}

impl OutputFormat {
    /// Lowercase canonical name.
    pub fn as_str(&self) -> &'static str {
        match self {
            OutputFormat::RawfileBinary => "rawbin",
            OutputFormat::RawfileAscii => "rawascii",
            OutputFormat::HspicePost => "hspice",
            OutputFormat::Touchstone => "touchstone",
            OutputFormat::Csv => "csv",
        }
    }

    /// Default file extension WITHOUT a leading dot.
    pub fn default_extension(&self) -> &'static str {
        match self {
            OutputFormat::RawfileBinary => "raw",
            OutputFormat::RawfileAscii => "raw",
            OutputFormat::HspicePost => "tr0",
            OutputFormat::Touchstone => "s2p",
            OutputFormat::Csv => "csv",
        }
    }

    /// Parse a canonical format name (case-insensitive).
    pub fn from_name(name: &str) -> Result<Self, FormatKindError> {
        match name.to_ascii_lowercase().as_str() {
            "rawbin" | "raw_binary" | "raw-binary" | "binary" | "ngspice" => {
                Ok(OutputFormat::RawfileBinary)
            }
            "rawascii" | "raw_ascii" | "raw-ascii" | "ascii" => Ok(OutputFormat::RawfileAscii),
            "raw" => Ok(OutputFormat::RawfileBinary),
            "hspice" | "hspice_post" | "post" | "tr0" | "ac0" | "sw0" | "mt0" => {
                Ok(OutputFormat::HspicePost)
            }
            "touchstone" | "snp" | "s1p" | "s2p" | "s3p" | "s4p" => Ok(OutputFormat::Touchstone),
            "csv" => Ok(OutputFormat::Csv),
            other => Err(FormatKindError::Unknown(other.to_string())),
        }
    }

    /// Guess the format from a path's file extension.
    pub fn from_extension(ext: &str) -> Result<Self, FormatKindError> {
        let lower = ext.to_ascii_lowercase();
        let stripped = lower.strip_prefix('.').unwrap_or(lower.as_str());
        match stripped {
            "raw" => Ok(OutputFormat::RawfileBinary),
            "rawascii" | "rawa" => Ok(OutputFormat::RawfileAscii),
            "tr0" | "ac0" | "sw0" | "mt0" => Ok(OutputFormat::HspicePost),
            "s1p" | "s2p" | "s3p" | "s4p" | "snp" => Ok(OutputFormat::Touchstone),
            "csv" | "tsv" | "txt" => Ok(OutputFormat::Csv),
            other => Err(FormatKindError::Unknown(other.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_from_name_csv() {
        assert_eq!(OutputFormat::from_name("csv").unwrap(), OutputFormat::Csv);
    }

    #[test]
    fn test_from_name_raw_aliases() {
        assert_eq!(OutputFormat::from_name("raw").unwrap(), OutputFormat::RawfileBinary);
        assert_eq!(OutputFormat::from_name("rawbin").unwrap(), OutputFormat::RawfileBinary);
        assert_eq!(OutputFormat::from_name("rawascii").unwrap(), OutputFormat::RawfileAscii);
        assert_eq!(OutputFormat::from_name("binary").unwrap(), OutputFormat::RawfileBinary);
    }

    #[test]
    fn test_from_name_hspice() {
        assert_eq!(OutputFormat::from_name("hspice").unwrap(), OutputFormat::HspicePost);
        assert_eq!(OutputFormat::from_name("tr0").unwrap(), OutputFormat::HspicePost);
    }

    #[test]
    fn test_from_name_touchstone() {
        assert_eq!(OutputFormat::from_name("touchstone").unwrap(), OutputFormat::Touchstone);
        assert_eq!(OutputFormat::from_name("s2p").unwrap(), OutputFormat::Touchstone);
    }

    #[test]
    fn test_from_name_unknown_errors() {
        assert!(OutputFormat::from_name("bogus").is_err());
        assert!(OutputFormat::from_name("").is_err());
    }

    #[test]
    fn test_from_extension() {
        assert_eq!(OutputFormat::from_extension("csv").unwrap(), OutputFormat::Csv);
        assert_eq!(OutputFormat::from_extension(".csv").unwrap(), OutputFormat::Csv);
        assert_eq!(OutputFormat::from_extension("raw").unwrap(), OutputFormat::RawfileBinary);
        assert_eq!(OutputFormat::from_extension("s2p").unwrap(), OutputFormat::Touchstone);
        assert_eq!(OutputFormat::from_extension("tr0").unwrap(), OutputFormat::HspicePost);
    }

    #[test]
    fn test_as_str_is_nonempty() {
        for fmt in [
            OutputFormat::Csv,
            OutputFormat::RawfileBinary,
            OutputFormat::RawfileAscii,
            OutputFormat::HspicePost,
            OutputFormat::Touchstone,
        ] {
            assert!(!fmt.as_str().is_empty());
        }
    }

    #[test]
    fn test_default_extension() {
        assert_eq!(OutputFormat::Csv.default_extension(), "csv");
        assert_eq!(OutputFormat::RawfileBinary.default_extension(), "raw");
        assert_eq!(OutputFormat::HspicePost.default_extension(), "tr0");
        assert_eq!(OutputFormat::Touchstone.default_extension(), "s2p");
    }

    #[test]
    fn test_case_insensitive_from_name() {
        assert_eq!(OutputFormat::from_name("CSV").unwrap(), OutputFormat::Csv);
        assert_eq!(OutputFormat::from_name("RAW").unwrap(), OutputFormat::RawfileBinary);
        assert_eq!(OutputFormat::from_name("HSPICE").unwrap(), OutputFormat::HspicePost);
    }
}
