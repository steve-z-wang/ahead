#!/usr/bin/env bash
# Prefer the optional workspace-local Rust install; otherwise use the developer's toolchain.
lfs_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$lfs_root/.tools/cargo/bin/cargo" ]]; then
 export CARGO_HOME="$lfs_root/.tools/cargo"
 export RUSTUP_HOME="$lfs_root/.tools/rustup"
 export PATH="$lfs_root/.tools/cargo/bin:$PATH"
fi
