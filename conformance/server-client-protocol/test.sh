#!/usr/bin/env bash

# The wire, with a real Dart client on one end and a real TypeScript host on
# the other.

set -euo pipefail

conformance="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "${LOCAL_SYNC_CONFORMANCE_PREPARED:-}" ]] || "$conformance/tool/prepare.sh"

cd "$conformance"
npx jest --runInBand server-client-protocol/typescript
