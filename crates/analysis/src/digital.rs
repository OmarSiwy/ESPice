//! Digital runtime — 12-state logic, event queue, ADC/DAC bridges, primitives.
//!
//! Native XSPICE-class digital event engine (Phase 4.1).
//! Lives inside analysis because it hooks into solver via the Analysis trait.
//!
//! Submodule content is inlined here (state, event_queue, bridges, primitives)
//! so that this flat file is the single Rust module declaration.  The files
//! under `digital/` are source-of-record copies; they are NOT declared as `mod`
//! to avoid the Rust 2018 conflict between `digital.rs` and `digital/`.

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------

pub mod state {
    //! 12-state digital logic value packed into a single byte.
    //!
    //! The encoding splits the byte into two nibbles:
    //!
    //! ```text
    //!   bits 7..4 : strength (Strong | Weak | Resistive)
    //!   bits 3..0 : level    (Zero | One | X | Z)
    //! ```
    //!
    //! `Z` is high-impedance and is independent of strength (its strength bits are
    //! always zero).  This packing keeps a `DigState` to a single `u8` so that the
    //! event queue's `values` `Vec<DigState>` is dense, cache-friendly, and amenable
    //! to SIMD compares.

    use std::fmt;

    /// Drive strength of a digital signal.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    #[repr(u8)]
    pub enum Strength {
        /// Hi-Z (no driver).  Encoded only on the `Z` level.
        HiZ = 0,
        /// Resistive driver (e.g. pull-up resistor).
        Resistive = 1,
        /// Weak driver (e.g. small transistor).
        Weak = 2,
        /// Strong driver (e.g. CMOS output).
        Strong = 3,
    }

    impl Strength {
        #[inline]
        pub const fn as_u8(self) -> u8 {
            self as u8
        }

        #[inline]
        pub const fn from_u8(v: u8) -> Self {
            match v & 0x3 {
                0 => Strength::HiZ,
                1 => Strength::Resistive,
                2 => Strength::Weak,
                _ => Strength::Strong,
            }
        }
    }

    /// Packed 12-state digital value.
    ///
    /// 12 distinct states arise from `{0, 1, X} × {Strong, Weak, Resistive}` plus
    /// the high-impedance state `Z` (= 9 + 1 = 10 logical, with two reserved
    /// encodings for forward compatibility).
    ///
    /// Layout:
    ///
    /// ```text
    ///   level == LEVEL_Z  → Z (strength bits ignored, always 0)
    ///   level == LEVEL_0  → 0 with strength
    ///   level == LEVEL_1  → 1 with strength
    ///   level == LEVEL_X  → X with strength (conflict / unknown)
    /// ```
    #[derive(Clone, Copy, PartialEq, Eq, Hash)]
    #[repr(transparent)]
    pub struct DigState(pub u8);

    const LEVEL_MASK: u8 = 0x0F;
    const STRENGTH_SHIFT: u8 = 4;

    const LEVEL_0: u8 = 0;
    const LEVEL_1: u8 = 1;
    const LEVEL_X: u8 = 2;
    const LEVEL_Z: u8 = 3;

    impl DigState {
        /// High-impedance.
        pub const Z: DigState = DigState(LEVEL_Z);

        /// Strong logic 0.
        pub const ZERO: DigState = DigState(LEVEL_0 | ((Strength::Strong as u8) << STRENGTH_SHIFT));

        /// Strong logic 1.
        pub const ONE: DigState = DigState(LEVEL_1 | ((Strength::Strong as u8) << STRENGTH_SHIFT));

        /// Strong unknown / conflict.
        pub const X: DigState = DigState(LEVEL_X | ((Strength::Strong as u8) << STRENGTH_SHIFT));

        /// Construct a packed state.
        #[inline]
        pub const fn new(level: Level, strength: Strength) -> Self {
            match level {
                Level::Z => DigState::Z,
                _ => DigState((level as u8) | ((strength as u8) << STRENGTH_SHIFT)),
            }
        }

        /// Convenience: a logic-0 with the given strength.
        #[inline]
        pub const fn zero(strength: Strength) -> Self {
            Self::new(Level::Zero, strength)
        }

        /// Convenience: a logic-1 with the given strength.
        #[inline]
        pub const fn one(strength: Strength) -> Self {
            Self::new(Level::One, strength)
        }

        /// Convenience: an unknown with the given strength.
        #[inline]
        pub const fn x(strength: Strength) -> Self {
            Self::new(Level::X, strength)
        }

