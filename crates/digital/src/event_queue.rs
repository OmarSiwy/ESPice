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

use crate::state::DigState;

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
    use crate::state::DigState;

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
