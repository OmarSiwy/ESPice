//! `bigospice-io` — simulator output format writers.
//!
//! Phase 3.8 of the BigOSpice roadmap consolidates every disk format the
//! simulator can emit behind a single crate so that:
//!
//! * The analysis crate stays focused on numerical math.
//! * Test infrastructure (round-tripping, golden comparison) lives next to
//!   the writers it targets.
//! * Adding a new format (HDF5, FsdB, native rawfile variants) is one new
//!   module + one `OutputFormat` variant — no parser or solver changes.
//!
//! ## Modules
//!
//! | Module           | Purpose                                                  |
//! |------------------|----------------------------------------------------------|
//! | [`rawfile`]      | Berkeley rawfile reader + ASCII / binary writer          |
//! | [`hspice`]       | HSPICE POST=2 binary `.tr0`/`.ac0`/`.sw0` + ASCII `.mt0` |
//! | [`touchstone`]   | Touchstone `.sNp` writer (S/Y/Z, MA/DB/RI)               |
//! | [`csv`]          | Generic column-major CSV writer                          |
//! | [`mt0`]          | Aggregated `.mt0` Monte-Carlo measurement output         |
//! | [`format_kind`]  | `OutputFormat` enum for runtime dispatch                 |
//! | [`print_select`] | Wildcard `.PRINT V(*) / I(*)` resolution                 |
//! | [`ac_output`]    | AC column extraction (VDB/VR/VI/VP/VM from complex data) |
//!
//! The four "user-facing" writer types are re-exported at crate root for
//! ergonomic `use bigospice_io::{RawfileWriter, HspicePostWriter, …};`.

#![deny(rust_2018_idioms)]

pub(crate) mod ac_output;
pub(crate) mod csv;
pub(crate) mod format_kind;
pub(crate) mod hspice;
pub(crate) mod mt0;
pub(crate) mod print_select;
pub(crate) mod rawfile;
pub(crate) mod touchstone;

// ── Public re-exports of the writer types ────────────────────────────────────

pub use ac_output::{AcData, UnknownNode, build_ac_columns, extract_ac_column};
pub use csv::CsvWriter;
pub use format_kind::{FormatKindError, OutputFormat};
pub use hspice::{HspiceMt0Writer, HspicePostKind, HspicePostWriter, HspiceVarType};
pub use mt0::{Mt0Row, Mt0Writer};
pub use print_select::{
    PrintColumn, PrintSelectError, PrintSpec, resolve as resolve_print_specs,
};
pub use rawfile::{Filetype, RawFile, RawFileError, RawFlag, RawVariable, RawfileWriter};
pub use touchstone::{ComplexFormat, FreqUnit, ParamType, TouchstoneError, TouchstoneWriter};
