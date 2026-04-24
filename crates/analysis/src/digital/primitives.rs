//! Native digital primitives — combinational and sequential.
//!
//! All primitives are stored in a single SoA `PrimitiveBlock`:
//!
//! ```text
//!   kinds   : Vec<PrimitiveKind>     // dispatch tag (1 byte each)
//!   inputs  : Vec<SmallVec<[DigNodeIdx; 4]>>
//!   outputs : Vec<DigNodeIdx>
//!   delays  : Vec<f64>
//!   memory  : Vec<DigState>          // per-primitive 1-state hot scratch
//! ```
//!
//! Dispatch is a flat `match` on `PrimitiveKind` — no vtables, no boxing.  The
//! eval function reads the current value of each input from a node-state slice
//! and either returns a single `DigState` (for combinational gates) or a
//! `(DigState, bool)` tuple (for sequential gates that report whether their
//! output actually changed).

use super::event_queue::DigNodeIdx;
use super::state::{DigState, Level, Strength};
use smallvec::{SmallVec, smallvec};

/// Edge-trigger polarity for sequential primitives (DFF, etc.).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EdgeKind {
    Rising = 0,
    Falling = 1,
}

/// Discriminant tag for the SoA primitive block.  Branchless dispatch via
/// `match`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PrimitiveKind {
    // Combinational
    Buf = 0,
    Not = 1,
    And = 2,
    Nand = 3,
    Or = 4,
    Nor = 5,
    Xor = 6,
    Xnor = 7,
    Mux2 = 8,
    Mux4 = 9,
    Demux2 = 10,
    Demux4 = 11,
    // Sequential
    DLatch = 12,
    DFlipFlop = 13,
    // Sources (no inputs; driven by an external schedule)
    DPulse = 14,
    DSource = 15,
    // State machine — minimal placeholder; the user supplies a transition
    // function in `memory_state`.  Hooked through `Primitive::new_state`.
    DState = 16,
}

/// A single primitive instance — *cold* fields used at construction time.
///
/// The hot path uses `PrimitiveBlock` directly so this struct never lives in
/// a tight loop; it's just a builder result.
#[derive(Debug, Clone)]
pub struct Primitive {
    pub kind: PrimitiveKind,
    pub inputs: SmallVec<[DigNodeIdx; 4]>,
    pub outputs: SmallVec<[DigNodeIdx; 4]>,
    /// Rise propagation delay: 0→1 transition delay [s].
    pub rise_delay: f64,
    /// Fall propagation delay: 1→0 transition delay [s].
    pub fall_delay: f64,
    pub edge: EdgeKind,
}

impl Primitive {
    /// Build a generic combinational gate with symmetric rise/fall delay.
    pub fn new_comb(
        kind: PrimitiveKind,
        inputs: &[DigNodeIdx],
        output: DigNodeIdx,
        delay: f64,
    ) -> Self {
        let outs: SmallVec<[DigNodeIdx; 4]> = smallvec![output];
        Self {
            kind,
            inputs: SmallVec::from_slice(inputs),
            outputs: outs,
            rise_delay: delay,
            fall_delay: delay,
            edge: EdgeKind::Rising,
        }
    }

    /// Build a generic combinational gate with separate rise and fall delays.
    pub fn new_comb_asym(
        kind: PrimitiveKind,
        inputs: &[DigNodeIdx],
        output: DigNodeIdx,
        rise_delay: f64,
        fall_delay: f64,
    ) -> Self {
        let outs: SmallVec<[DigNodeIdx; 4]> = smallvec![output];
        Self {
            kind,
            inputs: SmallVec::from_slice(inputs),
            outputs: outs,
            rise_delay,
            fall_delay,
            edge: EdgeKind::Rising,
        }
    }

