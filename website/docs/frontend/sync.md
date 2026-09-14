# Sync, offline work and recovery

Local reads and writes go through the Rust engine and SQLite. A connection handles network work in the background. Your app can continue using its local data while the connection is paused or a response is delayed.

## Subscribe and observe

=== "TypeScript"

    ```ts
    await client.channels.subscribe('book:demo');
    const stop = client.models.entry.watch({}, entries => render(entries), console.error);
    ```

=== "Flutter"

    ```dart
    await client.channels.subscribe('book:demo');
    final subscription = client.models.entry.watch().listen(
      render,
      onError: (Object error) => print(error),
    );
    ```

Here `render` is your UI's update function. Subscribing records the desired channel and wakes the connection; it does not wait for the initial data. Expect an empty initial result on a new database. `watch` emits again when synchronization commits records.

Use channel names that your backend notifies, and subscribe before writing when the client needs to receive the resulting server state. A channel is not a database query or an authorization token. Loaders decide which requested records the authenticated user may see.

## Work offline

=== "TypeScript"

    ```ts
    await client.connection!.pause();
    await client.transaction(tx => tx.mutate.edit({
      entry: { identity: { id: 'entry-1' }, values: { text: '  Draft  ' } },
    }));
    console.log((await client.models.entry.get({ id: 'entry-1' }))?.text);
    await client.connection!.resume();
    ```

=== "Flutter"

    ```dart
    await client.connection!.pause();
    await client.transaction((tx) => tx.mutate.edit(
      entry: const EditEntryUpdate(
        identity: EntryIdentity(id: 'entry-1'),
        text: Present('  Draft  '),
      ),
    ));
    print((await client.models.entry.get(const EntryIdentity(id: 'entry-1')))?.text);
    await client.connection!.resume();
    ```

This assumes `GeneratedClient.open` was given `server` and the record has already arrived locally. Without it the client is local-only until you connect its raw runtime. Dart uses the same `pause`/`resume` methods with its typed mutation arguments.

A local transaction's completion confirms local commit. It does not mean the server has accepted the operation. Display pending and rejected state using [recordStatus](runtime.md#pending-work-and-recovery) when that distinction matters to the UI.

You can close and reopen the same local database without losing queued changes. Keep the same backend database as well: replacing a backend's receipt/cursor history with an empty database is a reset, not a temporary network interruption. The tutorial's `offline` / `online` commands preserve both databases.

## Understand acceptance and rejection

After a local mutation, the connection pushes its frozen request. A successful receipt can require a channel checkpoint. The runtime retains optimistic state until the necessary authoritative progress is applied, then settles the accepted work and replays remaining local changes. This lets a handler's normalized result replace the optimistic value.

If a handler rejects the mutation, Ahead removes that mutation's optimistic contribution and retains its rejection code locally. Later valid pending work may still affect the displayed record, so rollback is not necessarily a return to the value the user saw before all edits.

=== "TypeScript"

    ```ts
    const { rejections } = await client.client.recordStatus('Entry', { id: 'entry-1' });
    console.log(rejections);
    // After handling the rejection in your UI:
    await client.client.dismissRejection(rejectionOrdinal);
    ```

=== "Flutter"

    ```dart
    final status = await client.client.recordStatus('Entry', {'id': 'entry-1'});
    print(status['rejections']);
    // After handling the rejection in your UI:
    await client.client.dismissRejection(rejectionOrdinal);
    ```

`rejectionOrdinal` is taken from the rejection you handled. Dismissing only clears the inbox entry. Retrying the business action means creating a new mutation after resolving its cause. `drop(ordinal)` is for eligible unsent mutations; it cannot cancel a request whose server outcome is unknown.

## Recover from connection failures

Provide `onError` to record background failures, and `refreshAuth` if your credentials can expire. Let the runtime retry frozen work; do not generate a new mutation merely because the original request timed out. The backend may already have committed it and retained its receipt.

Use `wake()` after an application event that should prompt another scheduling check. Use `resume()` after explicitly pausing. A closed connection cannot resume; create a new one through `client.client.connect` or reopen the owning client.

On connection or reconnection, Ahead establishes the WebSocket subscription, then catches up over HTTP from each channel's persisted cursor. It queues changes arriving during catch-up and continues with WebSocket updates once caught up. Both sources use the same Rust page processing: covered pages are discarded, overlapping pages apply their unseen changes, and gaps trigger HTTP recovery from saved progress. Subscription changes replace the session; pages from replaced or canceled sessions cannot update local data.

## Authentication and account changes

Authenticate requests on the backend and check business permissions in handlers and loaders. `devAuth` is only for the local example. In production, your `authenticate` callback should verify your existing application's credentials and return its user ID.

Use a separate local database per signed-in user. On an account change, stop and close the old client before opening the other user's database. Changing only the transport token leaves the old user's cached records and client identity in place.

When permissions change, notify the channels whose visible records changed. A loader can then return null to withdraw a record. Unsubscribing does not erase cached data and does not enforce authorization.

## Diagnose pending work

| Observation | Check |
| --- | --- |
| Empty local query after opening | Desired channel, running connection, loader output and read permission |
| `queued` with failed prerequisites | Host callback failure; reset its readiness to pending and run it again |
| `frozen` after a network failure | Connectivity/authentication; retain the frozen bytes for retry |
| `accepted` still pending | Required channel progress, notification and loader failures |
| Server values do not update | Whether every affected channel was notified |
| Local client fails after another process wrote | One active client per SQLite file; close/reopen the stale instance |

See [runtime APIs](runtime.md) for controls and [compatibility and recovery](storage.md) for storage constraints.
