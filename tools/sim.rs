//! Simulator runners: NgspiceRunner, XyceRunner, VacaskRunner.
//!
//! Includes a full Berkeley SPICE raw-file parser (ASCII + binary, real + complex)
//! and a full Xyce .prn parser.  Ported from crates/cli/src/io/rawfile.rs and
//! augmented with Xyce/VACASK specifics.

use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

// ── Variable type ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum VarKind {
    Time,
    Frequency,
    Voltage,
    Current,
    Other,
}

impl VarKind {
    fn from_str(s: &str) -> Self {
        // ngspice type names from typesdef.c
        match s.trim().to_lowercase().as_str() {
            "time" => Self::Time,
            "frequency" => Self::Frequency,
            "voltage" => Self::Voltage,
            "current" => Self::Current,
            _ => Self::Other,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Variable {
    pub name: String,
    pub kind: VarKind,
}

// ── Raw-file flags ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawFlag {
    Real,
    Complex,
}

// ── RawFile ───────────────────────────────────────────────────────────────────

/// Parsed Berkeley SPICE raw file (ngspice / Xyce -r / VACASK).
///
/// Layout of `data[point][slot]`:
/// - Real:    `slot == var_idx`
/// - Complex: `slot == 2*var_idx` (real part), `2*var_idx+1` (imaginary part)
#[derive(Debug, Clone)]
pub struct RawFile {
    pub plotname: String,
    pub flags: RawFlag,
    pub variables: Vec<Variable>,
    pub data: Vec<Vec<f64>>,
}

impl RawFile {
    /// Real part of variable `var` at data point `point`.
    pub fn real(&self, point: usize, var: usize) -> f64 {
        let slot = match self.flags {
            RawFlag::Real => var,
            RawFlag::Complex => 2 * var,
        };
        self.data
            .get(point)
            .and_then(|p| p.get(slot))
            .copied()
            .unwrap_or(0.0)
    }

    /// Imaginary part of variable `var` at data point `point`. 0.0 for real data.
    pub fn imag(&self, point: usize, var: usize) -> f64 {
        if self.flags == RawFlag::Real {
            return 0.0;
        }
        self.data
            .get(point)
            .and_then(|p| p.get(2 * var + 1))
            .copied()
            .unwrap_or(0.0)
    }

    /// Parse a single plot from a Berkeley raw file. For multi-plot files, use `read_all`.
    pub fn read<R: Read>(reader: R) -> Result<Self, String> {
        let plots = Self::read_all(reader)?;
        plots.into_iter().next().ok_or_else(|| "empty raw file".into())
    }

    /// Parse ALL plots from a Berkeley raw file (handles multi-plot rawfiles).
    pub fn read_all<R: Read>(reader: R) -> Result<Vec<Self>, String> {
        let mut buf = BufReader::new(reader);
        let mut plots = Vec::new();

        loop {
            match Self::read_one_plot(&mut buf) {
                Ok(plot) => plots.push(plot),
                Err(_) if !plots.is_empty() => break, // EOF after at least one plot
                Err(e) if plots.is_empty() => return Err(e),
                Err(_) => break,
            }
        }

        if plots.is_empty() {
            Err("empty raw file".into())
        } else {
            Ok(plots)
        }
    }

    /// Read a single plot from the current position in the buffered reader.
    fn read_one_plot<R: Read>(buf: &mut BufReader<R>) -> Result<Self, String> {
        let mut header_bytes = Vec::<u8>::new();
        let mut is_binary = false;
        let mut got_header = false;

        // Read header line-by-line until `Binary:` or `Values:`.
        loop {
            let mut line = Vec::<u8>::new();
            let n = buf
                .read_until(b'\n', &mut line)
                .map_err(|e| format!("io: {e}"))?;
            if n == 0 {
                if header_bytes.is_empty() {
                    return Err("eof".into());
                }
                break;
            }
            let trimmed = line
                .strip_suffix(b"\n")
                .map(|s| s.strip_suffix(b"\r").unwrap_or(s))
                .unwrap_or(&line);

            header_bytes.extend_from_slice(&line);

            if trimmed.eq_ignore_ascii_case(b"Binary:") {
                is_binary = true;
                got_header = true;
                break;
            }
            if trimmed.eq_ignore_ascii_case(b"Values:") {
                got_header = true;
                break;
            }
        }

        if !got_header && header_bytes.is_empty() {
            return Err("eof".into());
        }

        let header = String::from_utf8_lossy(&header_bytes);
        let (plotname, flags, variables, num_points) = parse_raw_header(&header)?;

        let data = if is_binary {
            parse_binary_body(buf, &flags, variables.len(), num_points)?
        } else {
            // For ASCII multi-plot, read lines until we hit a new "Title:" header or EOF.
            let mut body = String::new();
            loop {
                let mut line = String::new();
                let n = buf.read_line(&mut line).map_err(|e| format!("io: {e}"))?;
                if n == 0 {
                    break;
                }
                // A new plot starts with "Title:" at the beginning of a line
                if line.trim_start().to_lowercase().starts_with("title:") {
                    // Push it back conceptually — we can't un-read, so we'll lose it.
                    // For ASCII multi-plot this is a known limitation; binary is the common case.
                    break;
                }
                body.push_str(&line);
            }
            parse_ascii_body(&body, &flags, variables.len(), num_points)?
        };

        Ok(RawFile {
            plotname,
            flags,
            variables,
            data,
        })
    }

    /// Classify this plot's analysis type from its plotname.
    pub fn analysis_type(&self) -> RawPlotType {
        let pl = self.plotname.to_lowercase();
        if pl.contains("operating point") {
            RawPlotType::DcOp
        } else if pl.contains("dc transfer") || pl.contains("sweep") {
            RawPlotType::DcSweep
        } else if pl.contains("transient") {
            RawPlotType::Transient
        } else if pl.contains("ac") {
            RawPlotType::Ac
        } else if pl.contains("noise") {
            RawPlotType::Noise
        } else {
            RawPlotType::Other
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawPlotType {
    DcOp,
    DcSweep,
    Transient,
    Ac,
    Noise,
    Other,
}

// ── Raw-file header parser ────────────────────────────────────────────────────

fn parse_raw_header(header: &str) -> Result<(String, RawFlag, Vec<Variable>, usize), String> {
    let mut plotname: Option<String> = None;
    let mut flags: Option<RawFlag> = None;
    let mut num_variables: Option<usize> = None;
    let mut num_points: Option<usize> = None;
    let mut variables: Vec<Variable> = Vec::new();

    let mut in_variables = false;

    for line in header.lines() {
        // Strip trailing whitespace and CRLF.
        let line = line.trim_end_matches(|c| c == '\r' || c == ' ');

        if line.eq_ignore_ascii_case("Variables:") {
            in_variables = true;
            continue;
        }
        // Stop variable section when we see Binary: or Values:
        if line.eq_ignore_ascii_case("Binary:") || line.eq_ignore_ascii_case("Values:") {
            break;
        }

        if in_variables {
            // Variable line: `\t<idx>\t<name>\t<type>[optional fields]`
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 4 {
                let name = parts[2].to_string();
                // type field may have trailing grid/color hints — take first word.
                let type_str = parts[3].split_whitespace().next().unwrap_or("");
                variables.push(Variable {
                    name,
                    kind: VarKind::from_str(type_str),
                });
            }
            continue;
        }

        // Case-insensitive prefix matching for header fields.
        if let Some(val) = strip_prefix_ci(line, "Plotname: ") {
            plotname = Some(val.to_string());
        } else if let Some(val) = strip_prefix_ci(line, "Flags: ") {
            let first_word = val.split_whitespace().next().unwrap_or("").to_lowercase();
            flags = Some(match first_word.as_str() {
                "real" => RawFlag::Real,
                "complex" => RawFlag::Complex,
                other => return Err(format!("unknown raw flag: {other}")),
            });
        } else if let Some(val) = strip_prefix_ci(line, "No. Variables: ") {
            num_variables = Some(
                val.trim()
                    .parse::<usize>()
                    .map_err(|e| format!("bad variable count: {e}"))?,
            );
        } else if let Some(val) = strip_prefix_ci(line, "No. Points: ") {
            num_points = Some(
                val.trim()
                    .parse::<usize>()
                    .map_err(|e| format!("bad point count: {e}"))?,
            );
        }
    }

    let plotname = plotname.unwrap_or_default();
    let flags = flags.ok_or("raw file missing Flags: header")?;
    let num_points = num_points.ok_or("raw file missing No. Points: header")?;
    let num_variables = num_variables.unwrap_or(variables.len());

    // If variable lines were not parsed (e.g., 0 variables edge case), pad.
    while variables.len() < num_variables {
        variables.push(Variable {
            name: format!("v{}", variables.len()),
            kind: VarKind::Other,
        });
    }

    Ok((plotname, flags, variables, num_points))
}

fn strip_prefix_ci<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    if s.len() < prefix.len() {
        return None;
    }
    if s[..prefix.len()].eq_ignore_ascii_case(prefix) {
        Some(&s[prefix.len()..])
    } else {
        None
    }
}

// ── Raw-file data parsers ─────────────────────────────────────────────────────

fn parse_binary_body<R: Read>(
    buf: &mut BufReader<R>,
    flags: &RawFlag,
    nvars: usize,
    num_points: usize,
) -> Result<Vec<Vec<f64>>, String> {
    let slots = match flags {
        RawFlag::Real => nvars,
        RawFlag::Complex => 2 * nvars,
    };
    let total_bytes = num_points * slots * 8;
    let mut bytes = vec![0u8; total_bytes];

    // Read all binary data, tolerating a short read at EOF for the last plot.
    let mut read = 0;
    while read < total_bytes {
        match buf.read(&mut bytes[read..]) {
            Ok(0) => break,
            Ok(n) => read += n,
            Err(e) => return Err(format!("binary read error: {e}")),
        }
    }
    let actual_points = read / (slots * 8);

    let mut data = Vec::with_capacity(actual_points);
    for p in 0..actual_points {
        let mut row = Vec::with_capacity(slots);
        for s in 0..slots {
            let offset = (p * slots + s) * 8;
            let val = f64::from_ne_bytes(bytes[offset..offset + 8].try_into().unwrap());
            row.push(val);
        }
        data.push(row);
    }
    Ok(data)
}

fn parse_ascii_body(
    body: &str,
    flags: &RawFlag,
    nvars: usize,
    _num_points: usize,
) -> Result<Vec<Vec<f64>>, String> {
    let slots = match flags {
        RawFlag::Real => nvars,
        RawFlag::Complex => 2 * nvars,
    };

    let parse_slot = |s: &str| -> Result<Vec<f64>, String> {
        let s = s.trim();
        match flags {
            RawFlag::Real => {
                let v = s
                    .parse::<f64>()
                    .map_err(|e| format!("bad real value {s:?}: {e}"))?;
                Ok(vec![v])
            }
            RawFlag::Complex => {
                let (re_s, im_s) = s
                    .split_once(',')
                    .ok_or_else(|| format!("expected re,im pair, got: {s:?}"))?;
                let re = re_s
                    .trim()
                    .parse::<f64>()
                    .map_err(|e| format!("bad re {re_s:?}: {e}"))?;
                let im = im_s
                    .trim()
                    .parse::<f64>()
                    .map_err(|e| format!("bad im {im_s:?}: {e}"))?;
                Ok(vec![re, im])
            }
        }
    };

    let mut data: Vec<Vec<f64>> = Vec::new();
    let mut current: Option<Vec<f64>> = None;

    for line in body.lines() {
        if line.trim().is_empty() {
            // Blank line between points (ASCII format A).
            if let Some(row) = current.take() {
                if row.len() == slots {
                    data.push(row);
                }
            }
            continue;
        }

        if line.starts_with('\t') {
            // Continuation value for current point.
            if let Some(row) = current.as_mut() {
                row.extend(parse_slot(line)?);
            }
        } else {
            // New point: ` <idx>\t<value>` (format A) or `<idx>\t\t<value>` (format B).
            if let Some(row) = current.take() {
                if row.len() == slots {
                    data.push(row);
                }
            }
            // Split off the index prefix, then parse the value after the first tab.
            if let Some(tab_pos) = line.find('\t') {
                let value_part = line[tab_pos + 1..].trim_start_matches('\t');
                let mut row = Vec::with_capacity(slots);
                row.extend(parse_slot(value_part)?);
                current = Some(row);
            }
        }
    }
    if let Some(row) = current.take() {
        if row.len() == slots {
            data.push(row);
        }
    }
    Ok(data)
}

// ── Tolerance ─────────────────────────────────────────────────────────────────

pub struct Tolerance;

impl Tolerance {
    /// True if `actual` is within `abs_tol` absolute or `rel_tol` relative of `expected`.
    pub fn within(actual: f64, expected: f64, abs_tol: f64, rel_tol: f64) -> bool {
        let abs_err = (actual - expected).abs();
        let denom = expected.abs().max(abs_tol);
        abs_err <= abs_tol || abs_err / denom <= rel_tol
    }
}

// ── ngspice ───────────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct NgspiceRunner {
    pub binary: String,
}

pub struct NgspiceResult {
    /// All plots from the rawfile (multi-plot support).
    pub plots: Vec<RawFile>,
    /// Legacy: first plot's rawfile (for backward compat).
    pub rawfile: RawFile,
    #[allow(dead_code)]
    pub node_voltages: Vec<(String, f64)>,
}

impl Default for NgspiceRunner {
    fn default() -> Self {
        Self {
            binary: "ngspice".into(),
        }
    }
}

impl NgspiceRunner {
    const TIMEOUT: Duration = Duration::from_secs(30);

    pub fn is_available(&self) -> bool {
        Command::new(&self.binary).arg("--version").output().is_ok()
    }

    pub fn run(&self, sp: &Path) -> Result<NgspiceResult, String> {
        let tmp = tempfile::tempdir().map_err(|e| format!("tmpdir: {e}"))?;
        let raw_path = tmp.path().join("out.raw");

        // Copy any sibling include/model files into the tempdir.
        copy_siblings(sp, tmp.path());

        let mut cmd = Command::new(&self.binary);
        cmd.args(["-b", "-r"]).arg(&raw_path).arg(sp);
        let out =
            output_with_timeout(&mut cmd, Self::TIMEOUT).map_err(|e| format!("ngspice: {e}"))?;

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            return Err(format!("ngspice exit {:?}: {stderr}", out.status.code()));
        }

        let f = std::fs::File::open(&raw_path)
            .map_err(|e| format!("open {}: {e}", raw_path.display()))?;
        let plots = RawFile::read_all(f)?;

        // Use the first plot for legacy node_voltages extraction.
        let rawfile = plots.first().cloned().ok_or("empty raw file")?;
        let last = rawfile.data.len().saturating_sub(1);
        let node_voltages = rawfile
            .variables
            .iter()
            .enumerate()
            .filter(|(_, v)| matches!(v.kind, VarKind::Voltage))
            .map(|(i, v)| (v.name.clone(), rawfile.real(last, i)))
            .collect();

        Ok(NgspiceResult {
            plots,
            rawfile,
            node_voltages,
        })
    }
}

// ── Xyce ──────────────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct XyceRunner {
    pub binary: String,
}

pub struct XyceResult {
    pub node_voltages: Vec<(String, f64)>,
}

impl Default for XyceRunner {
    fn default() -> Self {
        Self {
            binary: "Xyce".into(),
        }
    }
}

impl XyceRunner {
    const TIMEOUT: Duration = Duration::from_secs(30);

