//! Flat behavioral expression AST for B-source / E / G evaluation.
//!
//! This module is the **DOD-friendly** representation of the behavioral
//! expressions used by `B`, `E`, and `G` elements.  It is the device-side
//! counterpart of `incspice_core::BehavioralExpr` (which is a tree built with
//! `Box`).  The flat representation here:
//!
//! - Stores all nodes in a contiguous `Vec<ExprNode>` (struct-of-arrays
//!   spirit — one big allocation per expression instead of one per AST node).
//! - Uses a typed `ExprIdx(u32)` index instead of `Box<ExprNode>` references.
//! - Evaluates with a single bottom-up pass over the node array — no
//!   recursion, no virtual dispatch, branchless tight loop.
//! - Differentiates symbolically with reverse-mode forward AD that emits
//!   new nodes into the same arena.
//!
//! The flat AST supports the full feature set required by Phase 2.1 + 2.2:
//!
//! | Construct                       | `ExprNode` variant            |
//! | ------------------------------- | ----------------------------- |
//! | Numeric literal                 | `Lit(f64)`                    |
//! | `.PARAM` reference              | `Param(u32)`                  |
//! | `V(node)`                       | `NodeVoltage(u32)`            |
//! | `V(n1, n2)`                     | desugared to `Sub` of two NV  |
//! | `I(vname)`                      | `BranchCurrent(u32)`          |
//! | `time`                          | `Time`                        |
//! | `temper`                        | `Temper`                      |
//! | `frequency`                     | `Frequency`                   |
//! | `-x`                            | `Neg(ExprIdx)`                |
//! | `a + b`, `a - b`, `a * b`, `a / b`, `a ** b` | `Add/Sub/Mul/Div/Pow` |
//! | `sqrt`, `exp`, `log`/`ln`, `abs`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan` | `Func1` |
//! | `min`, `max`, `pow`, `atan2`    | `Func2`                       |
//! | `if(c, a, b)`                   | `If`                          |
//! | `TABLE {expr} = (x1,y1) ...`    | `Table { x: ExprIdx, points } |
//!
//! ## Memory layout
//!
//! `ExprAst` owns three flat vectors:
//!
//! - `nodes: Vec<ExprNode>` — the AST nodes themselves.
//! - `param_names: Vec<String>` — interned `.PARAM` names; nodes hold an index.
//! - `node_refs: Vec<String>` — interned `V(name)` references; nodes hold an
//!   index.  This is also the ordered list returned to the stamper for
//!   resolving solution voltages.
//! - `branch_refs: Vec<String>` — interned `I(vname)` references.
//! - `tables: Vec<Vec<(f64, f64)>>` — interpolation tables; nodes hold an
//!   index.
//!
//! The root of the expression is `nodes.last()` (the latest pushed).
//!
//! ## Why not use `incspice_core::BehavioralExpr`?
//!
//! `BehavioralExpr` is a tree of `Box<BehavioralExpr>` with `String` leaves.
//! Every recursive call allocates and chases a pointer; differentiation
//! produces another tree of boxes.  For Phase 2.1 we need a representation
//! that:
//!
//! 1. Does **no** allocation in the eval inner loop (the stamper calls
//!    `eval` once per device per Newton iteration).
//! 2. Is **trivially copyable** — `ExprIdx` is `u32`.
//! 3. Supports **branchless evaluation** — the eval loop is one `match` in a
//!    flat for-loop.
//! 4. Is **cache-friendly** — all nodes for one expression are contiguous.
//!
//! `BehavioralExpr` remains the parser/circuit transport.  Conversion happens
//! lazily via `ExprAst::from_behavioral`.

use incspice_core::{BehavioralBinOp, BehavioralExpr, SimError};
use smallvec::SmallVec;

/// Typed index into an `ExprAst`'s `nodes` array.
///
/// `u32` is plenty (4 billion AST nodes per expression — astronomically more
/// than any real circuit will ever produce).  Using a typed newtype catches
/// accidental misuse and keeps the indirection visible at call sites.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ExprIdx(pub u32);

impl ExprIdx {
    #[inline]
    pub fn get(self) -> usize {
        self.0 as usize
    }
}

/// Single-arg numeric function tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Func1Tag {
    Sqrt,
    Abs,
    Exp,
    Ln,
    Log10,
    Sin,
    Cos,
    Tan,
    Asin,
    Acos,
    Atan,
    Sign,
}

/// Two-arg numeric function tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Func2Tag {
    Min,
    Max,
    Pow,
    Atan2,
}

