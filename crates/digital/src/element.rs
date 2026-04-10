//! XSPICE-compatible `A` element parsing.
//!
//! Syntax:
//!
//! ```text
//!   A<name> [in1 in2 ...] [out1 out2 ...] model_name
//! ```
//!
//! The bracketed groups are space-separated lists of node names enclosed in
//! `[` and `]`.  The trailing token is the model identifier (e.g. `nand2`,
//! `dff_rising`, `adc_bridge`, `dac_bridge`).
//!
//! This module exposes a *pure* parser hook (`parse_a_element`) that takes a
//! `&str` and produces an `AElement` IR.  It does no I/O, no allocations into
//! the global parser state, and is therefore safe to call from
//! `crates/parser/src/spice.rs` without additional glue beyond the dispatch
//! branch.

use crate::primitives::PrimitiveKind;

/// Outcome of `parse_a_element` — a fully decoded `A` element header.
#[derive(Debug, Clone, PartialEq)]
pub struct AElement<'a> {
    pub name: &'a str,
    pub inputs: Vec<&'a str>,
    pub outputs: Vec<&'a str>,
    pub model_name: &'a str,
}

/// Coarse classification of an `A` element model name.
///
/// The actual primitive parameters (delays, thresholds, etc.) are looked up
/// from `.MODEL` cards by the parser; this enum just tells the parser which
/// runtime construct to instantiate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AModelKind {
    Primitive(PrimitiveKind),
    AdcBridge,
    DacBridge,
    DSource,
    DPulse,
    DState,
    /// Unknown — caller should fall back to ignoring or erroring.
    Unknown,
}

impl AModelKind {
    /// Map a model name (case-insensitive) to a kind.
    pub fn from_model_name(name: &str) -> AModelKind {
        let lower = name.to_ascii_lowercase();
        match lower.as_str() {
            "buf" | "d_buffer" => AModelKind::Primitive(PrimitiveKind::Buf),
            "not" | "inv" | "d_inverter" => AModelKind::Primitive(PrimitiveKind::Not),
            "and" | "and2" | "d_and" => AModelKind::Primitive(PrimitiveKind::And),
            "nand" | "nand2" | "d_nand" => AModelKind::Primitive(PrimitiveKind::Nand),
            "or" | "or2" | "d_or" => AModelKind::Primitive(PrimitiveKind::Or),
            "nor" | "nor2" | "d_nor" => AModelKind::Primitive(PrimitiveKind::Nor),
            "xor" | "xor2" | "d_xor" => AModelKind::Primitive(PrimitiveKind::Xor),
            "xnor" | "xnor2" | "d_xnor" => AModelKind::Primitive(PrimitiveKind::Xnor),
            "mux2" | "d_mux2" => AModelKind::Primitive(PrimitiveKind::Mux2),
            "mux4" | "d_mux4" => AModelKind::Primitive(PrimitiveKind::Mux4),
            "demux2" | "d_demux2" => AModelKind::Primitive(PrimitiveKind::Demux2),
            "demux4" | "d_demux4" => AModelKind::Primitive(PrimitiveKind::Demux4),
            "dff" | "d_dff" | "d_ff" => AModelKind::Primitive(PrimitiveKind::DFlipFlop),
            "dlatch" | "d_dlatch" | "d_latch" => AModelKind::Primitive(PrimitiveKind::DLatch),
            "adc_bridge" => AModelKind::AdcBridge,
            "dac_bridge" => AModelKind::DacBridge,
            "d_source" => AModelKind::DSource,
            "d_pulse" => AModelKind::DPulse,
            "d_state" => AModelKind::DState,
            _ => AModelKind::Unknown,
        }
    }
}

/// Parse an `A` element line into an [`AElement`].
///
/// Accepted forms:
///
/// ```text
///   A1 [in1 in2] [out1] nand2
///   a_dff [d clk] [q] dff_rising
///   A2 [vin] [dout] adc_bridge
/// ```
///
/// Returns `None` for syntactically invalid input (no brackets, missing model
/// name, mismatched brackets, etc.).
pub fn parse_a_element(line: &str) -> Option<AElement<'_>> {
    let line = line.trim();
    let mut chars = line.char_indices();
    let _ = chars.next(); // skip leading 'A' / 'a'

    // Find the instance name (up to the first whitespace).
    let rest_start = match line.char_indices().find(|&(_, c)| c.is_whitespace()) {
        Some((i, _)) => i,
        None => return None,
    };
    let name = &line[..rest_start];
    let rest = line[rest_start..].trim_start();

    // Parse two bracketed groups followed by a bare model name.
    let (inputs, after_in) = parse_bracketed(rest)?;
    let after_in = after_in.trim_start();
    let (outputs, after_out) = parse_bracketed(after_in)?;
    let model_name = after_out.trim();
    if model_name.is_empty() || model_name.contains('[') || model_name.contains(']') {
        return None;
    }
    Some(AElement {
        name,
        inputs,
        outputs,
        model_name,
    })
}

/// Parse a `[a b c]` group from the start of `s`.  Returns the contents and
/// the remainder after the closing bracket.
fn parse_bracketed(s: &str) -> Option<(Vec<&str>, &str)> {
    let s = s.trim_start();
    if !s.starts_with('[') {
        return None;
    }
    let after_open = &s[1..];
    let close = after_open.find(']')?;
    let inner = &after_open[..close];
    let after = &after_open[close + 1..];
    let items: Vec<&str> = inner.split_ascii_whitespace().collect();
    Some((items, after))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_two_input_nand() {
        let e = parse_a_element("a1 [in1 in2] [out] nand2").unwrap();
        assert_eq!(e.name, "a1");
        assert_eq!(e.inputs, vec!["in1", "in2"]);
        assert_eq!(e.outputs, vec!["out"]);
        assert_eq!(e.model_name, "nand2");
        assert_eq!(
            AModelKind::from_model_name(e.model_name),
            AModelKind::Primitive(PrimitiveKind::Nand)
        );
    }

    #[test]
    fn parses_dff() {
        let e = parse_a_element("A_DFF [d clk] [q] dff").unwrap();
        assert_eq!(e.inputs.len(), 2);
        assert_eq!(e.outputs.len(), 1);
        assert_eq!(
            AModelKind::from_model_name(e.model_name),
            AModelKind::Primitive(PrimitiveKind::DFlipFlop)
        );
    }

    #[test]
    fn parses_adc_bridge() {
        let e = parse_a_element("A2 [vin] [dout] adc_bridge").unwrap();
        assert_eq!(AModelKind::from_model_name(e.model_name), AModelKind::AdcBridge);
    }

    #[test]
    fn rejects_missing_brackets() {
        assert!(parse_a_element("a1 in1 in2 out nand2").is_none());
    }

    #[test]
    fn unknown_model_returns_unknown() {
        assert_eq!(AModelKind::from_model_name("nope"), AModelKind::Unknown);
    }
}
