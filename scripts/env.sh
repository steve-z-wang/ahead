#!/usr/bin/env bash
# Prefer the optional workspace-local Rust install; otherwise use the developer's toolchain.
ahead_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$ahead_root/.tools/cargo/bin/cargo" ]]; then
 export CARGO_HOME="$ahead_root/.tools/cargo"
 export RUSTUP_HOME="$ahead_root/.tools/rustup"
 export PATH="$ahead_root/.tools/cargo/bin:$PATH"
fi
