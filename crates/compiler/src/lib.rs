//! The schema compiler: [`parse`] turns `.model` text into declarations,
//! [`validate`] checks them and produces the descriptors and typed-interface
//! input, and the emitters in [`emit`] render generated code.
use serde_json::Value;
mod emit;
mod history;
pub mod parse;
pub mod validate;
pub use emit::{backend_typescript, client_typescript, dart, typescript};
pub use history::{check_fence, reconcile_history};
pub use parse::{Declarations, Pos, parse};
pub use validate::validate;

/// Parse then validate one schema source.
pub fn compile(source: &str) -> Result<Value, String> {
    validate(&parse(source)?)
}
