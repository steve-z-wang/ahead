#!/usr/bin/env bash

# The Dart database port, proven against every adapter that claims it.

set -euo pipefail

conformance="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "${LOCAL_SYNC_CONFORMANCE_PREPARED:-}" ]] || "$conformance/tool/prepare.sh"

cd "$conformance"
dart test client-storage-contract/dart
