#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/scripts/env.sh"
cd "$root"
cargo test -p otter-compiler
cargo run -p otter-compiler -- compile fixtures/compiler integration/generated-api
"$root/node_modules/.bin/tsc" -p integration/generated-api
node integration/generated-api/test.ts
node integration/generated-api/native.mts
dart pub get --directory integration/generated-api
dart analyze integration/generated-api
cd integration/generated-api
dart test generated_test.dart
