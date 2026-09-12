#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/env.sh"
cd "$root"
npm ci
bash scripts/build.sh
cargo fmt --all --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
(cd examples/rust-round-trip && npm ci && npx prisma generate)
cargo run -p otter-compiler -- compile examples/rust-round-trip/models examples/rust-round-trip/generated
npm run typecheck
node --test integration/bindings/client-js/*.test.mjs
bash integration/persistence/transaction-probe/run.sh
bash integration/persistence/server/run.sh
(cd packages/nest && npm ci)
(cd integration/nest && npm ci && npm test)
case "$(uname -s)" in
 Darwin) export OTTER_LIBRARY="$root/target/debug/libotter_dart.dylib";;
 Linux) export OTTER_LIBRARY="$root/target/debug/libotter_dart.so";;
 *) echo 'Use the documented platform-specific native library path on this host.' >&2; exit 1;;
esac
export OTTER_DART_LIBRARY="$OTTER_LIBRARY"
(cd packages/dart && dart pub get && dart analyze && dart test)
bash integration/generated-api/verify.sh
bash integration/e2e/run.sh
