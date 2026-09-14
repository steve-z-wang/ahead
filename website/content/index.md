---
hide:
  - toc
---

<div class="otter-intro" markdown="1">

# Ahead

<p class="otter-lead">Ahead is a schema-driven framework for building local-first apps with your own backend.</p>

<p class="otter-platforms">Clients: TypeScript · Flutter<br>Backend: TypeScript</p>

[See the API](project.md#build-with-ahead){ .md-button .md-button--primary }
[Compare frameworks](project.md#how-ahead-compares-with-other-sync-frameworks){ .md-button }

</div>

- **Schema-driven.** Define your models and local mutations in a schema. Ahead handles the local state changes.
- **Type-safe end to end.** Get typed client calls and backend read/write interfaces from the same schema.
- **Works offline.** Read and write local SQLite without a connection. Ahead persists changes and syncs in the background.
- **Your backend.** Implement your own read and write logic and choose your database. No vendor cloud service required.

## Build with Ahead

<div class="otter-guide-grid" markdown="1">

<div markdown="1">

### 1. Define your schema

Describe your models and local write operations. Ahead generates the client APIs and typed backend interfaces.

[Schema guide](crates/compiler/README.md)

</div>
<div markdown="1">

### 2. Read and write locally

Call the generated client to read and update local data. Watch queries to update your UI when the data changes.

[TypeScript](packages/client-js/README.md) · [Flutter](packages/dart/README.md)

</div>
<div markdown="1">

### 3. Implement your backend

Implement handlers for writes and loaders for reads through the generated interfaces. Use your own business logic and database.

[Backend guide](packages/server/README.md)

</div>

</div>

## Local state, background sync

Writes take effect locally, so your app can read the updated data without waiting for the network. Ahead saves pending writes and syncs them with your backend when connected. If the backend rejects a mutation, its local changes roll back.

[View the architecture](project.md#local-state-background-sync) · [Read the concepts](concepts.md)

## Current support

| Layer | Supported today |
| --- | --- |
| Frontend / client | [TypeScript](packages/client-js/README.md) · [Flutter](packages/dart/README.md) |
| Backend | [TypeScript](packages/server/README.md) |
| Database adapter | [Prisma with PostgreSQL](packages/persistence-prisma/README.md) |

The TypeScript client and backend currently run on Node.js. The clients use native runtimes; browser support is not yet implemented. See [platform validation](integration/platform/README.md) for tested environments.

Need another language, runtime, or database adapter? [Request support](https://github.com/steve-z-wang/ahead/issues/new). More integrations can be added.

## Project status

Ahead is an early alpha. Packages have not been published, and a license has not yet been added. Mobile runtime support is not yet verified; see [implementation status](docs/implementation-progress.md) for current coverage.
