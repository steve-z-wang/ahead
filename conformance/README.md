# LocalSync conformance

Cross-layer agreements. A test belongs here when proving it needs generated
artifacts, more than one production package, or both languages. Everything a
single layer can prove alone stays beside that layer — the compiler's own tests
in `compiler/test/`, the Dart engine's in
`client/local_sync/test/`, the TypeScript Backend's in
`server/test/`.

## The five contracts

| Contract | Owns |
|---|---|
| [`model-generation/`](model-generation/) | The generated outputs express what the definitions declared |
| [`server-client-protocol/`](server-client-protocol/) | The wire between a real Dart client and a real TypeScript host |
| [`client-storage-contract/`](client-storage-contract/) | The Dart database port, against every adapter |
| [`server-persistence-contract/`](server-persistence-contract/) | The TypeScript persistence ports, against every adapter |
| [`end-to-end-sync/`](end-to-end-sync/) | A small set of whole framework promises, read back from local state |

Each directory carries a README naming what it owns and — just as load-bearing
— what it does not, plus a `test.sh` that runs it and nothing else.

## Running

```bash
tool/test.sh model-generation   # one contract
tool/test.sh all                # every contract, in order
tool/test.sh --list             # the contract list, in order
```

The dispatcher prepares once — both toolchains installed, the Backend runtime
built, generated outputs written fresh from `definitions/` — and tells the
runners so through `LOCAL_SYNC_CONFORMANCE_PREPARED`. A runner invoked
directly prepares itself. Generated output is never committed: it is rebuilt
from the compiler in the tree on every run.

`tool/test_test.sh` proves the dispatcher itself — the list, its order, and
that an unknown name or a missing runner fails loudly rather than passing
quietly.

## Shape

One Dart package and one Node package for the whole workspace, at this root —
not one per contract. `lib/` and `src/` hold only shared harness code and the
generated output; tests and the fixtures only one contract uses live under
that contract. A helper moves up to the shared roots when a second contract
needs it, and not before.

The complete picture — how these five relate to the layer-local tests and to
the product's own suites — is
[`docs/testing.md`](../docs/testing.md).
