#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$repo_root/conformance/tool/prepare.sh"
(
  cd "$repo_root/conformance"
  npm run build
)
node "$repo_root/examples/round-trip/run.cjs"