    /// Build a D flip-flop: inputs = [d, clk], output = q.
    pub fn new_dff(
        d: DigNodeIdx,
        clk: DigNodeIdx,
        q: DigNodeIdx,
        delay: f64,
        edge: EdgeKind,
    ) -> Self {
        Self {
            kind: PrimitiveKind::DFlipFlop,
            inputs: smallvec![d, clk],
            outputs: smallvec![q],
            rise_delay: delay,
            fall_delay: delay,
            edge,
        }
    }

    /// Build a D latch: inputs = [d, gate], output = q.  Transparent when gate=1.
    pub fn new_dlatch(d: DigNodeIdx, gate: DigNodeIdx, q: DigNodeIdx, delay: f64) -> Self {
        Self {
            kind: PrimitiveKind::DLatch,
            inputs: smallvec![d, gate],
            outputs: smallvec![q],
            rise_delay: delay,
            fall_delay: delay,
            edge: EdgeKind::Rising,
        }
    }

    /// Build a 2:1 mux: inputs = [s, a, b], output = y.
    pub fn new_mux2(
        sel: DigNodeIdx,
        a: DigNodeIdx,
        b: DigNodeIdx,
        y: DigNodeIdx,
        delay: f64,
    ) -> Self {
        Self {
            kind: PrimitiveKind::Mux2,
            inputs: smallvec![sel, a, b],
            outputs: smallvec![y],
            rise_delay: delay,
            fall_delay: delay,
            edge: EdgeKind::Rising,
        }
    }

    /// Build a 4:1 mux: inputs = [s0, s1, a, b, c, d], output = y.
    pub fn new_mux4(
        s0: DigNodeIdx,
        s1: DigNodeIdx,
        a: DigNodeIdx,
        b: DigNodeIdx,
        c: DigNodeIdx,
        d: DigNodeIdx,
        y: DigNodeIdx,
        delay: f64,
    ) -> Self {
        let mut inputs: SmallVec<[DigNodeIdx; 4]> = SmallVec::new();
        inputs.extend_from_slice(&[s0, s1, a, b, c, d]);
        Self {
            kind: PrimitiveKind::Mux4,
            inputs,
            outputs: smallvec![y],
            rise_delay: delay,
            fall_delay: delay,
            edge: EdgeKind::Rising,
        }
    }

    /// Build a 1:2 demux: inputs = [s, d], outputs = [y0, y1].
    pub fn new_demux2(
        sel: DigNodeIdx,
        data: DigNodeIdx,
        y0: DigNodeIdx,
        y1: DigNodeIdx,
        delay: f64,
    ) -> Self {
        Self {
            kind: PrimitiveKind::Demux2,
            inputs: smallvec![sel, data],
            outputs: smallvec![y0, y1],
            rise_delay: delay,
            fall_delay: delay,
            edge: EdgeKind::Rising,
        }
    }

    /// Build a 1:4 demux: inputs = [s0, s1, d], outputs = [y0..y3].
    pub fn new_demux4(
        s0: DigNodeIdx,
        s1: DigNodeIdx,
        data: DigNodeIdx,
        ys: [DigNodeIdx; 4],
        delay: f64,
    ) -> Self {
        let mut outs: SmallVec<[DigNodeIdx; 4]> = SmallVec::new();
        outs.extend_from_slice(&ys);
        Self {
            kind: PrimitiveKind::Demux4,
            inputs: smallvec![s0, s1, data],
            outputs: outs,
            rise_delay: delay,
            fall_delay: delay,
            edge: EdgeKind::Rising,
        }
    }

    /// Build a clock pulse source.  No inputs.  `delay` is the period (one
    /// cycle = high half + low half).
    pub fn new_pulse(out: DigNodeIdx, period: f64) -> Self {
        Self {
            kind: PrimitiveKind::DPulse,
            inputs: SmallVec::new(),
            outputs: smallvec![out],
            rise_delay: period,
            fall_delay: period,
            edge: EdgeKind::Rising,
        }
    }

