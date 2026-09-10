#!/usr/bin/env bash

# The TypeScript persistence ports, proven against the in-memory adapter.

set -euo pipefail

conformance="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "${LOCAL_SYNC_CONFORMANCE_PREPARED:-}" ]] || "$conformance/tool/prepare.sh"

cd "$conformance"
npx jest --runInBand server-persistence-contract/typescript