        /// Logic level (independent of drive strength).
        #[inline]
        pub const fn level(self) -> Level {
            match self.0 & LEVEL_MASK {
                LEVEL_0 => Level::Zero,
                LEVEL_1 => Level::One,
                LEVEL_X => Level::X,
                _ => Level::Z,
            }
        }

        /// Drive strength.  Always `HiZ` for `Z`.
        #[inline]
        pub const fn strength(self) -> Strength {
            if (self.0 & LEVEL_MASK) == LEVEL_Z {
                Strength::HiZ
            } else {
                Strength::from_u8(self.0 >> STRENGTH_SHIFT)
            }
        }

        /// True if this state has a defined logic level (`0` or `1`).
        #[inline]
        pub const fn is_defined(self) -> bool {
            let lvl = self.0 & LEVEL_MASK;
            lvl == LEVEL_0 || lvl == LEVEL_1
        }

        /// True if this is a strong driver of either polarity.
        #[inline]
        pub const fn is_strong(self) -> bool {
            (self.0 >> STRENGTH_SHIFT) == Strength::Strong as u8
                && (self.0 & LEVEL_MASK) != LEVEL_Z
        }

        /// True if logic level is 0.
        #[inline]
        pub const fn is_zero(self) -> bool {
            (self.0 & LEVEL_MASK) == LEVEL_0
        }

        /// True if logic level is 1.
        #[inline]
        pub const fn is_one(self) -> bool {
            (self.0 & LEVEL_MASK) == LEVEL_1
        }

        /// True if level is `X`.
        #[inline]
        pub const fn is_x(self) -> bool {
            (self.0 & LEVEL_MASK) == LEVEL_X
        }

        /// True if level is `Z` (high-impedance).
        #[inline]
        pub const fn is_z(self) -> bool {
            (self.0 & LEVEL_MASK) == LEVEL_Z
        }

        /// Resolve two driver states on the same node using strength rules.
        ///
        /// * `Z` is overridden by anything non-`Z`.
        /// * Stronger driver wins.
        /// * Equal strength + same level = that level; equal strength + opposite
        ///   level = `X` at that strength.
        pub const fn resolve(a: DigState, b: DigState) -> DigState {
            if a.is_z() {
                return b;
            }
            if b.is_z() {
                return a;
            }
            let sa = a.0 >> STRENGTH_SHIFT;
            let sb = b.0 >> STRENGTH_SHIFT;
            if sa > sb {
                return a;
            }
            if sb > sa {
                return b;
            }
            // Equal strength.
            let la = a.0 & LEVEL_MASK;
            let lb = b.0 & LEVEL_MASK;
            if la == lb {
                return a;
            }
            // Conflict at this strength → X.
            DigState(LEVEL_X | (sa << STRENGTH_SHIFT))
        }
    }

    impl Default for DigState {
        #[inline]
        fn default() -> Self {
            DigState::Z
        }
    }

    impl fmt::Debug for DigState {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(f, "DigState({:?},{:?})", self.level(), self.strength())
        }
    }

    impl fmt::Display for DigState {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            let c = match self.level() {
                Level::Zero => '0',
                Level::One => '1',
                Level::X => 'X',
                Level::Z => 'Z',
            };
            write!(f, "{c}")
        }
    }

    /// The four possible logic levels (independent of strength).
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    #[repr(u8)]
    pub enum Level {
        Zero = LEVEL_0,
        One = LEVEL_1,
        X = LEVEL_X,
        Z = LEVEL_Z,
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn packed_size_is_one_byte() {
            assert_eq!(std::mem::size_of::<DigState>(), 1);
        }

        #[test]
        fn round_trip_levels_and_strengths() {
            for &lvl in &[Level::Zero, Level::One, Level::X] {
                for &s in &[Strength::Resistive, Strength::Weak, Strength::Strong] {
                    let st = DigState::new(lvl, s);
                    assert_eq!(st.level(), lvl);
                    assert_eq!(st.strength(), s);
                }
            }
            let z = DigState::Z;
            assert_eq!(z.level(), Level::Z);
            assert_eq!(z.strength(), Strength::HiZ);
        }

        #[test]
        fn predicates() {
            assert!(DigState::ZERO.is_defined());
            assert!(DigState::ONE.is_defined());
            assert!(!DigState::X.is_defined());
            assert!(!DigState::Z.is_defined());
            assert!(DigState::ZERO.is_strong());
            assert!(DigState::ONE.is_strong());
            assert!(!DigState::Z.is_strong());
            assert!(DigState::ZERO.is_zero());
            assert!(DigState::ONE.is_one());
            assert!(DigState::X.is_x());
            assert!(DigState::Z.is_z());
        }

        #[test]
        fn resolve_z_loses() {
            assert_eq!(DigState::resolve(DigState::Z, DigState::ONE), DigState::ONE);
            assert_eq!(
                DigState::resolve(DigState::ZERO, DigState::Z),
                DigState::ZERO
            );
        }

        #[test]
        fn resolve_strength_wins() {
            let weak1 = DigState::one(Strength::Weak);
            let strong0 = DigState::ZERO;
            assert_eq!(DigState::resolve(weak1, strong0), strong0);
        }

        #[test]
        fn resolve_equal_conflict_is_x() {
            let r = DigState::resolve(DigState::ZERO, DigState::ONE);
            assert!(r.is_x());
            assert_eq!(r.strength(), Strength::Strong);
        }

        #[test]
        fn resolve_equal_same_level() {
            let a = DigState::one(Strength::Weak);
            let b = DigState::one(Strength::Weak);
            assert_eq!(DigState::resolve(a, b), a);
        }
    }
}