/// A single node in the flat behavioral AST.
///
/// All children are referenced by `ExprIdx` indices into the parent
/// `ExprAst`'s `nodes` array.  Sub-expressions always have a smaller index
/// than their parent (topological order), which makes evaluation a single
/// forward pass over the array.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ExprNode {
    /// Numeric literal.
    Lit(f64),
    /// `.PARAM` reference; the `u32` indexes into `param_names`.
    Param(u32),
    /// `V(node)` reference; the `u32` indexes into `node_refs`.
    NodeVoltage(u32),
    /// `I(vname)` branch-current reference; the `u32` indexes into
    /// `branch_refs`.
    BranchCurrent(u32),
    /// Built-in `time` variable.
    Time,
    /// Built-in `temper` (temperature in Celsius) variable.
    Temper,
    /// Built-in `frequency` variable (used in AC behavioral models).
    Frequency,
    /// Unary minus.
    Neg(ExprIdx),
    /// Binary `+`.
    Add(ExprIdx, ExprIdx),
    /// Binary `-`.
    Sub(ExprIdx, ExprIdx),
    /// Binary `*`.
    Mul(ExprIdx, ExprIdx),
    /// Binary `/`.
    Div(ExprIdx, ExprIdx),
    /// Binary `**` (or `pow`).
    Pow(ExprIdx, ExprIdx),
    /// One-argument intrinsic.
    Func1(Func1Tag, ExprIdx),
    /// Two-argument intrinsic.
    Func2(Func2Tag, ExprIdx, ExprIdx),
    /// Three-argument `if(cond, a, b)`.
    If(ExprIdx, ExprIdx, ExprIdx),
    /// Linear-interpolation table: `TABLE {x} = (x0,y0) (x1,y1) ...`.
    /// `x` is the input expression; `points_idx` indexes into `tables`.
    Table { x: ExprIdx, points_idx: u32 },
}

/// Context passed to `ExprAst::eval` so the eval loop can resolve external
/// references (node voltages, branch currents, parameters, time, temper,
/// frequency).
///
/// All slices are passed by borrow; `eval` performs no allocation.  The
/// `node_voltages` slice is indexed by the same order as `ExprAst::node_refs`
/// (i.e. `node_voltages[i]` is the value of `V(node_refs[i])`).
#[derive(Debug, Clone, Copy)]
pub struct EvalCtx<'a> {
    pub node_voltages: &'a [f64],
    pub branch_currents: &'a [f64],
    pub params: &'a [f64],
    pub time: f64,
    pub temper: f64,
    pub frequency: f64,
}

impl<'a> EvalCtx<'a> {
    /// Trivial DC context: zero time/temper/frequency, no branches/params.
    pub fn dc(node_voltages: &'a [f64]) -> Self {
        Self {
            node_voltages,
            branch_currents: &[],
            params: &[],
            time: 0.0,
            temper: 27.0,
            frequency: 0.0,
        }
    }
}

/// A flat behavioral expression AST.
///
/// All sub-expressions are interned into `nodes` in topological order: a
/// child node always has a smaller index than its parent.  This guarantees
/// that a single linear pass `for i in 0..nodes.len() { stack[i] = ... }`
/// computes every value bottom-up with no recursion and no virtual dispatch.
#[derive(Debug, Clone, Default)]
pub struct ExprAst {
    pub nodes: Vec<ExprNode>,
    pub param_names: Vec<String>,
    pub node_refs: Vec<String>,
    pub branch_refs: Vec<String>,
    pub tables: Vec<Vec<(f64, f64)>>,
}

impl ExprAst {
    /// Create an empty AST.
    pub fn new() -> Self {
        Self::default()
    }

    /// Index of the root node (always the last pushed).
    #[inline]
    pub fn root(&self) -> ExprIdx {
        debug_assert!(!self.nodes.is_empty(), "ExprAst has no root");
        ExprIdx((self.nodes.len() - 1) as u32)
    }

    /// Number of nodes in this AST.
    #[inline]
    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    /// Append a node and return its index.  The eval loop relies on the
    /// invariant that an `ExprIdx` always points to a node already in the
    /// arena, so all `push_*` helpers below produce sub-expression indices
    /// before calling this on the parent node.
    fn push(&mut self, node: ExprNode) -> ExprIdx {
        let idx = self.nodes.len() as u32;
        self.nodes.push(node);
        ExprIdx(idx)
    }

    fn intern_param(&mut self, name: &str) -> u32 {
        if let Some(i) = self.param_names.iter().position(|n| n == name) {
            return i as u32;
        }
        self.param_names.push(name.to_string());
        (self.param_names.len() - 1) as u32
    }

    fn intern_node(&mut self, name: &str) -> u32 {
        if let Some(i) = self.node_refs.iter().position(|n| n == name) {
            return i as u32;
        }
        self.node_refs.push(name.to_string());
        (self.node_refs.len() - 1) as u32
    }

