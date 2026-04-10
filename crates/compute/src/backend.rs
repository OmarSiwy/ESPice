use rayon::prelude::*;

use crate::parallel::ParallelConfig;

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// Abstraction over a compute backend (CPU, GPU, ...).
///
/// All operations take plain slices so the caller is free to use any storage
/// (e.g. [`AlignedVec`](crate::AlignedVec) or a raw `Vec<f64>`).
pub trait ComputeBackend: Send + Sync {
    /// Evaluate a batch of device instances in parallel.
    ///
    /// `voltages` has shape `[num_devices * num_terminals]` (row-major),
    /// `results`  has shape `[num_devices * num_outputs]`.
    fn eval_batch(
        &self,
        voltages: &[f64],
        num_devices: usize,
        num_terminals: usize,
        results: &mut [f64],
    );

    /// Parallel axpy: `y[i] += alpha * x[i]`.
    fn axpy(&self, alpha: f64, x: &[f64], y: &mut [f64]);

    /// Parallel dot product: `sum(x[i] * y[i])`.
    fn dot(&self, x: &[f64], y: &[f64]) -> f64;

    /// Parallel infinity norm: `max(|x[i]|)`.
    fn norm_inf(&self, x: &[f64]) -> f64;

    /// Parallel scale: `x[i] *= alpha`.
    fn scale(&self, alpha: f64, x: &mut [f64]);

    /// Human-readable backend name.
    fn name(&self) -> &str;
}

// ---------------------------------------------------------------------------
// CPU backend
// ---------------------------------------------------------------------------

/// CPU backend using `std::simd` (portable_simd) and rayon.
pub struct CpuBackend {
    pub num_threads: usize,
    config: ParallelConfig,
}

impl CpuBackend {
    /// Create a backend that parallelizes when vectors exceed `min_parallel_size`.
    pub fn new(num_threads: usize) -> Self {
        Self {
            num_threads,
            config: ParallelConfig::new(1024, 256),
        }
    }

    /// Create a backend with a custom parallel configuration.
    pub fn with_config(num_threads: usize, config: ParallelConfig) -> Self {
        Self {
            num_threads,
            config,
        }
    }
}

impl Default for CpuBackend {
    fn default() -> Self {
        Self::new(rayon::current_num_threads())
    }
}

// ---------------------------------------------------------------------------
// SIMD kernels (sequential, operate on contiguous slices)
// ---------------------------------------------------------------------------

const LANES: usize = 4;

/// `y += alpha * x` — auto-vectorizable scalar loop.
fn simd_axpy(alpha: f64, x: &[f64], y: &mut [f64]) {
    debug_assert_eq!(x.len(), y.len());
    y.iter_mut()
        .zip(x.iter())
        .for_each(|(yi, &xi)| *yi += alpha * xi);
}

/// dot product — auto-vectorizable scalar loop.
fn simd_dot(x: &[f64], y: &[f64]) -> f64 {
    debug_assert_eq!(x.len(), y.len());
    x.iter()
        .zip(y.iter())
        .map(|(&xi, &yi)| xi * yi)
        .sum()
}

/// infinity norm — auto-vectorizable scalar loop.
fn simd_norm_inf(x: &[f64]) -> f64 {
    x.iter()
        .copied()
        .fold(0.0f64, |acc, v| acc.max(v.abs()))
}

/// scale: `x *= alpha` — auto-vectorizable scalar loop.
fn simd_scale(alpha: f64, x: &mut [f64]) {
    x.iter_mut().for_each(|v| *v *= alpha);
}

// ---------------------------------------------------------------------------
// ComputeBackend impl
// ---------------------------------------------------------------------------