    /// Build a `d_source` — values are externally scheduled into the queue.
    pub fn new_source(out: DigNodeIdx) -> Self {
        Self {
            kind: PrimitiveKind::DSource,
            inputs: SmallVec::new(),
            outputs: smallvec![out],
            rise_delay: 0.0,
            fall_delay: 0.0,
            edge: EdgeKind::Rising,
        }
    }
}

/// SoA storage for a population of primitives.
///
/// Hot loops index by primitive id and read parallel slices.
pub struct PrimitiveBlock {
    pub kinds: Vec<PrimitiveKind>,
    pub inputs: Vec<SmallVec<[DigNodeIdx; 4]>>,
    pub outputs: Vec<SmallVec<[DigNodeIdx; 4]>>,
    /// Rise delay: 0→1 transition propagation delay [s].
    pub rise_delays: Vec<f64>,
    /// Fall delay: 1→0 transition propagation delay [s].
    pub fall_delays: Vec<f64>,
    pub edges: Vec<EdgeKind>,
    /// Per-primitive scratch state (e.g. last clock value for DFF edge detect,
    /// stored Q for DLatch).
    pub memory: Vec<DigState>,
}

impl PrimitiveBlock {
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            kinds: Vec::with_capacity(cap),
            inputs: Vec::with_capacity(cap),
            outputs: Vec::with_capacity(cap),
            rise_delays: Vec::with_capacity(cap),
            fall_delays: Vec::with_capacity(cap),
            edges: Vec::with_capacity(cap),
            memory: Vec::with_capacity(cap),
        }
    }

    pub fn len(&self) -> usize {
        self.kinds.len()
    }

    pub fn is_empty(&self) -> bool {
        self.kinds.is_empty()
    }

    /// Append a new primitive instance.  Returns its index.
    pub fn push(&mut self, p: Primitive) -> usize {
        let id = self.kinds.len();
        self.kinds.push(p.kind);
        self.inputs.push(p.inputs);
        self.outputs.push(p.outputs);
        self.rise_delays.push(p.rise_delay);
        self.fall_delays.push(p.fall_delay);
        self.edges.push(p.edge);
        self.memory.push(DigState::X);
        id
    }

    /// Evaluate primitive `id` against the supplied node-state slice.
    ///
    /// Returns the new value(s) to drive on each output node, paired with the
    /// output node index, or an empty smallvec if the primitive does not
    /// produce a change.  The caller is responsible for scheduling the output
    /// changes through the event queue with `delays[id]`.
    ///
    /// This is the hot dispatch loop — branchless on `PrimitiveKind`.
    pub fn eval(
        &mut self,
        id: usize,
        node_state: &[DigState],
    ) -> SmallVec<[(DigNodeIdx, DigState); 4]> {
        let kind = self.kinds[id];
        let ins = &self.inputs[id];
        let outs = &self.outputs[id];
        let mut result: SmallVec<[(DigNodeIdx, DigState); 4]> = SmallVec::new();

        match kind {
            PrimitiveKind::Buf => {
                let v = read(ins, 0, node_state);
                result.push((outs[0], v));
            }
            PrimitiveKind::Not => {
                let v = read(ins, 0, node_state);
                result.push((outs[0], not(v)));
            }
            PrimitiveKind::And => result.push((outs[0], reduce(ins, node_state, AndOp))),
            PrimitiveKind::Nand => {
                let r = reduce(ins, node_state, AndOp);
                result.push((outs[0], not(r)));
            }
            PrimitiveKind::Or => result.push((outs[0], reduce(ins, node_state, OrOp))),
            PrimitiveKind::Nor => {
                let r = reduce(ins, node_state, OrOp);
                result.push((outs[0], not(r)));
            }
            PrimitiveKind::Xor => result.push((outs[0], reduce(ins, node_state, XorOp))),
            PrimitiveKind::Xnor => {
                let r = reduce(ins, node_state, XorOp);
                result.push((outs[0], not(r)));
            }
            PrimitiveKind::Mux2 => {
                let s = read(ins, 0, node_state);
                let a = read(ins, 1, node_state);
                let b = read(ins, 2, node_state);
                let y = match s.level() {
                    Level::Zero => a,
                    Level::One => b,
                    _ => DigState::X,
                };
                result.push((outs[0], y));
            }
            PrimitiveKind::Mux4 => {
                let s0 = read(ins, 0, node_state);
                let s1 = read(ins, 1, node_state);
                let data = [
                    read(ins, 2, node_state),
                    read(ins, 3, node_state),
                    read(ins, 4, node_state),
                    read(ins, 5, node_state),
                ];
                let y = if s0.is_x() || s0.is_z() || s1.is_x() || s1.is_z() {
                    DigState::X
                } else {
                    let idx = (s1.is_one() as usize) << 1 | s0.is_one() as usize;
                    data[idx]
                };
                result.push((outs[0], y));
            }
            PrimitiveKind::Demux2 => {
                let s = read(ins, 0, node_state);
                let d = read(ins, 1, node_state);
                let (y0, y1) = match s.level() {
                    Level::Zero => (d, DigState::ZERO),
                    Level::One => (DigState::ZERO, d),
                    _ => (DigState::X, DigState::X),
                };
                result.push((outs[0], y0));
                result.push((outs[1], y1));
            }
            PrimitiveKind::Demux4 => {
                let s0 = read(ins, 0, node_state);
                let s1 = read(ins, 1, node_state);
                let d = read(ins, 2, node_state);
                let mut ys = [DigState::ZERO; 4];
                if s0.is_x() || s0.is_z() || s1.is_x() || s1.is_z() {
                    ys = [DigState::X; 4];
                } else {
                    let idx = (s1.is_one() as usize) << 1 | s0.is_one() as usize;
                    ys[idx] = d;
                }
                for i in 0..4 {
                    result.push((outs[i], ys[i]));
                }
            }
            PrimitiveKind::DLatch => {
                let d = read(ins, 0, node_state);
                let g = read(ins, 1, node_state);
                let stored = self.memory[id];
                let q = if g.is_one() {
                    d
                } else if g.is_zero() {
                    stored
                } else {
                    DigState::X
                };
                self.memory[id] = q;
                result.push((outs[0], q));
            }
            PrimitiveKind::DFlipFlop => {
                let d = read(ins, 0, node_state);
                let clk = read(ins, 1, node_state);
                let prev_clk = self.memory[id];
                let edge = self.edges[id];
                let triggered = match edge {
                    EdgeKind::Rising => prev_clk.is_zero() && clk.is_one(),
                    EdgeKind::Falling => prev_clk.is_one() && clk.is_zero(),
                };
                // Store the new clock for next-edge detection.  We piggy-back
                // on `memory[id]` because this primitive only has 1 byte of
                // state and the eval driver checks the *previous* iteration's
                // value.
                self.memory[id] = clk;
                if triggered {
                    result.push((outs[0], d));
                }
            }
            PrimitiveKind::DPulse => {
                // The pulse waveform is driven externally by `tick_pulses`.
                // Calling `eval` directly is a no-op.
            }
            PrimitiveKind::DSource | PrimitiveKind::DState => {
                // Pure event sources; no eval-time logic.
            }
        }

        result
    }

    /// Tick all `DPulse` primitives, scheduling their next high/low transition
    /// in `queue`.  Called from the transient hook before each NR step.
    ///
    /// `t_now` is the current simulation time.  Each pulse with period `p`
    /// emits a transition at `t_next = t_now + p/2` of opposite polarity to
    /// its current `memory` value.
    pub fn tick_pulses(&mut self, t_now: f64, queue: &mut super::event_queue::EventQueue) {
        for id in 0..self.kinds.len() {
            if self.kinds[id] != PrimitiveKind::DPulse {
                continue;
            }
            // For a pulse source, rise_delay == fall_delay == period (set in new_pulse).
            let period = self.rise_delays[id];
            if period <= 0.0 {
                continue;
            }
            let cur = self.memory[id];
            let next = if cur.is_one() {
                DigState::ZERO
            } else {
                DigState::ONE
            };
            queue.schedule(t_now + period * 0.5, self.outputs[id][0], next);
            self.memory[id] = next;
        }
    }
}

