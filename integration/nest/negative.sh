#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
result="$(mktemp "${TMPDIR:-/tmp}/otter-nest-types.XXXXXX")"
trap 'rm -f "$result"' EXIT
if ./node_modules/.bin/tsc --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext --strict --skipLibCheck --allowImportingTsExtensions wrong-input.ts >"$result" 2>&1; then
  echo 'Invalid handler input unexpectedly typechecked.' >&2
  exit 1
fi
if ! grep -q "TS2339: Property 'missing' does not exist on type 'Input'" "$result"; then
  cat "$result" >&2
  exit 1
fi
