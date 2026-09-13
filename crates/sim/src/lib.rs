//! Deterministic simulation of N clients and one server in one process.
//! See docs/testing.md, section "Simulation crate".
pub mod net;
pub mod rng;
pub mod schema;
pub use rng::Rng;
