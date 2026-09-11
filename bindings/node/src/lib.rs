mod server;
use napi::{bindgen_prelude::*, threadsafe_function::ThreadsafeFunction};
use napi_derive::napi;
use std::time::Instant;

#[napi(object)]
pub struct ProbeResult {
    pub observed: u32,
    pub callback_count: u32,
    pub payload_bytes: u32,
    pub elapsed_micros: f64,
}

/// No connection or ORM crosses this boundary. Each promise resolves on the
/// Node event loop using the application's existing transaction capability.
#[napi]
pub async fn run_probe(
    callback: ThreadsafeFunction<String, Promise<u32>, String, Status, false>,
    fail_after_write: bool,
) -> Result<ProbeResult> {
    let started = Instant::now();
    callback.call_async_catch("write".to_owned()).await?.await?;
    if fail_after_write {
        return Err(Error::from_reason("rust_probe_error"));
    }
    let observed = callback.call_async_catch("count".to_owned()).await?.await?;
    Ok(ProbeResult {
        observed,
        callback_count: 2,
        payload_bytes: ("write".len() + "count".len() + 2 * std::mem::size_of::<u32>()) as u32,
        elapsed_micros: started.elapsed().as_micros() as f64,
    })
}

mod client;
