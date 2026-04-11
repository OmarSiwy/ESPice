//! I/O round-trip tests: rawfile, CSV, Touchstone.
#[path = "../common/mod.rs"]
mod common;
use common::{RawFile, RawFlag, GoldenData};
use std::io::Write;

// ── Rawfile tests ─────────────────────────────────────────────────────────────

const DC_OP_RAW: &str = "\
Title: * voltage divider test
Date: Sun Apr  5 16:30:31  2026
Command: ngspice-44.2
Plotname: Operating Point
Flags: real
No. Variables: 3
No. Points: 1
Variables:
\t0\tv(1)\tvoltage
\t1\tv(2)\tvoltage
\t2\ti(v1)\tcurrent
Values:
 0\t5.000000000000000e+00
\t2.500000000000000e+00
\t-2.500000000000000e-03
";

const TRAN_RAW: &str = "\
Title: * rc transient
Date: Sun Apr  5 16:30:31  2026
Command: ngspice-44.2
Plotname: Transient Analysis
Flags: real
No. Variables: 3
No. Points: 3
Variables:
\t0\ttime\ttime
\t1\tv(1)\tvoltage
\t2\tv(2)\tvoltage
Values:
 0\t0.000000000000000e+00
\t5.000000000000000e+00
\t0.000000000000000e+00
 1\t5.000000000000000e-07
\t5.000000000000000e+00
\t3.934693402873666e+00
 2\t1.000000000000000e-06
\t5.000000000000000e+00
\t4.323323583816936e+00
";

#[test]
fn rawfile_parse_dc_op() {
    let raw = RawFile::parse(DC_OP_RAW).unwrap();
    assert_eq!(raw.title, "* voltage divider test");
    assert_eq!(raw.plotname, "Operating Point");
    assert!(matches!(raw.flags, RawFlag::Real));
    assert_eq!(raw.variables.len(), 3);
    assert_eq!(raw.variables[0].name, "v(1)");
    assert_eq!(raw.data.len(), 1);
    assert!((raw.data[0][0] - 5.0).abs() < 1e-12);
    assert!((raw.data[0][1] - 2.5).abs() < 1e-12);
    assert!((raw.data[0][2] + 0.0025).abs() < 1e-12);
}

#[test]
fn rawfile_parse_transient() {
    let raw = RawFile::parse(TRAN_RAW).unwrap();
    assert_eq!(raw.plotname, "Transient Analysis");
    assert_eq!(raw.variables.len(), 3);
    assert_eq!(raw.data.len(), 3);
    assert!((raw.data[1][0] - 5e-7).abs() < 1e-15);
    assert!((raw.data[2][2] - 4.323323583816936).abs() < 1e-12);
}

#[test]
fn rawfile_as_dc_pairs() {
    let raw = RawFile::parse(DC_OP_RAW).unwrap();
    let pairs = raw.as_dc_pairs();
    assert_eq!(pairs.len(), 3);
    assert_eq!(pairs[0].0, "v(1)");
    assert!((pairs[0].1 - 5.0).abs() < 1e-12);
}

#[test]
fn rawfile_as_waveform() {
    let raw = RawFile::parse(TRAN_RAW).unwrap();
    let (sweep, names, data) = raw.as_waveform();
    assert_eq!(sweep.len(), 3);
    assert_eq!(names, vec!["v(1)", "v(2)"]);
    assert_eq!(data.len(), 3);
    assert!((data[0][0] - 5.0).abs() < 1e-12);
}

#[test]
fn rawfile_variable_by_name() {
    let raw = RawFile::parse(TRAN_RAW).unwrap();
    let v2 = raw.variable_by_name("v(2)").unwrap();
    assert_eq!(v2.len(), 3);
    assert!((v2[0] - 0.0).abs() < 1e-12);
    assert!((v2[1] - 3.934693402873666).abs() < 1e-12);
}

#[test]
fn rawfile_parse_empty_input() {
    let result = RawFile::parse("");
    assert!(result.is_ok());
    assert!(result.unwrap().data.is_empty());
}

#[test]
fn rawfile_missing_values_section_error() {
    let input = "\
Title: test
Plotname: Operating Point
Flags: real
No. Variables: 1
No. Points: 1
Variables:
\t0\tv(1)\tvoltage
";
    let result = RawFile::parse(input);
    assert!(result.is_err());
}

// ── Golden CSV tests ──────────────────────────────────────────────────────────

#[test]
fn golden_csv_write_and_read_roundtrip() {
    let dir = std::env::temp_dir().join("bigospice_io_test_roundtrip");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("test.csv");

    let golden = GoldenData {
        headers: vec!["V(1)".into(), "V(2)".into(), "I(V1)".into()],
        rows: vec![vec![5.0, 2.5, -0.0025]],
    };
    golden.write_csv(&path).unwrap();

    let loaded = GoldenData::from_csv(&path).unwrap();
    assert_eq!(loaded.headers, golden.headers);
    assert_eq!(loaded.rows.len(), 1);
    assert!((loaded.rows[0][0] - 5.0).abs() < 1e-12);
    assert!((loaded.rows[0][2] + 0.0025).abs() < 1e-12);

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn golden_from_rawfile_conversion() {
    let raw = RawFile::parse(DC_OP_RAW).unwrap();
    let golden = GoldenData::from_rawfile(&raw);
    assert_eq!(golden.headers, vec!["v(1)", "v(2)", "i(v1)"]);
    assert_eq!(golden.rows.len(), 1);
    assert!((golden.rows[0][0] - 5.0).abs() < 1e-12);
}

#[test]
fn golden_as_dc_pairs() {
    let dir = std::env::temp_dir().join("bigospice_io_test_pairs");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("dc_test.csv");
    let mut f = std::fs::File::create(&path).unwrap();
    writeln!(f, "V(1),V(2),I(V1)").unwrap();
    writeln!(f, "5.0,2.5,-0.0025").unwrap();
    drop(f);

    let golden = GoldenData::from_csv(&path).unwrap();
    assert_eq!(golden.headers, vec!["V(1)", "V(2)", "I(V1)"]);
    let pairs = golden.as_dc_pairs();
    assert_eq!(pairs.len(), 3);
    assert!((pairs[0].1 - 5.0).abs() < 1e-12);

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
#[ignore = "requires bigospice-io Touchstone round-trip implementation"]
fn touchstone_s2p_roundtrip() {}
