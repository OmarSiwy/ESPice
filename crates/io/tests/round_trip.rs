//! Round-trip integration tests for the writers in `bigospice_io`.
//!
//! Each test creates a synthetic result, runs it through one of the writers,
//! parses the bytes back via the public reader (or a small ad-hoc parser when
//! no reader exists, e.g. HSPICE binary / Touchstone) and asserts equality
//! column-by-column.

use bigospice_io::{
    CsvWriter,
    HspiceMt0Writer, HspicePostKind, HspicePostWriter, HspiceVarType,
    RawFile, RawFlag, RawfileWriter,
    ComplexFormat, FreqUnit, ParamType, TouchstoneWriter,
};

// ─── rawfile (ASCII + binary) ────────────────────────────────────────────────

fn synthetic_transient() -> (Vec<f64>, Vec<f64>, Vec<f64>) {
    // 17-point synthetic transient: time, v(out) = (1 - exp(-t/tau)), v(in) = 5.
    let n = 17;
    let dt = 1e-7_f64;
    let tau = 1e-6_f64;
    let times: Vec<f64> = (0..n).map(|i| i as f64 * dt).collect();
    let v_out: Vec<f64> = times.iter().map(|t| 5.0 * (1.0 - (-t / tau).exp())).collect();
    let v_in: Vec<f64> = vec![5.0; n];
    (times, v_out, v_in)
}

#[test]
fn rawfile_ascii_round_trip_transient() {
    let (times, v_out, v_in) = synthetic_transient();
    let mut w = RawfileWriter::new("rc round-trip", "Transient Analysis", RawFlag::Real);
    w.add_variable("time", "time");
    w.add_variable("v(out)", "voltage");
    w.add_variable("v(in)", "voltage");
    w.set_real_columns(&[times.clone(), v_out.clone(), v_in.clone()])
        .unwrap();

    let mut buf = Vec::new();
    w.write_ascii(&mut buf).unwrap();

    let parsed = RawFile::read(&buf[..]).unwrap();
    assert_eq!(parsed.title, "rc round-trip");
    assert_eq!(parsed.plotname, "Transient Analysis");
    assert_eq!(parsed.flags, RawFlag::Real);
    assert_eq!(parsed.num_points(), times.len());
    assert_eq!(parsed.num_variables(), 3);

    for (i, t) in times.iter().enumerate() {
        assert!((parsed.real(i, 0) - *t).abs() < 1e-15);
        assert!((parsed.real(i, 1) - v_out[i]).abs() < 1e-12);
        assert!((parsed.real(i, 2) - v_in[i]).abs() < 1e-15);
    }
}

#[test]
fn rawfile_binary_round_trip_transient() {
    let (times, v_out, v_in) = synthetic_transient();
    let mut w = RawfileWriter::new("rc binary", "Transient Analysis", RawFlag::Real);
    w.add_variable("time", "time");
    w.add_variable("v(out)", "voltage");
    w.add_variable("v(in)", "voltage");
    w.set_real_columns(&[times.clone(), v_out.clone(), v_in.clone()])
        .unwrap();

    let mut buf = Vec::new();
    w.write_binary(&mut buf).unwrap();

    let parsed = RawFile::read(&buf[..]).unwrap();
    assert_eq!(parsed.flags, RawFlag::Real);
    assert_eq!(parsed.num_points(), times.len());

    // Binary uses bit-exact f64 — we should round-trip with zero loss.
    for (i, t) in times.iter().enumerate() {
        assert_eq!(parsed.real(i, 0), *t);
        assert_eq!(parsed.real(i, 1), v_out[i]);
        assert_eq!(parsed.real(i, 2), v_in[i]);
    }
}

#[test]
fn rawfile_ascii_round_trip_ac() {
    // 4-point synthetic AC sweep, complex.
    let freqs = [1.0, 10.0, 100.0, 1000.0];
    let re = vec![1.0, 0.95, 0.7, 0.1];
    let im = vec![0.0, -0.1, -0.4, -0.9];

    let mut w = RawfileWriter::new("ac demo", "AC Analysis", RawFlag::Complex);
    w.add_variable("frequency", "frequency");
    w.add_variable("v(out)", "voltage");
    w.set_complex_columns(
        &[freqs.to_vec(), re.clone()],
        &[vec![0.0; 4], im.clone()],
    )
    .unwrap();

    let mut buf = Vec::new();
    w.write_ascii(&mut buf).unwrap();

    let parsed = RawFile::read(&buf[..]).unwrap();
    assert_eq!(parsed.flags, RawFlag::Complex);
    assert_eq!(parsed.num_points(), 4);
    for i in 0..4 {
        assert!((parsed.real(i, 0) - freqs[i]).abs() < 1e-12);
        assert!((parsed.real(i, 1) - re[i]).abs() < 1e-12);
        assert!((parsed.imag(i, 1) - im[i]).abs() < 1e-12);
    }
}