impl ComputeBackend for CpuBackend {
    fn eval_batch(
        &self,
        voltages: &[f64],
        num_devices: usize,
        num_terminals: usize,
        results: &mut [f64],
    ) {
        assert_eq!(
            voltages.len(),
            num_devices * num_terminals,
            "voltages length mismatch"
        );

        let num_outputs = if num_devices == 0 {
            0
        } else {
            results.len() / num_devices
        };

        if num_devices == 0 {
            return;
        }

        assert_eq!(
            results.len(),
            num_devices * num_outputs,
            "results length mismatch"
        );

        if num_devices >= self.config.min_parallel_size {
            results
                .par_chunks_mut(num_outputs)
                .enumerate()
                .for_each(|(dev_idx, out)| {
                    let v_start = dev_idx * num_terminals;
                    let v = &voltages[v_start..v_start + num_terminals];
                    // Default evaluation: sum terminal voltages per output.
                    let sum: f64 = v.iter().sum();
                    for o in out.iter_mut() {
                        *o = sum;
                    }
                });
        } else {
            for dev_idx in 0..num_devices {
                let v_start = dev_idx * num_terminals;
                let o_start = dev_idx * num_outputs;
                let v = &voltages[v_start..v_start + num_terminals];
                let sum: f64 = v.iter().sum();
                for o in &mut results[o_start..o_start + num_outputs] {
                    *o = sum;
                }
            }
        }
    }

    fn axpy(&self, alpha: f64, x: &[f64], y: &mut [f64]) {
        assert_eq!(x.len(), y.len(), "axpy: length mismatch");
        let n = x.len();

        if n >= self.config.min_parallel_size {
            let chunk = self.config.chunk_size.max(LANES);
            x.par_chunks(chunk)
                .zip(y.par_chunks_mut(chunk))
                .for_each(|(xc, yc)| {
                    simd_axpy(alpha, xc, yc);
                });
        } else {
            simd_axpy(alpha, x, y);
        }
    }

    fn dot(&self, x: &[f64], y: &[f64]) -> f64 {
        assert_eq!(x.len(), y.len(), "dot: length mismatch");
        let n = x.len();

        if n >= self.config.min_parallel_size {
            let chunk = self.config.chunk_size.max(LANES);
            x.par_chunks(chunk)
                .zip(y.par_chunks(chunk))
                .map(|(xc, yc)| simd_dot(xc, yc))
                .sum()
        } else {
            simd_dot(x, y)
        }
    }

    fn norm_inf(&self, x: &[f64]) -> f64 {
        let n = x.len();

        if n >= self.config.min_parallel_size {
            let chunk = self.config.chunk_size.max(LANES);
            x.par_chunks(chunk)
                .map(|xc| simd_norm_inf(xc))
                .reduce(|| 0.0f64, f64::max)
        } else {
            simd_norm_inf(x)
        }
    }

    fn scale(&self, alpha: f64, x: &mut [f64]) {
        let n = x.len();

        if n >= self.config.min_parallel_size {
            let chunk = self.config.chunk_size.max(LANES);
            x.par_chunks_mut(chunk).for_each(|xc| {
                simd_scale(alpha, xc);
            });
        } else {
            simd_scale(alpha, x);
        }
    }

    fn name(&self) -> &str {
        "cpu"
    }
}

// ---------------------------------------------------------------------------
// Enum dispatch backend
// ---------------------------------------------------------------------------

/// Concrete compute backend using enum dispatch instead of trait objects.
///
/// This avoids vtable indirection on every BLAS call while still supporting
/// multiple backend implementations.  The `ComputeBackend` trait is kept for
/// documentation and extensibility — `Backend` wraps the concrete types and
/// forwards via `match`.
pub enum Backend {
    /// CPU backend with SIMD + rayon parallelism.
    Cpu(CpuBackend),
    /// GPU backend using wgpu compute shaders.
    Gpu(crate::gpu_backend::WgpuBackend),
}

impl Backend {
    /// Create a CPU backend using all available rayon threads.
    pub fn cpu() -> Self {
        Self::Cpu(CpuBackend::default())
    }

    /// Create a CPU backend pinned to `n` threads.
    pub fn cpu_with_threads(n: usize) -> Self {
        Self::Cpu(CpuBackend::new(n))
    }

