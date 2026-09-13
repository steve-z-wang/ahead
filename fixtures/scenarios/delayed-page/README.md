# Delayed page

Entry e is provided by channels A and B. B delivers the record at stamp 8 first. A's page carrying stamp 7 arrives later: its content is discarded, A's cursor advances and A's claim is recorded. A later page from A at stamp 9 with the same content is a no-op. Covered by `delayed_page_from_another_channel_cannot_regress_newer_content` in `crates/sqlite/tests/stamp_scenarios.rs`.
