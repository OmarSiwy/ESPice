// dod-utils modules (canonical going forward)
pub mod soa;
pub mod arena;
pub mod pool;
pub mod index;
pub mod bitset;
pub mod simd;

pub use arena::Arena;
pub use pool::{Pool, Handle};
pub use index::TypedIndex;
pub use bitset::BitSet;

pub(crate) mod static_map;
pub use static_map::{si_multiplier, SI_SUFFIX_MAP};
