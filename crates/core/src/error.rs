use thiserror::Error;

/// Top-level error type for all VOLTAIC operations.
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
    InvalidParam { param: String, value: f64, reason: String },

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
}

/// Result alias for VOLTAIC operations.
pub type Result<T> = std::result::Result<T, SimError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_display() {
        let e = SimError::Convergence { iterations: 50, residual: 1e-3 };
        assert!(format!("{e}").contains("50 iterations"));

        let e = SimError::SingularMatrix { row: 5 };
        assert!(format!("{e}").contains("row 5"));
    }
}
