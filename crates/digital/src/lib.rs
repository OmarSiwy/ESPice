//! `bigospice-digital` — Native XSPICE-class digital event engine.
//!
//! This crate implements Phase 4.1 of the BigOSpice mixed-signal plan: a
//! data-oriented event-driven simulator for digital logic that interoperates
//! with the analog Newton-Raphson transient solver via `adc_bridge` /
//! `dac_bridge` elements (XSPICE-compatible `A` element syntax).
//!
//! ## Design highlights
//!
//! * **12-state logic** packed into a single byte (`DigState` is `#[repr(u8)]`).
//!   Strength is encoded in the upper bits so the basic value (0/1/X/Z) can be
//!   tested with a single mask.
//! * **SoA event queue** (`EventQueue`) — `times`, `nodes`, `values` live in
//!   parallel `Vec`s, with a `heap_indices` permutation maintaining the
//!   min-heap invariant on `times`. No `Box`/`Rc` per event.
//! * **Branchless primitive dispatch** via the `PrimitiveKind` enum and a flat
//!   `match` over a contiguous slice of primitive instances.
//! * **Bridges** — `AdcBridge` converts an analog node voltage into a digital
//!   event with hysteresis; `DacBridge` exposes a time-varying analog voltage
//!   driven by the digital state.
//! * **Transient hook** (`transient_hook::DigitalRuntime`) — flushes events up
//!   to `t_now` before each NR step and rolls back the queue past
//!   `t_now - h_new` if the analog NR fails.
//!
//! All hot loops are zero-allocation: capacity is reserved up-front and event
//! storage is reused via `swap_remove`.
//!
//! ## Public API summary
//!
//! ```text
//! DigState                — packed 12-state digital value
//! Strength                — Strong / Weak / Resistive
//! DigNodeIdx, EventIdx    — typed indices (newtype u32)
//! Event                   — pop_due output: { time, node, value }
//! EventQueue              — SoA priority queue with rollback
//! PrimitiveKind, Primitive— combinational + sequential primitives
//! PrimitiveBlock          — SoA storage for all primitives in a netlist
//! AdcBridge, DacBridge    — analog/digital boundary elements
//! BridgeBlock             — SoA storage for bridges
//! DigitalNet              — top-level container (nodes, primitives, bridges, queue)
//! AElement                — parser-side IR for an XSPICE `A` element
//! parse_a_element         — pure parser hook (string → AElement)
//! DigitalRuntime          — transient solver integration adapter
//! ```
//!
//! See `tests/schmitt_counter_dac.rs` for an end-to-end integration example.

pub(crate) mod state;
pub(crate) mod event_queue;
pub(crate) mod primitives;
pub(crate) mod bridges;
pub(crate) mod element;
pub(crate) mod transient_hook;

pub use state::{DigState, Strength};
pub use event_queue::{DigNodeIdx, Event, EventIdx, EventQueue};
pub use primitives::{Primitive, PrimitiveBlock, PrimitiveKind, EdgeKind};
pub use bridges::{AdcBridge, BridgeBlock, BridgeId, DacBridge};
pub use element::{parse_a_element, AElement, AModelKind};
pub use transient_hook::{DigitalNet, DigitalRuntime, RollbackPolicy};
