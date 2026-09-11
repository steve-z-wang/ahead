#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/env.sh"
cd "$root"
cargo build --workspace --locked
node bindings/node/build.mjs
(cd packages/server && npm ci)