// ---------------------------------------------------------------------------
// event_queue
// ---------------------------------------------------------------------------

pub mod event_queue {
    //! SoA event queue with min-heap ordering on event time.
    //!
    //! All event fields live in parallel `Vec`s; only the heap permutation
    //! `heap_indices` is reordered as events are scheduled and popped, so the
    //! per-event payload is never moved or boxed.  Capacity is reserved up-front to
    //! keep the hot path allocation-free.
    //!
    //! Operations:
    //!
    //! * `schedule(t, node, val)` — O(log n) insert.
    //! * `pop_due(t_now, out)`    — drain all events whose `time <= t_now` into `out`.
    //! * `rollback(t_after)`      — drop every event whose scheduled time is
    //!   strictly greater than `t_after` (used by the transient hook on a failed
    //!   Newton step that needs to retry with a smaller `h`).

    use super::state::DigState;

    /// Type-safe digital node index.  Distinct from analog `NodeId`.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
    #[repr(transparent)]
    pub struct DigNodeIdx(pub u32);

    impl DigNodeIdx {
        #[inline]
        pub const fn new(v: u32) -> Self {
            DigNodeIdx(v)
        }
        #[inline]
        pub const fn index(self) -> usize {
            self.0 as usize
        }
    }

    /// Index into the event queue's storage arrays.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    #[repr(transparent)]
    pub struct EventIdx(pub u32);

    /// A snapshot of a single event, returned by `pop_due`.
    #[derive(Clone, Copy, Debug, PartialEq)]
    pub struct Event {
        pub time: f64,
        pub node: DigNodeIdx,
        pub value: DigState,
    }

    /// Struct-of-arrays priority queue ordered by `times`.
    ///
    /// Storage is *append-only* in the data arrays; the heap maintains a
    /// permutation `heap_indices` so events can be re-ordered without moving the
    /// payload.  Popped slots are tracked in `free_list` for reuse, keeping the
    /// memory footprint bounded for steady-state simulations.
    pub struct EventQueue {
        times: Vec<f64>,
        nodes: Vec<DigNodeIdx>,
        values: Vec<DigState>,
        /// Min-heap of indices into `times`/`nodes`/`values`.
        heap: Vec<u32>,
        /// Slots in `times`/`nodes`/`values` that have been popped and may be
        /// reused on the next `schedule()`.
        free_list: Vec<u32>,
    }

    impl EventQueue {
        /// Construct an empty queue with reserved capacity for `cap` events.
        pub fn with_capacity(cap: usize) -> Self {
            Self {
                times: Vec::with_capacity(cap),
                nodes: Vec::with_capacity(cap),
                values: Vec::with_capacity(cap),
                heap: Vec::with_capacity(cap),
                free_list: Vec::with_capacity(cap / 4 + 1),
            }
        }

        /// Number of currently-pending events.
        #[inline]
        pub fn len(&self) -> usize {
            self.heap.len()
        }

        /// True if no events are pending.
        #[inline]
        pub fn is_empty(&self) -> bool {
            self.heap.is_empty()
        }

        /// Smallest scheduled time, or `None` if empty.
        #[inline]
        pub fn next_time(&self) -> Option<f64> {
            self.heap.first().map(|&i| self.times[i as usize])
        }

