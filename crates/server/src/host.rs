//! The one typed definition of the host operation contract.
//!
//! Every request the engine may issue is a [`HostRequest`] variant and every
//! answer a host may give is one of the response types below. The TypeScript
//! mirror is `packages/server/host-contract.mts` and the shared examples are
//! `fixtures/protocol/host-operations.json`; a change here belongs in all three.
//!
//! This types what exists today. It adds no failure result and changes no
//! transaction semantics; [#95](https://github.com/zanminwang/ahead/issues/95)
//! may extend `handle`, `rollback` and `load` later.
use crate::{Error, Host, Result, code, valid_code};
use ahead_core::read_counter;
use serde::{Deserialize, Deserializer, Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::{fmt::Display, future::Future, pin::Pin};

/// A counter field that keeps [`read_counter`]'s tolerance (any integral JSON
/// number inside the safe range) and names itself when it refuses a value.
macro_rules! counter_field {
    ($module:ident, $label:literal, $positive:expr) => {
        mod $module {
            use super::*;
            pub fn serialize<S: serde::Serializer>(
                value: &u64,
                serializer: S,
            ) -> std::result::Result<S::Ok, S::Error> {
                serializer.serialize_u64(*value)
            }
            pub fn deserialize<'de, D: Deserializer<'de>>(
                deserializer: D,
            ) -> std::result::Result<u64, D::Error> {
                let value = Value::deserialize(deserializer)?;
                read_counter(&value, $positive).map_err(|error| {
                    serde::de::Error::custom(format!("invalid {}: {error}", $label))
                })
            }
        }
    };
}
counter_field!(counter, "counter", false);
counter_field!(sequence, "sequence", false);
counter_field!(cursor, "cursor", true);
counter_field!(stamp, "stamp", true);

/// `Some(Value::Null)` for an explicit `null`, `None` only when the key is absent.
fn present<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<Value>, D::Error> {
    Value::deserialize(deserializer).map(Some)
}

/// Every operation, in the order [`HostRequest`] declares them. The fixture
/// and `packages/server/host-contract.mts` carry the same list; the contract
/// test checks this one against the enum itself.
pub const OPERATIONS: [&str; 10] = [
    "claim",
    "saveReceipt",
    "head",
    "scan",
    "savepoint",
    "rollback",
    "release",
    "handle",
    "load",
    "publish",
];

/// Every request the engine issues to a host, tagged by `op` on the wire.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "op",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum HostRequest {
    /// Lock this client's row and report its last accepted batch.
    Claim { owner: String, client_id: String },
    /// Record the receipt for an accepted batch.
    SaveReceipt {
        owner: String,
        client_id: String,
        sequence: u64,
        receipt: String,
    },
    /// The channel's current head cursor.
    Head { channel: String },
    /// Invalidation rows after `after`, at most `limit` of them, in cursor order.
    Scan {
        channel: String,
        after: u64,
        limit: u64,
    },
    /// Open the savepoint that isolates one mutation.
    Savepoint { ordinal: u64 },
    /// Undo one mutation's effects back to its savepoint.
    Rollback { ordinal: u64 },
    /// Discard one mutation's savepoint, keeping its effects.
    Release { ordinal: u64 },
    /// Run one mutation's handler. `arguments` carries the decoded slots
    /// verbatim: its shape is the schema's business, not the contract's.
    Handle {
        name: String,
        version: u64,
        arguments: Value,
        owner: String,
        ordinal: u64,
    },
    /// Load the current state of these identities for this channel.
    Load {
        model: String,
        identities: Vec<Value>,
        owner: String,
        channel: String,
    },
    /// Invalidate one record on one channel and allocate its cursor and stamp.
    Publish {
        channel: String,
        model: String,
        identity: Value,
        identity_key: String,
    },
}

