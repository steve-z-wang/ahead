---
hide:
  - toc
---

<div class="lfs-intro" markdown="1">

<p class="lfs-kicker">LOCAL-FIRST STATE FRAMEWORK</p>

# State lives here.<br>Your backend stays yours.

<p class="lfs-lead">Read and edit local data. Keep it through restarts. Let the framework reconcile your changes with your application’s backend.</p>

<p class="lfs-platforms">TypeScript and Dart clients · TypeScript backend SDK · Shared Rust runtime</p>

[Run the example](examples/rust-round-trip/README.md){ .md-button .md-button--primary }
[Understand the model](concepts.md){ .md-button }

</div>

<div class="lfs-flow" role="group" aria-label="How a local edit reaches authoritative settlement">
  <div class="lfs-flow-step"><span class="lfs-state">LOCAL EDIT</span><strong>Visible immediately</strong><span>Your query reads the optimistic result.</span></div>
  <div class="lfs-flow-step"><span class="lfs-state">DURABLE MUTATION</span><strong>Ready when connected</strong><span>Queued intent survives a restart.</span></div>
  <div class="lfs-flow-step"><span class="lfs-state">AUTHORITATIVE STATE</span><strong>Reconciled through Pull</strong><span>Accepted edits settle at their checkpoints.</span></div>
</div>

## Try a complete round trip

Start the example from a source checkout with Rust, Node 22.18+, Python 3 and PostgreSQL command-line tools installed:

```sh
bash examples/rust-round-trip/run.sh
```

Then open the TypeScript client in a second terminal at the repository root:

```sh
node examples/rust-round-trip/client.mts
```

Try `sync`, `edit hello`, and `show`. Edit while offline, reopen the client, then reconnect to see the queued change reach the backend. The [quick start](examples/rust-round-trip/README.md) also walks through server normalization and rejection.

<div class="lfs-guide-grid" markdown="1">

<div markdown="1">

### Build the client

Query, watch and mutate local SQLite through typed APIs. Rust owns the durable queue and optimistic replay.

[TypeScript client](packages/client-js/README.md) · [Dart client](packages/dart/README.md)

</div>
<div markdown="1">

### Connect your backend

Implement Handlers and Loaders. Publish changes to explicit Channels within transactions your application owns.

[Backend SDK](packages/server/README.md) · [Prisma adapter](packages/persistence-prisma/README.md) · [Nest integration](packages/nest/README.md)

</div>
<div markdown="1">

### Define your models

Generate language types from a schema. Client models can differ from backend tables; the Rust runtime reads generic schema data.

[Schema compiler](crates/lfs-compiler/README.md) · [Architecture](docs/architecture/code-organization.md)

</div>

</div>

!!! note "Source alpha"
    Start from the runnable source example. Native Node and Dart flows are verified on macOS and Linux. Browser/WASM is not implemented; mobile runtime support is not yet verified. See [implementation status](docs/implementation-progress.md) and [compatibility and recovery](docs/architecture/compatibility-and-recovery.md) before integrating an existing application.

## One set of state rules

The shared Rust runtime handles schema validation, optimistic state, mutation scheduling, channel cursors and settlement. The language SDKs expose those capabilities through TypeScript and Dart APIs. Your business logic, authorization, network I/O and backend transactions stay in your application.

[Read the concepts](concepts.md) or explore the [tests and verification](integration/README.md).