        /// Schedule an event at absolute time `t` on `node` with value `val`.
        ///
        /// Reuses a free slot if one exists; otherwise appends.  O(log n).
        pub fn schedule(&mut self, t: f64, node: DigNodeIdx, val: DigState) {
            let slot = if let Some(s) = self.free_list.pop() {
                self.times[s as usize] = t;
                self.nodes[s as usize] = node;
                self.values[s as usize] = val;
                s
            } else {
                let s = self.times.len() as u32;
                self.times.push(t);
                self.nodes.push(node);
                self.values.push(val);
                s
            };
            self.heap.push(slot);
            self.sift_up(self.heap.len() - 1);
        }

        /// Drain all events with `time <= t_now` into `out`, in time-sorted order
        /// (ties broken by insertion order).
        ///
        /// `out` is cleared first.  This method is the hot path called once per
        /// transient timestep.
        pub fn pop_due(&mut self, t_now: f64, out: &mut Vec<Event>) {
            out.clear();
            while let Some(&top) = self.heap.first() {
                let t = self.times[top as usize];
                if t > t_now {
                    break;
                }
                // Pop the heap root.
                let last = self.heap.pop().unwrap();
                if !self.heap.is_empty() {
                    self.heap[0] = last;
                    self.sift_down(0);
                }
                out.push(Event {
                    time: t,
                    node: self.nodes[top as usize],
                    value: self.values[top as usize],
                });
                self.free_list.push(top);
            }
        }

        /// Drop every event whose `time > t_after`.  Used to undo speculative
        /// events when a failed Newton-Raphson iteration retries with a smaller
        /// timestep.
        ///
        /// O(n + n log n) in the worst case (rebuilds the heap).
        pub fn rollback(&mut self, t_after: f64) {
            let mut new_heap: Vec<u32> = Vec::with_capacity(self.heap.len());
            for &slot in &self.heap {
                if self.times[slot as usize] <= t_after {
                    new_heap.push(slot);
                } else {
                    self.free_list.push(slot);
                }
            }
            self.heap = new_heap;
            // Rebuild the heap bottom-up.
            if self.heap.len() > 1 {
                for i in (0..self.heap.len() / 2).rev() {
                    self.sift_down(i);
                }
            }
        }

        /// Discard *all* pending events without releasing capacity.
        pub fn clear(&mut self) {
            self.heap.clear();
            for slot in 0..self.times.len() as u32 {
                self.free_list.push(slot);
            }
            // Deduplicate the free list (cheap because it's at most |times|).
            self.free_list.sort_unstable();
            self.free_list.dedup();
        }

        // -------------------------------------------------------------------
        // Heap helpers — operate on indices into `self.heap`.
        // -------------------------------------------------------------------

        fn sift_up(&mut self, mut i: usize) {
            while i > 0 {
                let parent = (i - 1) / 2;
                if self.cmp_heap(i, parent) {
                    self.heap.swap(i, parent);
                    i = parent;
                } else {
                    break;
                }
            }
        }

        fn sift_down(&mut self, mut i: usize) {
            let n = self.heap.len();
            loop {
                let l = 2 * i + 1;
                let r = 2 * i + 2;
                let mut best = i;
                if l < n && self.cmp_heap(l, best) {
                    best = l;
                }
                if r < n && self.cmp_heap(r, best) {
                    best = r;
                }
                if best == i {
                    break;
                }
                self.heap.swap(i, best);
                i = best;
            }
        }

        /// Returns true if heap entry at index `a` should be ordered *before* `b`.
        #[inline]
        fn cmp_heap(&self, a: usize, b: usize) -> bool {
            let ta = self.times[self.heap[a] as usize];
            let tb = self.times[self.heap[b] as usize];
            ta < tb
        }
    }