    pub fn is_available(&self) -> bool {
        Command::new(&self.binary).arg("-v").output().is_ok()
    }

    pub fn run(&self, sp: &Path) -> Result<XyceResult, String> {
        let tmp = tempfile::tempdir().map_err(|e| format!("tmpdir: {e}"))?;
        let tmp_sp = tmp.path().join(sp.file_name().unwrap());
        std::fs::copy(sp, &tmp_sp).map_err(|e| format!("copy: {e}"))?;
        copy_siblings(sp, tmp.path());

        let mut cmd = Command::new(&self.binary);
        cmd.arg(&tmp_sp);
        let out = output_with_timeout(&mut cmd, Self::TIMEOUT).map_err(|e| format!("xyce: {e}"))?;

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            return Err(format!("xyce exit {:?}: {stderr}", out.status.code()));
        }

        // Prefer raw file output if Xyce was invoked with -r (it won't be here,
        // so we fall through to .prn). Try base.prn first, then base.FD.prn.
        let stem = sp
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let prn_candidates = [
            tmp.path().join(format!("{stem}.prn")),
            tmp.path().join(format!("{stem}.FD.prn")),
            tmp.path().join(format!("{stem}.TD.prn")),
        ];

        for prn in &prn_candidates {
            if prn.exists() {
                return parse_xyce_prn(prn);
            }
        }

