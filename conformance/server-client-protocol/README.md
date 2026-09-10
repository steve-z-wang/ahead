# server-client-protocol

**Participants:** the real Dart transport and codec, the real TypeScript host.
Neither side stands in for the other, so a disagreement about the envelope
fails here and nowhere else.

**Owns:** scoped envelope shape, positional settlement, pull and live pages,
per-scope cursors and paging, the exact live subscribe acknowledgement, auth
refresh, the build gate, authorization refusal, and status classification.

**Does not own:** applying a page to the canonical database, or any product
behavior — that convergence is `end-to-end-sync`. Every scenario here stops at
the decoded envelope. The shared Dart harness opens a scratch database only
to build the generated registry and Uplink fixtures; this contract never
applies a page or asserts canonical local Model/cursor state.

```bash
conformance/tool/test.sh server-client-protocol
```

## The scenarios

Each is one named Dart executable run against one host the spec started.

| Scenario | The agreement it proves |
|---|---|
| `upload` | a batch of Dart-written bytes is read and answered positionally |
| `int` | an `Int` survives the round trip as a number, not a bigint |
| `reject` | a refusal is stated in place and its neighbours still land |
| `pull` | the cursor walks forward and the page says where it ends |
| `multipage` | 51 changes split 50 + 1, and the second page starts where the first ended |
| `live` | a page arrives over the socket, beginning where the device stands |
| `live-equivalent` | the pushed page and the asked-for page are the same page |
| `reconnect` | the channel opens and the catch-up the connection owes lands |
| `scoped` | `User` and `Space` ledgers stay independent over HTTP and one multiplexed live handshake |
| `mixed-authorization` | one live handshake accepts `User`, refuses `Book`, and still delivers the authorized stream |
| `denied-scope` | an unauthorized opaque scope string is refused terminally |
| `refresh` | a refused credential is refreshed exactly once and the call lands |
| `build-accepted` | a client standing on the host's floor is admitted |
| `build-refused` | a client below it is refused 426, terminally, without a retry loop |

The client never requests a page limit; the server owns its fixed ceiling.
`multipage` independently expects 50 + 1 and proves the boundary by behavior,
without importing the server's constant. The build floor is named the same
way. Live setup is equally explicit: the client sends one canonical nonempty
scope set and receives an exact accepted/rejected partition in `subscribed`
before any page. A refused neighbour never suppresses an authorized scope's
stream. Scope values are scalar JSON strings and are compared and carried
verbatim; the Framework does not parse namespaces or relate them to Models.
