use thiserror::Error;

/// Top-level error type for all BigOSpice operations.
#[derive(Debug, Error)]
pub enum SimError {
    #[error("Parse error: {0}")]
    Parse(String),

    #[error("Convergence failure after {iterations} iterations (residual={residual:.2e})")]
    Convergence { iterations: u32, residual: f64 },

    #[error("Singular matrix at row {row}")]
    SingularMatrix { row: usize },

    #[error("Node '{0}' not found")]
    NodeNotFound(String),

    #[error("Device '{0}' not found")]
    DeviceNotFound(String),

    #[error("Parameter '{param}' not set on device '{device}'")]
    MissingParam { device: String, param: String },

    #[error("Invalid parameter value: {param}={value} ({reason})")]
    InvalidParam {
        param: String,
        value: f64,
        reason: String,
    },

    #[error("Timestep too small: {0:.2e}")]
    TimestepTooSmall(f64),

    #[error("Analysis error: {0}")]
    Analysis(String),

    #[error("Cache error: {0}")]
    Cache(String),

    #[error("Compute backend error: {0}")]
    Compute(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Device '{device}' requires a branch index but none was assigned")]
    MissingBranchIndex { device: String },

    #[error("Analysis type '{analysis}' is not yet implemented")]
    Unimplemented { analysis: String },

    #[error("GPU backend unavailable: {reason}")]
    GpuUnavailable { reason: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_display() {
        let e = SimError::Convergence {
            iterations: 50,
            residual: 1e-3,
        };
        assert!(format!("{e}").contains("50 iterations"));

        let e = SimError::SingularMatrix { row: 5 };
        assert!(format!("{e}").contains("row 5"));
    }

    #[test]
    fn parse_error_display_contains_message() {
        let e = SimError::Parse("unexpected token 'x'".into());
        let s = format!("{e}");
        assert!(s.contains("unexpected token 'x'"), "got: {s}");
    }

    #[test]
    fn node_not_found_display_contains_name() {
        let e = SimError::NodeNotFound("vdd".into());
        let s = format!("{e}");
        assert!(s.contains("vdd"), "got: {s}");
    }

    #[test]
    fn device_not_found_display_contains_name() {
        let e = SimError::DeviceNotFound("R1".into());
        let s = format!("{e}");
        assert!(s.contains("R1"), "got: {s}");
    }

    #[test]
    fn missing_param_display_contains_device_and_param() {
        let e = SimError::MissingParam {
            device: "M1".into(),
            param: "kp".into(),
        };
        let s = format!("{e}");
        assert!(s.contains("M1"), "got: {s}");
        assert!(s.contains("kp"), "got: {s}");
    }

    #[test]
    fn invalid_param_display_contains_all_fields() {
        let e = SimError::InvalidParam {
            param: "vth".into(),
            value: -99.0,
            reason: "must be positive".into(),
        };
        let s = format!("{e}");
        assert!(s.contains("vth"), "got: {s}");
        assert!(s.contains("must be positive"), "got: {s}");
    }

    #[test]
    fn timestep_too_small_display_contains_value() {
        let e = SimError::TimestepTooSmall(1e-18);
        let s = format!("{e}");
        assert!(s.contains("1.00e-18") || s.contains("e-18"), "got: {s}");
    }

    #[test]
    fn analysis_error_display_contains_message() {
        let e = SimError::Analysis("DC sweep failed".into());
        let s = format!("{e}");
        assert!(s.contains("DC sweep failed"), "got: {s}");
    }

    #[test]
    fn cache_error_display_contains_message() {
        let e = SimError::Cache("stale cache version".into());
        let s = format!("{e}");
        assert!(s.contains("stale cache version"), "got: {s}");
    }

    #[test]
    fn compute_error_display_contains_message() {
        let e = SimError::Compute("GPU OOM".into());
        let s = format!("{e}");
        assert!(s.contains("GPU OOM"), "got: {s}");
    }

    #[test]
    fn missing_branch_index_display_contains_device() {
        let e = SimError::MissingBranchIndex { device: "L1".into() };
        let s = format!("{e}");
        assert!(s.contains("L1"), "got: {s}");
    }

    #[test]
    fn unimplemented_error_display_contains_analysis() {
        let e = SimError::Unimplemented { analysis: "Monte Carlo".into() };
        let s = format!("{e}");
        assert!(s.contains("Monte Carlo"), "got: {s}");
    }

    #[test]
    fn gpu_unavailable_display_contains_reason() {
        let e = SimError::GpuUnavailable { reason: "no CUDA device".into() };
        let s = format!("{e}");
        assert!(s.contains("no CUDA device"), "got: {s}");
    }

    #[test]
    fn convergence_error_display_contains_residual() {
        let e = SimError::Convergence { iterations: 100, residual: 1.23e-4 };
        let s = format!("{e}");
        // The residual format is {:.2e}
        assert!(s.contains("1.23e-4") || s.contains("1.23") || s.contains("e-4"),
            "display should mention residual: got {s}");
    }

    #[test]
    fn singular_matrix_display_contains_row_zero() {
        let e = SimError::SingularMatrix { row: 0 };
        let s = format!("{e}");
        assert!(s.contains("0"), "got: {s}");
    }
}
