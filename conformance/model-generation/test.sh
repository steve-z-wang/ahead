#!/usr/bin/env bash

# What the compiler wrote, run rather than read.

set -euo pipefail

conformance="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "${LOCAL_SYNC_CONFORMANCE_PREPARED:-}" ]] || "$conformance/tool/prepare.sh"

cd "$conformance"
dart test model-generation/dart
npx jest --runInBand model-generation/typescript
