# Settlement

Process decoded receipts and cursors to confirm mutations, roll back rejections and replay pending changes.

Current code: [client/push.rs](../../../../../crates/client/src/push.rs) (`settle_push`, `remove_rejected`); replay in [client/mutate.rs](../../../../../crates/client/src/mutate.rs) (`rebuild`)
