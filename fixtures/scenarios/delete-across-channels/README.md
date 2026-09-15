# Delete across channels

Entry e is provided by channels A (stamp 1) and B (stamp 2). The delete is published to both. B delivers it first at stamp 4: the row is removed and the stamp is retained as evidence. A delayed upsert on A at stamp 3 is discarded. A's copy of the delete carries the same version: it changes nothing and only advances A's cursor. The stamp outlives the row, close and reopen, and an unsubscribe. Covered by `delete_keeps_its_stamp_so_stale_content_cannot_resurrect_the_record` and `reopen_preserves_stamps_and_tombstones` in `crates/sqlite/tests/stamp_scenarios.rs`.
