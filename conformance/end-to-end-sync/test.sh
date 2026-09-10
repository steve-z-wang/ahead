#!/usr/bin/env bash

# The whole promise: generated definitions, a real host, real bytes, and the
# answer read back out of the client's own database.

set -euo pipefail

conformance="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "${LOCAL_SYNC_CONFORMANCE_PREPARED:-}" ]] || "$conformance/tool/prepare.sh"

cd "$conformance"
npx jest --runInBand end-to-end-sync/typescript