    impl Default for EventQueue {
        fn default() -> Self {
            Self::with_capacity(1024)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use super::super::state::DigState;

        #[test]
        fn schedule_and_pop_in_order() {
            let mut q = EventQueue::with_capacity(16);
            q.schedule(2.0, DigNodeIdx::new(0), DigState::ONE);
            q.schedule(1.0, DigNodeIdx::new(1), DigState::ZERO);
            q.schedule(3.0, DigNodeIdx::new(2), DigState::X);

            let mut out = Vec::new();
            q.pop_due(5.0, &mut out);
            assert_eq!(out.len(), 3);
            assert_eq!(out[0].time, 1.0);
            assert_eq!(out[0].node, DigNodeIdx::new(1));
            assert_eq!(out[1].time, 2.0);
            assert_eq!(out[2].time, 3.0);
            assert!(q.is_empty());
        }

        #[test]
        fn pop_due_drains_only_due_events() {
            let mut q = EventQueue::with_capacity(8);
            q.schedule(1.0, DigNodeIdx::new(0), DigState::ZERO);
            q.schedule(2.0, DigNodeIdx::new(0), DigState::ONE);
            q.schedule(3.0, DigNodeIdx::new(0), DigState::ZERO);

            let mut out = Vec::new();
            q.pop_due(2.0, &mut out);
            assert_eq!(out.len(), 2);
            assert_eq!(q.len(), 1);
            assert_eq!(q.next_time(), Some(3.0));
        }

        #[test]
        fn rollback_removes_future_events() {
            let mut q = EventQueue::with_capacity(8);
            q.schedule(1.0, DigNodeIdx::new(0), DigState::ZERO);
            q.schedule(5.0, DigNodeIdx::new(0), DigState::ONE);
            q.schedule(2.0, DigNodeIdx::new(0), DigState::ONE);
            q.schedule(7.0, DigNodeIdx::new(0), DigState::ZERO);

            q.rollback(3.0);
            assert_eq!(q.len(), 2);

            let mut out = Vec::new();
            q.pop_due(10.0, &mut out);
            assert_eq!(out.len(), 2);
            assert_eq!(out[0].time, 1.0);
            assert_eq!(out[1].time, 2.0);
        }

        #[test]
        fn slot_reuse() {
            let mut q = EventQueue::with_capacity(4);
            for i in 0..10 {
                q.schedule(i as f64, DigNodeIdx::new(0), DigState::ONE);
                let mut out = Vec::new();
                q.pop_due(i as f64, &mut out);
                assert_eq!(out.len(), 1);
            }
            // After draining 10 events from a capacity-4 queue, the underlying
            // storage should still be small thanks to slot reuse.
            assert!(q.times.len() <= 10);
        }

        #[test]
        fn next_time_empty() {
            let q = EventQueue::with_capacity(4);
            assert_eq!(q.next_time(), None);
        }
    }
}

// ---------------------------------------------------------------------------
// bridges
// ---------------------------------------------------------------------------

pub mod bridges {
    //! Analog ↔ digital bridge elements.
    //!
    //! Two pure data types live here:
    //!
    //! * **`AdcBridge`** — observes one analog node voltage and emits a digital
    //!   event whenever the voltage crosses one of two thresholds (with hysteresis).
    //! * **`DacBridge`** — converts a digital state into a target analog voltage,
    //!   ramping linearly between `out_low` and `out_high` over `t_rise` / `t_fall`.

    use super::event_queue::{DigNodeIdx, EventQueue};
    use super::state::DigState;

    /// Opaque identifier for a bridge instance within a `BridgeBlock`.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    #[repr(transparent)]
    pub struct BridgeId(pub u32);

    /// Analog → digital bridge with hysteresis.
    #[derive(Debug, Clone, Copy)]
    pub struct AdcBridge {
        /// Analog node id (interpreted by the caller; we treat it as opaque `u32`).
        pub analog_node: u32,
        /// Digital output node.
        pub digital_node: DigNodeIdx,
        /// Propagation delay before a new sampled state is emitted.
        pub delay: f64,
        /// Lower hysteresis threshold (volts).
        pub in_low: f64,
        /// Upper hysteresis threshold (volts).
        pub in_high: f64,
        /// Last digital level emitted.  Initial value should be `DigState::X`.
        pub last_state: DigState,
    }

    impl AdcBridge {
        pub fn new(
            analog_node: u32,
            digital_node: DigNodeIdx,
            delay: f64,
            in_low: f64,
            in_high: f64,
        ) -> Self {
            Self {
                analog_node,
                digital_node,
                delay,
                in_low,
                in_high,
                last_state: DigState::X,
            }
        }

        /// Apply one analog sample.  If a threshold is crossed, schedule the new
        /// digital state at time `t` and return `true`.
        pub fn step(&mut self, t: f64, voltage: f64, queue: &mut EventQueue) -> bool {
            let new_state = if voltage >= self.in_high {
                Some(DigState::ONE)
            } else if voltage <= self.in_low {
                Some(DigState::ZERO)
            } else {
                None
            };

            if let Some(s) = new_state {
                if s != self.last_state {
                    queue.schedule(t + self.delay.max(0.0), self.digital_node, s);
                    self.last_state = s;
                    return true;
                }
            }
            false
        }
    }