        // Fallback: glob any .prn in the tempdir.
        if let Ok(entries) = std::fs::read_dir(tmp.path()) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.extension().is_some_and(|e| e == "prn") {
                    return parse_xyce_prn(&p);
                }
            }
        }

        Err("no .prn output file from Xyce".into())
    }
}

fn parse_xyce_prn(path: &Path) -> Result<XyceResult, String> {
    let text =
        std::fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))?;

    let mut lines = text.lines().peekable();

    // Skip blank lines before header.
    while lines.peek().map_or(false, |l| l.trim().is_empty()) {
        lines.next();
    }

    let header_line = lines.next().ok_or("empty .prn file")?;

    // Header tokens: ["Index", "V(1)", "I(V1)", ...]
    // May also start with "STEPNUM  Index" or be absent (PRINTHEADER=false).
    let cols: Vec<String> = header_line
        .split_whitespace()
        .map(|s| s.to_string())
        .collect();

    // Identify which columns are data (skip "Index", "STEPNUM").
    // The first non-index column after "Index" is the start of data.
    let data_start = cols
        .iter()
        .position(|c| {
            let cu = c.to_uppercase();
            cu != "INDEX" && cu != "STEPNUM"
        })
        .unwrap_or(1);

    let data_cols = &cols[data_start..];

    // Collect all data rows (non-empty, not the footer).
    let mut last_row: Option<Vec<f64>> = None;
    for line in lines {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.starts_with("End of Xyce") {
            break;
        }
        let tokens: Vec<&str> = trimmed.split_whitespace().collect();
        // Expect at least data_start integer prefix(es) + data values.
        if tokens.len() < data_start + 1 {
            continue;
        }
        // The first data_start tokens are the index/stepnum integers.
        let vals: Vec<f64> = tokens[data_start..]
            .iter()
            .map(|s| s.parse::<f64>().unwrap_or(f64::NAN))
            .collect();
        if !vals.is_empty() {
            last_row = Some(vals);
        }
    }

    let last = last_row.ok_or("no data rows in .prn")?;

    // Map column name → last-row value. Column names follow Xyce conventions:
    //   V(node)         node voltage
    //   V(n1,n2)        differential
    //   I(Vsource)      branch current through voltage source
    //   Re(V(n)), Im(V(n))  AC cartesian
    //   FREQ, TIME      sweep variables
    let node_voltages: Vec<(String, f64)> = data_cols
        .iter()
        .zip(last.iter())
        .map(|(col, &val)| (col.to_lowercase(), val))
        .collect();

    Ok(XyceResult { node_voltages })
}