#[test]
fn rawfile_binary_round_trip_ac() {
    let freqs = [1.0, 10.0, 100.0, 1000.0];
    let re = vec![1.0, 0.95, 0.7, 0.1];
    let im = vec![0.0, -0.1, -0.4, -0.9];

    let mut w = RawfileWriter::new("ac demo bin", "AC Analysis", RawFlag::Complex);
    w.add_variable("frequency", "frequency");
    w.add_variable("v(out)", "voltage");
    w.set_complex_columns(
        &[freqs.to_vec(), re.clone()],
        &[vec![0.0; 4], im.clone()],
    )
    .unwrap();

    let mut buf = Vec::new();
    w.write_binary(&mut buf).unwrap();

    let parsed = RawFile::read(&buf[..]).unwrap();
    assert_eq!(parsed.flags, RawFlag::Complex);
    for i in 0..4 {
        assert_eq!(parsed.real(i, 0), freqs[i]);
        assert_eq!(parsed.real(i, 1), re[i]);
        assert_eq!(parsed.imag(i, 1), im[i]);
    }
}

#[test]
fn rawfile_dc_op_single_point() {
    let mut w = RawfileWriter::new("dc op", "Operating Point", RawFlag::Real);
    w.add_variable("v(1)", "voltage");
    w.add_variable("v(2)", "voltage");
    w.add_variable("i(v1)", "current");
    w.set_real_columns(&[vec![5.0], vec![2.5], vec![-2.5e-3]]).unwrap();
    let mut buf = Vec::new();
    w.write_binary(&mut buf).unwrap();
    let parsed = RawFile::read(&buf[..]).unwrap();
    assert_eq!(parsed.num_points(), 1);
    assert_eq!(parsed.real(0, 0), 5.0);
    assert_eq!(parsed.real(0, 1), 2.5);
    assert_eq!(parsed.real(0, 2), -2.5e-3);
}

// ─── HSPICE .mt0 (ASCII) ─────────────────────────────────────────────────────

#[test]
fn hspice_mt0_round_trip_ascii() {
    let mut w = HspiceMt0Writer::new("rc tran");
    w.add_measurement("trise", 1.123e-6);
    w.add_measurement("vmax", 4.95);
    w.add_measurement("ipeak", -2.5e-3);

    let mut buf = Vec::new();
    w.write(&mut buf).unwrap();
    let s = std::str::from_utf8(&buf).unwrap();

    // Structural assertions: marker, title, names, numbers.
    assert!(s.starts_with("$DATA1"));
    assert!(s.contains(".TITLE 'rc tran'"));
    let lines: Vec<&str> = s.lines().collect();
    // 4 lines: data marker, title, header, data.
    assert_eq!(lines.len(), 4, "expected 4 lines, got {}: {s}", lines.len());

    // Header row contains all three names.
    let header_tokens: Vec<&str> = lines[2].split_whitespace().collect();
    assert_eq!(header_tokens, vec!["trise", "vmax", "ipeak"]);

    // Data row parses back to the same numeric values.
    let value_tokens: Vec<&str> = lines[3].split_whitespace().collect();
    assert_eq!(value_tokens.len(), 3);
    let parsed_trise: f64 = value_tokens[0].parse().unwrap();
    let parsed_vmax: f64 = value_tokens[1].parse().unwrap();
    let parsed_ipeak: f64 = value_tokens[2].parse().unwrap();
    assert!((parsed_trise - 1.123e-6).abs() < 1e-12);
    assert!((parsed_vmax - 4.95).abs() < 1e-6);
    assert!((parsed_ipeak - -2.5e-3).abs() < 1e-9);
}

// ─── HSPICE POST=2 binary structural test ────────────────────────────────────

#[test]
fn hspice_post_tr0_block_layout() {
    let mut w = HspicePostWriter::new(HspicePostKind::Transient, "rc test");
    w.set_independent("time", &[0.0, 1e-6, 2e-6, 3e-6]);
    w.add_column("v(out)", HspiceVarType::Voltage, &[0.0, 0.63, 0.86, 0.95]);

    let mut buf = Vec::new();
    w.write(&mut buf).unwrap();

    // Walk Fortran-style records and decode each block.
    let mut records: Vec<Vec<u8>> = Vec::new();
    let mut i = 0usize;
    while i + 4 <= buf.len() {
        let len = u32::from_le_bytes([buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]) as usize;
        i += 4;
        let payload = buf[i..i + len].to_vec();
        i += len;
        let trailer = u32::from_le_bytes([buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]) as usize;
        assert_eq!(trailer, len, "record trailer mismatch");
        i += 4;
        records.push(payload);
    }
    assert_eq!(records.len(), 4, "expected 4 blocks (header, types, names, data)");

    // Block 1: header.  First field is `nauto` = 2 (independent + 1 column),
    // padded to 9 ASCII characters.
    let header = std::str::from_utf8(&records[0]).unwrap();
    let nauto: usize = header[..9].trim().parse().unwrap();
    assert_eq!(nauto, 2);

    // Block 2: variable types.  2 columns of 9 chars each.
    let types_block = std::str::from_utf8(&records[1]).unwrap();
    assert_eq!(types_block.len(), 18);
    let indep_type: i32 = types_block[..9].trim().parse().unwrap();
    let v_out_type: i32 = types_block[9..18].trim().parse().unwrap();
    assert_eq!(indep_type, HspiceVarType::Independent.code());
    assert_eq!(v_out_type, HspiceVarType::Voltage.code());

    // Block 3: variable names.  2 columns of 16 chars each.
    let names_block = std::str::from_utf8(&records[2]).unwrap();
    assert_eq!(names_block.len(), 32);
    assert!(names_block[..16].trim().eq("time"));
    assert!(names_block[16..32].trim().eq("v(out)"));

    // Block 4: data.  4 points * 2 cols * 4 bytes + 4 byte sentinel = 36 bytes.
    let data = &records[3];
    assert_eq!(data.len(), 4 * 2 * 4 + 4);

    // Decode the first time/voltage pair.
    let t0 = f32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    let v0 = f32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    assert!(t0.abs() < 1e-12);
    assert!(v0.abs() < 1e-12);

    // Decode the third point's voltage = 0.86.
    let v2 = f32::from_le_bytes([data[20], data[21], data[22], data[23]]);
    assert!((v2 - 0.86).abs() < 1e-5);

    // Sentinel = 1e30.
    let sentinel = f32::from_le_bytes([data[32], data[33], data[34], data[35]]);
    assert!(sentinel > 1e29);
}