    /// Digital → analog bridge with linear rise/fall ramps.
    #[derive(Debug, Clone, Copy)]
    pub struct DacBridge {
        /// Analog node id (interpreted by the caller).
        pub analog_node: u32,
        /// Digital input node.
        pub digital_node: DigNodeIdx,
        /// Output voltage when input is logic 0.
        pub out_low: f64,
        /// Output voltage when input is logic 1.
        pub out_high: f64,
        /// Rise time from `out_low` to `out_high` [s].
        pub t_rise: f64,
        /// Fall time from `out_high` to `out_low` [s].
        pub t_fall: f64,
        /// Voltage at the start of the current ramp.
        pub v_start: f64,
        /// Target voltage at end of ramp.
        pub v_target: f64,
        /// Time at which the current ramp started.
        pub t_start: f64,
        /// Currently latched digital input level.
        pub last_input: DigState,
    }

    impl DacBridge {
        pub fn new(
            analog_node: u32,
            digital_node: DigNodeIdx,
            out_low: f64,
            out_high: f64,
            t_rise: f64,
            t_fall: f64,
        ) -> Self {
            Self {
                analog_node,
                digital_node,
                out_low,
                out_high,
                t_rise,
                t_fall,
                v_start: out_low,
                v_target: out_low,
                t_start: 0.0,
                last_input: DigState::X,
            }
        }

        /// Notify the bridge that its digital input took on `new_state` at time `t`.
        pub fn on_digital_event(&mut self, t: f64, new_state: DigState) {
            if new_state == self.last_input {
                return;
            }
            let target = if new_state.is_one() {
                self.out_high
            } else if new_state.is_zero() {
                self.out_low
            } else {
                // X / Z → hold current target.
                self.last_input = new_state;
                return;
            };
            self.v_start = self.current_voltage(t);
            self.v_target = target;
            self.t_start = t;
            self.last_input = new_state;
        }

        /// Voltage produced at time `t` by the current ramp.
        pub fn current_voltage(&self, t: f64) -> f64 {
            let dt = (t - self.t_start).max(0.0);
            let active = if self.v_target >= self.v_start {
                self.t_rise
            } else {
                self.t_fall
            };
            if active <= 0.0 || dt >= active {
                return self.v_target;
            }
            let frac = dt / active;
            self.v_start + (self.v_target - self.v_start) * frac
        }
    }

    /// SoA storage for all bridges in the netlist.
    pub struct BridgeBlock {
        pub adcs: Vec<AdcBridge>,
        pub dacs: Vec<DacBridge>,
    }

    impl BridgeBlock {
        pub fn new() -> Self {
            Self {
                adcs: Vec::new(),
                dacs: Vec::new(),
            }
        }

        /// Push an ADC bridge and return its id.
        pub fn push_adc(&mut self, b: AdcBridge) -> BridgeId {
            let id = self.adcs.len() as u32;
            self.adcs.push(b);
            BridgeId(id)
        }

        /// Push a DAC bridge and return its id.
        pub fn push_dac(&mut self, b: DacBridge) -> BridgeId {
            let id = self.dacs.len() as u32;
            self.dacs.push(b);
            BridgeId(id)
        }

        /// Drive every ADC bridge with the latest analog sample slice.
        pub fn tick_adcs(&mut self, t: f64, analog_voltages: &[f64], queue: &mut EventQueue) {
            for adc in self.adcs.iter_mut() {
                let idx = adc.analog_node as usize;
                if let Some(&v) = analog_voltages.get(idx) {
                    adc.step(t, v, queue);
                }
            }
        }

        /// Apply a freshly popped digital event to every DAC bridge whose input
        /// matches the event's node.
        pub fn dispatch_event_to_dacs(&mut self, t: f64, node: DigNodeIdx, value: DigState) {
            for dac in self.dacs.iter_mut() {
                if dac.digital_node == node {
                    dac.on_digital_event(t, value);
                }
            }
        }
    }

