#!/usr/bin/env bash

# Everything a contract needs before it can assert anything: both toolchains
# installed, the TypeScript Backend runtime built (the conformance workspace
# depends on it by path), and the generated outputs written fresh from the
# definitions. Conformance generation is never committed — it is regenerated
# here, so a contract always runs against the compiler in the tree.

set -euo pipefail

conformance="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
local_sync="$(cd "$conformance/.." && pwd)"

(
  cd "$local_sync/server"
  npm ci
  # Built from clean: the conformance workspace resolves this package by path,
  # so a stale dist/ would let a contract pass against last week's Backend.
  rm -rf dist
  npm run build
)

(
  cd "$conformance"
  npm ci
  dart pub get
)

(
  cd "$local_sync/compiler"
  dart pub get
  dart run bin/local_sync_compiler.dart \
    --definitions ../conformance/definitions \
    --mutation-history ../conformance/definitions/mutation-contract.json \
    --dart-out ../conformance/lib/src/generated \
    --contract-out ../conformance/generated/model-contract.json \
    --typescript-backend-out ../conformance/generated/backend
)
