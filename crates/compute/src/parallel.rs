use rayon::prelude::*;

/// Configuration for when to switch from sequential to parallel execution.
pub struct ParallelConfig {
    /// Minimum number of elements before we dispatch to rayon.
    pub min_parallel_size: usize,
    /// Chunk size for parallel iteration.
    pub chunk_size: usize,
}

impl Default for ParallelConfig {
    fn default() -> Self {
        Self {
            min_parallel_size: 1024,
            chunk_size: 256,
        }
    }
}

impl ParallelConfig {
    /// Create a new configuration.
    pub fn new(min_parallel_size: usize, chunk_size: usize) -> Self {
        Self {
            min_parallel_size,
            chunk_size,
        }
    }
}

/// Execute `f(i)` for `i` in `0..range`, switching to rayon when `range` exceeds
/// the configured threshold.
pub fn parallel_for<F>(range: usize, config: &ParallelConfig, f: F)
where
    F: Fn(usize) + Sync + Send,
{
    if range >= config.min_parallel_size {
        (0..range).into_par_iter().for_each(|i| f(i));
    } else {
        for i in 0..range {
            f(i);
        }
    }
}

/// Parallel reduce over `0..range`. Each element produces a value via `f(i)`,
/// and results are combined with `reduce`. Falls back to sequential when below
/// the parallel threshold.
pub fn parallel_reduce<T, F, R>(
    range: usize,
    config: &ParallelConfig,
    identity: T,
    f: F,
    reduce: R,
) -> T
where
    T: Clone + Send + Sync,
    F: Fn(usize) -> T + Sync + Send,
    R: Fn(T, T) -> T + Sync + Send,
{
    if range >= config.min_parallel_size {
        (0..range)
            .into_par_iter()
            .map(|i| f(i))
            .reduce(|| identity.clone(), |a, b| reduce(a, b))
    } else {
        let mut acc = identity;
        for i in 0..range {
            acc = reduce(acc, f(i));
        }
        acc
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn parallel_for_small_stays_sequential() {
        // With a high threshold, a small range should still execute every index.
        let config = ParallelConfig::new(1024, 64);
        let counter = AtomicUsize::new(0);
        parallel_for(100, &config, |_| {
            counter.fetch_add(1, Ordering::Relaxed);
        });
        assert_eq!(counter.load(Ordering::Relaxed), 100);
    }

    #[test]
    fn parallel_for_large_correctness() {
        let config = ParallelConfig::new(512, 128);
        let n = 2048;
        let counter = AtomicUsize::new(0);
        parallel_for(n, &config, |_| {
            counter.fetch_add(1, Ordering::Relaxed);
        });
        assert_eq!(counter.load(Ordering::Relaxed), n);
    }

    #[test]
    fn parallel_for_zero_range() {
        let config = ParallelConfig::default();
        let counter = AtomicUsize::new(0);
        parallel_for(0, &config, |_| {
            counter.fetch_add(1, Ordering::Relaxed);
        });
        assert_eq!(counter.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn parallel_reduce_sum_small() {
        let config = ParallelConfig::new(1024, 64);
        let n = 100;
        let result = parallel_reduce(n, &config, 0u64, |i| i as u64, |a, b| a + b);
        assert_eq!(result, (n as u64 - 1) * n as u64 / 2);
    }

    #[test]
    fn parallel_reduce_sum_large() {
        let config = ParallelConfig::new(512, 128);
        let n = 5000;
        let result = parallel_reduce(n, &config, 0u64, |i| i as u64, |a, b| a + b);
        assert_eq!(result, (n as u64 - 1) * n as u64 / 2);
    }

    #[test]
    fn parallel_reduce_max() {
        let config = ParallelConfig::new(64, 16);
        let n = 2000;
        let result = parallel_reduce(
            n,
            &config,
            0usize,
            |i| i,
            |a, b| a.max(b),
        );
        assert_eq!(result, n - 1);
    }

    #[test]
    fn parallel_reduce_empty() {
        let config = ParallelConfig::default();
        let result = parallel_reduce(0, &config, 42u64, |i| i as u64, |a, b| a + b);
        assert_eq!(result, 42);
    }

    #[test]
    fn default_config_values() {
        let config = ParallelConfig::default();
        assert_eq!(config.min_parallel_size, 1024);
        assert_eq!(config.chunk_size, 256);
    }
}
