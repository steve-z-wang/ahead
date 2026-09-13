# Next things / TODO

> Historical design record (2026-09-10): status statements and proposed APIs below reflect the original planning stage. See [implementation evidence](implementation-progress.md) for the current delivered scope and verified limitations.

2026-09-10: The user explicitly decided to finish the Rust rewrite while preserving existing behavior before discussing the capabilities below. These items are not prerequisites for the current implementation and do not indicate that they have been implemented.

## Current scope

Implement a schema-driven Rust client/server runtime, language SDKs, generators, and persistence adapters from scratch. Algorithmic behavior follows the reference implementation; improvements to names and public APIs must not silently change transaction, queue, settlement, or protocol semantics.

## Later work

- [ ] **Cross-channel record revision**: compare content versions when the same record arrives from different channels; do not use the channel cursor as a cross-channel recency measure.
- [ ] Consistent reads of recordRevision and loaded state; distribute the same version to multiple channels from one publication.
- [ ] Tests for same-version idempotence, conflict diagnostics, late old pages, and Move A→B→A.
- [ ] When extending cross-channel semantics, explicitly distinguish remove-from-channel from true delete, and design tombstone/watermark retention and safe cleanup.
- [ ] Evaluate the upgrade/fencing cost of optional revisions; there is currently no decision that every record must carry one or that revisions are enabled on demand.
- [ ] Review separately the current behavior that skips/advances the cursor after a pull failure; record the risk, and do not casually turn it into atomic whole-page apply during the rewrite.
- [ ] If needed, revisit per-mutation receipts / independent transactions and removal of accepted-prefix blocking; the current scope preserves batch transactions, batch receipts, and prefix settlement.
- [ ] A new wire version, decimal-string counters, epoch/reset, and automatic GC; these are separately designed protocol changes and are not enabled by default with the Rust migration.
- [ ] Extend the schema compatibility fence to inspect identity/type/nullability changes; preserve the current fence first, then design this independently.
- [ ] Wake after external user-transaction commits, additional polling, and multi-process notification strategy; first verify the current notification boundary.
- [ ] Improve settlement witness coverage, recovery after permission revocation, and the current channel-authorizer/host policy; do not remove old behavior without review.
- [ ] Client `openClient`: open in one step with a built-in transport, symmetric with the backend's `createBackend`.
- [ ] `authenticate` receives a Node `IncomingMessage`; supporting other runtimes needs an abstract request type.

## Confirmed naming

Use the names in [Concepts and Naming](architecture/concepts-and-naming.md). The names themselves are settled and are no longer TODOs. Current documentation and new APIs use Channel, Loader, Push/Pull, and Cursor/Checkpoint; old source and wire/storage fields retain their original names for comparison.

## Earlier record-revision proposal for future review

The earlier technical draft is retained below with terminology updated to the current names; example action names are not enabled wire fields. Expressions such as “recommended” and “first version/alpha” refer to the design of a future capability, not a decision for the current Rust rewrite. Optionality, deletion semantics, authorization, and GC still require confirmation.

### Two numbers, each with one purpose

- `channelCursor`: delivery progress for one channel, also used as a settlement witness.
- `recordRevision`: content recency for one `(model, identity)`; revisions of different records cannot be compared.

The recommendation is for every synchronized record to carry a revision from creation, avoiding the complexity of upgrading old messages after overlap is discovered. This needs neither a system-global variable nor one counter per model table.

One publish call fanning out to A/B shares one record revision; A and B each allocate their own channel cursor. Repeated publish calls for the same record require transaction-local merging or explicit reuse of a publication token; two distinct calls must not be described incorrectly as naturally incrementing only once.

The comparison domain for revisions also includes the authority namespace of the account/service instance. Within one client session, the same key/revision must yield the same complete authoritative content. If content differs by viewer, caches without account isolation cannot be reused when switching accounts. Different channels for the same viewer cannot present different field views under the same key/revision; split the model/identity instead.

Republishing solely because the audience changed may bump the revision even when the content is identical. The guarantee is that the same revision cannot represent conflicting authoritative content; the converse does not require identical content to share a revision.

### Three wire actions

- `upsert(identity, recordRevision, fullState)`: visible authoritative state.
- `removeFromChannel(identity)`: the current channel no longer provides it; changes membership in that channel's order.
- `deleteRecord(identity, recordRevision)`: the entity is truly deleted, superseding all older versions; deletion must still notify affected channels.

`removeFromChannel` and `deleteRecord` are explicitly distinct at the protocol level and cannot be inferred from null. Channel claims remain valuable after adding record revision and cannot simply be removed.

### Client application rules

1. First validate channel epoch/from/through and page order.
2. Process membership according to channel-stream progress; judge record content by cross-channel recordRevision. Ignoring stale content does not permit discarding its valid membership event.
3. A newer upsert advances the authoritative base, then replays pending work; the same revision with the same content is idempotent; conflicting content at the same revision is a protocol error and stops advancement.
4. A newer tombstone prevents an old upsert from resurrecting the record; an older tombstone likewise cannot replace newer content.
5. Removal releases only the current claim; retain the record if another valid claim exists. When the final claim leaves, authority availability becomes absent and pending work is handled by the established replay rules; pending work must not be silently discarded.
6. When channel removal causes a parent record to leave, it must not clear a child's valid claim from another channel without an explicit check. Test entity cascade separately from channel-membership cascade.

### Fetching the latest state does not solve reordering

Snapshot S1 reads rev10 and is delayed by the network; S2 reads rev11 and arrives first. The client must still reject rev10 when it later arrives. An invalidation's old revision cannot be paired with newer content read by a loader; current revision and state must agree within the snapshot.

### Storage scale and reset

The client retains version watermarks/tombstones to prevent old offline messages from resurrecting data; alpha does not use guessed TTL-based GC. Provide row/byte statistics and an explicit account-level reset. The server retains compacted invalidations and deduplication information. Before reaching scale limits, design channel generation + snapshot reset: fence old sessions first, then rebuild claims/cursors without deleting pending/local-only data. A watermark may be cleared only when old messages can be proven unable to reappear. Do not claim the cache is permanently bounded before this mechanism is complete.

Permission to subscribe to a channel does not imply that a record is visible. The loader is the content-authorization boundary; if an identity is itself sensitive, the transport layer must also filter withdrawal notifications for unknown identities. An optional channel guard is an optimization/metadata-protection measure, not a required business primitive. Permission changes must publish a withdrawal or trigger an explicit resnapshot.
