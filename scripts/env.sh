#!/usr/bin/env bash
# Prefer the optional workspace-local Rust install; otherwise use the developer's toolchain.
savoia_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$savoia_root/.tools/cargo/bin/cargo" ]]; then
 export CARGO_HOME="$savoia_root/.tools/cargo"
 export RUSTUP_HOME="$savoia_root/.tools/rustup"
 export PATH="$savoia_root/.tools/cargo/bin:$PATH"
fi