    /// Create a CPU backend with a custom parallel configuration.
    pub fn cpu_with_config(num_threads: usize, config: ParallelConfig) -> Self {
        Self::Cpu(CpuBackend::with_config(num_threads, config))
    }

    /// Try to create a GPU backend. Returns `None` if no adapter is found.
    pub fn gpu(min_gpu_size: usize) -> Option<Self> {
        crate::gpu_backend::WgpuBackend::new(min_gpu_size).map(Self::Gpu)
    }
}

impl ComputeBackend for Backend {
    fn eval_batch(
        &self,
        voltages: &[f64],
        num_devices: usize,
        num_terminals: usize,
        results: &mut [f64],
    ) {
        match self {
            Self::Cpu(b) => b.eval_batch(voltages, num_devices, num_terminals, results),
            Self::Gpu(b) => b.eval_batch(voltages, num_devices, num_terminals, results),
        }
    }

    fn axpy(&self, alpha: f64, x: &[f64], y: &mut [f64]) {
        match self {
            Self::Cpu(b) => b.axpy(alpha, x, y),
            Self::Gpu(b) => b.axpy(alpha, x, y),
        }
    }

    fn dot(&self, x: &[f64], y: &[f64]) -> f64 {
        match self {
            Self::Cpu(b) => b.dot(x, y),
            Self::Gpu(b) => b.dot(x, y),
        }
    }

    fn norm_inf(&self, x: &[f64]) -> f64 {
        match self {
            Self::Cpu(b) => b.norm_inf(x),
            Self::Gpu(b) => b.norm_inf(x),
        }
    }

    fn scale(&self, alpha: f64, x: &mut [f64]) {
        match self {
            Self::Cpu(b) => b.scale(alpha, x),
            Self::Gpu(b) => b.scale(alpha, x),
        }
    }