impl Default for PrimitiveBlock {
    fn default() -> Self {
        Self::with_capacity(64)
    }
}

// ---------------------------------------------------------------------------
// Inline helpers
// ---------------------------------------------------------------------------

#[inline]
fn read(ins: &SmallVec<[DigNodeIdx; 4]>, slot: usize, ns: &[DigState]) -> DigState {
    ins.get(slot)
        .and_then(|n| ns.get(n.index()))
        .copied()
        .unwrap_or(DigState::X)
}

#[inline]
fn not(v: DigState) -> DigState {
    if v.is_zero() {
        DigState::one(v.strength())
    } else if v.is_one() {
        DigState::zero(v.strength())
    } else {
        DigState::x(Strength::Strong)
    }
}

trait BinOp {
    fn apply(a: DigState, b: DigState) -> DigState;
    fn identity() -> DigState;
}

struct AndOp;
impl BinOp for AndOp {
    #[inline]
    fn apply(a: DigState, b: DigState) -> DigState {
        if a.is_zero() || b.is_zero() {
            DigState::ZERO
        } else if a.is_one() && b.is_one() {
            DigState::ONE
        } else {
            DigState::X
        }
    }
    #[inline]
    fn identity() -> DigState {
        DigState::ONE
    }
}

struct OrOp;
impl BinOp for OrOp {
    #[inline]
    fn apply(a: DigState, b: DigState) -> DigState {
        if a.is_one() || b.is_one() {
            DigState::ONE
        } else if a.is_zero() && b.is_zero() {
            DigState::ZERO
        } else {
            DigState::X
        }
    }
    #[inline]
    fn identity() -> DigState {
        DigState::ZERO
    }
}

