use crate::{Error, Host, Result, code, head, principal, process_pull};
use ahead_core::{PullPage, SubscribeRequest, SubscriptionAck};
use serde::Serialize;
use serde_json::json;

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

/// The subscribe frame's shape and scope normalization are protocol rules
/// ([`SubscribeRequest`]); this maps their refusal to the request code.
pub fn decode_subscribe(bytes: &[u8]) -> Result<Vec<String>> {
    SubscribeRequest::decode(bytes)
        .map(|request| request.scopes)
        .map_err(|e| Error::new(code::REQUEST_INVALID, e.to_string()))
}

pub async fn negotiate(owner: &str, bytes: &[u8], host: &impl Host) -> Result<Negotiation> {
    principal(owner)?;
    let scopes = decode_subscribe(bytes)?;
    let mut accepted = vec![];
    for scope in scopes {
        let from_cursor = head(host, &scope).await?;
        accepted.push(Subscription { scope, from_cursor });
    }
    let ack = SubscriptionAck::new(accepted.iter().map(|entry| entry.scope.clone()).collect())
        .and_then(|ack| ack.encode())
        .map_err(|error| Error::new(code::INTERNAL, error.to_string()))?;
    let response =
        String::from_utf8(ack).map_err(|error| Error::new(code::INTERNAL, error.to_string()))?;
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
    let invalid = |m: String| Error::new(code::LIVE_INVALID_PAGE, m);
    let decoded = PullPage::decode(page.as_bytes())
        .map_err(|e| invalid(format!("invalid live page: {e}")))?;
    if decoded.channel != expected_scope {
        return Err(invalid("invalid live page scope".into()));
    }
    if decoded.from_cursor != expected_cursor {
        return Err(invalid("invalid live page progression".into()));
    }
    Ok(PageProgress {
        page: page.into(),
        to_cursor: decoded.to_cursor,
        continues: decoded.continues(),
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
            .map_err(|error| Error::new(code::INTERNAL, error.to_string()))?;
    let page = process_pull(config, owner, &request, host).await?;
    page_progress(&page, scope, from_cursor)
}