// ── VACASK ────────────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct VacaskRunner {
    pub binary: String,
}

pub struct VacaskResult {
    pub node_voltages: Vec<(String, f64)>,
}

impl Default for VacaskRunner {
    fn default() -> Self {
        Self {
            binary: "vacask".into(),
        }
    }
}

impl VacaskRunner {
    const TIMEOUT: Duration = Duration::from_secs(30);

    pub fn is_available(&self) -> bool {
        Command::new(&self.binary).arg("--version").output().is_ok()
    }

    pub fn run(&self, sp: &Path) -> Result<VacaskResult, String> {
        // VACASK writes `<analysis_name>.raw` in the current working directory,
        // nothing to stdout. Run it in a tempdir to capture the output files.
        let tmp = tempfile::tempdir().map_err(|e| format!("tmpdir: {e}"))?;
        let tmp_sp = tmp.path().join(sp.file_name().unwrap());
        std::fs::copy(sp, &tmp_sp).map_err(|e| format!("copy: {e}"))?;
        copy_siblings(sp, tmp.path());

        let mut cmd = Command::new(&self.binary);
        cmd.current_dir(tmp.path()).arg(&tmp_sp);
        let out =
            output_with_timeout(&mut cmd, Self::TIMEOUT).map_err(|e| format!("vacask: {e}"))?;

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            return Err(format!("vacask exit {:?}: {stderr}", out.status.code()));
        }

