import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

/// The protocol contract's half of the cross-language suite: a real Dart
/// client, driven one named scenario at a time by the TypeScript harness that
/// started the host. Every scenario here stops at the envelope — what a page
/// does once it reaches a database belongs to `end-to-end-sync`.

const momentId = '550e8400-e29b-41d4-a716-446655440000';
const sampleId = '9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d';
const capturedAt = '2026-08-05T00:00:00.000Z';

StoredMutationOperation momentCreate(
  int ordinal, {
  String id = momentId,
  String caption = 'first',
}) => StoredMutationOperation(
  mutationOrdinal: ordinal,
  position: 0,
  model: 'Moment',
  identityJson: jsonEncode({'id': id}),
  operation: 'create',
  valuesJson: jsonEncode({
    'caption': caption,
    'capturedAt': capturedAt,
    'spaceId': conformanceSpaceId,
  }),
  isUplink: true,
);

/// A realistic page carries a family: the Moment and both of its owners.
List<StoredMutationOperation> momentWithItsOwners() => [
  conformanceUserRow(),
  conformanceSpaceRow(),
  momentCreate(3),
];

/// The Uplink carries at most this many rows in one batch, so a page's worth
/// of identities is never one call.
const uplinkBatchLimit = 20;

/// The server owns the fixed Downlink page size. This independent fixture
/// value makes a disagreement observable without exposing it in the request.
const conformanceDownlinkPageSize = 50;

/// One more identity than a page holds, so the server has to split its answer.
/// The family's two owners lead; the rest are Moments of their own.
List<StoredMutationOperation> aPageAndOneMore() => [
  conformanceUserRow(),
  conformanceSpaceRow(),
  for (
    var ordinal = 3;
    ordinal <= conformanceDownlinkPageSize + 1;
    ordinal += 1
  )
    momentCreate(
      ordinal,
      id: 'c0ffee00-0000-4000-8000-${'$ordinal'.padLeft(12, '0')}',
      caption: 'page $ordinal',
    ),
];

/// The Model carrying an Int. Canonical JSON cannot encode a bigint, so a page
/// with one of these is exactly what a protobuf-era widening would break —
/// which is why the cross-language fixture insists on carrying one.
StoredMutationOperation scalarSampleCreate(
  int ordinal, {
  int rank = 7,
  String id = sampleId,
}) => StoredMutationOperation(
  mutationOrdinal: ordinal,
  position: 0,
  model: 'ScalarSample',
  identityJson: jsonEncode({'id': id}),
  operation: 'create',
  valuesJson: jsonEncode({
    'enabled': true,
    'rank': rank,
    'score': 1.5,
    'optionalAt': null,
    'optionalUuid': null,
  }),
  isUplink: true,
);

StoredMutationOperation bookNoteCreate(int ordinal) => StoredMutationOperation(
  mutationOrdinal: ordinal,
  position: 0,
  model: 'LocalNote',
  identityJson: jsonEncode({'id': conformanceBookBNoteId}),
  operation: 'create',
  valuesJson: jsonEncode({'text': 'Book B', 'status': 'active'}),
  isUplink: true,
);

/// A decoded page reduced to what the harness can compare: where it starts,
/// where it ends, and every change it carries.
Map<String, Object?> normalized(DownlinkPage page) => {
  'scope': page.scope,
  'from': page.fromSyncId,
  'through': page.throughSyncId,
  'changes': [for (final change in page.changes) change.raw],
};

/// The floor the harness stands its host on. Both sides name it on their own;
/// that they agree is the whole of what the build scenarios prove.
const hostMinimumBuild = 100;

/// The build a scenario declares as `?build=`. Only the two that cross the
/// floor name one — a build the host is never told is a build it passes.
int? declaredBuild(String scenario) => switch (scenario) {
  'build-accepted' => hostMinimumBuild,
  'build-refused' => hostMinimumBuild - 1,
  _ => null,
};

Future<void> main(List<String> arguments) => runWireScenario(
  arguments,
  _protocol,
  clientBuild: declaredBuild(arguments[1]),
);

