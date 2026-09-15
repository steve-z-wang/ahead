mod server;
/// The transaction-bridge probe used only by the bindings' integration test.
/// It is compiled into the addon only with `--features probe`, so the normal
/// addon exposes no probe API.
#[cfg(feature = "probe")]
mod probe;
mod client;
