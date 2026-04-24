pub mod aligned_vec;
pub mod backend;
pub mod bsim4_batch;
pub mod memory_pool;
pub mod parallel;
#[cfg(feature = "gpu")]
pub mod gpu_backend;

pub use aligned_vec::AlignedVec;
pub use backend::{Backend, ComputeBackend, CpuBackend};
pub use bsim4_batch::{
    Bsim4BatchInput, Bsim4BatchOutput, ComputeError, eval_bsim4_batch, eval_bsim4_batch_cpu,
};
pub use memory_pool::MemoryPool;
pub use parallel::{ParallelConfig, parallel_for, parallel_reduce};
#[cfg(feature = "gpu")]
pub use gpu_backend::WgpuBackend;
