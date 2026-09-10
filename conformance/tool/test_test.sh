#!/usr/bin/env bash

# The dispatcher's own test. The dispatcher is the only thing that knows which
# contracts exist and in what order, so that knowledge is asserted here rather
# than trusted: a contract silently dropped from the list, or a contract whose
# runner went missing, would otherwise look exactly like a green gate.
#
# Every case below runs against stub runners in a sandbox, so this file proves
# the dispatcher and costs none of the suites' time.

set -euo pipefail

tool="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dispatcher="$tool/test.sh"
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "ok — $label"
    return
  fi
  echo "FAIL — $label" >&2
  echo "  expected: $(printf '%q' "$expected")" >&2
  echo "  actual:   $(printf '%q' "$actual")" >&2
  failures=$((failures + 1))
}

# The list, in full and in order. Read it as the ownership map it is: what the
# compiler wrote, what crosses the wire, what each side stores, and last the
# whole promise end to end.
expected_contracts=$'model-generation\nserver-client-protocol\nclient-storage-contract\nserver-persistence-contract\nend-to-end-sync'
check "the contract list is exact and ordered" \
  "$expected_contracts" \
  "$("$dispatcher" --list)"

# The list is a claim about the repository, not a string: every named contract
# must exist here with a runner that can be executed.
missing=''
while read -r contract; do
  [[ -d "$tool/../$contract" ]] || missing+="no directory: $contract"$'\n'
  [[ -x "$tool/../$contract/test.sh" ]] || missing+="no runner: $contract"$'\n'
done <<< "$expected_contracts"
check "every named contract is present with a runner" '' "${missing%$'\n'}"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/tool"
cp "$dispatcher" "$sandbox/tool/test.sh"
while read -r contract; do
  mkdir -p "$sandbox/$contract"
  printf '#!/usr/bin/env bash\necho "ran %s"\n' "$contract" \
    > "$sandbox/$contract/test.sh"
  chmod +x "$sandbox/$contract/test.sh"
done <<< "$expected_contracts"

export LOCAL_SYNC_CONFORMANCE_PREPARED=1

# `all` runs every contract, once each, in the listed order.
check "all runs every contract in order" \
  "$(while read -r contract; do echo "ran $contract"; done \
      <<< "$expected_contracts")" \
  "$("$sandbox/tool/test.sh" all | grep '^ran ')"

# One name runs one contract.
check "a named contract runs alone" \
  'ran client-storage-contract' \
  "$("$sandbox/tool/test.sh" client-storage-contract | grep '^ran ')"

refuses() {
  local label="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "FAIL — $label (the dispatcher succeeded)" >&2
    failures=$((failures + 1))
  else
    echo "ok — $label"
  fi
}

refuses "a name nobody owns" "$sandbox/tool/test.sh" no-such-contract
refuses "no argument at all" "$sandbox/tool/test.sh"

# A contract whose runner was deleted, and a contract whose directory was
# deleted. An empty or absent runner is never a pass.
rm "$sandbox/model-generation/test.sh"
refuses "a contract with no runner" "$sandbox/tool/test.sh" model-generation
refuses "a contract with no runner, under all" "$sandbox/tool/test.sh" all

rm -rf "$sandbox/end-to-end-sync"
refuses "a contract with no directory" "$sandbox/tool/test.sh" end-to-end-sync

if [[ $failures -ne 0 ]]; then
  echo "$failures dispatcher check(s) failed" >&2
  exit 1
fi
echo "dispatcher: all checks passed"
