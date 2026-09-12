#!/usr/bin/env bash
# Prefer the optional workspace-local Rust install; otherwise use the developer's toolchain.
otter_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$otter_root/.tools/cargo/bin/cargo" ]]; then
 export CARGO_HOME="$otter_root/.tools/cargo"
 export RUSTUP_HOME="$otter_root/.tools/rustup"
 export PATH="$otter_root/.tools/cargo/bin:$PATH"
fi
