//! Solver crate — all Newton-Raphson math, convergence aids, Jacobian stamping.
//!
//! Submodule layout:
//!   src/linalg/    — sparse matrix, LU factorization (formerly incspice_linalg)
//!   src/compute/   — ComputeBackend (CPU/GPU BLAS) (formerly incspice_compute)
//!   src/device/    — device models, DeviceRegistry, DeviceEval (formerly incspice_device)
//!
//! Flat solver modules:
//!   src/backend.rs       — SolverConfig, SolverKind, Solver enum
//!   src/convergence.rs   — ConvergenceCriteria, ConvergenceStatus
//!   src/damping.rs       — DampingStrategy (None, Fixed, BankRose)
//!   src/device_eval.rs   — eval_bsim4_batch(), should_use_gpu()
//!   src/gmin_stepping.rs — GminStepping convergence aid
//!   src/source_stepping.rs — SourceStepping convergence aid
//!   src/junction_limit.rs  — pnjlim / fetlim / limvds
//!   src/pseudo_transient.rs — PseudoTransientConfig, solve_pseudo_transient()
//!   src/newton.rs        — NewtonRaphson, NrConfig, NrResult, VoltagePin
//!   src/stamper.rs       — stamp_circuit*(), update_{tline,ltra}_histories()
//!   src/anderson.rs      — AndersonAcceleration

pub mod linalg;
pub mod compute;
pub mod device;

pub mod anderson;
pub mod backend;
pub mod convergence;
pub mod damping;
pub mod device_eval;
pub mod gmin_stepping;
pub mod junction_limit;
pub mod newton;
pub mod pseudo_transient;
pub mod source_stepping;
pub mod stamper;

pub use anderson::AndersonAcceleration;
pub use backend::{Solver, SolverConfig, SolverKind};
pub use convergence::{ConvergenceCriteria, ConvergenceStatus};
pub use damping::DampingStrategy;
pub use device_eval::{eval_bsim4_batch, should_use_gpu};
pub use gmin_stepping::GminStepping;
pub use newton::{DEFAULT_GPU_DEVICE_THRESHOLD, NewtonRaphson, NrConfig, NrResult, VoltagePin};
pub use pseudo_transient::{PseudoTransientConfig, PtcResult, solve_pseudo_transient};
pub use source_stepping::{SourceStepping, SourceSteppingConfig};
pub use stamper::{
    stamp_circuit, stamp_circuit_gc_at_time, stamp_circuit_gc_into,
    stamp_circuit_gc_par_at_time, stamp_circuit_into, stamp_circuit_with_source_scale,
    update_ltra_histories, update_tline_histories,
};

// Re-export linalg types needed by analysis, cache, and cli.
pub use linalg::{CscMatrix, DenseVec, LuFactors, LinSolver, LinSolverKind, TripletMatrix};

// Re-export compute types needed by analysis and cli.
pub use compute::{AlignedVec, Backend, ComputeBackend, CpuBackend};

// Re-export device types at crate root for registry.rs convenience.
pub use device::{Bsim4};

/// Type alias: `SolverError` is `incspice_core::SimError`.
///
/// All solver functions return `incspice_core::SimError` directly. This alias
/// lets callers write `incspice_solver::SolverError` without a separate type.
pub type SolverError = incspice_core::SimError;

/// Check whether the GPU backend is available for use.
///
/// Returns `Ok(())` when the GPU feature is compiled in and at least one
/// wgpu adapter can be acquired at runtime.
///
/// Returns `Err(SimError::GpuUnavailable)` when:
/// - The crate was compiled without the `gpu` feature flag, or
/// - No compatible GPU adapter is found at runtime.
///
/// Call this before dispatching work to the GPU backend so that the caller
/// receives a typed error rather than a silent fall-through.
pub fn check_gpu_available() -> Result<(), incspice_core::SimError> {
    #[cfg(not(feature = "gpu"))]
    return Err(incspice_core::SimError::GpuUnavailable {
        reason: "compiled without 'gpu' feature".into(),
    });

    #[cfg(feature = "gpu")]
    {
        if !compute::WgpuBackend::is_available() {
            return Err(incspice_core::SimError::GpuUnavailable {
                reason: "no GPU adapter found".into(),
            });
        }
        Ok(())
    }
}

/// Tests for the GPU feature-flag system.  These always compile regardless of
/// whether the `gpu` feature is enabled.
#[cfg(test)]
mod gpu_feature_tests {
    use super::check_gpu_available;
    use incspice_core::SimError;

    /// Documents the feature-flag system and always passes.
    /// In CI without GPU hardware: `has_gpu_feature` will be `false`, which is correct.
    #[test]
    fn test_gpu_feature_gated_correctly() {
        let has_gpu_feature = cfg!(feature = "gpu");
        // In CI without GPU: has_gpu_feature = false, that's fine.
        let _ = has_gpu_feature;
    }

    /// When compiled without the `gpu` feature, `check_gpu_available()` must
    /// return a typed `GpuUnavailable` error mentioning the missing feature.
    #[test]
    #[cfg(not(feature = "gpu"))]
    fn test_gpu_backend_returns_error_without_feature() {
        let result = check_gpu_available();
        match result {
            Err(SimError::GpuUnavailable { reason }) => {
                assert!(
                    reason.contains("gpu"),
                    "expected reason to mention 'gpu', got: {reason}"
                );
            }
            other => panic!("expected GpuUnavailable, got: {other:?}"),
        }
    }
}

/// Convenience top-level solve function.
///
/// Runs a Newton-Raphson solve with the default `SolverConfig` and returns
/// the `NrResult`. Analysis crates call this instead of constructing a `Solver`
/// manually when they just need a DC operating point.
pub fn solve(
    circuit: &incspice_core::Circuit,
    registry: &device::DeviceRegistry,
    _config: &newton::NrConfig,
    _cache: &mut incspice_cache::CacheManager,
) -> Result<newton::NrResult, incspice_core::SimError> {
    let solver = backend::Solver::default();
    solver.solve(circuit, registry, None)
}

/// Like [`solve`] but seeds Newton-Raphson with a previous solution vector.
///
/// DC sweep uses this to carry the converged solution from one sweep point
/// to the next, matching ngspice's CKTrhsOld continuation behaviour.
pub fn solve_with_initial_guess(
    circuit: &incspice_core::Circuit,
    registry: &device::DeviceRegistry,
    _config: &newton::NrConfig,
    _cache: &mut incspice_cache::CacheManager,
    initial_guess: Option<&[f64]>,
) -> Result<newton::NrResult, incspice_core::SimError> {
    let solver = backend::Solver::default();
    solver.solve(circuit, registry, initial_guess)
}
