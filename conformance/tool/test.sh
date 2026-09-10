#!/usr/bin/env bash

# The conformance entrypoint: one named contract, or all of them.
#
#   tool/test.sh model-generation
#   tool/test.sh all
#   tool/test.sh --list
#
# Preparation happens here, once, and is announced to the runners through
# LOCAL_SYNC_CONFORMANCE_PREPARED so a contract invoked directly still
# prepares itself and a contract invoked from here does not pay twice. The
# root framework gate prepares its own way and sets the same variable.

set -euo pipefail

conformance="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The contracts, in the order a change travels: what the compiler wrote, what
# crosses the wire, what each side stores, and last the whole promise proved
# from local state. This list is the ownership map — tool/test_test.sh pins it.
contracts=(
  model-generation
  server-client-protocol
  client-storage-contract
  server-persistence-contract
  end-to-end-sync
)

usage() {
  echo "usage: $(basename "${BASH_SOURCE[0]}") <contract|all|--list>" >&2
  printf '  %s\n' "${contracts[@]}" >&2
}

selection="${1:-}"

if [[ "$selection" == '--list' ]]; then
  printf '%s\n' "${contracts[@]}"
  exit 0
fi

if [[ -z "$selection" ]]; then
  usage
  exit 1
fi

if [[ "$selection" != 'all' ]]; then
  known=''
  for contract in "${contracts[@]}"; do
    [[ "$contract" == "$selection" ]] && known='yes'
  done
  if [[ -z "$known" ]]; then
    echo "conformance: no contract named \"$selection\"" >&2
    usage
    exit 1
  fi
fi

if [[ -z "${LOCAL_SYNC_CONFORMANCE_PREPARED:-}" ]]; then
  "$conformance/tool/prepare.sh"
  export LOCAL_SYNC_CONFORMANCE_PREPARED=1
fi

# A contract that cannot be run is a contract nobody is proving. Say so and
# stop; a silent skip is the failure this whole reorganization exists to end.
run() {
  local contract="$1"
  if [[ ! -d "$conformance/$contract" ]]; then
    echo "conformance: $contract has no directory" >&2
    exit 1
  fi
  if [[ ! -x "$conformance/$contract/test.sh" ]]; then
    echo "conformance: $contract has no executable test.sh" >&2
    exit 1
  fi
  echo "── conformance: $contract"
  "$conformance/$contract/test.sh"
}

if [[ "$selection" == 'all' ]]; then
  for contract in "${contracts[@]}"; do
    run "$contract"
  done
else
  run "$selection"
fi
