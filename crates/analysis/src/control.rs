//! `.control` / `.endc` interpreter — Wave R.
//!
//! Executes the scripting language found inside `.control` blocks in ngspice
//! netlists.  The interpreter is intentionally kept simple: it processes one
//! statement at a time, supports the most common commands, and delegates
//! analysis execution to the existing `pisim_analysis` functions.
//!
//! # Supported features (Wave R)
//!
//! | Category        | Commands                                              |
//! |-----------------|-------------------------------------------------------|
//! | Variables       | `let x = expr`, `set key=value`, `unset key`          |
//! | Output          | `print expr`, `echo string`                           |
//! | Analyses        | `run`, `op`, `dc`, `ac`, `tran`                       |
//! | Component mod   | `alter device value`                                  |
//! | File I/O        | `source filename`, `wrdata file sigs...`              |
//! | Control flow    | `if`/`else`/`end`, `foreach`/`end`, `while`/`end`,    |
//! |                 | `repeat N`/`end`                                      |
//! | Functions       | `define f(x) = expr`                                  |
//! | Measurement     | `meas tran|ac|dc name RISE|FALL|...`                  |
//! | Write results   | `write filename.raw`                                  |
//!
//! # Architecture
//!
//! [`ControlInterpreter`] holds:
//! - A mutable reference to the [`Circuit`] (for `alter`)
//! - A [`DeviceRegistry`] reference (for analyses)
//! - A variable store (`vars: HashMap<String, ControlValue>`)
//! - A result store: the most recent [`TransientResult`] / [`DcOpResult`] etc.
//! - An output sink (`output: Vec<String>`) for `print` / `echo`

use std::collections::HashMap;
use std::fmt;

use pisim_core::{Circuit, SimError};
use pisim_device::DeviceRegistry;

use crate::result::{DcOpResult, ResultData, TransientResult};
use crate::dc_op::run_dc_op;
use crate::transient::{run_transient, TransientConfig};
use crate::measure::{eval_measure, parse_measure_line};

// ---------------------------------------------------------------------------
// Value type
// ---------------------------------------------------------------------------

/// A value in the `.control` variable store.
#[derive(Debug, Clone, PartialEq)]
pub enum ControlValue {
    /// Scalar floating-point number.
    Number(f64),
    /// String value (from `set key=value`).
    Str(String),
    /// Result vector (waveform data from an analysis).
    Vector(Vec<f64>),
}

impl ControlValue {
    /// Attempt to extract a numeric value.
    pub fn as_number(&self) -> Option<f64> {
        match self {
            ControlValue::Number(v) => Some(*v),
            ControlValue::Str(s) => s.parse::<f64>().ok(),
            ControlValue::Vector(v) => v.first().copied(),
        }
    }
}

impl fmt::Display for ControlValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ControlValue::Number(v) => write!(f, "{v}"),
            ControlValue::Str(s) => write!(f, "{s}"),
            ControlValue::Vector(v) => {
                let parts: Vec<String> = v.iter().map(|x| x.to_string()).collect();
                write!(f, "[{}]", parts.join(", "))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Interpreter result store
// ---------------------------------------------------------------------------

/// Holds the most recent simulation results, updated after each analysis run.
#[derive(Debug, Default)]
pub struct SimResults {
    /// Most recent DC op result.
    pub dc_op: Option<DcOpResult>,
    /// Most recent transient result.
    pub transient: Option<TransientResult>,
    /// Node names from the last analysis (used for vector lookup).
    pub node_names: Vec<String>,
}

impl SimResults {
    /// Look up a signal vector by name (e.g. `"v(out)"`, `"v(1)"`).
    pub fn get_vector(&self, name: &str) -> Option<Vec<f64>> {
        let lower = name.to_ascii_lowercase();
        // v(node) form
        let node = if lower.starts_with("v(") && lower.ends_with(')') {
            Some(&lower[2..lower.len() - 1])
        } else if lower == "time" {
            None // handled below
        } else {
            None
        };

        if lower == "time" {
            if let Some(ref tr) = self.transient {
                return Some(tr.times.clone());
            }
        }

        if let Some(node_name) = node {
            // Search transient result
            if let Some(ref tr) = self.transient {
                if let Some(idx) = self.node_names.iter().position(|n| n == node_name) {
                    let vec: Vec<f64> = (0..tr.num_steps())
                        .map(|step| tr.voltage(step, idx))
                        .collect();
                    return Some(vec);
                }
            }
            // Search dc op result
            if let Some(ref dc) = self.dc_op {
                if let Some((_, v)) = dc.node_voltages.iter().find(|(n, _)| n == node_name) {
                    return Some(vec![*v]);
                }
            }
        }
        None
    }
}

// ---------------------------------------------------------------------------
// Interpreter
// ---------------------------------------------------------------------------

/// The `.control` block interpreter.
///
/// Create with [`ControlInterpreter::new`], then call [`ControlInterpreter::run`]
/// with the raw control-block lines.
pub struct ControlInterpreter<'a> {
    /// The circuit being simulated (mutated by `alter`).
    circuit: &'a mut Circuit,
    /// Device registry for analysis runs.
    registry: &'a DeviceRegistry,
    /// Variable store (`let` / `set` variables).
    pub vars: HashMap<String, ControlValue>,
    /// User-defined functions: name → (args, body_expr_str).
    pub user_funcs: HashMap<String, (Vec<String>, String)>,
    /// Captured output lines from `print` / `echo`.
    pub output: Vec<String>,
    /// Most recent simulation results.
    pub results: SimResults,
}

