// Original modules
pub mod simd_block;
pub mod soa_vec;
pub mod simd_complex;
pub mod typed_arena;
pub mod index_vec;

pub use simd_block::SimdBlock;
pub use soa_vec::SoaVec;
pub use simd_complex::SimdComplex;
pub use typed_arena::TypedArena;
pub use index_vec::IndexVec;

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