    fn intern_branch(&mut self, name: &str) -> u32 {
        if let Some(i) = self.branch_refs.iter().position(|n| n == name) {
            return i as u32;
        }
        self.branch_refs.push(name.to_string());
        (self.branch_refs.len() - 1) as u32
    }

    /// Convert a tree-shaped `BehavioralExpr` (used by parser/circuit) into
    /// the flat representation.  Special-case markers used by the parser to
    /// smuggle non-standard constructs into the tree are decoded here:
    ///
    /// - `Param("__time__")` / `Param("__temper__")` / `Param("__frequency__")`
    ///   become `Time` / `Temper` / `Frequency` nodes.
    /// - `Func("__branch_current__", [Param(name)])` becomes `BranchCurrent`.
    /// - `Func("__table__", [x, x0, y0, x1, y1, ...])` becomes a `Table` node.
    pub fn from_behavioral(expr: &BehavioralExpr) -> Result<Self, SimError> {
        let mut ast = Self::new();
        ast.lower(expr)?;
        Ok(ast)
    }

    fn lower(&mut self, expr: &BehavioralExpr) -> Result<ExprIdx, SimError> {
        match expr {
            BehavioralExpr::Lit(v) => Ok(self.push(ExprNode::Lit(*v))),
            BehavioralExpr::Param(name) => match name.as_str() {
                "__time__" | "time" => Ok(self.push(ExprNode::Time)),
                "__temper__" | "temper" => Ok(self.push(ExprNode::Temper)),
                "__frequency__" | "frequency" => Ok(self.push(ExprNode::Frequency)),
                _ => {
                    let idx = self.intern_param(name);
                    Ok(self.push(ExprNode::Param(idx)))
                }
            },
            BehavioralExpr::NodeVoltage(name) => {
                let idx = self.intern_node(name);
                Ok(self.push(ExprNode::NodeVoltage(idx)))
            }
            BehavioralExpr::Neg(inner) => {
                let i = self.lower(inner)?;
                Ok(self.push(ExprNode::Neg(i)))
            }
            BehavioralExpr::BinOp(op, l, r) => {
                let li = self.lower(l)?;
                let ri = self.lower(r)?;
                let node = match op {
                    BehavioralBinOp::Add => ExprNode::Add(li, ri),
                    BehavioralBinOp::Sub => ExprNode::Sub(li, ri),
                    BehavioralBinOp::Mul => ExprNode::Mul(li, ri),
                    BehavioralBinOp::Div => ExprNode::Div(li, ri),
                    BehavioralBinOp::Pow => ExprNode::Pow(li, ri),
                };
                Ok(self.push(node))
            }
            BehavioralExpr::Func(name, args) => self.lower_func(name, args),
        }
    }

