//! Phase 5.5 — Transient checkpointing.
//!
//! Periodic snapshots of the transient solver's full state, kept in a flat
//! arena so a `.STEP` parametric sweep can hot-rewind from the nearest prior
//! sample of the swept parameter.
//!
//! ## Storage layout (DOD)
//!
//! Snapshots live in three SoA buffers:
//!
//! ```text
//!   times:        Vec<f64>          // length N — checkpoint times
//!   state_offset: Vec<u32>          // length N+1 — CSR-style offsets
//!   state_data:   Vec<f64>          // flat concatenated state vectors
//! ```
//!
//! Charge histories and event queues are optional and stored alongside
//! using the same offset/data SoA scheme.  The whole structure is a single
//! [`Arena`](TransientArena) so it can be reset in O(1).
//!
//! `nearest_before(t)` does a `partition_point` (binary search) on the
//! sorted `times` vector — `O(log N)`.

/// Identifier of one checkpoint within a [`TransientArena`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CheckpointIdx(pub u32);

/// SoA storage for transient simulation checkpoints.
///
/// Add a checkpoint with [`push`].  Restore the nearest one with
/// [`nearest_before`] + [`get`].  Reset the whole arena with [`reset`].
#[derive(Debug, Clone, Default)]
pub struct TransientArena {
    times: Vec<f64>,

    // CSR-style flat storage of state vectors.
    state_offset: Vec<u32>,
    state_data: Vec<f64>,

    // Optional companion charge / flux history blocks.
    charge_offset: Vec<u32>,
    charge_data: Vec<f64>,

    // Optional digital event queue snapshots, stored as `(time, code)` pairs.
    event_offset: Vec<u32>,
    event_data: Vec<(f64, u32)>,
}

impl TransientArena {
    pub fn new() -> Self {
        Self {
            times: Vec::new(),
            state_offset: vec![0],
            state_data: Vec::new(),
            charge_offset: vec![0],
            charge_data: Vec::new(),
            event_offset: vec![0],
            event_data: Vec::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.times.len()
    }

    pub fn is_empty(&self) -> bool {
        self.times.is_empty()
    }

    /// Append a checkpoint to the arena.  `time` must be ≥ the time of the
    /// previous checkpoint (we assume monotone insertion order).
    pub fn push(
        &mut self,
        time: f64,
        state: &[f64],
        charges: &[f64],
        events: &[(f64, u32)],
    ) -> CheckpointIdx {
        if let Some(&last) = self.times.last() {
            debug_assert!(time >= last, "checkpoints must be inserted in time order");
        }
        let idx = self.times.len() as u32;
        self.times.push(time);

        self.state_data.extend_from_slice(state);
        self.state_offset.push(self.state_data.len() as u32);

        self.charge_data.extend_from_slice(charges);
        self.charge_offset.push(self.charge_data.len() as u32);

        self.event_data.extend_from_slice(events);
        self.event_offset.push(self.event_data.len() as u32);

        CheckpointIdx(idx)
    }

    /// Drop every checkpoint, retaining the underlying buffer capacity.
    pub fn reset(&mut self) {
        self.times.clear();
        self.state_offset.clear();
        self.state_offset.push(0);
        self.state_data.clear();
        self.charge_offset.clear();
        self.charge_offset.push(0);
        self.charge_data.clear();
        self.event_offset.clear();
        self.event_offset.push(0);
        self.event_data.clear();
    }

    /// Read-only access to one checkpoint.
    pub fn get(&self, idx: CheckpointIdx) -> Option<Checkpoint<'_>> {
        let i = idx.0 as usize;
        if i >= self.times.len() {
            return None;
        }
        let s0 = self.state_offset[i] as usize;
        let s1 = self.state_offset[i + 1] as usize;
        let c0 = self.charge_offset[i] as usize;
        let c1 = self.charge_offset[i + 1] as usize;
        let e0 = self.event_offset[i] as usize;
        let e1 = self.event_offset[i + 1] as usize;
        Some(Checkpoint {
            time: self.times[i],
            state: &self.state_data[s0..s1],
            charges: &self.charge_data[c0..c1],
            events: &self.event_data[e0..e1],
        })
    }

    /// Find the index of the latest checkpoint with `time ≤ t`.
    pub fn nearest_before(&self, t: f64) -> Option<CheckpointIdx> {
        if self.times.is_empty() {
            return None;
        }
        // partition_point gives the first index whose time > t.
        let pos = self
            .times
            .partition_point(|&ts| ts <= t);
        if pos == 0 {
            None
        } else {
            Some(CheckpointIdx((pos - 1) as u32))
        }
    }
}

/// Borrowed view of one checkpoint inside a [`TransientArena`].
#[derive(Debug, Clone, Copy)]
pub struct Checkpoint<'a> {
    pub time: f64,
    pub state: &'a [f64],
    pub charges: &'a [f64],
    pub events: &'a [(f64, u32)],
}

/// Owned snapshot of one checkpoint — returned by [`TransientArena::get_owned`].
#[derive(Debug, Clone)]
pub struct CheckpointSnapshot {
    pub time: f64,
    pub state: Vec<f64>,
    pub charge_hist: Vec<f64>,
    pub events: Vec<(f64, u32)>,
}

impl TransientArena {
    /// Return an owned copy of checkpoint `idx`, or `None` if out of bounds.
    pub fn get_owned(&self, idx: CheckpointIdx) -> Option<CheckpointSnapshot> {
        self.get(idx).map(|cp| CheckpointSnapshot {
            time: cp.time,
            state: cp.state.to_vec(),
            charge_hist: cp.charges.to_vec(),
            events: cp.events.to_vec(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_and_get() {
        let mut arena = TransientArena::new();
        let i0 = arena.push(0.0, &[1.0, 2.0], &[0.5], &[]);
        let i1 = arena.push(1.0, &[3.0, 4.0], &[0.7], &[(0.9, 42)]);
        assert_eq!(arena.len(), 2);

        let c0 = arena.get(i0).unwrap();
        assert_eq!(c0.time, 0.0);
        assert_eq!(c0.state, &[1.0, 2.0]);
        assert_eq!(c0.charges, &[0.5]);

        let c1 = arena.get(i1).unwrap();
        assert_eq!(c1.events, &[(0.9, 42)]);
    }

    #[test]
    fn nearest_before_query() {
        let mut arena = TransientArena::new();
        arena.push(0.0, &[0.0], &[], &[]);
        arena.push(1.0, &[1.0], &[], &[]);
        arena.push(2.5, &[2.0], &[], &[]);
        arena.push(5.0, &[3.0], &[], &[]);

        assert_eq!(arena.nearest_before(-1.0), None);
        assert_eq!(arena.nearest_before(0.0), Some(CheckpointIdx(0)));
        assert_eq!(arena.nearest_before(1.5), Some(CheckpointIdx(1)));
        assert_eq!(arena.nearest_before(2.5), Some(CheckpointIdx(2)));
        assert_eq!(arena.nearest_before(100.0), Some(CheckpointIdx(3)));
    }

    #[test]
    fn reset_clears() {
        let mut arena = TransientArena::new();
        arena.push(0.0, &[1.0, 2.0], &[], &[]);
        arena.reset();
        assert!(arena.is_empty());
        assert!(arena.nearest_before(10.0).is_none());
    }
}
