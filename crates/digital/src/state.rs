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
        assert_eq!(DigState::resolve(DigState::ZERO, DigState::Z), DigState::ZERO);
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