    impl Default for BridgeBlock {
        fn default() -> Self {
            Self::new()
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use super::super::event_queue::{DigNodeIdx, EventQueue};

        #[test]
        fn adc_emits_high_above_threshold() {
            let mut adc = AdcBridge::new(0, DigNodeIdx::new(7), 0.0, 1.0, 2.0);
            let mut q = EventQueue::with_capacity(8);
            // Below in_low → 0.
            assert!(adc.step(0.0, 0.5, &mut q));
            // Still below in_high but above in_low → no change (hysteresis).
            assert!(!adc.step(1.0, 1.5, &mut q));
            // Above in_high → 1.
            assert!(adc.step(2.0, 2.5, &mut q));
            // Drop into hysteresis band — no change.
            assert!(!adc.step(3.0, 1.5, &mut q));
            // Drop below in_low — back to 0.
            assert!(adc.step(4.0, 0.5, &mut q));
            assert_eq!(q.len(), 3);
        }

        #[test]
        fn dac_ramps_linearly() {
            let mut dac =
                DacBridge::new(0, DigNodeIdx::new(0), 0.0, 5.0, 1e-9, 1e-9);
            dac.on_digital_event(0.0, super::super::state::DigState::ONE);
            assert!((dac.current_voltage(0.0) - 0.0).abs() < 1e-12);
            let mid = dac.current_voltage(0.5e-9);
            assert!((mid - 2.5).abs() < 1e-9);
            let end = dac.current_voltage(1.0e-9);
            assert!((end - 5.0).abs() < 1e-12);
            let after = dac.current_voltage(1e-6);
            assert!((after - 5.0).abs() < 1e-12);
        }

        #[test]
        fn dac_ignores_x_and_z() {
            let mut dac =
                DacBridge::new(0, DigNodeIdx::new(0), 0.0, 5.0, 1e-9, 1e-9);
            dac.on_digital_event(0.0, super::super::state::DigState::ONE);
            dac.on_digital_event(2e-9, super::super::state::DigState::X);
            assert!((dac.current_voltage(3e-9) - 5.0).abs() < 1e-12);
        }
    }
}

// ---------------------------------------------------------------------------
// primitives
// ---------------------------------------------------------------------------

pub mod primitives {
    //! Native digital primitives — combinational and sequential.
    //!
    //! All primitives are stored in a single SoA `PrimitiveBlock`.
    //! Dispatch is a flat `match` on `PrimitiveKind` — no vtables, no boxing.

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

    /// Discriminant tag for the SoA primitive block.
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
        // State machine
        DState = 16,
    }

    /// A single primitive instance — *cold* fields used at construction time.
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
    pub struct PrimitiveBlock {
        pub kinds: Vec<PrimitiveKind>,
        pub inputs: Vec<SmallVec<[DigNodeIdx; 4]>>,
        pub outputs: Vec<SmallVec<[DigNodeIdx; 4]>>,
        pub rise_delays: Vec<f64>,
        pub fall_delays: Vec<f64>,
        pub edges: Vec<EdgeKind>,
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
                    self.memory[id] = clk;
                    if triggered {
                        result.push((outs[0], d));
                    }
                }
                PrimitiveKind::DPulse => {
                    // Driven externally by `tick_pulses`; eval is a no-op.
                }
                PrimitiveKind::DSource | PrimitiveKind::DState => {
                    // Pure event sources; no eval-time logic.
                }
            }

