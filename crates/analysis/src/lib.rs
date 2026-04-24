//! Analysis engine — trait-based. Every analysis implements `Analysis`.
//! Digital runtime also lives here (hooks into solver via analysis trait).
//!
//! Streaming: each analysis writes results through `StreamingSink` per-point.
//! NR inner loop = feedback (can't stream). Sweep points = stream out.

pub mod digital;
pub mod cosim;

mod r#trait;
mod dc_op;
mod dc_sweep;
mod transient;
mod ac;
mod public_api;
mod hb;
mod pss;
mod mc;
mod sensitivity;
mod result;
mod sweep;
mod companion;
mod measure;
mod rol;
mod sampling;
mod noise;
mod fourier;
mod fft;
mod pz;
mod tf;
mod sp;
mod disto;
mod envelope;
mod wcase;
mod alter;
mod control;
mod sens_ac;

pub use r#trait::*;
pub use dc_op::*;
pub use dc_sweep::*;
pub use transient::*;
pub use ac::*;
pub use hb::*;
pub use pss::*;
pub use mc::*;
pub use sensitivity::*;
pub use result::*;
pub use sweep::*;
pub use companion::*;
pub use measure::*;
pub use rol::*;
pub use sampling::*;
pub use noise::*;
pub use fourier::*;
pub use fft::*;
pub use pz::*;
pub use tf::*;
pub use sp::*;
pub use disto::*;
pub use envelope::*;
pub use wcase::*;
pub use alter::*;
pub use control::*;
pub use sens_ac::*;
pub use public_api::*;