    fn name(&self) -> &str {
        match self {
            Self::Cpu(b) => b.name(),
            Self::Gpu(b) => b.name(),
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn cpu() -> CpuBackend {
        CpuBackend::new(1)
    }

    // -- axpy ---------------------------------------------------------------

    #[test]
    fn axpy_basic() {
        let b = cpu();
        let x = vec![1.0, 2.0, 3.0, 4.0];
        let mut y = vec![10.0, 20.0, 30.0, 40.0];
        b.axpy(2.0, &x, &mut y);
        assert_eq!(y, vec![12.0, 24.0, 36.0, 48.0]);
    }

    #[test]
    fn axpy_zero_alpha() {
        let b = cpu();
        let x = vec![1.0; 8];
        let mut y = vec![5.0; 8];
        b.axpy(0.0, &x, &mut y);
        assert_eq!(y, vec![5.0; 8]);
    }

    #[test]
    fn axpy_negative_alpha() {
        let b = cpu();
        let x = vec![1.0, 2.0, 3.0];
        let mut y = vec![10.0, 10.0, 10.0];
        b.axpy(-1.0, &x, &mut y);
        assert_eq!(y, vec![9.0, 8.0, 7.0]);
    }

    #[test]
    fn axpy_non_simd_aligned_length() {
        let b = cpu();
        // 7 elements — not a multiple of LANES (4).
        let x = vec![1.0; 7];
        let mut y = vec![0.0; 7];
        b.axpy(3.0, &x, &mut y);
        assert_eq!(y, vec![3.0; 7]);
    }

    #[test]
    fn axpy_empty() {
        let b = cpu();
        let x: Vec<f64> = vec![];
        let mut y: Vec<f64> = vec![];
        b.axpy(1.0, &x, &mut y);
        assert!(y.is_empty());
    }

    #[test]
    fn axpy_large_parallel() {
        let b = CpuBackend::new(4);
        let n = 4096;
        let x: Vec<f64> = (0..n).map(|i| i as f64).collect();
        let mut y = vec![1.0; n];
        b.axpy(2.0, &x, &mut y);
        for i in 0..n {
            assert_eq!(y[i], 1.0 + 2.0 * i as f64);
        }
    }

    // -- dot ----------------------------------------------------------------

    #[test]
    fn dot_basic() {
        let b = cpu();
        let x = vec![1.0, 2.0, 3.0, 4.0];
        let y = vec![5.0, 6.0, 7.0, 8.0];
        let result = b.dot(&x, &y);
        // 1*5 + 2*6 + 3*7 + 4*8 = 5 + 12 + 21 + 32 = 70
        assert_eq!(result, 70.0);
    }

    #[test]
    fn dot_self() {
        let b = cpu();
        let x = vec![3.0, 4.0];
        let result = b.dot(&x, &x);
        assert_eq!(result, 25.0); // 9 + 16
    }

    #[test]
    fn dot_non_aligned() {
        let b = cpu();
        let x = vec![1.0, 1.0, 1.0, 1.0, 1.0]; // 5 elements
        let y = vec![2.0, 2.0, 2.0, 2.0, 2.0];
        assert_eq!(b.dot(&x, &y), 10.0);
    }

    #[test]
    fn dot_empty() {
        let b = cpu();
        let x: Vec<f64> = vec![];
        let y: Vec<f64> = vec![];
        assert_eq!(b.dot(&x, &y), 0.0);
    }

    #[test]
    fn dot_large_parallel() {
        let b = CpuBackend::new(4);
        let n = 8192;
        let x = vec![1.0; n];
        let y = vec![1.0; n];
        assert_eq!(b.dot(&x, &y), n as f64);
    }

    // -- norm_inf -----------------------------------------------------------

    #[test]
    fn norm_inf_basic() {
        let b = cpu();
        let x = vec![1.0, -5.0, 3.0, 2.0];
        assert_eq!(b.norm_inf(&x), 5.0);
    }

    #[test]
    fn norm_inf_all_negative() {
        let b = cpu();
        let x = vec![-3.0, -7.0, -1.0];
        assert_eq!(b.norm_inf(&x), 7.0);
    }

    #[test]
    fn norm_inf_zeros() {
        let b = cpu();
        let x = vec![0.0; 8];
        assert_eq!(b.norm_inf(&x), 0.0);
    }

    #[test]
    fn norm_inf_single() {
        let b = cpu();
        assert_eq!(b.norm_inf(&[-42.0]), 42.0);
    }

    #[test]
    fn norm_inf_empty() {
        let b = cpu();
        assert_eq!(b.norm_inf(&[]), 0.0);
    }

    #[test]
    fn norm_inf_non_aligned() {
        let b = cpu();
        let x = vec![-1.0, 2.0, -3.0, 4.0, -5.0, 6.0, -7.0];
        assert_eq!(b.norm_inf(&x), 7.0);
    }

    #[test]
    fn norm_inf_large_parallel() {
        let b = CpuBackend::new(4);
        let n = 4096;
        let mut x = vec![1.0; n];
        x[n / 2] = -999.0;
        assert_eq!(b.norm_inf(&x), 999.0);
    }

    // -- scale --------------------------------------------------------------

    #[test]
    fn scale_basic() {
        let b = cpu();
        let mut x = vec![1.0, 2.0, 3.0, 4.0];
        b.scale(3.0, &mut x);
        assert_eq!(x, vec![3.0, 6.0, 9.0, 12.0]);
    }

    #[test]
    fn scale_zero() {
        let b = cpu();
        let mut x = vec![1.0, 2.0, 3.0];
        b.scale(0.0, &mut x);
        assert_eq!(x, vec![0.0, 0.0, 0.0]);
    }

    #[test]
    fn scale_negative() {
        let b = cpu();
        let mut x = vec![1.0, -2.0, 3.0];
        b.scale(-1.0, &mut x);
        assert_eq!(x, vec![-1.0, 2.0, -3.0]);
    }

    #[test]
    fn scale_non_aligned() {
        let b = cpu();
        let mut x = vec![2.0; 5];
        b.scale(0.5, &mut x);
        assert_eq!(x, vec![1.0; 5]);
    }

    #[test]
    fn scale_empty() {
        let b = cpu();
        let mut x: Vec<f64> = vec![];
        b.scale(2.0, &mut x);
        assert!(x.is_empty());
    }

    #[test]
    fn scale_large_parallel() {
        let b = CpuBackend::new(4);
        let n = 4096;
        let mut x: Vec<f64> = (0..n).map(|i| i as f64).collect();
        b.scale(2.0, &mut x);
        for i in 0..n {
            assert_eq!(x[i], 2.0 * i as f64);
        }
    }

    // -- eval_batch ---------------------------------------------------------

    #[test]
    fn eval_batch_basic() {
        let b = cpu();
        // 3 devices, 2 terminals each, 1 output each.
        let voltages = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
        let mut results = vec![0.0; 3];
        b.eval_batch(&voltages, 3, 2, &mut results);
        // Each output = sum of terminals for that device.
        assert_eq!(results, vec![3.0, 7.0, 11.0]);
    }

    #[test]
    fn eval_batch_empty() {
        let b = cpu();
        let voltages: Vec<f64> = vec![];
        let mut results: Vec<f64> = vec![];
        b.eval_batch(&voltages, 0, 2, &mut results);
        assert!(results.is_empty());
    }

    #[test]
    fn eval_batch_multi_output() {
        let b = cpu();
        // 2 devices, 3 terminals, 2 outputs each.
        let voltages = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
        let mut results = vec![0.0; 4]; // 2 devices * 2 outputs
        b.eval_batch(&voltages, 2, 3, &mut results);
        // device 0: sum = 6.0 -> [6.0, 6.0]
        // device 1: sum = 15.0 -> [15.0, 15.0]
        assert_eq!(results, vec![6.0, 6.0, 15.0, 15.0]);
    }

    // -- name ---------------------------------------------------------------

    #[test]
    fn name_is_cpu() {
        let b = cpu();
        assert_eq!(b.name(), "cpu");
    }

    // -- trait object -------------------------------------------------------

    #[test]
    fn backend_is_object_safe() {
        let b: Box<dyn ComputeBackend> = Box::new(CpuBackend::default());
        assert_eq!(b.name(), "cpu");
        let x = vec![1.0, 2.0, 3.0, 4.0];
        let y = vec![1.0, 1.0, 1.0, 1.0];
        assert_eq!(b.dot(&x, &y), 10.0);
    }

    // -- enum dispatch ------------------------------------------------------

    #[test]
    fn backend_enum_cpu() {
        let b = Backend::cpu();
        assert_eq!(b.name(), "cpu");
        let x = vec![1.0, 2.0, 3.0, 4.0];
        let mut y = vec![10.0, 20.0, 30.0, 40.0];
        b.axpy(2.0, &x, &mut y);
        assert_eq!(y, vec![12.0, 24.0, 36.0, 48.0]);
    }

    #[test]
    fn backend_enum_cpu_with_threads() {
        let b = Backend::cpu_with_threads(2);
        assert_eq!(b.name(), "cpu");
        assert_eq!(b.dot(&[1.0, 2.0, 3.0], &[4.0, 5.0, 6.0]), 32.0);
    }

    #[test]
    fn backend_enum_cpu_norm_inf() {
        let b = Backend::cpu();
        assert_eq!(b.norm_inf(&[1.0, -5.0, 3.0]), 5.0);
    }

    #[test]
    fn backend_enum_cpu_scale() {
        let b = Backend::cpu();
        let mut x = vec![1.0, 2.0, 3.0, 4.0];
        b.scale(3.0, &mut x);
        assert_eq!(x, vec![3.0, 6.0, 9.0, 12.0]);
    }

    #[test]
    fn backend_enum_cpu_eval_batch() {
        let b = Backend::cpu();
        let voltages = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
        let mut results = vec![0.0; 3];
        b.eval_batch(&voltages, 3, 2, &mut results);
        assert_eq!(results, vec![3.0, 7.0, 11.0]);
    }
}
