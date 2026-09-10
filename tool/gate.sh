#!/usr/bin/env bash

# The framework's complete gate: each layer's
# own tests beside that layer, then every cross-layer conformance contract, then
# the independence fences. Product generation lives with its consumers.
#
# The contract list is not written here. This script prepares conformance once
# and asks the conformance dispatcher what to run, so adding a test — or a whole
# contract's worth of them — never means editing the gate.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="$repo_root/compiler"
runtime="$repo_root/client/local_sync"
conformance="$repo_root/conformance"
backend="$repo_root/server"
typescript_backend="$conformance/generated/backend"

# ── The layers, each proving its own algorithms.

(
  cd "$compiler"
  dart pub get
  dart format --output=none --set-exit-if-changed lib test bin
  dart analyze
  dart test
)

(
  cd "$runtime"
  dart pub get
  dart format --output=none --set-exit-if-changed lib test
  dart analyze
  dart test
)

# Installs both toolchains, builds the Backend runtime from clean, and
# regenerates the conformance outputs from the definitions. Conformance
# generation is never committed — it is rebuilt here, from the compiler that
# was just proved above.
"$conformance/tool/prepare.sh"

(
  cd "$backend"
  npm test
)

(
  cd "$conformance"
  dart format --output=none --set-exit-if-changed .
  dart analyze
  rm -rf dist
  npm run build
)

# ── The cross-layer contracts.

LOCAL_SYNC_CONFORMANCE_PREPARED=1 "$conformance/tool/test_test.sh"
LOCAL_SYNC_CONFORMANCE_PREPARED=1 "$conformance/tool/test.sh" all

# ── The fences.

# The Framework must stay independent of the product it will later serve, and
# generated source must stay free of the algorithms the core owns.
forbid() {
  local label="$1" pattern="$2"
  shift 2
  # A fence that scans nothing is a fence that is gone: every non-option
  # argument must exist, and a grep error must fail loudly, or a renamed
  # directory would silently turn this check into a no-op.
  local argument
  for argument in "$@"; do
    case "$argument" in
      --*) continue ;;
    esac
    if [[ ! -e "$argument" ]]; then
      echo "LocalSync gate: $label — path does not exist: $argument" >&2
      exit 1
    fi
  done
  local hit status
  hit="$(grep -rnE "$pattern" "$@")" && status=0 || status=$?
  if [[ $status -eq 0 ]]; then
    echo "LocalSync gate: $label" >&2
    echo "$hit" >&2
    exit 1
  fi
  if [[ $status -ge 2 ]]; then
    echo "LocalSync gate: $label — grep failed with status $status" >&2
    exit 1
  fi
}

forbid "Framework code must not import the product" \
  'backend/src|@prisma|PrismaService|DomainService' \
  --include='*.ts' --include='*.dart' \
  "$backend/src" \
  "$compiler/lib" "$runtime/lib"

forbid "publication scope must stay explicit" \
  'AsyncLocalStorage' \
  --include='*.ts' --include='*.dart' \
  "$backend/src" "$conformance/src"

forbid "the Framework must stand alone" \
  '@nestjs|@grpc/grpc-js|\.proto([^t]|$)' \
  --include='*.ts' --include='*.dart' \
  "$backend/src" "$compiler/lib" "$runtime/lib" "$typescript_backend"

forbid "generated Backend source must own no algorithm" \
  'savepoint|AsyncLocalStorage|setInterval|lockOrCreateDownlinkHead|scanInvalidations' \
  --include='*.ts' "$typescript_backend"

# A Model says nothing about replication since CAP-488, so there is no such
# thing as a Model the Backend outputs must not name: the contract carries
# every generated Model and the Backend picks its Downlink surface by
# registering loaders. What must stay gone is the mode that used to decide it.
forbid "Model replication mode must stay deleted" \
  '@@local|@@sync|ModelMode|SyncModelRegistry|LocalSlotWriter|GeneratedMutation +[A-Za-z]' \
  --include='*.ts' --include='*.dart' --include='*.model' \
  "$compiler/lib" "$runtime/lib" "$backend/src" "$conformance/definitions" \
  "$conformance/src" "$typescript_backend"