Future<Map<String, Object?>> _protocol(
  WireSession session,
  String scenario,
) async {
  switch (scenario) {
    // Uplink round-trip: the Dart runtime writes the bytes, the TypeScript
    // host reads them, and the answer comes back positionally.
    case 'upload':
      final response = await session.settle(1, momentWithItsOwners());
      return {
        'requiredScope': response.legacyPrincipalCheckpoint.scope,
        'requiredSyncId': response.legacyPrincipalCheckpoint.syncId,
        'rejections': response.rejections.length,
      };

    case 'mutation-versions':
      await session.settle(1, momentWithItsOwners());
      final rows = [
        for (var ordinal = 4; ordinal <= 6; ordinal++)
          StoredMutationOperation(
            mutationOrdinal: ordinal,
            position: 0,
            model: 'Space',
            identityJson: jsonEncode({'id': conformanceSpaceId}),
            operation: 'update',
            valuesJson: jsonEncode({'name': 'rename-$ordinal'}),
            isUplink: true,
          ),
      ];
      final bytes = session.codec.encodeUplinkRequest(
        clientId: conformanceClientId,
        batchSequence: 2,
        mutations: rows,
        records: {
          for (final row in rows)
            row.mutationOrdinal: StoredMutation(
              ordinal: row.mutationOrdinal,
              name: 'RenameSpace',
              legacyFifo: false,
              version: switch (row.mutationOrdinal) {
                4 => null,
                5 => 1,
                _ => 2,
              },
            ),
        },
      );
      final response = await session.transport.sendUplink(bytes);
      final replay = await session.transport.sendUplink(bytes);
      final body =
          jsonDecode(utf8.decode(localSyncResponseBody(response))) as Map;
      return {
        'status': response.statusCode,
        'rejections': body['rejections'],
        'replaySame':
            utf8.decode(localSyncResponseBody(replay)) ==
            utf8.decode(localSyncResponseBody(response)),
        'versions': [
          for (final act
              in (jsonDecode(utf8.decode(bytes)) as Map)['mutations'] as List)
            (act as Map)['version'],
        ],
      };

    case 'multi-checkpoint':
      final response = await session.settle(1, [
        conformanceSpaceRow(ordinal: 1),
        momentCreate(2, id: conformanceBookAMomentId),
        bookNoteCreate(3),
      ]);
      return {
        'requiredCheckpoints': [
          for (final checkpoint in response.requiredCheckpoints)
            {'scope': checkpoint.scope, 'syncId': checkpoint.syncId},
        ],
        'legacyPrincipal': {
          'scope': response.legacyPrincipalCheckpoint.scope,
          'syncId': response.legacyPrincipalCheckpoint.syncId,
        },
      };

    case 'legacy-receipt':
      final response = session.codec.decodeUplinkResponse(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'requiredScope': conformanceUserScope,
              'requiredSyncId': 7,
              'rejections': <Object?>[],
            }),
          ),
        ),
        requestMutationIds: const {1},
      );
      return {
        'checkpoints': [
          for (final checkpoint in response.requiredCheckpoints)
            {'scope': checkpoint.scope, 'syncId': checkpoint.syncId},
        ],
      };

    // An Int survives the round trip as a number rather than failing to
    // serialize on the way back down.
    case 'int':
      await session.settle(1, [scalarSampleCreate(1, rank: 42)]);
      final page = await session.pull(0, scope: conformanceSpaceScope);
      final sample = page.changes
          .map((change) => change.raw)
          .firstWhere((raw) => raw['model'] == 'ScalarSample');
      return {'rank': (sample['data']! as Map)['rank']};

    // Positional rejection: one mutation is refused by name, its neighbours
    // land, and the batch is not refused.
    case 'reject':
      final response = await session.settle(1, [
        ...momentWithItsOwners(),
        StoredMutationOperation(
          mutationOrdinal: 4,
          position: 0,
          model: 'Moment',
          identityJson: jsonEncode({
            'id': 'd1e2f3a4-b5c6-4d7e-8f90-a1b2c3d4e5f6',
          }),
          operation: 'create',
          valuesJson: jsonEncode({
            'caption': 'reject-me',
            'capturedAt': capturedAt,
            'spaceId': conformanceSpaceId,
          }),
          isUplink: true,
        ),
      ]);
      return {
        'rejections': [
          for (final rejection in response.rejections)
            {'ordinal': rejection.mutationId, 'code': rejection.code},
        ],
      };

    // Pull paging: the cursor walks forward and the page says where it ends.
    case 'pull':
      await session.settle(1, momentWithItsOwners());
      final first = await session.pull(0);
      final second = await session.pull(first.throughSyncId);
      return {
        'firstFrom': first.fromSyncId,
        'firstThrough': first.throughSyncId,
        'firstChanges': first.changes.length,
        'models': first.changes
            .map((change) => change.raw['model'])
            .toList(growable: false),
        // The cursor is caught up, so the next page moves nothing.
        'secondChanges': second.changes.length,
        'secondEmptyAtCursor': second.fromSyncId == second.throughSyncId,
      };

    // One more identity than a page holds, so the answer has to split. Both
    // sides declare the page size on their own; this is where they either
    // agree about it or fail.
    case 'multipage':
      final rows = aPageAndOneMore();
      for (var start = 0; start < rows.length; start += uplinkBatchLimit) {
        final end = start + uplinkBatchLimit;
        await session.settle(
          start ~/ uplinkBatchLimit + 1,
          rows.sublist(start, end < rows.length ? end : rows.length),
        );
      }
      final first = await session.pull(0);
      // Where the first page ended is the only thing the second one is told.
      final second = await session.pull(first.throughSyncId);
      return {
        'firstCount': first.changes.length,
        'firstFrom': first.fromSyncId,
        'firstThrough': first.throughSyncId,
        'secondCount': second.changes.length,
        'secondFrom': second.fromSyncId,
        'secondThrough': second.throughSyncId,
        'syncIds': [
          for (final change in [...first.changes, ...second.changes])
            change.syncId,
        ],
      };

    // Live page push: the channel opens, a write happens, and the page
    // arrives over the socket rather than by asking.
    case 'live':
      final pages = <DownlinkPage>[];
      final arrived = Completer<void>();
      final subscription = await subscribeLive(
        session,
        [conformanceUserScope],
        onPage: (page) {
          pages.add(page);
          if (!arrived.isCompleted) arrived.complete();
        },
      );

      await session.settle(1, momentWithItsOwners());
      await arrived.future.timeout(const Duration(seconds: 10));
      await subscription.cancel();
      return {
        'pages': pages.length,
        'changes': pages.first.changes.length,
        // CAP-374: a pushed page begins where the device stands, or it is
        // dropped and pulled. Here the device is at zero.
        'beginsAtCursor': pages.first.fromSyncId == 0,
      };

    // Two doors onto the same page: the one the channel pushed and the one
    // the cursor asked for. Decoded whole, they must be the same page.
    case 'live-equivalent':
      final pushed = Completer<DownlinkPage>();
      final subscription = await subscribeLive(
        session,
        [conformanceUserScope],
        onPage: (page) {
          if (!pushed.isCompleted) pushed.complete(page);
        },
      );

      await session.settle(1, momentWithItsOwners());
      final live = await pushed.future.timeout(const Duration(seconds: 10));
      // The channel began where the device stands, so the pull that would have
      // fetched the same page asks from there too.
      final asked = await session.pull(live.fromSyncId);
      await subscription.cancel();
      return {'live': normalized(live), 'pull': normalized(asked)};

    // Reconnect-pull: what a client owes itself on every connection is one
    // catch-up, and the pull is where it says where it stands.
    case 'reconnect':
      await session.settle(1, momentWithItsOwners());
      final connects = <void>[];
      final subscription = await subscribeLive(session, [
        conformanceUserScope,
      ], onConnected: () => connects.add(null));
      // The catch-up the connection owes, made explicitly.
      final page = await session.pull(0);
      await subscription.cancel();
      return {
        'connects': connects.length,
        'caughtUpChanges': page.changes.length,
      };

    // A client standing exactly on the floor is admitted, and the connection
    // it opens is worth having: the catch-up it owes itself lands.
    case 'build-accepted':
      await session.settle(1, momentWithItsOwners());
      final connects = <void>[];
      final subscription = await subscribeLive(session, [
        conformanceUserScope,
      ], onConnected: () => connects.add(null));
      final page = await session.pull(0);
      await subscription.cancel();
      return {
        'connects': connects.length,
        'caughtUpChanges': page.changes.length,
      };

    case 'scoped':
      await session.settle(1, momentWithItsOwners());
      final samples = [
        for (
          var index = 1;
          index <= conformanceDownlinkPageSize + 1;
          index += 1
        )
          scalarSampleCreate(
            (index - 1) % uplinkBatchLimit + 1,
            rank: index,
            id:
                '9a8b7c6d-5e4f-4a3b-8c2d-'
                '${index.toString().padLeft(12, '0')}',
          ),
      ];
      for (var start = 0; start < samples.length; start += uplinkBatchLimit) {
        final candidateEnd = start + uplinkBatchLimit;
        final end = candidateEnd < samples.length
            ? candidateEnd
            : samples.length;
        await session.settle(
          start ~/ uplinkBatchLimit + 2,
          samples.sublist(start, end),
        );
      }
      final user = await session.pull(0);
      final space = await session.pull(0, scope: conformanceSpaceScope);
      final spaceNext = await session.pull(
        space.throughSyncId,
        scope: conformanceSpaceScope,
      );
      final subscription = await subscribeLive(session, [
        conformanceSpaceScope,
        conformanceUserScope,
      ]);
      await subscription.cancel();
      return {
        'userScope': normalized(user),
        'spaceScope': normalized(space),
        'spaceNext': normalized(spaceNext),
        'liveAcknowledgement': {
          'accepted': [
            for (final scope in subscription.acknowledgement.scopes) scope,
          ],
          'rejections': [
            for (final rejection in subscription.acknowledgement.rejections)
              '${rejection.scope}:${rejection.code}',
          ],
        },
      };

    case 'mixed-authorization':
      final userLiveChanges = Completer<int>();
      final subscription = await subscribeLive(
        session,
        [conformanceUserScope, conformanceDeniedBookScope],
        onPage: (page) {
          if (page.scope == conformanceUserScope &&
              !userLiveChanges.isCompleted) {
            userLiveChanges.complete(page.changes.length);
          }
        },
      );
      await session.settle(1, [conformanceUserRow()]);
      final changes = await userLiveChanges.future.timeout(
        const Duration(seconds: 10),
      );
      await subscription.cancel();
      return {
        'accepted': [
          for (final scope in subscription.acknowledgement.scopes) scope,
        ],
        'rejected': [
          for (final rejection in subscription.acknowledgement.rejections)
            '${rejection.scope}:${rejection.code}',
        ],
        'userLiveChanges': changes,
      };

    case 'denied-scope':
      const denied = 'User:ffffffff-ffff-4fff-8fff-ffffffffffff';
      await session.pull(0, scope: denied);
      throw StateError('denied scope unexpectedly pulled');

    // A client below the floor is refused, and the refusal is said out loud
    // rather than reconnected against: no build upgrades itself by asking.
    case 'build-refused':
      final connects = <void>[];
      final failed = Completer<LocalSyncTransportFailure>();
      final subscription = session.transport.downlinkEvents.listen((event) {
        if (event is DownlinkConnected) connects.add(null);
        if (event is DownlinkFailed && !failed.isCompleted) {
          failed.complete(event.failure);
        }
      });
      await session.transport.start();
      final failure = await failed.future.timeout(const Duration(seconds: 10));
      await subscription.cancel();
      return {
        'failure': failure.runtimeType.toString(),
        'status': failure.status,
        'connects': connects.length,
      };

    // Auth refresh: the first credential is refused, the wrapper fetches a
    // fresh one exactly once, and the call lands.
    case 'refresh':
      final sent = await session.send(1, momentWithItsOwners());
      final response = session.codec.decodeUplinkResponse(
        sent.body,
        requestMutationIds: sent.ordinals,
      );
      return {
        'status': sent.status,
        'requiredSyncId': response.legacyPrincipalCheckpoint.syncId,
      };
  }
  throw ArgumentError('unknown scenario "$scenario"');
}