struct XorOp;
impl BinOp for XorOp {
    #[inline]
    fn apply(a: DigState, b: DigState) -> DigState {
        if !a.is_defined() || !b.is_defined() {
            DigState::X
        } else if a.is_one() != b.is_one() {
            DigState::ONE
        } else {
            DigState::ZERO
        }
    }
    #[inline]
    fn identity() -> DigState {
        DigState::ZERO
    }
}

#[inline]
fn reduce<O: BinOp>(ins: &SmallVec<[DigNodeIdx; 4]>, ns: &[DigState], _op: O) -> DigState {
    let mut acc = O::identity();
    for (i, _) in ins.iter().enumerate() {
        acc = O::apply(acc, read(ins, i, ns));
    }
    acc
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::state::DigState;

    fn nodes(n: usize) -> Vec<DigState> {
        vec![DigState::ZERO; n]
    }

    #[test]
    fn and_gate_basic() {
        let mut blk = PrimitiveBlock::with_capacity(1);
        let a = DigNodeIdx::new(0);
        let b = DigNodeIdx::new(1);
        let y = DigNodeIdx::new(2);
        let id = blk.push(Primitive::new_comb(PrimitiveKind::And, &[a, b], y, 0.0));
        let mut ns = nodes(3);
        ns[0] = DigState::ONE;
        ns[1] = DigState::ONE;
        let r = blk.eval(id, &ns);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].1, DigState::ONE);
        ns[1] = DigState::ZERO;
        let r = blk.eval(id, &ns);
        assert_eq!(r[0].1, DigState::ZERO);
    }

    #[test]
    fn nand_inverts_and() {
        let mut blk = PrimitiveBlock::with_capacity(1);
        let id = blk.push(Primitive::new_comb(
            PrimitiveKind::Nand,
            &[DigNodeIdx::new(0), DigNodeIdx::new(1)],
            DigNodeIdx::new(2),
            0.0,
        ));
        let mut ns = nodes(3);
        ns[0] = DigState::ONE;
        ns[1] = DigState::ONE;
        let r = blk.eval(id, &ns);
        assert_eq!(r[0].1, DigState::ZERO);
    }

    #[test]
    fn xor_propagates_x() {
        let mut blk = PrimitiveBlock::with_capacity(1);
        let id = blk.push(Primitive::new_comb(
            PrimitiveKind::Xor,
            &[DigNodeIdx::new(0), DigNodeIdx::new(1)],
            DigNodeIdx::new(2),
            0.0,
        ));
        let mut ns = nodes(3);
        ns[0] = DigState::X;
        ns[1] = DigState::ONE;
        let r = blk.eval(id, &ns);
        assert!(r[0].1.is_x());
    }

    #[test]
    fn dff_rising_edge_captures_d() {
        let mut blk = PrimitiveBlock::with_capacity(1);
        let id = blk.push(Primitive::new_dff(
            DigNodeIdx::new(0),
            DigNodeIdx::new(1),
            DigNodeIdx::new(2),
            0.0,
            EdgeKind::Rising,
        ));
        let mut ns = nodes(3);
        // Step 1: clk=0, d=1 → no event.
        ns[0] = DigState::ONE;
        ns[1] = DigState::ZERO;
        let r = blk.eval(id, &ns);
        assert!(r.is_empty());
        // Step 2: clk=1, d=1 → rising edge → emit q=1.
        ns[1] = DigState::ONE;
        let r = blk.eval(id, &ns);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].1, DigState::ONE);
        // Step 3: clk still 1 → no edge.
        let r = blk.eval(id, &ns);
        assert!(r.is_empty());
    }

    #[test]
    fn d_latch_transparent_when_gate_high() {
        let mut blk = PrimitiveBlock::with_capacity(1);
        let id = blk.push(Primitive::new_dlatch(
            DigNodeIdx::new(0),
            DigNodeIdx::new(1),
            DigNodeIdx::new(2),
            0.0,
        ));
        let mut ns = nodes(3);
        ns[0] = DigState::ONE;
        ns[1] = DigState::ONE; // gate high
        let r = blk.eval(id, &ns);
        assert_eq!(r[0].1, DigState::ONE);
        // Now lower the gate; q should hold.
        ns[1] = DigState::ZERO;
        ns[0] = DigState::ZERO;
        let r = blk.eval(id, &ns);
        assert_eq!(r[0].1, DigState::ONE);
    }

    #[test]
    fn mux2_selects() {
        let mut blk = PrimitiveBlock::with_capacity(1);
        let id = blk.push(Primitive::new_mux2(
            DigNodeIdx::new(0),
            DigNodeIdx::new(1),
            DigNodeIdx::new(2),
            DigNodeIdx::new(3),
            0.0,
        ));
        let mut ns = nodes(4);
        ns[0] = DigState::ZERO; // sel=0 → pick a
        ns[1] = DigState::ONE;
        ns[2] = DigState::ZERO;
        let r = blk.eval(id, &ns);
        assert_eq!(r[0].1, DigState::ONE);
        ns[0] = DigState::ONE; // sel=1 → pick b
        let r = blk.eval(id, &ns);
        assert_eq!(r[0].1, DigState::ZERO);
    }

    #[test]
    fn pulse_tick_alternates() {
        let mut blk = PrimitiveBlock::with_capacity(1);
        let _id = blk.push(Primitive::new_pulse(DigNodeIdx::new(0), 1e-6));
        let mut q = super::super::event_queue::EventQueue::with_capacity(8);
        blk.tick_pulses(0.0, &mut q);
        blk.tick_pulses(0.5e-6, &mut q);
        assert_eq!(q.len(), 2);
    }
}
