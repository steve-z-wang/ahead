#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/scripts/env.sh"
cd "$root"
cargo test -p otter-compiler
cargo run -p otter-compiler -- compile fixtures/compiler integration/generated-api --backend-runtime ../../packages/server/index.mts --client-runtime ../../packages/client-js/index.mts
"$root/node_modules/.bin/tsc" -p integration/generated-api
if "$root/node_modules/.bin/tsc" --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext --strict --skipLibCheck --allowImportingTsExtensions integration/generated-api/backend-missing.ts >/dev/null 2>&1; then
  echo 'A handlers object missing a mutation unexpectedly typechecked.' >&2
  exit 1
fi
node integration/generated-api/test.ts
node integration/generated-api/native.mts
dart pub get --directory integration/generated-api
dart analyze integration/generated-api
cd integration/generated-api
dart test generated_test.dart