impl HostRequest {
    /// The operation, and the ordinal when the operation carries one.
    pub fn label(&self) -> String {
        match self {
            Self::Claim { .. } => "claim".into(),
            Self::SaveReceipt { .. } => "saveReceipt".into(),
            Self::Head { .. } => "head".into(),
            Self::Scan { .. } => "scan".into(),
            Self::Savepoint { ordinal } => format!("savepoint(ordinal {ordinal})"),
            Self::Rollback { ordinal } => format!("rollback(ordinal {ordinal})"),
            Self::Release { ordinal } => format!("release(ordinal {ordinal})"),
            Self::Handle { ordinal, .. } => format!("handle(ordinal {ordinal})"),
            Self::Load { .. } => "load".into(),
            Self::Publish { .. } => "publish".into(),
        }
    }
    /// The code an unusable response to this operation has always carried.
    fn invalid_code(&self) -> &'static str {
        match self {
            Self::Claim { .. } | Self::SaveReceipt { .. } | Self::Scan { .. } => {
                code::STORAGE_INVALID
            }
            Self::Handle { .. } => code::HANDLER_INVALID,
            Self::Load { .. } => code::LOADER_INVALID,
            Self::Head { .. }
            | Self::Savepoint { .. }
            | Self::Rollback { .. }
            | Self::Release { .. }
            | Self::Publish { .. } => code::HOST_INVALID,
        }
    }
    /// A response the protocol cannot use, named by operation.
    pub fn invalid_response(&self, detail: impl Display) -> Error {
        Error::new(
            self.invalid_code(),
            format!("{} response invalid: {detail}", self.label()),
        )
    }
}

/// An operation whose only answer is "done": `saveReceipt`, `savepoint`,
/// `rollback` and `release` all return `null` today.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Acknowledged;

/// The answer to `claim`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Claimed {
    pub client_id: String,
    pub owner: String,
    #[serde(with = "sequence")]
    pub sequence: u64,
    /// Absent and `null` both mean "no stored receipt", as they always have.
    #[serde(default)]
    pub receipt: Option<String>,
}

/// The answer to `head`: a bare counter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Head(#[serde(with = "counter")] pub u64);

/// One row of the answer to `scan`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Invalidation {
    pub channel: String,
    #[serde(with = "cursor")]
    pub cursor: u64,
    pub model: String,
    pub identity: Value,
    pub identity_key: String,
    #[serde(with = "stamp")]
    pub stamp: u64,
}

/// The answer to `scan`.
pub type Scanned = Vec<Invalidation>;

/// The answer to `load`: one entry per requested identity, `null` for a
/// record the channel cannot see.
pub type Loaded = Vec<Option<Value>>;

/// The answer to `publish`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Published {
    #[serde(with = "cursor")]
    pub cursor: u64,
    #[serde(with = "stamp")]
    pub stamp: u64,
}

/// The answer to `handle`: exactly one of a settlement channel or a rejection
/// code. Carrying both, or neither, is refused.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged, try_from = "HandledWire")]
pub enum Handled {
    Settled { channel: String },
    Rejected { rejection: String },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HandledWire {
    #[serde(default, deserialize_with = "present")]
    channel: Option<Value>,
    #[serde(default, deserialize_with = "present")]
    rejection: Option<Value>,
}

impl TryFrom<HandledWire> for Handled {
    type Error = String;
    fn try_from(wire: HandledWire) -> std::result::Result<Self, String> {
        match (wire.channel, wire.rejection) {
            (Some(_), Some(_)) => {
                Err("a settlement carries a channel or a rejection, not both".into())
            }
            (_, Some(rejection)) => rejection
                .as_str()
                .filter(|code| valid_code(code))
                .map(|code| Self::Rejected {
                    rejection: code.into(),
                })
                .ok_or_else(|| "invalid rejection code".into()),
            (Some(channel), None) => channel
                .as_str()
                .map(|channel| Self::Settled {
                    channel: channel.into(),
                })
                .ok_or_else(|| "invalid handler settlement".into()),
            (None, None) => Err("invalid handler settlement".into()),
        }
    }
}

/// Issue one typed request and decode the typed answer. `Host::call` keeps its
/// `Value` shape, so implementations outside this crate still compile.
pub trait HostExt {
    fn call_typed<'a, R: DeserializeOwned + Send + 'a>(
        &'a self,
        request: HostRequest,
    ) -> Pin<Box<dyn Future<Output = Result<R>> + Send + 'a>>;
}

impl<H: Host + ?Sized> HostExt for H {
    fn call_typed<'a, R: DeserializeOwned + Send + 'a>(
        &'a self,
        request: HostRequest,
    ) -> Pin<Box<dyn Future<Output = Result<R>> + Send + 'a>> {
        Box::pin(async move {
            let encoded = serde_json::to_value(&request)
                .map_err(|error| Error::new(code::INTERNAL, error.to_string()))?;
            let response = self.call(encoded).await?;
            serde_json::from_value(response).map_err(|error| request.invalid_response(error))
        })
    }
}
