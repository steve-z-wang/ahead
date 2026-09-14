use crate::{Host, Result, head, principal, process_pull};
use ahead_core::read_counter;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeSet;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Subscribe {
    #[serde(rename = "type")]
    kind: String,
    scopes: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Subscription {
    pub scope: String,
    pub from_cursor: u64,
}

#[derive(Debug, Serialize)]
pub struct Negotiation {
    pub response: String,
    pub subscriptions: Vec<Subscription>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageProgress {
    pub page: String,
    pub to_cursor: u64,
    pub continues: bool,
}

pub fn decode_subscribe(bytes: &[u8]) -> Result<Vec<String>> {
    let request: Subscribe = serde_json::from_slice(bytes).map_err(|_| "request.invalid")?;
    if request.kind != "subscribe" || request.scopes.is_empty() {
        return Err("request.invalid".into());
    }
    if request.scopes.iter().any(|scope| scope.is_empty()) {
        return Err("request.invalid".into());
    }
    let mut scopes: Vec<_> = request
        .scopes
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    scopes.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
    Ok(scopes)
}

pub async fn negotiate(owner: &str, bytes: &[u8], host: &impl Host) -> Result<Negotiation> {
    principal(owner)?;
    let scopes = decode_subscribe(bytes)?;
    let mut accepted = vec![];
    for scope in scopes {
        let from_cursor = head(host, &scope).await?;
        accepted.push(Subscription { scope, from_cursor });
    }
    let response = serde_json::to_string(&json!({
        "type":"subscribed",
        "scopes":accepted.iter().map(|entry| &entry.scope).collect::<Vec<_>>(),
        "rejections":[],
    }))
    .map_err(|error| error.to_string())?;
    Ok(Negotiation {
        response,
        subscriptions: accepted,
    })
}

pub fn page_progress(
    page: &str,
    expected_scope: &str,
    expected_cursor: u64,
) -> Result<PageProgress> {
    let value: Value = serde_json::from_str(page).map_err(|_| "invalid live page")?;
    if value["scope"] != expected_scope {
        return Err("invalid live page scope".into());
    }
    let from_cursor =
        read_counter(&value["fromCursor"], false).map_err(|error| error.to_string())?;
    let to_cursor = read_counter(&value["toCursor"], false).map_err(|error| error.to_string())?;
    let changes = value["changes"].as_array().ok_or("invalid live page")?;
    if from_cursor != expected_cursor || to_cursor < from_cursor || changes.len() > 50 {
        return Err("invalid live page progression".into());
    }
    Ok(PageProgress {
        page: page.into(),
        to_cursor,
        continues: changes.len() == 50,
    })
}

pub async fn pull(
    config: &crate::Config,
    owner: &str,
    scope: &str,
    from_cursor: u64,
    host: &impl Host,
) -> Result<PageProgress> {
    let request =
        serde_json::to_vec(&json!({"clientId":"live","scope":scope,"fromCursor":from_cursor}))
            .map_err(|error| error.to_string())?;
    let page = process_pull(config, owner, &request, host).await?;
    page_progress(&page, scope, from_cursor)
}
