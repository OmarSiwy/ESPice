//! A seeded PRNG behind the two `std.testing.Smith` calls the frontend's
//! structured generators make, so a merge-gate test runs a generator over
//! thousands of inputs without `--fuzz` (which replays only the corpus).
const std = @import("std");

/// `index` and `eosWeightedSimple`, as `Smith` answers them.
pub const Seeded = struct {
    r: std.Random,

    /// Uniform in `0..len`; asserts `len > 0`.
    pub fn index(self: *Seeded, len: usize) usize {
        return self.r.uintLessThan(usize, len);
    }

    /// True with probability true_weight / (false_weight + true_weight).
    pub fn eosWeightedSimple(self: *Seeded, false_weight: u64, true_weight: u64) bool {
        return self.r.uintLessThan(u64, false_weight + true_weight) < true_weight;
    }
};