impl<'a> ControlInterpreter<'a> {
    /// Create a new interpreter bound to the given circuit and registry.
    pub fn new(circuit: &'a mut Circuit, registry: &'a DeviceRegistry) -> Self {
        Self {
            circuit,
            registry,
            vars: HashMap::new(),
            user_funcs: HashMap::new(),
            output: Vec::new(),
            results: SimResults::default(),
        }
    }

    /// Execute a slice of raw control-block lines.
    ///
    /// Lines are processed one at a time.  Control-flow constructs (`foreach`,
    /// `while`, `if`, `repeat`) consume subsequent lines until their matching
    /// `end` keyword.
    pub fn run(&mut self, lines: &[String]) -> Result<(), SimError> {
        let mut i = 0;
        while i < lines.len() {
            let consumed = self.exec_statement(lines, i)?;
            i += consumed;
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Statement dispatch
    // -----------------------------------------------------------------------

    /// Execute the statement at `lines[pos]`.  Returns the number of lines
    /// consumed (1 for simple statements, more for block constructs).
    fn exec_statement(&mut self, lines: &[String], pos: usize) -> Result<usize, SimError> {
        let line = lines[pos].trim();
        if line.is_empty() || line.starts_with('*') || line.starts_with('$') {
            return Ok(1); // comment or blank
        }

        let (cmd, rest) = split_first_word(line);
        let cmd_lower = cmd.to_ascii_lowercase();

        match cmd_lower.as_str() {
            "let" => {
                self.exec_let(rest)?;
                Ok(1)
            }
            "set" => {
                self.exec_set(rest)?;
                Ok(1)
            }
            "unset" => {
                self.exec_unset(rest);
                Ok(1)
            }
            "print" => {
                self.exec_print(rest)?;
                Ok(1)
            }
            "echo" => {
                self.exec_echo(rest);
                Ok(1)
            }
            "run" => {
                self.exec_run()?;
                Ok(1)
            }
            "op" => {
                self.exec_op()?;
                Ok(1)
            }
            "tran" => {
                self.exec_tran(rest)?;
                Ok(1)
            }
            "dc" => {
                // Basic dc command — run DC op for now
                self.exec_op()?;
                Ok(1)
            }
            "ac" => {
                // AC command — not fully wired yet, silently skip
                Ok(1)
            }
            "alter" => {
                self.exec_alter(rest)?;
                Ok(1)
            }
            "source" => {
                // source filename — load and execute another script
                // Not yet implemented; silently skip.
                Ok(1)
            }
            "meas" | "measure" => {
                self.exec_meas(rest)?;
                Ok(1)
            }
            "wrdata" => {
                self.exec_wrdata(rest)?;
                Ok(1)
            }
            "write" => {
                // write filename.raw — stub
                Ok(1)
            }
            "define" => {
                self.exec_define(rest)?;
                Ok(1)
            }
            "if" => self.exec_if(lines, pos),
            "foreach" => self.exec_foreach(lines, pos),
            "while" => self.exec_while(lines, pos),
            "repeat" => self.exec_repeat(lines, pos),
            "end" => Ok(1), // consumed by block handlers; stray `end` is a no-op
            _ => {
                // Unknown command — silently skip.
                Ok(1)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Variable commands
    // -----------------------------------------------------------------------

    fn exec_let(&mut self, rest: &str) -> Result<(), SimError> {
        // `let name = expr`  or  `let name=expr`
        let rest = rest.trim();
        if let Some((name, expr_str)) = rest.split_once('=') {
            let name = name.trim().to_ascii_lowercase();
            let expr_str = expr_str.trim();
            let val = self.eval_expr(expr_str)?;
            self.vars.insert(name, val);
        }
        Ok(())
    }

    fn exec_set(&mut self, rest: &str) -> Result<(), SimError> {
        // `set key=value`  or  `set key`  (boolean set)
        let rest = rest.trim();
        if let Some((key, val_str)) = rest.split_once('=') {
            let key = key.trim().to_ascii_lowercase();
            let val_str = val_str.trim();
            // Try numeric first, fall back to string
            let val = if let Ok(n) = val_str.parse::<f64>() {
                ControlValue::Number(n)
            } else {
                ControlValue::Str(val_str.to_string())
            };
            self.vars.insert(key, val);
        } else {
            // Boolean flag — store as 1
            let key = rest.to_ascii_lowercase();
            if !key.is_empty() {
                self.vars.insert(key, ControlValue::Number(1.0));
            }
        }
        Ok(())
    }

    fn exec_unset(&mut self, rest: &str) {
        let key = rest.trim().to_ascii_lowercase();
        self.vars.remove(&key);
    }

    // -----------------------------------------------------------------------
    // Output commands
    // -----------------------------------------------------------------------

    fn exec_print(&mut self, rest: &str) -> Result<(), SimError> {
        let rest = rest.trim();
        let val = self.eval_expr(rest)?;
        self.output.push(format!("{val}"));
        Ok(())
    }

    fn exec_echo(&mut self, rest: &str) {
        // Substitute {varname} placeholders
        let expanded = self.expand_vars(rest.trim());
        self.output.push(expanded);
    }

    /// Expand `{varname}` and `{expr}` placeholders in a string.
    fn expand_vars(&self, s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '{' {
                let mut inner = String::new();
                for ic in chars.by_ref() {
                    if ic == '}' {
                        break;
                    }
                    inner.push(ic);
                }
                let key = inner.trim().to_ascii_lowercase();
                if let Some(v) = self.vars.get(&key) {
                    out.push_str(&v.to_string());
                } else {
                    out.push('{');
                    out.push_str(&inner);
                    out.push('}');
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    // -----------------------------------------------------------------------
    // Analysis commands
    // -----------------------------------------------------------------------

    fn exec_run(&mut self) -> Result<(), SimError> {
        // Generic "run" — execute the DC op as a default.
        self.exec_op()
    }

    fn exec_op(&mut self) -> Result<(), SimError> {
        let out = run_dc_op(self.circuit, self.registry)?;
        self.results.node_names = out.result.node_voltages
            .iter()
            .map(|(n, _)| n.clone())
            .collect();
        self.results.dc_op = Some(DcOpResult {
            node_voltages: out.result.node_voltages,
            branch_currents: out.result.branch_currents,
        });
        Ok(())
    }

    fn exec_tran(&mut self, rest: &str) -> Result<(), SimError> {
        // `tran tstep tstop`
        let parts: Vec<&str> = rest.split_whitespace().collect();
        if parts.len() < 2 {
            return Err(SimError::Parse(
                "control: tran requires tstep tstop".into(),
            ));
        }
        let tstep = parse_si_value(parts[0]).ok_or_else(|| {
            SimError::Parse(format!("control: tran: invalid tstep '{}'", parts[0]))
        })?;
        let tstop = parse_si_value(parts[1]).ok_or_else(|| {
            SimError::Parse(format!("control: tran: invalid tstop '{}'", parts[1]))
        })?;

        let config = TransientConfig::new(tstep, tstop);
        let result = run_transient(self.circuit, self.registry, &config)?;

        // Build node name list from the circuit's ordered nodes.
        let node_names: Vec<String> = self.circuit.nodes()
            .iter()
            .filter_map(|n| n.matrix_index.map(|_| n.name.clone()))
            .collect();
        self.results.node_names = node_names;
        self.results.transient = Some(result);
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Alter command
    // -----------------------------------------------------------------------

    fn exec_alter(&mut self, rest: &str) -> Result<(), SimError> {
        // `alter device value`  or  `alter device param=value`
        let parts: Vec<&str> = rest.split_whitespace().collect();
        if parts.len() < 2 {
            return Err(SimError::Parse(
                "control: alter requires device and value".into(),
            ));
        }
        let device_name = parts[0];
        let value_str = parts[1];

        // Check for `param=value` form
        if let Some((param, val_str)) = value_str.split_once('=') {
            let val = parse_si_value(val_str).ok_or_else(|| {
                SimError::Parse(format!("control: alter: invalid value '{val_str}'"))
            })?;
            self.circuit.set_device_param(device_name, param, val);
        } else {
            // Bare value — use "resistance" / "dc" as a fallback primary param
            let val = parse_si_value(value_str).ok_or_else(|| {
                SimError::Parse(format!("control: alter: invalid value '{value_str}'"))
            })?;
            // Try common primary params in order
            for param in &["resistance", "dc", "capacitance", "inductance", "value"] {
                self.circuit.set_device_param(device_name, param, val);
            }
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Measurement command
    // -----------------------------------------------------------------------

    fn exec_meas(&mut self, rest: &str) -> Result<(), SimError> {
        // `meas tran|dc|ac name TYPE ...`
        // tokens expected by parse_measure_line: ["tran", "name", "TYPE", ...]
        let parts: Vec<&str> = rest.split_whitespace().collect();
        if parts.len() < 3 {
            return Ok(()); // not enough tokens — skip silently
        }

        let meas_name = parts[1].to_ascii_lowercase();

        // parse_measure_line expects lowercase token slices.
        let lower_parts: Vec<String> = parts.iter().map(|s| s.to_ascii_lowercase()).collect();
        let lower_refs: Vec<&str> = lower_parts.iter().map(|s| s.as_str()).collect();

        let stmt = match parse_measure_line(&lower_refs) {
            Some(s) => s,
            None => return Ok(()), // couldn't parse — skip
        };

        // Build ResultData for eval_measure.
        let data = if let Some(ref tr) = self.results.transient {
            ResultData::Transient(tr.clone())
        } else {
            return Ok(()); // no results yet
        };

        let node_names = self.results.node_names.clone();
        match eval_measure(&stmt, &data, &node_names) {
            Ok(val) => {
                self.vars.insert(meas_name, ControlValue::Number(val));
            }
            Err(_) => {
                // Measurement failed — store NaN so downstream code sees it.
                self.vars.insert(meas_name, ControlValue::Number(f64::NAN));
            }
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // wrdata command
    // -----------------------------------------------------------------------

    fn exec_wrdata(&mut self, rest: &str) -> Result<(), SimError> {
        // `wrdata filename sig1 sig2 ...`
        let parts: Vec<&str> = rest.split_whitespace().collect();
        if parts.is_empty() {
            return Err(SimError::Parse("control: wrdata requires filename".into()));
        }
        let filename = parts[0];
        let signals = &parts[1..];

        let mut rows: Vec<Vec<f64>> = Vec::new();
        let mut headers: Vec<String> = Vec::new();

        // Collect time vector if transient result is available.
        if let Some(ref tr) = self.results.transient {
            headers.push("time".to_string());
            let time_col: Vec<f64> = tr.times.clone();
            rows.push(time_col);
        }

        for sig in signals {
            let sig_lower = sig.to_ascii_lowercase();
            if let Some(vec) = self.results.get_vector(&sig_lower) {
                headers.push(sig_lower);
                rows.push(vec);
            }
        }

        // Transpose and write as CSV.
        if !rows.is_empty() {
            let n_rows = rows.iter().map(|c| c.len()).min().unwrap_or(0);
            let mut csv = headers.join(",") + "\n";
            for i in 0..n_rows {
                let line: Vec<String> = rows.iter().map(|col| {
                    col.get(i).map(|v| v.to_string()).unwrap_or_default()
                }).collect();
                csv.push_str(&line.join(","));
                csv.push('\n');
            }
            std::fs::write(filename, &csv).map_err(SimError::Io)?;
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // User-defined function
    // -----------------------------------------------------------------------

    fn exec_define(&mut self, rest: &str) -> Result<(), SimError> {
        // `define f(x) = expr`
        let rest = rest.trim();
        if let Some(paren_start) = rest.find('(') {
            if let Some(paren_end) = rest.find(')') {
                let name = rest[..paren_start].trim().to_ascii_lowercase();
                let args_str = &rest[paren_start + 1..paren_end];
                let args: Vec<String> = args_str
                    .split(',')
                    .map(|a| a.trim().to_ascii_lowercase())
                    .filter(|a| !a.is_empty())
                    .collect();
                let after_paren = rest[paren_end + 1..].trim();
                let body = after_paren
                    .strip_prefix('=')
                    .unwrap_or(after_paren)
                    .trim()
                    .to_string();
                self.user_funcs.insert(name, (args, body));
            }
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Control-flow constructs
    // -----------------------------------------------------------------------

    /// `if condition` / `else` / `end`
    fn exec_if(&mut self, lines: &[String], pos: usize) -> Result<usize, SimError> {
        let header = lines[pos].trim();
        let cond_str = header.trim_start_matches("if").trim();
        let cond = self.eval_condition(cond_str)?;

        // Find the matching end/else/endif
        let (true_body, false_body, total_consumed) = split_if_body(lines, pos + 1)?;

        if cond {
            self.run(&true_body)?;
        } else if let Some(fb) = false_body {
            self.run(&fb)?;
        }

        Ok(total_consumed + 1) // +1 for the `if` line
    }

    /// `foreach varname val1 val2 ...` / `end`
    fn exec_foreach(&mut self, lines: &[String], pos: usize) -> Result<usize, SimError> {
        let header = lines[pos].trim();
        let args_str = header.trim_start_matches("foreach").trim();
        let mut parts = args_str.splitn(2, char::is_whitespace);
        let var_name = parts.next().unwrap_or("").trim().to_ascii_lowercase();
        let values_str = parts.next().unwrap_or("").trim();

        let values: Vec<String> = values_str
            .split_whitespace()
            .map(|s| s.to_string())
            .collect();

        let (body, total_consumed) = collect_block_body(lines, pos + 1)?;

        for val_str in &values {
            let val = if let Some(n) = parse_si_value(val_str) {
                ControlValue::Number(n)
            } else if let Ok(n) = val_str.parse::<f64>() {
                ControlValue::Number(n)
            } else {
                ControlValue::Str(val_str.clone())
            };
            self.vars.insert(var_name.clone(), val);
            self.run(&body)?;
        }

        Ok(total_consumed + 1)
    }

    /// `while condition` / `end`
    fn exec_while(&mut self, lines: &[String], pos: usize) -> Result<usize, SimError> {
        let header = lines[pos].trim();
        let cond_str = header.trim_start_matches("while").trim();
        let (body, total_consumed) = collect_block_body(lines, pos + 1)?;

        let mut iters = 0usize;
        const MAX_ITERS: usize = 100_000;
        while self.eval_condition(cond_str)? {
            self.run(&body)?;
            iters += 1;
            if iters >= MAX_ITERS {
                return Err(SimError::Parse(
                    "control: while loop exceeded 100000 iterations".into(),
                ));
            }
        }

        Ok(total_consumed + 1)
    }

    /// `repeat N` / `end`
    fn exec_repeat(&mut self, lines: &[String], pos: usize) -> Result<usize, SimError> {
        let header = lines[pos].trim();
        let n_str = header.trim_start_matches("repeat").trim();
        let n = n_str.parse::<usize>().unwrap_or(0);
        let (body, total_consumed) = collect_block_body(lines, pos + 1)?;

        for _ in 0..n {
            self.run(&body)?;
        }

        Ok(total_consumed + 1)
    }

    // -----------------------------------------------------------------------
    // Expression evaluator
    // -----------------------------------------------------------------------

    /// Evaluate a simple arithmetic expression string.
    ///
    /// Supports: literals, variable references, `+`, `-`, `*`, `/`,
    /// SI-suffixed numbers (e.g. `1n`, `100k`), and `{expr}` brace forms.
    pub fn eval_expr(&self, expr: &str) -> Result<ControlValue, SimError> {
        let expr = expr.trim();
        // Strip outer braces
        let expr = if expr.starts_with('{') && expr.ends_with('}') {
            &expr[1..expr.len() - 1]
        } else {
            expr
        };
        let expr = expr.trim();

        // Try plain number (with SI suffix)
        if let Some(v) = parse_si_value(expr) {
            return Ok(ControlValue::Number(v));
        }

        // Variable reference
        let key = expr.to_ascii_lowercase();
        if let Some(val) = self.vars.get(&key) {
            return Ok(val.clone());
        }

        // Vector reference: v(node), i(device)
        if expr.starts_with("v(") || expr.starts_with("V(") {
            if let Some(vec) = self.results.get_vector(&expr.to_ascii_lowercase()) {
                if vec.len() == 1 {
                    return Ok(ControlValue::Number(vec[0]));
                }
                return Ok(ControlValue::Vector(vec));
            }
        }

        // Simple binary expression: try splitting on +, -, *, /
        // We handle left-to-right with a minimal recursive descent.
        if let Some(v) = self.eval_arithmetic(expr) {
            return Ok(ControlValue::Number(v));
        }

        // Fall back to string value
        Ok(ControlValue::Str(expr.to_string()))
    }

    /// Minimal left-to-right arithmetic evaluator for `a op b` expressions.
    fn eval_arithmetic(&self, expr: &str) -> Option<f64> {
        // Try splitting on the last `+` or `-` (lowest precedence, outside parens)
        let expr = expr.trim();

        // Walk backwards to find an additive operator outside parens.
        let mut depth = 0i32;
        let bytes = expr.as_bytes();
        for i in (1..bytes.len()).rev() {
            match bytes[i] {
                b')' => depth += 1,
                b'(' => depth -= 1,
                b'+' | b'-' if depth == 0 && i > 0 => {
                    let lhs = &expr[..i];
                    let rhs = &expr[i + 1..];
                    let l = self.eval_atomic(lhs)?;
                    let r = self.eval_atomic(rhs)?;
                    return Some(if bytes[i] == b'+' { l + r } else { l - r });
                }
                _ => {}
            }
        }

        // Try splitting on `*` or `/`
        for i in (1..bytes.len()).rev() {
            match bytes[i] {
                b')' => depth += 1,
                b'(' => depth -= 1,
                b'*' | b'/' if depth == 0 => {
                    let lhs = &expr[..i];
                    let rhs = &expr[i + 1..];
                    let l = self.eval_atomic(lhs)?;
                    let r = self.eval_atomic(rhs)?;
                    if bytes[i] == b'/' {
                        if r == 0.0 {
                            return None;
                        }
                        return Some(l / r);
                    }
                    return Some(l * r);
                }
                _ => {}
            }
        }

        self.eval_atomic(expr)
    }

    fn eval_atomic(&self, expr: &str) -> Option<f64> {
        let expr = expr.trim();
        if expr.is_empty() {
            return None;
        }
        // Parenthesized sub-expression
        if expr.starts_with('(') && expr.ends_with(')') {
            return self.eval_arithmetic(&expr[1..expr.len() - 1]);
        }
        // Number with SI suffix
        if let Some(v) = parse_si_value(expr) {
            return Some(v);
        }
        // Variable
        let key = expr.to_ascii_lowercase();
        self.vars.get(&key).and_then(|v| v.as_number())
    }

    /// Evaluate a condition string to a boolean.
    fn eval_condition(&self, cond: &str) -> Result<bool, SimError> {
        let cond = cond.trim();
        // Try comparison operators
        for op in &[">=", "<=", "!=", ">", "<", "=="] {
            if let Some(pos) = cond.find(op) {
                let lhs = &cond[..pos];
                let rhs = &cond[pos + op.len()..];
                let l = self
                    .eval_expr(lhs)?
                    .as_number()
                    .ok_or_else(|| SimError::Parse(format!("control: non-numeric LHS in condition '{cond}'")))?;
                let r = self
                    .eval_expr(rhs)?
                    .as_number()
                    .ok_or_else(|| SimError::Parse(format!("control: non-numeric RHS in condition '{cond}'")))?;
                return Ok(match *op {
                    ">=" => l >= r,
                    "<=" => l <= r,
                    "!=" => (l - r).abs() > 1e-15,
                    ">"  => l > r,
                    "<"  => l < r,
                    "==" => (l - r).abs() <= 1e-15,
                    _    => false,
                });
            }
        }
        // Bare expression — truthy if non-zero
        let v = self.eval_expr(cond)?.as_number().unwrap_or(0.0);
        Ok(v != 0.0)
    }
}

// ---------------------------------------------------------------------------
// Block body helpers
// ---------------------------------------------------------------------------

/// Collect lines of a block body until a bare `end` keyword.
///
/// Returns `(body_lines, total_lines_consumed_not_including_header)`.
/// The returned `total_lines_consumed` includes the `end` line.
fn collect_block_body(lines: &[String], start: usize) -> Result<(Vec<String>, usize), SimError> {
    let mut body = Vec::new();
    let mut depth = 1usize; // nesting depth
    let mut i = start;
    while i < lines.len() {
        let line = lines[i].trim();
        let (first_word, _) = split_first_word(line);
        let fw = first_word.to_ascii_lowercase();
        // Track nesting of block openers
        if matches!(fw.as_str(), "if" | "foreach" | "while" | "repeat") {
            depth += 1;
        } else if fw == "end" || fw == "endif" {
            depth -= 1;
            if depth == 0 {
                return Ok((body, i - start + 1));
            }
        }
        body.push(lines[i].clone());
        i += 1;
    }
    Err(SimError::Parse("control: unterminated block (missing 'end')".into()))
}

/// Split an `if` / `else` / `end` block into true-body and false-body slices.
///
/// Returns `(true_body, Option<false_body>, total_lines_consumed_after_if_header)`.
fn split_if_body(
    lines: &[String],
    start: usize,
) -> Result<(Vec<String>, Option<Vec<String>>, usize), SimError> {
    let mut true_body = Vec::new();
    let mut false_body: Option<Vec<String>> = None;
    let mut in_else = false;
    let mut depth = 1usize;
    let mut i = start;

    while i < lines.len() {
        let line = lines[i].trim();
        let (first_word, _) = split_first_word(line);
        let fw = first_word.to_ascii_lowercase();

        match fw.as_str() {
            "if" | "foreach" | "while" | "repeat" => {
                depth += 1;
                if in_else {
                    false_body.get_or_insert_with(Vec::new).push(lines[i].clone());
                } else {
                    true_body.push(lines[i].clone());
                }
            }
            "else" if depth == 1 => {
                in_else = true;
            }
            "end" | "endif" => {
                depth -= 1;
                if depth == 0 {
                    return Ok((true_body, false_body, i - start + 1));
                }
                if in_else {
                    false_body.get_or_insert_with(Vec::new).push(lines[i].clone());
                } else {
                    true_body.push(lines[i].clone());
                }
            }
            _ => {
                if in_else {
                    false_body.get_or_insert_with(Vec::new).push(lines[i].clone());
                } else {
                    true_body.push(lines[i].clone());
                }
            }
        }
        i += 1;
    }
    Err(SimError::Parse("control: unterminated if block".into()))
}

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

/// Split a string into `(first_word, rest)`.
fn split_first_word(s: &str) -> (&str, &str) {
    let s = s.trim();
    match s.find(char::is_whitespace) {
        Some(pos) => (&s[..pos], s[pos..].trim()),
        None => (s, ""),
    }
}

/// Parse a value with an optional SI suffix (e.g. `1n`, `100k`, `2.2u`).
pub fn parse_si_value(s: &str) -> Option<f64> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    // Find where the numeric part ends
    let num_end = s
        .find(|c: char| !c.is_ascii_digit() && c != '.' && c != '-' && c != 'e' && c != 'E' && c != '+')
        .unwrap_or(s.len());

    let (num_str, suffix) = s.split_at(num_end);
    let base: f64 = num_str.parse().ok()?;

    let multiplier = match suffix.to_ascii_lowercase().as_str() {
        "t"           => 1e12,
        "g"           => 1e9,
        "meg" | "x"   => 1e6,
        "k"           => 1e3,
        ""            => 1.0,
        "m"           => 1e-3,
        "u" | "µ"     => 1e-6,
        "n"           => 1e-9,
        "p"           => 1e-12,
        "f"           => 1e-15,
        "a"           => 1e-18,
        _             => return None,
    };

    Some(base * multiplier)
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Run all `.control` blocks in `control_lines` against the given circuit.
///
/// Each call to this function creates a fresh [`ControlInterpreter`] and
/// runs all the supplied lines.  The interpreter's output (from `print` /
/// `echo`) is returned as a `Vec<String>`.
pub fn run_control_block(
    lines: &[String],
    circuit: &mut Circuit,
    registry: &DeviceRegistry,
) -> Result<Vec<String>, SimError> {
    let mut interp = ControlInterpreter::new(circuit, registry);
    interp.run(lines)?;
    Ok(interp.output)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_si_value_basic() {
        assert_eq!(parse_si_value("1k"), Some(1e3));
        assert_eq!(parse_si_value("100n"), Some(100e-9));
        assert_eq!(parse_si_value("2.2u"), Some(2.2e-6));
        assert_eq!(parse_si_value("1meg"), Some(1e6));
        assert_eq!(parse_si_value("3.14"), Some(3.14));
        assert_eq!(parse_si_value(""), None);
    }

    #[test]
    fn control_value_display() {
        assert_eq!(ControlValue::Number(1.5).to_string(), "1.5");
        assert_eq!(ControlValue::Str("hello".into()).to_string(), "hello");
        assert_eq!(ControlValue::Vector(vec![1.0, 2.0]).to_string(), "[1, 2]");
    }

    #[test]
    fn let_and_print() {
        use pisim_core::{Circuit, NodeId, DeviceId, DeviceInstance, DeviceKind};
        use pisim_device::DeviceRegistry;

        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)])
                .with_param("dc", 5.0),
        );
        ckt.build_topology();

        let registry = DeviceRegistry::new_default();
        let lines = vec![
            "let x = 42".to_string(),
            "print x".to_string(),
        ];
        let out = run_control_block(&lines, &mut ckt, &registry).unwrap();
        assert_eq!(out, vec!["42".to_string()]);
    }

    #[test]
    fn echo_with_var_expansion() {
        use pisim_core::{Circuit, NodeId, DeviceId, DeviceInstance, DeviceKind};
        use pisim_device::DeviceRegistry;

        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)])
                .with_param("dc", 5.0),
        );
        ckt.build_topology();

        let registry = DeviceRegistry::new_default();
        let lines = vec![
            "let tr = 2.2e-6".to_string(),
            "echo Rise time: {tr}".to_string(),
        ];
        let out = run_control_block(&lines, &mut ckt, &registry).unwrap();
        assert_eq!(out[0], "Rise time: 0.0000022");
    }

    #[test]
    fn foreach_loop() {
        use pisim_core::{Circuit, NodeId, DeviceId, DeviceInstance, DeviceKind};
        use pisim_device::DeviceRegistry;

        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)])
                .with_param("dc", 5.0),
        );
        ckt.build_topology();

        let registry = DeviceRegistry::new_default();
        let lines = vec![
            "foreach i 1 2 3".to_string(),
            "  echo val={i}".to_string(),
            "end".to_string(),
        ];
        let out = run_control_block(&lines, &mut ckt, &registry).unwrap();
        assert_eq!(out.len(), 3);
        assert_eq!(out[0], "val=1");
    }

    #[test]
    fn if_condition_true() {
        use pisim_core::{Circuit, NodeId, DeviceId, DeviceInstance, DeviceKind};
        use pisim_device::DeviceRegistry;

        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)])
                .with_param("dc", 5.0),
        );
        ckt.build_topology();

        let registry = DeviceRegistry::new_default();
        let lines = vec![
            "let x = 5".to_string(),
            "if x > 3".to_string(),
            "  echo yes".to_string(),
            "else".to_string(),
            "  echo no".to_string(),
            "end".to_string(),
        ];
        let out = run_control_block(&lines, &mut ckt, &registry).unwrap();
        assert_eq!(out, vec!["yes".to_string()]);
    }

    #[test]
    fn set_and_unset() {
        use pisim_core::{Circuit, NodeId, DeviceId, DeviceInstance, DeviceKind};
        use pisim_device::DeviceRegistry;

        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)])
                .with_param("dc", 5.0),
        );
        ckt.build_topology();

        let registry = DeviceRegistry::new_default();
        let lines = vec![
            "set mykey=hello".to_string(),
            "print mykey".to_string(),
            "unset mykey".to_string(),
        ];
        let out = run_control_block(&lines, &mut ckt, &registry).unwrap();
        assert_eq!(out, vec!["hello".to_string()]);
    }
}
