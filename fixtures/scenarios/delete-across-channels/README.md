# Delete across channels

Entry e is claimed by A (stamp 1) and B (stamp 2). The delete is notified to both. B delivers it first at stamp 4: the row is removed, A's claim remains as the tombstone marker. A delayed upsert on A at stamp 3 is discarded. A's delete at stamp 5 removes the last claim and the tombstone. Covered by `delete_across_channels_keeps_a_tombstone_until_every_claim_confirms` and `reopen_preserves_stamps_claims_and_tombstones` in `crates/sqlite/tests/stamp_scenarios.rs`.