        // Collect all *.raw files written by VACASK, sorted (op before tran, etc.).
        let mut raw_files: Vec<PathBuf> = std::fs::read_dir(tmp.path())
            .map_err(|e| format!("read tmpdir: {e}"))?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|ext| ext == "raw"))
            .collect();
        raw_files.sort();

        if raw_files.is_empty() {
            return Err("vacask produced no .raw output files".into());
        }

        // Prefer the DC OP raw file (plotname contains "operating point") for
        // node-voltage extraction. Fall back to the first file.
        let mut node_voltages: Vec<(String, f64)> = Vec::new();

        for raw_path in &raw_files {
            let f = std::fs::File::open(raw_path)
                .map_err(|e| format!("open {}: {e}", raw_path.display()))?;
            let raw = match RawFile::read(f) {
                Ok(r) => r,
                Err(_) => continue,
            };

            let pl = raw.plotname.to_lowercase();
            let is_op = pl.contains("operating") || pl.contains("dc transfer");
            let is_tran = pl.contains("transient");

            // For DC/OP: extract last-point voltages.
            // For transient: also extract final-point voltages (useful for DC comparison).
            // Skip pure AC plots for node-voltage extraction (use complex magnitude instead).
            if is_op || is_tran {
                let last = raw.data.len().saturating_sub(1);
                // VACASK uses bare node names (no "v()" wrapper) — normalise to v(name).
                for (i, var) in raw.variables.iter().enumerate() {
                    if matches!(var.kind, VarKind::Voltage) {
                        let key = normalise_vacask_node(&var.name);
                        let val = raw.real(last, i);
                        node_voltages.push((key, val));
                    }
                }
                // Prefer OP over transient: break as soon as we get OP results.
                if is_op && !node_voltages.is_empty() {
                    break;
                }
            }
        }

        if node_voltages.is_empty() {
            return Err("no voltage variables found in VACASK raw output".into());
        }

        Ok(VacaskResult { node_voltages })
    }
}