    fn lower_func(&mut self, name: &str, args: &[BehavioralExpr]) -> Result<ExprIdx, SimError> {
        // Marker functions used by the parser to smuggle in non-standard
        // constructs.
        match name {
            "__branch_current__" => {
                // Form: __branch_current__(name)  where name is Param.
                if args.len() != 1 {
                    return Err(SimError::Parse(
                        "B-source: I(...) expects exactly one argument".into(),
                    ));
                }
                if let BehavioralExpr::Param(vname) = &args[0] {
                    let idx = self.intern_branch(vname);
                    return Ok(self.push(ExprNode::BranchCurrent(idx)));
                }
                return Err(SimError::Parse(
                    "B-source: I(...) argument must be a voltage source name".into(),
                ));
            }
            "__table__" => {
                // Form: __table__(x, x0, y0, x1, y1, ...)
                if args.is_empty() || args.len() % 2 == 0 {
                    return Err(SimError::Parse(
                        "B-source: TABLE expects (x, then odd count of breakpoint coords)".into(),
                    ));
                }
                let x_idx = self.lower(&args[0])?;
                // Decode literal pairs into a points vec.
                let mut points: Vec<(f64, f64)> = Vec::with_capacity((args.len() - 1) / 2);
                let mut i = 1usize;
                while i + 1 < args.len() {
                    let x = match &args[i] {
                        BehavioralExpr::Lit(v) => *v,
                        BehavioralExpr::Neg(inner) => {
                            if let BehavioralExpr::Lit(v) = inner.as_ref() {
                                -*v
                            } else {
                                return Err(SimError::Parse(
                                    "TABLE: breakpoint X must be a literal".into(),
                                ));
                            }
                        }
                        _ => {
                            return Err(SimError::Parse(
                                "TABLE: breakpoint X must be a literal".into(),
                            ));
                        }
                    };
                    let y = match &args[i + 1] {
                        BehavioralExpr::Lit(v) => *v,
                        BehavioralExpr::Neg(inner) => {
                            if let BehavioralExpr::Lit(v) = inner.as_ref() {
                                -*v
                            } else {
                                return Err(SimError::Parse(
                                    "TABLE: breakpoint Y must be a literal".into(),
                                ));
                            }
                        }
                        _ => {
                            return Err(SimError::Parse(
                                "TABLE: breakpoint Y must be a literal".into(),
                            ));
                        }
                    };
                    points.push((x, y));
                    i += 2;
                }
                // Sort breakpoints by X for safe binary search interpolation.
                points.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
                let table_idx = self.tables.len() as u32;
                self.tables.push(points);
                return Ok(self.push(ExprNode::Table {
                    x: x_idx,
                    points_idx: table_idx,
                }));
            }
            _ => {}
        }

        // Standard intrinsics.
        match (name, args.len()) {
            ("sqrt", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Sqrt, a)))
            }
            ("abs", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Abs, a)))
            }
            ("exp", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Exp, a)))
            }
            ("log" | "ln", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Ln, a)))
            }
            ("log10", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Log10, a)))
            }
            ("sin", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Sin, a)))
            }
            ("cos", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Cos, a)))
            }
            ("tan", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Tan, a)))
            }
            ("asin", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Asin, a)))
            }
            ("acos", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Acos, a)))
            }
            ("atan", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Atan, a)))
            }
            ("sign", 1) => {
                let a = self.lower(&args[0])?;
                Ok(self.push(ExprNode::Func1(Func1Tag::Sign, a)))
            }
            ("min", 2) => {
                let a = self.lower(&args[0])?;
                let b = self.lower(&args[1])?;
                Ok(self.push(ExprNode::Func2(Func2Tag::Min, a, b)))
            }
            ("max", 2) => {
                let a = self.lower(&args[0])?;
                let b = self.lower(&args[1])?;
                Ok(self.push(ExprNode::Func2(Func2Tag::Max, a, b)))
            }
            ("pow", 2) => {
                let a = self.lower(&args[0])?;
                let b = self.lower(&args[1])?;
                Ok(self.push(ExprNode::Func2(Func2Tag::Pow, a, b)))
            }
            ("atan2", 2) => {
                let a = self.lower(&args[0])?;
                let b = self.lower(&args[1])?;
                Ok(self.push(ExprNode::Func2(Func2Tag::Atan2, a, b)))
            }
            ("if", 3) => {
                let c = self.lower(&args[0])?;
                let t = self.lower(&args[1])?;
                let e = self.lower(&args[2])?;
                Ok(self.push(ExprNode::If(c, t, e)))
            }
            (other, n) => Err(SimError::Parse(format!(
                "B-source: unknown function '{other}' with {n} arguments"
            ))),
        }
    }

    /// Evaluate the expression at the given context.
    ///
    /// Single linear pass over `nodes`; each node reads from `stack[child.0]`
    /// (always already populated because of topological order) and writes its
    /// own value to `stack[i]`.  Returns the root's value.
    pub fn eval(&self, ctx: &EvalCtx<'_>) -> Result<f64, SimError> {
        // Stack-allocated for small expressions; spills to heap for huge ones.
        let mut stack: SmallVec<[f64; 64]> = SmallVec::with_capacity(self.nodes.len());
        for node in &self.nodes {
            let v = match *node {
                ExprNode::Lit(v) => v,
                ExprNode::Param(i) => *ctx.params.get(i as usize).ok_or_else(|| {
                    SimError::Parse(format!(
                        "B-source: parameter '{}' not provided",
                        self.param_names[i as usize]
                    ))
                })?,
                ExprNode::NodeVoltage(i) => {
                    *ctx.node_voltages.get(i as usize).ok_or_else(|| {
                        SimError::Parse(format!(
                            "B-source: node voltage V({}) not provided",
                            self.node_refs[i as usize]
                        ))
                    })?
                }
                ExprNode::BranchCurrent(i) => {
                    *ctx.branch_currents.get(i as usize).ok_or_else(|| {
                        SimError::Parse(format!(
                            "B-source: branch current I({}) not provided",
                            self.branch_refs[i as usize]
                        ))
                    })?
                }
                ExprNode::Time => ctx.time,
                ExprNode::Temper => ctx.temper,
                ExprNode::Frequency => ctx.frequency,
                ExprNode::Neg(a) => -stack[a.get()],
                ExprNode::Add(a, b) => stack[a.get()] + stack[b.get()],
                ExprNode::Sub(a, b) => stack[a.get()] - stack[b.get()],
                ExprNode::Mul(a, b) => stack[a.get()] * stack[b.get()],
                ExprNode::Div(a, b) => {
                    let r = stack[b.get()];
                    if r == 0.0 {
                        return Err(SimError::Parse(
                            "B-source: division by zero in expression".into(),
                        ));
                    }
                    stack[a.get()] / r
                }
                ExprNode::Pow(a, b) => stack[a.get()].powf(stack[b.get()]),
                ExprNode::Func1(tag, a) => {
                    let x = stack[a.get()];
                    match tag {
                        Func1Tag::Sqrt => x.sqrt(),
                        Func1Tag::Abs => x.abs(),
                        Func1Tag::Exp => x.exp(),
                        Func1Tag::Ln => x.ln(),
                        Func1Tag::Log10 => x.log10(),
                        Func1Tag::Sin => x.sin(),
                        Func1Tag::Cos => x.cos(),
                        Func1Tag::Tan => x.tan(),
                        Func1Tag::Asin => x.asin(),
                        Func1Tag::Acos => x.acos(),
                        Func1Tag::Atan => x.atan(),
                        Func1Tag::Sign => x.signum(),
                    }
                }
                ExprNode::Func2(tag, a, b) => {
                    let x = stack[a.get()];
                    let y = stack[b.get()];
                    match tag {
                        Func2Tag::Min => x.min(y),
                        Func2Tag::Max => x.max(y),
                        Func2Tag::Pow => x.powf(y),
                        Func2Tag::Atan2 => x.atan2(y),
                    }
                }
                ExprNode::If(c, t, e) => {
                    if stack[c.get()] != 0.0 {
                        stack[t.get()]
                    } else {
                        stack[e.get()]
                    }
                }
                ExprNode::Table { x, points_idx } => {
                    let xv = stack[x.get()];
                    table_lookup(&self.tables[points_idx as usize], xv)
                }
            };
            stack.push(v);
        }
        Ok(*stack.last().expect("ExprAst::eval on empty AST"))
    }

    /// Evaluate the partial derivative of the expression with respect to the
    /// node-voltage referenced by `var_node` (must be one of `self.node_refs`).
    ///
    /// Implementation: forward-mode AD over the same flat array.  We compute,
    /// in lockstep with the eval pass, both the value `v[i]` and the partial
    /// `d[i] = ∂v[i]/∂V(var_node)` for every node.  This is much cheaper than
    /// constructing a separate derivative AST and re-evaluating it: a single
    /// pass over `nodes` produces the partial directly.
    ///
    /// Non-differentiable nodes (`min`, `max`, `if`, `sign`, `Table`) treat
    /// their derivative as 0 — a valid but sub-optimal approximation.  Users
    /// who care should provide a smooth analytic equivalent.
    pub fn partial(&self, ctx: &EvalCtx<'_>, var_node: &str) -> Result<f64, SimError> {
        let var_idx = match self.node_refs.iter().position(|n| n == var_node) {
            Some(i) => i,
            // Variable not referenced — partial is identically 0.
            None => return Ok(0.0),
        };

        let mut v: SmallVec<[f64; 64]> = SmallVec::with_capacity(self.nodes.len());
        let mut d: SmallVec<[f64; 64]> = SmallVec::with_capacity(self.nodes.len());

        for node in &self.nodes {
            let (vi, di) = match *node {
                ExprNode::Lit(c) => (c, 0.0),
                ExprNode::Param(i) => (
                    *ctx.params.get(i as usize).ok_or_else(|| {
                        SimError::Parse(format!(
                            "B-source: parameter '{}' not provided",
                            self.param_names[i as usize]
                        ))
                    })?,
                    0.0,
                ),
                ExprNode::NodeVoltage(i) => {
                    let val = *ctx.node_voltages.get(i as usize).ok_or_else(|| {
                        SimError::Parse(format!(
                            "B-source: node voltage V({}) not provided",
                            self.node_refs[i as usize]
                        ))
                    })?;
                    let deriv = if i as usize == var_idx { 1.0 } else { 0.0 };
                    (val, deriv)
                }
                ExprNode::BranchCurrent(i) => (
                    *ctx.branch_currents.get(i as usize).ok_or_else(|| {
                        SimError::Parse(format!(
                            "B-source: branch current I({}) not provided",
                            self.branch_refs[i as usize]
                        ))
                    })?,
                    0.0,
                ),
                ExprNode::Time => (ctx.time, 0.0),
                ExprNode::Temper => (ctx.temper, 0.0),
                ExprNode::Frequency => (ctx.frequency, 0.0),
                ExprNode::Neg(a) => (-v[a.get()], -d[a.get()]),
                ExprNode::Add(a, b) => (v[a.get()] + v[b.get()], d[a.get()] + d[b.get()]),
                ExprNode::Sub(a, b) => (v[a.get()] - v[b.get()], d[a.get()] - d[b.get()]),
                ExprNode::Mul(a, b) => (
                    v[a.get()] * v[b.get()],
                    d[a.get()] * v[b.get()] + v[a.get()] * d[b.get()],
                ),
                ExprNode::Div(a, b) => {
                    let bv = v[b.get()];
                    if bv == 0.0 {
                        return Err(SimError::Parse(
                            "B-source: division by zero in derivative".into(),
                        ));
                    }
                    (
                        v[a.get()] / bv,
                        (d[a.get()] * bv - v[a.get()] * d[b.get()]) / (bv * bv),
                    )
                }
                ExprNode::Pow(a, b) => {
                    // d(u^v) general:
                    //   = u^v * (v' * ln(u) + v * u'/u)
                    // For the common case where v is constant (v' = 0):
                    //   = v * u^(v-1) * u'
                    let uv = v[a.get()];
                    let vv = v[b.get()];
                    let up = d[a.get()];
                    let vp = d[b.get()];
                    let val = uv.powf(vv);
                    let deriv = if vp == 0.0 {
                        // Pure constant exponent — avoid log(u) which may NaN.
                        vv * uv.powf(vv - 1.0) * up
                    } else if uv > 0.0 {
                        val * (vp * uv.ln() + vv * up / uv)
                    } else {
                        // u <= 0 with non-constant exponent — derivative undefined; return 0.
                        0.0
                    };
                    (val, deriv)
                }
                ExprNode::Func1(tag, a) => {
                    let x = v[a.get()];
                    let dx = d[a.get()];
                    let (val, deriv) = match tag {
                        Func1Tag::Sqrt => {
                            let s = x.sqrt();
                            (s, if s != 0.0 { dx / (2.0 * s) } else { 0.0 })
                        }
                        Func1Tag::Abs => (x.abs(), x.signum() * dx),
                        Func1Tag::Exp => {
                            let e = x.exp();
                            (e, e * dx)
                        }
                        Func1Tag::Ln => {
                            if x == 0.0 {
                                return Err(SimError::Parse(
                                    "B-source: ln(0) in derivative".into(),
                                ));
                            }
                            (x.ln(), dx / x)
                        }
                        Func1Tag::Log10 => {
                            if x == 0.0 {
                                return Err(SimError::Parse(
                                    "B-source: log10(0) in derivative".into(),
                                ));
                            }
                            (x.log10(), dx / (x * std::f64::consts::LN_10))
                        }
                        Func1Tag::Sin => (x.sin(), x.cos() * dx),
                        Func1Tag::Cos => (x.cos(), -x.sin() * dx),
                        Func1Tag::Tan => {
                            let c = x.cos();
                            (x.tan(), if c != 0.0 { dx / (c * c) } else { 0.0 })
                        }
                        Func1Tag::Asin => {
                            let denom = (1.0 - x * x).sqrt();
                            (x.asin(), if denom != 0.0 { dx / denom } else { 0.0 })
                        }
                        Func1Tag::Acos => {
                            let denom = (1.0 - x * x).sqrt();
                            (x.acos(), if denom != 0.0 { -dx / denom } else { 0.0 })
                        }
                        Func1Tag::Atan => (x.atan(), dx / (1.0 + x * x)),
                        Func1Tag::Sign => (x.signum(), 0.0),
                    };
                    (val, deriv)
                }
                ExprNode::Func2(tag, a, b) => {
                    let x = v[a.get()];
                    let y = v[b.get()];
                    let dx = d[a.get()];
                    let dy = d[b.get()];
                    let (val, deriv) = match tag {
                        Func2Tag::Min => {
                            let v = x.min(y);
                            (v, if x <= y { dx } else { dy })
                        }
                        Func2Tag::Max => {
                            let v = x.max(y);
                            (v, if x >= y { dx } else { dy })
                        }
                        Func2Tag::Pow => {
                            let val = x.powf(y);
                            let deriv = if dy == 0.0 {
                                y * x.powf(y - 1.0) * dx
                            } else if x > 0.0 {
                                val * (dy * x.ln() + y * dx / x)
                            } else {
                                0.0
                            };
                            (val, deriv)
                        }
                        Func2Tag::Atan2 => {
                            let val = x.atan2(y);
                            // d(atan2(x,y))/dt = (y*dx - x*dy)/(x^2+y^2)
                            let denom = x * x + y * y;
                            let deriv = if denom != 0.0 {
                                (y * dx - x * dy) / denom
                            } else {
                                0.0
                            };
                            (val, deriv)
                        }
                    };
                    (val, deriv)
                }
                ExprNode::If(c, t, e) => {
                    let val = if v[c.get()] != 0.0 {
                        v[t.get()]
                    } else {
                        v[e.get()]
                    };
                    let deriv = if v[c.get()] != 0.0 {
                        d[t.get()]
                    } else {
                        d[e.get()]
                    };
                    (val, deriv)
                }
                ExprNode::Table { x, points_idx } => {
                    let xv = v[x.get()];
                    let dxv = d[x.get()];
                    let pts = &self.tables[points_idx as usize];
                    let val = table_lookup(pts, xv);
                    let slope = table_slope(pts, xv);
                    (val, slope * dxv)
                }
            };
            v.push(vi);
            d.push(di);
        }
        Ok(*d.last().expect("ExprAst::partial on empty AST"))
    }
}