final class LiveSubscription {
  LiveSubscription(this._events, this.acknowledgement);

  final StreamSubscription<DownlinkTransportEvent> _events;
  final DownlinkSubscribed acknowledgement;

  Future<void> cancel() => _events.cancel();
}

Future<LiveSubscription> subscribeLive(
  WireSession session,
  Iterable<String> scopes, {
  void Function()? onConnected,
  void Function(DownlinkPage page)? onPage,
}) async {
  final requested = scopes.toSet().toList()..sort();
  if (requested.isEmpty) throw StateError('live scope set must be nonempty');
  final acknowledged = Completer<DownlinkSubscribed>();
  late final StreamSubscription<DownlinkTransportEvent> subscription;
  subscription = session.transport.downlinkEvents.listen((event) {
    switch (event) {
      case DownlinkConnected():
        onConnected?.call();
        unawaited(
          session.transport
              .sendDownlinkFrame(
                session.codec.encodeDownlinkSubscribe(requested),
              )
              .catchError((Object error, StackTrace stackTrace) {
                if (!acknowledged.isCompleted) {
                  acknowledged.completeError(error, stackTrace);
                }
              }),
        );
      case DownlinkPageReceived(:final page):
        try {
          switch (session.codec.decodeDownlinkLiveMessage(page)) {
            case final DownlinkSubscribed acknowledgement:
              _validateAcknowledgement(requested, acknowledgement);
              if (!acknowledged.isCompleted) {
                acknowledged.complete(acknowledgement);
              }
            case DownlinkLivePage(:final page):
              onPage?.call(page);
          }
        } catch (error, stackTrace) {
          if (!acknowledged.isCompleted) {
            acknowledged.completeError(error, stackTrace);
          }
        }
      case DownlinkFailed(:final failure):
        if (!acknowledged.isCompleted) acknowledged.completeError(failure);
    }
  });
  await session.transport.start();
  final acknowledgement = await acknowledged.future.timeout(
    const Duration(seconds: 10),
  );
  return LiveSubscription(subscription, acknowledgement);
}

void _validateAcknowledgement(
  List<String> requested,
  DownlinkSubscribed acknowledgement,
) {
  final partition = [
    ...acknowledgement.scopes,
    for (final rejection in acknowledgement.rejections) rejection.scope,
  ];
  final normalized = partition.toSet().toList()..sort();
  if (partition.length != requested.length ||
      !_sameScopes(normalized, requested)) {
    throw StateError('server acknowledged a different scope partition');
  }
}

bool _sameScopes(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
