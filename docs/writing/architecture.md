# Writing architecture documentation

Adapted from arc42: [building blocks](https://docs.arc42.org/section-5/), [runtime view](https://docs.arc42.org/section-6/) and [decisions](https://docs.arc42.org/section-9/). Required/optional choices below are Ahead conventions.

## Style

Keep each point short. Omit optional items unless needed. Verify claims against the code and distinguish target design.

## Content

### Required

1. **Responsibility** — What it owns and where its boundary ends.
2. **Interfaces** — How callers interact: inputs, outputs and operations.
3. **Invariants** — Correctness conditions that must always hold, even when the implementation changes.
4. **Code** — Link to implementation; add relevant tests when useful.

### Optional

5. **How it works** — Processing steps, loops, state and transitions.
6. **Failure and recovery** — Errors, retries, cancellation and rollback.
7. **Concurrency** — Ordering, coordination and transaction boundaries.
8. **Design decisions** — Important choices, alternatives and consequences.

## Examples

Client Push:

- **Responsibility** — Prepare queued mutations for delivery.
- **Interfaces** — Freeze eligible mutations into a batch; return none when no batch is available.
- **Invariants** — Retrying the same frozen batch preserves its sequence and payload.
- **Code** — [client/push.rs](../../crates/client/src/push.rs).
- **How it works (optional)** — Return an unacknowledged frozen batch before preparing a new one.

## Organization

Follow the [component tree](../engineering/architecture.md). One file per leaf; READMEs contain links and brief descriptions.