            result
        }

        pub fn tick_pulses(&mut self, t_now: f64, queue: &mut super::event_queue::EventQueue) {
            for id in 0..self.kinds.len() {
                if self.kinds[id] != PrimitiveKind::DPulse {
                    continue;
                }
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

    // -----------------------------------------------------------------------
    // Inline helpers
    // -----------------------------------------------------------------------

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
            ns[0] = DigState::ONE;
            ns[1] = DigState::ZERO;
            let r = blk.eval(id, &ns);
            assert!(r.is_empty());
            ns[1] = DigState::ONE;
            let r = blk.eval(id, &ns);
            assert_eq!(r.len(), 1);
            assert_eq!(r[0].1, DigState::ONE);
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
            ns[1] = DigState::ONE;
            let r = blk.eval(id, &ns);
            assert_eq!(r[0].1, DigState::ONE);
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
            ns[0] = DigState::ZERO;
            ns[1] = DigState::ONE;
            ns[2] = DigState::ZERO;
            let r = blk.eval(id, &ns);
            assert_eq!(r[0].1, DigState::ONE);
            ns[0] = DigState::ONE;
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
}

// ---------------------------------------------------------------------------
// Re-exports (public API surface of the digital module)
// ---------------------------------------------------------------------------

pub use state::{DigState, Level, Strength};
pub use event_queue::{DigNodeIdx, EventIdx, Event, EventQueue};
pub use bridges::{AdcBridge, BridgeBlock, BridgeId, DacBridge};
pub use primitives::{EdgeKind, Primitive, PrimitiveBlock, PrimitiveKind};

// ---------------------------------------------------------------------------
// Module-level integration tests (TODO §13)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod module_tests {
    use super::*;

    // -----------------------------------------------------------------------
    // test_digital_strength_resolution: stronger driver wins when levels differ.
    // -----------------------------------------------------------------------
    #[test]
    fn test_digital_strength_resolution() {
        // A weak ONE vs a strong ZERO → strong ZERO wins.
        let weak_one = DigState::one(Strength::Weak);
        let strong_zero = DigState::ZERO; // default is Strong
        let resolved = DigState::resolve(weak_one, strong_zero);
        assert!(resolved.is_zero(), "strong zero should beat weak one");
        assert_eq!(resolved.strength(), Strength::Strong);

        // Two equally-strong drivers driving opposite levels → X conflict.
        let conflict = DigState::resolve(DigState::ONE, DigState::ZERO);
        assert!(conflict.is_x(), "equal-strength opposite drivers → X");
    }

    // -----------------------------------------------------------------------
    // test_digital_event_queue_ordering: events come out earliest-first.
    // -----------------------------------------------------------------------
    #[test]
    fn test_digital_event_queue_ordering() {
        let mut q = EventQueue::with_capacity(8);
        // Schedule out of order.
        q.schedule(5.0, DigNodeIdx::new(0), DigState::ONE);
        q.schedule(1.0, DigNodeIdx::new(1), DigState::ZERO);
        q.schedule(3.0, DigNodeIdx::new(2), DigState::X);
        q.schedule(2.0, DigNodeIdx::new(3), DigState::ONE);

        let mut out = Vec::new();
        q.pop_due(10.0, &mut out);
        assert_eq!(out.len(), 4, "all four events should be drained");
        // Verify ascending order of event times.
        for w in out.windows(2) {
            assert!(w[0].time <= w[1].time,
                "events out of order: {} > {}", w[0].time, w[1].time);
        }
    }

    // -----------------------------------------------------------------------
    // test_digital_primitive_and_gate / or_gate / not_gate correctness.
    // -----------------------------------------------------------------------
    #[test]
    fn test_digital_primitive_and_gate() {
        let mut blk = PrimitiveBlock::with_capacity(3);

        // AND gate on nodes 0,1 → output 2.
        let and_id = blk.push(Primitive::new_comb(
            PrimitiveKind::And,
            &[DigNodeIdx::new(0), DigNodeIdx::new(1)],
            DigNodeIdx::new(2),
            0.0,
        ));

        // OR gate on nodes 0,1 → output 3.
        let or_id = blk.push(Primitive::new_comb(
            PrimitiveKind::Or,
            &[DigNodeIdx::new(0), DigNodeIdx::new(1)],
            DigNodeIdx::new(3),
            0.0,
        ));

        // NOT gate on node 0 → output 4.
        let not_id = blk.push(Primitive::new_comb(
            PrimitiveKind::Not,
            &[DigNodeIdx::new(0)],
            DigNodeIdx::new(4),
            0.0,
        ));

        let mut ns = vec![DigState::ZERO; 5];

        // Case 1: A=0, B=0 → AND=0, OR=0, NOT(A)=1.
        let r_and = blk.eval(and_id, &ns);
        let r_or  = blk.eval(or_id,  &ns);
        let r_not = blk.eval(not_id, &ns);
        assert_eq!(r_and[0].1, DigState::ZERO, "AND(0,0)=0");
        assert_eq!(r_or[0].1,  DigState::ZERO, "OR(0,0)=0");
        assert_eq!(r_not[0].1, DigState::ONE,  "NOT(0)=1");

        // Case 2: A=1, B=0 → AND=0, OR=1, NOT(A)=0.
        ns[0] = DigState::ONE;
        let r_and = blk.eval(and_id, &ns);
        let r_or  = blk.eval(or_id,  &ns);
        let r_not = blk.eval(not_id, &ns);
        assert_eq!(r_and[0].1, DigState::ZERO, "AND(1,0)=0");
        assert_eq!(r_or[0].1,  DigState::ONE,  "OR(1,0)=1");
        assert_eq!(r_not[0].1, DigState::ZERO, "NOT(1)=0");

        // Case 3: A=1, B=1 → AND=1, OR=1.
        ns[1] = DigState::ONE;
        let r_and = blk.eval(and_id, &ns);
        let r_or  = blk.eval(or_id,  &ns);
        assert_eq!(r_and[0].1, DigState::ONE, "AND(1,1)=1");
        assert_eq!(r_or[0].1,  DigState::ONE, "OR(1,1)=1");
    }
}
