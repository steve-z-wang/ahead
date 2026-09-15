use napi::{bindgen_prelude::*, threadsafe_function::ThreadsafeFunction};
use napi_derive::napi;
use serde_json::Value;
use std::{future::Future, pin::Pin};
struct CallbackHost(ThreadsafeFunction<String, Promise<String>, String, Status, false>);
impl ahead_server::Host for CallbackHost {
    fn call(
        &self,
        request: Value,
    ) -> Pin<Box<dyn Future<Output = ahead_server::HostResult<Value>> + Send + '_>> {
        Box::pin(async move {
            let returned = self
                .0
                .call_async_catch(request.to_string())
                .await
                .map_err(|e| e.to_string())?
                .await
                .map_err(|e| e.to_string())?;
            serde_json::from_str(&returned).map_err(|e| e.to_string())
        })
    }
}
/// The engine error crosses N-API as its JSON encoding in the reason string;
/// the server SDK decodes it back into `{code, message, details}`.
fn reason(error: ahead_server::Error) -> Error {
    Error::from_reason(serde_json::to_string(&error).unwrap_or_else(|_| error.to_string()))
}
fn internal(error: impl std::fmt::Display) -> Error {
    reason(ahead_server::Error::new(
        ahead_server::code::INTERNAL,
        error.to_string(),
    ))
}
fn config(raw: &str) -> Result<ahead_server::Config> {
    ahead_server::Config::decode(serde_json::from_str(raw).map_err(|e| {
        reason(ahead_server::Error::new(
            ahead_server::code::CONFIG_INVALID,
            e.to_string(),
        ))
    })?)
    .map_err(reason)
}
#[napi]
pub fn validate_config(config_json: String) -> Result<()> {
    config(&config_json).map(|_| ())
}
#[napi]
pub async fn process_push(
    config_json: String,
    owner: String,
    request_json: String,
    callback: ThreadsafeFunction<String, Promise<String>, String, Status, false>,
) -> Result<String> {
    ahead_server::process_push(
        &config(&config_json)?,
        &owner,
        request_json.as_bytes(),
        &CallbackHost(callback),
    )
    .await
    .map_err(reason)
}
#[napi]
pub async fn process_pull(
    config_json: String,
    owner: String,
    request_json: String,
    callback: ThreadsafeFunction<String, Promise<String>, String, Status, false>,
) -> Result<String> {
    ahead_server::process_pull(
        &config(&config_json)?,
        &owner,
        request_json.as_bytes(),
        &CallbackHost(callback),
    )
    .await
    .map_err(reason)
}
#[napi]
pub async fn publish(
    config_json: String,
    changes_json: String,
    channels_json: String,
    callback: ThreadsafeFunction<String, Promise<String>, String, Status, false>,
) -> Result<String> {
    let publish_invalid = |e: serde_json::Error| {
        reason(ahead_server::Error::new(
            ahead_server::code::PUBLISH_INVALID,
            e.to_string(),
        ))
    };
    let changes = serde_json::from_str(&changes_json).map_err(publish_invalid)?;
    let channels = serde_json::from_str(&channels_json).map_err(publish_invalid)?;
    ahead_server::publish(
        &config(&config_json)?,
        &changes,
        &channels,
        &CallbackHost(callback),
    )
    .await
    .map(|v| v.to_string())
    .map_err(reason)
}
#[napi]
pub async fn negotiate_live(
    owner: String,
    request_json: String,
    callback: ThreadsafeFunction<String, Promise<String>, String, Status, false>,
) -> Result<String> {
    let result =
        ahead_server::live::negotiate(&owner, request_json.as_bytes(), &CallbackHost(callback))
            .await
            .map_err(reason)?;
    serde_json::to_string(&result).map_err(internal)
}
#[napi]
pub async fn pull_live(
    config_json: String,
    owner: String,
    scope: String,
    from_cursor: f64,
    callback: ThreadsafeFunction<String, Promise<String>, String, Status, false>,
) -> Result<String> {
    if !from_cursor.is_finite()
        || from_cursor.fract() != 0.0
        || from_cursor < 0.0
        || from_cursor > 9_007_199_254_740_991.0
    {
        return Err(reason(ahead_server::Error::new(
            ahead_server::code::REQUEST_INVALID,
            "invalid live cursor",
        )));
    }
    let result = ahead_server::live::pull(
        &config(&config_json)?,
        &owner,
        &scope,
        from_cursor as u64,
        &CallbackHost(callback),
    )
    .await
    .map_err(reason)?;
    serde_json::to_string(&result).map_err(internal)
}