// ─── Touchstone .s2p ─────────────────────────────────────────────────────────

#[test]
fn touchstone_s2p_five_freqs_field_check() {
    let mut w =
        TouchstoneWriter::new(2, FreqUnit::GHz, ParamType::S, ComplexFormat::RI, 50.0);
    let freqs: Vec<f64> = (1..=5).map(|i| i as f64 * 1e9).collect();
    w.set_frequencies(&freqs);
    // Distinguishable S-params per frequency: S11=f, S12=f+0.1, S21=f+0.2, S22=f+0.3.
    let mut data = Vec::new();
    for (i, _) in freqs.iter().enumerate() {
        let f = (i + 1) as f64;
        data.push((f, 0.0));        // S11 row-major
        data.push((f + 0.1, 0.0));  // S12
        data.push((f + 0.2, 0.0));  // S21
        data.push((f + 0.3, 0.0));  // S22
    }
    w.set_data(&data).unwrap();

    let mut buf = Vec::new();
    w.write(&mut buf).unwrap();
    let s = String::from_utf8(buf).unwrap();

    // Structural: option line present.
    assert!(s.contains("# GHz S RI R 50"));

    // Parse data lines and assert order S11, S21, S12, S22.
    let freq_lines: Vec<&str> = s
        .lines()
        .filter(|l| l.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false))
        .collect();
    assert_eq!(freq_lines.len(), 5);

    for (idx, line) in freq_lines.iter().enumerate() {
        let nums: Vec<f64> = line
            .split_whitespace()
            .map(|t| t.parse().unwrap())
            .collect();
        assert_eq!(nums.len(), 9, "row {idx}: expected freq + 4 (re,im) pairs");

        let f = (idx + 1) as f64;
        assert!((nums[0] - f).abs() < 1e-9, "freq mismatch on row {idx}");
        // S11 = f
        assert!((nums[1] - f).abs() < 1e-9);
        assert!(nums[2].abs() < 1e-12);
        // S21 = f + 0.2  (the 2-port transposition rule)
        assert!((nums[3] - (f + 0.2)).abs() < 1e-9);
        assert!(nums[4].abs() < 1e-12);
        // S12 = f + 0.1
        assert!((nums[5] - (f + 0.1)).abs() < 1e-9);
        assert!(nums[6].abs() < 1e-12);
        // S22 = f + 0.3
        assert!((nums[7] - (f + 0.3)).abs() < 1e-9);
        assert!(nums[8].abs() < 1e-12);
    }
}

// ─── CSV ─────────────────────────────────────────────────────────────────────

#[test]
fn csv_round_trip_transient() {
    let (times, v_out, v_in) = synthetic_transient();
    let mut w = CsvWriter::new();
    w.set_headers(&["time", "v(out)", "v(in)"]);
    w.set_columns(&[times.clone(), v_out.clone(), v_in.clone()])
        .unwrap();

    let mut buf = Vec::new();
    w.write(&mut buf).unwrap();
    let s = String::from_utf8(buf).unwrap();

    let lines: Vec<&str> = s.lines().collect();
    assert_eq!(lines[0], "time,v(out),v(in)");
    assert_eq!(lines.len(), 1 + times.len());

    // Parse data rows back.
    for (i, line) in lines[1..].iter().enumerate() {
        let nums: Vec<f64> = line.split(',').map(|t| t.parse().unwrap()).collect();
        assert_eq!(nums.len(), 3);
        assert!((nums[0] - times[i]).abs() < 1e-15);
        assert!((nums[1] - v_out[i]).abs() < 1e-9);
        assert!((nums[2] - v_in[i]).abs() < 1e-15);
    }
}