/// Linear interpolation between sorted breakpoints.  Outside the table the
/// value is clamped to the nearest endpoint (consistent with ngspice / hspice).
pub fn table_lookup(points: &[(f64, f64)], x: f64) -> f64 {
    if points.is_empty() {
        return 0.0;
    }
    if x <= points[0].0 {
        return points[0].1;
    }
    if x >= points[points.len() - 1].0 {
        return points[points.len() - 1].1;
    }
    // Binary search for the interval containing x.
    let i = match points
        .binary_search_by(|p| p.0.partial_cmp(&x).unwrap_or(std::cmp::Ordering::Equal))
    {
        Ok(i) => return points[i].1,
        Err(i) => i,
    };
    // i is the index of the first point with X > x; interpolate (i-1, i).
    let (x0, y0) = points[i - 1];
    let (x1, y1) = points[i];
    let t = (x - x0) / (x1 - x0);
    y0 + t * (y1 - y0)
}

/// Slope dy/dx at the position `x` for a piecewise-linear table.  Outside
/// the table the slope is zero (clamped extrapolation).
pub fn table_slope(points: &[(f64, f64)], x: f64) -> f64 {
    if points.len() < 2 {
        return 0.0;
    }
    if x <= points[0].0 || x >= points[points.len() - 1].0 {
        return 0.0;
    }
    let i = match points
        .binary_search_by(|p| p.0.partial_cmp(&x).unwrap_or(std::cmp::Ordering::Equal))
    {
        Ok(i) => {
            // On a knot — use the right-hand slope.
            if i + 1 < points.len() {
                let (x0, y0) = points[i];
                let (x1, y1) = points[i + 1];
                return (y1 - y0) / (x1 - x0);
            }
            return 0.0;
        }
        Err(i) => i,
    };
    let (x0, y0) = points[i - 1];
    let (x1, y1) = points[i];
    (y1 - y0) / (x1 - x0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{BehavioralBinOp, BehavioralExpr};

    fn lit(v: f64) -> BehavioralExpr {
        BehavioralExpr::Lit(v)
    }
    fn nv(name: &str) -> BehavioralExpr {
        BehavioralExpr::NodeVoltage(name.into())
    }
    fn add(a: BehavioralExpr, b: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::BinOp(BehavioralBinOp::Add, Box::new(a), Box::new(b))
    }
    fn mul(a: BehavioralExpr, b: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::BinOp(BehavioralBinOp::Mul, Box::new(a), Box::new(b))
    }
    fn pow(a: BehavioralExpr, b: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::BinOp(BehavioralBinOp::Pow, Box::new(a), Box::new(b))
    }
    fn func1(name: &str, a: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::Func(name.into(), vec![a])
    }

    fn ctx(node_voltages: &[f64]) -> EvalCtx<'_> {
        EvalCtx {
            node_voltages,
            branch_currents: &[],
            params: &[],
            time: 0.0,
            temper: 27.0,
            frequency: 0.0,
        }
    }

    #[test]
    fn lit_eval() {
        let ast = ExprAst::from_behavioral(&lit(3.14)).unwrap();
        assert!((ast.eval(&ctx(&[])).unwrap() - 3.14).abs() < 1e-15);
    }

    #[test]
    fn node_voltage_eval() {
        let ast = ExprAst::from_behavioral(&nv("a")).unwrap();
        assert_eq!(ast.node_refs, vec!["a"]);
        let v = ast.eval(&ctx(&[2.5])).unwrap();
        assert!((v - 2.5).abs() < 1e-15);
    }

    #[test]
    fn add_two_nodes() {
        let ast = ExprAst::from_behavioral(&add(nv("a"), nv("b"))).unwrap();
        assert_eq!(ast.node_refs, vec!["a", "b"]);
        let v = ast.eval(&ctx(&[3.0, 4.0])).unwrap();
        assert!((v - 7.0).abs() < 1e-15);
    }

    #[test]
    fn mul_partial() {
        // V(a)*V(b)  ->  d/dV(a) = V(b)
        let ast = ExprAst::from_behavioral(&mul(nv("a"), nv("b"))).unwrap();
        let p = ast.partial(&ctx(&[3.0, 4.0]), "a").unwrap();
        assert!((p - 4.0).abs() < 1e-12);
        let p = ast.partial(&ctx(&[3.0, 4.0]), "b").unwrap();
        assert!((p - 3.0).abs() < 1e-12);
    }

    #[test]
    fn pow_partial_constant_exponent() {
        // V(x)^2 -> d/dV(x) = 2*V(x)
        let ast = ExprAst::from_behavioral(&pow(nv("x"), lit(2.0))).unwrap();
        let p = ast.partial(&ctx(&[3.0]), "x").unwrap();
        assert!((p - 6.0).abs() < 1e-10);
    }

    #[test]
    fn sqrt_partial() {
        // sqrt(V(x))  ->  d/dV(x) = 1/(2 sqrt(V(x)))
        let ast = ExprAst::from_behavioral(&func1("sqrt", nv("x"))).unwrap();
        let p = ast.partial(&ctx(&[4.0]), "x").unwrap();
        assert!((p - 0.25).abs() < 1e-12, "p={p}");
    }

    #[test]
    fn exp_partial() {
        // exp(V(x))  ->  d/dV(x) = exp(V(x))
        let ast = ExprAst::from_behavioral(&func1("exp", nv("x"))).unwrap();
        let p = ast.partial(&ctx(&[1.0]), "x").unwrap();
        assert!((p - std::f64::consts::E).abs() < 1e-10, "p={p}");
    }

    #[test]
    fn time_node_evaluates() {
        let mut ast = ExprAst::new();
        let _ = ast.push(ExprNode::Time);
        let mut c = ctx(&[]);
        c.time = 1e-3;
        let v = ast.eval(&c).unwrap();
        assert_eq!(v, 1e-3);
    }

    #[test]
    fn unknown_func_rejected() {
        let bad = BehavioralExpr::Func("bogus".into(), vec![lit(1.0)]);
        assert!(ExprAst::from_behavioral(&bad).is_err());
    }

    #[test]
    fn table_lookup_clamps_outside() {
        let pts = vec![(0.0, 0.0), (1.0, 10.0), (2.0, 20.0)];
        assert_eq!(table_lookup(&pts, -5.0), 0.0);
        assert_eq!(table_lookup(&pts, 0.5), 5.0);
        assert_eq!(table_lookup(&pts, 1.5), 15.0);
        assert_eq!(table_lookup(&pts, 99.0), 20.0);
    }

    #[test]
    fn table_node_eval_and_partial() {
        // TABLE {V(x)} = (0,0) (1,2) (2,4)  → slope 2 inside
        let bx = BehavioralExpr::Func(
            "__table__".into(),
            vec![
                nv("x"),
                lit(0.0),
                lit(0.0),
                lit(1.0),
                lit(2.0),
                lit(2.0),
                lit(4.0),
            ],
        );
        let ast = ExprAst::from_behavioral(&bx).unwrap();
        let v = ast.eval(&ctx(&[0.5])).unwrap();
        assert!((v - 1.0).abs() < 1e-12, "expected 1.0 at x=0.5, got {v}");
        let dp = ast.partial(&ctx(&[0.5]), "x").unwrap();
        assert!((dp - 2.0).abs() < 1e-12, "expected slope 2, got {dp}");
    }

    #[test]
    fn branch_current_lower() {
        let bx = BehavioralExpr::Func(
            "__branch_current__".into(),
            vec![BehavioralExpr::Param("Vmon".into())],
        );
        let ast = ExprAst::from_behavioral(&bx).unwrap();
        assert_eq!(ast.branch_refs, vec!["Vmon"]);
        let mut c = ctx(&[]);
        c.branch_currents = &[0.123];
        let v = ast.eval(&c).unwrap();
        assert!((v - 0.123).abs() < 1e-15);
    }

    /// Finite-difference cross-check for a non-trivial expression.
    #[test]
    fn fd_crosscheck_nonlinear() {
        // f = sin(V(a)) * V(b)^2
        let expr = mul(func1("sin", nv("a")), pow(nv("b"), lit(2.0)));
        let ast = ExprAst::from_behavioral(&expr).unwrap();

        let h = 1e-6;
        // FD ∂f/∂V(a) at V(a)=0.3, V(b)=2.0
        let f = |a: f64, b: f64| (a.sin()) * b.powi(2);
        let fd_a = (f(0.3 + h, 2.0) - f(0.3 - h, 2.0)) / (2.0 * h);
        let fd_b = (f(0.3, 2.0 + h) - f(0.3, 2.0 - h)) / (2.0 * h);
        let pa = ast.partial(&ctx(&[0.3, 2.0]), "a").unwrap();
        let pb = ast.partial(&ctx(&[0.3, 2.0]), "b").unwrap();
        assert!((pa - fd_a).abs() < 1e-7, "∂/∂a sym={pa}, fd={fd_a}");
        assert!((pb - fd_b).abs() < 1e-7, "∂/∂b sym={pb}, fd={fd_b}");
    }
}
