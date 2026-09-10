# Standalone preparation

Prepared 2026-09-09 from LocalSync source revision `78e64a9bc93d3dab4bf256eed0a3051702f58882`.

## Scope

An independent source repository, documentation, CI, and an executable example.
Keep the compiler, Dart runtime and database adapters, TypeScript server, and all
five conformance contracts together. Keep package publication disabled for this
first source release. No application code, deployment configuration, credentials,
or Git history is included. The original application continues using its copy.

## Preparation plan

- Export only tracked framework files; omit the 10 tracked build/cache artifacts.
- Make the gate resolve paths from this repository root.
- Add standalone contributor documentation and CI using the existing gate.
- Add a runnable walkthrough using the real generated client, server and SQLite.
- Run the gate and example from this directory, and record results.
- Inspect the export for accidental credentials, outside-tree dependencies and broken links.

## Before public release

The owner must choose the license and confirm the rights to distribute this code.
No license grant is added during preparation. Repository name and public hosting
are also pending. npm and pub.dev packages remain unpublished.

## Alternatives considered

A new source snapshot keeps unrelated application history out of the repository.
A filtered history would preserve framework development history but requires
reviewing historical blobs before release. Preparing registry releases immediately
would add package naming, versioning and dependency distribution work; that is
outside this first phase.
