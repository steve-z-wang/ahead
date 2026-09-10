# end-to-end-sync

**Participants:** the generated definitions, the TypeScript host, real bytes on
a loopback socket, the Dart apply path, and SQLite.

**Owns:** a deliberately small set of final framework promises, each asserted
from local state rather than from the wire. CAP-428 is the founding case: every
protocol scenario stops at the envelope, so a `state` the two languages spell
differently reaches a database here and nowhere else.

**Does not own:** exhaustive protocol matrices or per-algorithm coverage. This
suite stays small on purpose — a promise, not a matrix.

Each journey ends by reading the client's own local state; an assertion whose
answer is on the wire belongs to `server-client-protocol/`, whatever else it
happened to exercise.

| Journey | The promise |
|---|---|
| `apply` | A list, an explicit null and an enum reach SQLite spelled as the Model says (CAP-428, the baseline). |
| `scoped-streams` | Two authorized opaque scope strings land different identities with independent SQLite cursors; advancing `Space:space-a` cannot settle an Uplink act waiting on `User:user-a`. |
| `scoped-runtime` | The generated runtime opens `User:user-a` and `Space:space-a` together, handshakes and catches both up over one live transport, then settles a User-scoped act without moving Space. |
| `typed-lifecycle` | A create, an update to an explicit null, and a delete each land as their own page, read back through the generated typed API. |
| `rejection-rebuild` | An edit the host refuses leaves the queue and the row rebuilds to server truth, with no mutation and no batch left behind. |
| `multipage-apply` | A stream too long for one page applies across pages, each row exactly once, the cursor ending where the last page did. |
| `reconnect-catch-up` | A write made while the client was away arrives on the pull the next connection owes, and the channel does not reopen after it. |
| `atomic-local-failure` | A page that cannot write the cursor writes nothing at all, and the same page applied again lands whole. |
| `named-mutation` | One named act of 42 operations applies at once, queues as one record, waits on every readiness key, runs one resolver, and settles leaving nothing — including a row the server wrote that no operation named (CAP-439). |
| `named-mutation-rejection` | An act the host refuses rolls back whole on both sides while an unrelated act in the same batch stands. |
| `uplink-scheduling` | Exact earlier-ordinal lifecycle and product-order edges survive restart; unrelated work overtakes readiness, business order may share a batch, lifecycle waits for acceptance, refusal semantics stay distinct, and an unknown outcome retries identical frozen bytes first. |

What each journey deliberately leaves alone: envelope shapes, page-size
agreement, status classification and the build floor are
`server-client-protocol/`'s; a port's own semantics belong to the storage
contracts; and per-algorithm matrices stay beside the algorithm.

```bash
conformance/tool/test.sh end-to-end-sync
```