/// VACASK raw files store bare node names; normalise to `v(<name>)` so they
/// compare cleanly with ngspice/Xyce output (which uses `v(node)`).
fn normalise_vacask_node(name: &str) -> String {
    let n = name.to_lowercase();
    if n.starts_with("v(") {
        n
    } else {
        format!("v({n})")
    }
}

// ── Shared helpers ────────────────────────────────────────────────────────────

/// Copy sibling `.lib`, `.inc`, `.mod` files from `sp`'s parent into `dest`
/// so included model files are visible to the simulator subprocess.
fn copy_siblings(sp: &Path, dest: &Path) {
    let Some(parent) = sp.parent() else { return };
    let Ok(entries) = std::fs::read_dir(parent) else {
        return;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension()
            .is_some_and(|e| matches!(e.to_str(), Some("lib" | "inc" | "mod")))
        {
            if let Some(name) = p.file_name() {
                let _ = std::fs::copy(&p, dest.join(name));
            }
        }
    }
}

fn output_with_timeout(cmd: &mut Command, timeout: Duration) -> Result<Output, String> {
    let mut child = cmd.spawn().map_err(|e| format!("spawn: {e}"))?;
    let start = Instant::now();

    loop {
        match child.try_wait().map_err(|e| format!("wait: {e}"))? {
            Some(_) => return child.wait_with_output().map_err(|e| format!("output: {e}")),
            None if start.elapsed() >= timeout => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("timed out after {:.0}s", timeout.as_secs_f64()));
            }
            None => std::thread::sleep(Duration::from_millis(20)),
        }
    }
}
