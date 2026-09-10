import 'dart:async';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/src/support/rest_ws_conformance.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

/// What a client owes itself on every connection, paid in full: a channel
/// opens, closes, a write happens while nobody is listening, and the next
/// connection ends with that write in the client's own database.
///
/// The live channel carries no history — a socket subscribes from the server's
/// head at the moment it opens, so a page written while the client was away is
/// on no channel to be missed. Only the pull the connection owes can fetch it,
/// and only applying that pull proves it arrived.
Future<Map<String, Object?>> runReconnectCatchUp(WireSession session) async {
  final connections = _ChannelCounter();

  // Away and back: two real channels, because a closed transport is closed for
  // good — which is exactly what a client that lost its connection has.
  await connections.openAndClose(session.port);
  await session.settle(1, momentFamily());
  final channel = await connections.open(session.port);

  try {
    final cursorBefore = await readCursor(session.scope);
    // The catch-up the connection owes, made explicitly.
    final page = await session.pull(cursorBefore);
    final applied = await applyPage(
      session.scope,
      page,
      afterSyncId: cursorBefore,
    );
    final moment = await typedModels(
      session.scope,
    ).moment.get(momentIdOf(conformanceMomentId));
    final connects = connections.count;

    // A channel that keeps reopening is a client that never caught up. Give
    // it long enough to say so, and expect silence.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    return {
      'failures': [for (final failure in applied.failures) failure.toString()],
      'connects': connects,
      'connectsAfterCatchUp': connections.count,
      'caption': moment?.caption,
      'cursorBefore': cursorBefore,
      'cursor': await readCursor(session.scope),
    };
  } finally {
    await channel.close();
  }
}

/// Counts every `DownlinkConnected` across every channel this journey opens,
/// so a silent retry loop shows up as a number rather than as a hang.
final class _ChannelCounter {
  int count = 0;

  Future<_Channel> open(int port) async {
    final transport = RestWsTransport(
      baseUri: Uri.parse('http://127.0.0.1:$port/'),
      getAccessToken: () async => conformanceToken,
      sleep: (_) async {},
    );
    final connected = Completer<void>();
    final subscription = transport.downlinkEvents.listen((event) {
      if (event is! DownlinkConnected) return;
      count += 1;
      if (!connected.isCompleted) connected.complete();
    });
    await transport.start();
    await connected.future.timeout(const Duration(seconds: 10));
    return _Channel(transport, subscription);
  }

  Future<void> openAndClose(int port) async => (await open(port)).close();
}

final class _Channel {
  _Channel(this._transport, this._subscription);

  final LocalSyncTransport _transport;
  final StreamSubscription<DownlinkTransportEvent> _subscription;

  Future<void> close() async {
    await _subscription.cancel();
    await _transport.close();
  }
}
