pub(crate) mod circuit;
pub(crate) mod device;
pub(crate) mod error;
pub(crate) mod expr;
pub(crate) mod expr_stats;
pub(crate) mod graph;
pub(crate) mod node;
pub(crate) mod options;
pub(crate) mod param;
pub(crate) mod stamp;
pub(crate) mod units;

pub use circuit::{
    AcStimulus, AdcBridgeSpec, Circuit, DacBridgeSpec, DigitalNetSpec, DigitalPrimitiveSpec,
    LtraHistoryStore, ModelKind, SubcktCall, SubcktDef, TlineHistory, VoltageConstraint,
};
pub use device::{DeviceId, DeviceInstance, DeviceKind, Terminal};
pub use error::SimError;
pub use expr::{BehavioralExpr, BinOp as BehavioralBinOp, BsourceExpr, ExprEval, ExprError, topo_sort_params};
pub use expr_stats::{Matching, StatExpr, StatKind, StatRng};
pub use graph::CompressedGraph;
pub use node::{Ground, Node, NodeId};
pub use options::{
    IntegrationMethod, LinSolverChoice, LinSolverKind, RawFmt, RolConfig, SimOptions,
};
pub use param::{CompiledParams, ParamKey, ParamMap, compiled_get};
pub use stamp::{StampEntry, StampType};
pub use units::Si;

// ── Streaming output sink ─────────────────────────────────────────────────────

/// Trait for streaming simulation output.
///
/// `emit_point` is called once per time/frequency/sweep step.
/// `finalize` is called once at the end to flush buffered data.
pub trait StreamingSink {
    fn emit_point(&mut self, sweep_val: f64, values: &[f64]) -> Result<(), SimError>;
    fn finalize(&mut self) -> Result<(), SimError>;
}

/// A no-op sink for benchmarks and analyses that produce no output.
pub struct NullSink;

impl StreamingSink for NullSink {
    fn emit_point(&mut self, _: f64, _: &[f64]) -> Result<(), SimError> { Ok(()) }
    fn finalize(&mut self) -> Result<(), SimError> { Ok(()) }
}
