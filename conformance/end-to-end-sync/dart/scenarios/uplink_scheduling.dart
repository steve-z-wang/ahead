import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/support/rest_ws_conformance.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

const _clientId = 'a6220000-0000-4000-8000-000000000001';
const _blockedMomentId = 'a6220000-0000-4000-8000-000000000002';
const _blockedTagId = 'a6220000-0000-4000-8000-000000000003';
const _unrelatedNoteId = 'a6220000-0000-4000-8000-000000000004';
const _sameBatchMomentId = 'a6220000-0000-4000-8000-000000000005';
const _lifecycleMomentId = 'a6220000-0000-4000-8000-000000000006';
const _lifecycleTagId = 'a6220000-0000-4000-8000-000000000007';
const _rejectedMomentId = 'a6220000-0000-4000-8000-000000000008';
const _rejectedDependentTagId = 'a6220000-0000-4000-8000-000000000009';
const _cascadeNoteId = 'a6220000-0000-4000-8000-000000000013';
const _sequenceMomentId = 'a6220000-0000-4000-8000-000000000010';
const _sequenceTagId = 'a6220000-0000-4000-8000-000000000011';
const _sequenceNoteId = 'a6220000-0000-4000-8000-000000000014';
const _retryNoteId = 'a6220000-0000-4000-8000-000000000012';
const _blockedGate = 'scheduling-gate';
const _lifecycleGate = 'lifecycle-gate';
const _sequenceGate = 'sequence-gate';

/// The scheduler's durable promises, exercised across the real Dart runtime
/// and TypeScript host. Lifecycle prerequisites and product ordering are two
/// different edge sets: the former require an earlier create to be accepted;
/// the latter may share a batch and are released, not cascaded, on refusal.
Future<Map<String, Object?>> runUplinkScheduling(WireSession session) async {
  final directory = await Directory.systemTemp.createTemp(
    'local_sync_scheduling_',
  );
  final path = '${directory.path}/local-sync.sqlite';
  final prerequisites = ControlledPrerequisites();
  try {
    await _seed(session, path, prerequisites);
    final business = await _businessOrdering(session, path, prerequisites);
    final sameBatch = await _businessSameBatch(session, path, prerequisites);
    final lifecycle = await _lifecycleAcceptance(session, path, prerequisites);
    final cascade = await _lifecycleRejection(session, path, prerequisites);
    final release = await _sequenceRejection(session, path, prerequisites);
    final retry = await _frozenRetry(session, path, prerequisites);

    final finalRuntime = await _open(
      session,
      path,
      prerequisites,
      activate: false,
    );
    try {
      return {
        ...business,
        ...sameBatch,
        ...lifecycle,
        ...cascade,
        ...release,
        ...retry,
        'records': await _count(finalRuntime, 'pending_mutations'),
        'operations': await _count(finalRuntime, 'pending_mutation_operations'),
        'batches': await _count(finalRuntime, 'uplink_batches'),
      };
    } finally {
      await finalRuntime.close();
    }
  } finally {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<void> _seed(
  WireSession session,
  String path,
  ControlledPrerequisites prerequisites,
) async {
  final localSync = await _open(session, path, prerequisites);
  try {
    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (
          user: User.create(
            id: UUID.withValidation(conformanceUserId),
            handle: 'steve',
          ),
        ),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: UUID.withValidation(conformanceSpaceId),
            ownerId: UUID.withValidation(conformanceUserId),
            name: 'Family',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    await _waitUntilSettled(localSync);
  } finally {
    await localSync.close();
  }
}

/// A1, B1-after-A1, A2: B1 does not acquire a dependency on the later A2,
/// while A2 retains only the ordinary same-row order behind A1.
Future<Map<String, Object?>> _businessOrdering(
  WireSession session,
  String path,
  ControlledPrerequisites prerequisites,
) async {
  var localSync = await _open(session, path, prerequisites, activate: false);
  await _rename(localSync, 'A1');
  await _capture(
    localSync,
    momentId: _blockedMomentId,
    caption: 'blocked',
    tagId: _blockedTagId,
    tagLabel: _blockedGate,
  );
  await _rename(localSync, 'A2');
  await _publishNote(localSync, _unrelatedNoteId, 'unrelated');

  final parents = await _parents(localSync);
  final a1 = parents[0].ordinal;
  final b1 = parents[1].ordinal;
  final a2 = parents[2].ordinal;
  final pairs = await _sequencePairs(localSync);
  final explicitEdge = pairs.contains((b1, a1));
  final selfEdge = pairs.contains((a2, a1));
  final noImplicitJoin = !pairs.contains((b1, a2)) && !pairs.contains((a2, b1));
  final beforeRestart = await _durableSchedulingState(localSync);
  await localSync.close();

  final probe = _ProbeTransport(_restTransport(session));
  localSync = await _open(
    session,
    path,
    prerequisites,
    activate: false,
    transport: probe,
  );
  try {
    final restartPreserved =
        beforeRestart == await _durableSchedulingState(localSync);
    await startLocalSync(localSync);
    await _waitForRequests(probe, 1);
    await _waitFor(
      localSync,
      () async =>
          _sameNames(await _queuedNames(localSync), const ['CaptureMoment']) &&
          await _count(localSync, 'uplink_batches') == 0,
    );
    final firstNames = probe.uplinkNames.first;
    final unrelatedOvertook =
        firstNames.length == 3 &&
        firstNames[0] == 'RenameSpace' &&
        firstNames[1] == 'RenameSpace' &&
        firstNames[2] == 'PublishNote';

    prerequisites.complete(_blockedGate, PrerequisiteAttemptResult.ready);
    await _waitUntilSettled(localSync);
    return {
      'explicitEdge': explicitEdge,
      'selfEdge': selfEdge,
      'noImplicitJoin': noImplicitJoin,
      'restartPreserved': restartPreserved,
      'unrelatedOvertook': unrelatedOvertook,
      'blockedMomentCaption': (await localSync.models.moment.get(
        _momentId(_blockedMomentId),
      ))?.caption,
      'spaceNameAfterOvertake': (await localSync.models.space.get(
        _spaceId(),
      ))?.name,
    };
  } finally {
    await localSync.close();
  }
}

Future<Map<String, Object?>> _businessSameBatch(
  WireSession session,
  String path,
  ControlledPrerequisites prerequisites,
) async {
  final probe = _ProbeTransport(_restTransport(session));
  final localSync = await _open(
    session,
    path,
    prerequisites,
    activate: false,
    transport: probe,
  );
  try {
    await _rename(localSync, 'Same batch');
    await _capture(
      localSync,
      momentId: _sameBatchMomentId,
      caption: 'same batch',
    );
    await startLocalSync(localSync);
    await _waitForRequests(probe, 1);
    await _waitUntilSettled(localSync);
    return {
      'businessSameBatch': _sameNames(probe.uplinkNames.first, const [
        'RenameSpace',
        'CaptureMoment',
      ]),
    };
  } finally {
    await localSync.close();
  }
}

Future<Map<String, Object?>> _lifecycleAcceptance(
  WireSession session,
  String path,
  ControlledPrerequisites prerequisites,
) async {
  final probe = _ProbeTransport(_restTransport(session), holdDownlink: true);
  final localSync = await _open(
    session,
    path,
    prerequisites,
    activate: false,
    transport: probe,
  );
  try {
    await _capture(
      localSync,
      momentId: _lifecycleMomentId,
      caption: 'lifecycle root',
    );
    await _revise(
      localSync,
      momentId: _lifecycleMomentId,
      caption: 'lifecycle dependent',
      tagId: _lifecycleTagId,
      tagLabel: _lifecycleGate,
    );
    prerequisites.complete(_lifecycleGate, PrerequisiteAttemptResult.ready);
    final prerequisiteCount = await _count(
      localSync,
      'pending_mutation_prerequisites',
    );

    await startLocalSync(localSync);
    await _waitForRequests(probe, 2);
    await _waitFor(
      localSync,
      () async => await _acceptedBatchCount(localSync) == 2,
    );
    final acceptedBeforeSettlement =
        await _count(localSync, 'pending_mutations') == 2 &&
        await _acceptedBatchCount(localSync) == 2;
    final lifecycleSeparateRequests =
        _sameNames(probe.uplinkNames[0], const ['CaptureMoment']) &&
        _sameNames(probe.uplinkNames[1], const ['ReviseMoment']);

    probe.releaseDownlink();
    await _waitUntilSettled(localSync);
    return {
      'lifecycleEdgeFrozen': prerequisiteCount == 1,
      'lifecycleSeparateRequests': lifecycleSeparateRequests,
      'acceptedBeforeSettlement': acceptedBeforeSettlement,
    };
  } finally {
    probe.releaseDownlink();
    await localSync.close();
  }
}

Future<Map<String, Object?>> _lifecycleRejection(
  WireSession session,
  String path,
  ControlledPrerequisites prerequisites,
) async {
  final probe = _ProbeTransport(_restTransport(session));
  final localSync = await _open(
    session,
    path,
    prerequisites,
    activate: false,
    transport: probe,
  );
  try {
    await _capture(
      localSync,
      momentId: _rejectedMomentId,
      caption: rejectedCaption,
    );
    await _revise(
      localSync,
      momentId: _rejectedMomentId,
      caption: 'must not reach the host',
      tagId: _rejectedDependentTagId,
      tagLabel: 'cascade-ready',
    );
    prerequisites.complete('cascade-ready', PrerequisiteAttemptResult.ready);
    // The successful neighbour advances Downlink. A batch containing only
    // refusals emits no invalidation, which is a separate receipt-lifecycle
    // question rather than part of dependency cascading.
    await _publishNote(localSync, _cascadeNoteId, 'cascade neighbour');
    await startLocalSync(localSync);
    await _waitUntilSettled(localSync);
    final sent = probe.uplinkNames.expand((names) => names).toList();
    return {
      'lifecycleCascade':
          _sameNames(sent, const ['CaptureMoment', 'PublishNote']) &&
          await localSync.models.moment.get(_momentId(_rejectedMomentId)) ==
              null &&
          await localSync.models.starTag.get(_tagId(_rejectedDependentTagId)) ==
              null,
    };
  } finally {
    await localSync.close();
  }
}

Future<Map<String, Object?>> _sequenceRejection(
  WireSession session,
  String path,
  ControlledPrerequisites prerequisites,
) async {
  var localSync = await _open(session, path, prerequisites);
  await localSync.transaction(
    (outerTx) => outerTx.mutate.writeMoment(
      (tx) async => (
        moment: Moment.create(
          id: UUID.withValidation(_sequenceMomentId),
          spaceId: UUID.withValidation(conformanceSpaceId),
          capturedAt: DateTime.parse(conformanceCapturedAt),
          caption: 'sequence base',
        ),
      ),
    ),
  );
  await _waitUntilSettled(localSync);
  await localSync.close();

  final probe = _ProbeTransport(_restTransport(session));
  localSync = await _open(
    session,
    path,
    prerequisites,
    activate: false,
    transport: probe,
  );
  try {
    await _revise(
      localSync,
      momentId: _sequenceMomentId,
      caption: rejectedCaption,
    );
    await _revise(
      localSync,
      momentId: _sequenceMomentId,
      caption: 'after sequence rejection',
      tagId: _sequenceTagId,
      tagLabel: _sequenceGate,
    );
    final sequenceEdgeCount = await _count(
      localSync,
      'pending_mutation_sequences',
    );
    final prerequisiteCount = await _count(
      localSync,
      'pending_mutation_prerequisites',
    );
    await _publishNote(localSync, _sequenceNoteId, 'sequence neighbour');

    await startLocalSync(localSync);
    await _waitFor(
      localSync,
      () async =>
          probe.uplinkNames.isNotEmpty &&
          _sameNames(await _queuedNames(localSync), const ['ReviseMoment']) &&
          await _count(localSync, 'uplink_batches') == 0,
    );
    final dependentSurvived =
        await localSync.models.moment.get(_momentId(_sequenceMomentId)) != null;
    prerequisites.complete(_sequenceGate, PrerequisiteAttemptResult.ready);
    await _waitUntilSettled(localSync);
    final sent = probe.uplinkNames.expand((names) => names).toList();
    return {
      'sequenceOnlyEdgeFrozen':
          sequenceEdgeCount == 1 && prerequisiteCount == 0,
      'sequenceReleased':
          dependentSurvived &&
          _sameNames(sent, const [
            'ReviseMoment',
            'PublishNote',
            'ReviseMoment',
          ]) &&
          (await localSync.models.moment.get(
                _momentId(_sequenceMomentId),
              ))?.caption ==
              'after sequence rejection' &&
          await localSync.models.starTag.get(_tagId(_sequenceTagId)) != null,
    };
  } finally {
    await localSync.close();
  }
}

Future<Map<String, Object?>> _frozenRetry(
  WireSession session,
  String path,
  ControlledPrerequisites prerequisites,
) async {
  final probe = _ProbeTransport(
    _restTransport(session),
    holdDownlink: true,
    loseFirstUplinkResponse: true,
  );
  final localSync = await _open(
    session,
    path,
    prerequisites,
    activate: false,
    transport: probe,
  );
  try {
    await _rename(localSync, 'Retry exactly');
    await startLocalSync(localSync);
    await probe.firstResponseLost.timeout(const Duration(seconds: 30));
    await _publishNote(localSync, _retryNoteId, 'after frozen retry');
    await probe.retryArrived.timeout(const Duration(seconds: 30));

    final retryIdentical =
        probe.uplinkBodies.length >= 2 &&
        _bytesEqual(probe.uplinkBodies[0], probe.uplinkBodies[1]);
    final retryBeforeNewWork =
        _sameNames(probe.uplinkNames[0], const ['RenameSpace']) &&
        _sameNames(probe.uplinkNames[1], const ['RenameSpace']);
    probe.allowRetry();
    await _waitForRequests(probe, 3);
    probe.releaseDownlink();
    await _waitUntilSettled(localSync);
    return {
      'retryIdentical': retryIdentical,
      'retryBeforeNewWork': retryBeforeNewWork,
      'newWorkFollowedRetry': _sameNames(probe.uplinkNames[2], const [
        'PublishNote',
      ]),
    };
  } finally {
    probe.allowRetry();
    probe.releaseDownlink();
    await localSync.close();
  }
}

Future<void> _capture(
  LocalSync localSync, {
  required String momentId,
  required String caption,
  String? tagId,
  String? tagLabel,
}) async {
  if ((tagId == null) != (tagLabel == null)) {
    throw ArgumentError('tag id and label must be supplied together');
  }
  final id = UUID.withValidation(momentId);
  await localSync.transaction(
    (outerTx) => outerTx.mutate.captureMoment(
      (tx) async => (
        moment: Moment.create(
          id: id,
          spaceId: UUID.withValidation(conformanceSpaceId),
          capturedAt: DateTime.parse(conformanceCapturedAt),
          caption: caption,
        ),
        star: Star.create(
          userId: UUID.withValidation(conformanceUserId),
          momentId: id,
        ),
        tags: [
          if (tagId != null)
            StarTag.create(
              id: UUID.withValidation(tagId),
              userId: UUID.withValidation(conformanceUserId),
              momentId: id,
              label: tagLabel!,
            ),
        ],
      ),
    ),
  );
}

Future<void> _revise(
  LocalSync localSync, {
  required String momentId,
  required String caption,
  String? tagId,
  String? tagLabel,
}) async {
  if ((tagId == null) != (tagLabel == null)) {
    throw ArgumentError('tag id and label must be supplied together');
  }
  final id = _momentId(momentId);
  await localSync.transaction(
    (outerTx) => outerTx.mutate.reviseMoment((tx) async {
      final moment = await tx.models.moment.get(id);
      if (moment == null) throw StateError('Moment $momentId is missing');
      return (
        moment: tx.moment.update(moment, caption: FieldUpdate.set(caption)),
        removedTags: <StarTagDelete>[],
        addedTags: [
          if (tagId != null)
            StarTag.create(
              id: UUID.withValidation(tagId),
              userId: UUID.withValidation(conformanceUserId),
              momentId: id.value,
              label: tagLabel!,
            ),
        ],
        star: null,
      );
    }),
  );
}

Future<void> _rename(LocalSync localSync, String name) async {
  await localSync.transaction(
    (outerTx) => outerTx.mutate.renameSpace((tx) async {
      final space = await tx.models.space.get(_spaceId());
      if (space == null) throw StateError('seeded Space is missing');
      return (space: tx.space.update(space, name: name));
    }),
  );
}

Future<void> _publishNote(LocalSync localSync, String id, String text) =>
    localSync.transaction(
      (outerTx) => outerTx.mutate.publishNote(
        (tx) async => (
          note: LocalNote.create(
            id: UUID.withValidation(id),
            text: text,
            status: LocalNoteStatus.active,
          ),
        ),
      ),
    );

Future<LocalSync> _open(
  WireSession session,
  String path,
  ControlledPrerequisites prerequisites, {
  bool activate = true,
  LocalSyncTransport? transport,
}) async {
  final localSync = await LocalSync.open(
    driver: localSyncDatabaseDriver(path: path),
    clientId: _clientId,
    transport: transport ?? _restTransport(session),
    prerequisites: prerequisites.handlers,
  );
  if (activate) await startLocalSync(localSync);
  return localSync;
}

RestWsTransport _restTransport(WireSession session) => RestWsTransport(
  baseUri: Uri.parse('http://127.0.0.1:${session.port}/'),
  getAccessToken: () async => conformanceToken,
  sleep: (_) async {},
);

Future<List<({int ordinal, String name})>> _parents(LocalSync localSync) async {
  final result = await localSync.readOnlySql.query(
    'SELECT ordinal, name FROM pending_mutations ORDER BY ordinal',
  );
  return [
    for (final row in result.rows)
      (ordinal: row['ordinal']! as int, name: row['name']! as String),
  ];
}

Future<Set<(int, int)>> _sequencePairs(LocalSync localSync) async {
  final result = await localSync.readOnlySql.query(
    'SELECT mutation_ordinal, predecessor_ordinal '
    'FROM pending_mutation_sequences ORDER BY mutation_ordinal, '
    'predecessor_ordinal',
  );
  return {
    for (final row in result.rows)
      (row['mutation_ordinal']! as int, row['predecessor_ordinal']! as int),
  };
}

Future<String> _durableSchedulingState(LocalSync localSync) async {
  Future<List<List<Object?>>> rows(String sql) async {
    final result = await localSync.readOnlySql.query(sql);
    return [
      for (final row in result.rows)
        [
          for (var index = 0; index < result.columns.length; index += 1)
            row.valueAt(index),
        ],
    ];
  }

  return jsonEncode({
    'parents': await rows(
      'SELECT ordinal, name, batch_sequence FROM pending_mutations '
      'ORDER BY ordinal',
    ),
    'sequences': await rows(
      'SELECT mutation_ordinal, predecessor_ordinal '
      'FROM pending_mutation_sequences ORDER BY mutation_ordinal, '
      'predecessor_ordinal',
    ),
    'prerequisites': await rows(
      'SELECT mutation_ordinal, prerequisite_ordinal '
      'FROM pending_mutation_prerequisites ORDER BY mutation_ordinal, '
      'prerequisite_ordinal',
    ),
  });
}

Future<List<String>> _queuedNames(LocalSync localSync) async {
  final result = await localSync.readOnlySql.query(
    'SELECT name FROM pending_mutations ORDER BY ordinal',
  );
  return [for (final row in result.rows) row['name']! as String];
}

Future<int> _acceptedBatchCount(LocalSync localSync) async {
  final result = await localSync.readOnlySql.query(
    'SELECT COUNT(*) AS count FROM uplink_batches '
    'WHERE required_sync_id IS NOT NULL',
  );
  return result.rows.single['count']! as int;
}

Future<int> _count(LocalSync localSync, String table) async {
  final result = await localSync.readOnlySql.query(
    'SELECT COUNT(*) AS count FROM "$table"',
  );
  return result.rows.single['count']! as int;
}

Future<void> _waitUntilSettled(LocalSync localSync) => _waitFor(
  localSync,
  () async =>
      await _count(localSync, 'pending_mutations') == 0 &&
      await _count(localSync, 'uplink_batches') == 0,
);

Future<void> _waitForRequests(_ProbeTransport probe, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    if (probe.uplinkNames.length >= count) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('expected $count Uplink requests, got ${probe.uplinkNames}');
}

Future<void> _waitFor(
  LocalSync localSync,
  Future<bool> Function() condition,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError(
    'the scheduling journey did not settle; '
    'queued=${await _queuedNames(localSync)}, '
    'batches=${await _count(localSync, 'uplink_batches')}',
  );
}

MomentId _momentId(String value) => MomentId(UUID.withValidation(value));
StarTagId _tagId(String value) => StarTagId(UUID.withValidation(value));
SpaceId _spaceId() => SpaceId(UUID.withValidation(conformanceSpaceId));

bool _sameNames(List<String> actual, List<String> expected) {
  if (actual.length != expected.length) return false;
  for (var index = 0; index < actual.length; index += 1) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// A byte-level observer around the real HTTP/WebSocket transport. It can
/// delay Downlink without interpreting it and can simulate exactly one lost
/// Uplink response after the host has accepted the request.
final class _ProbeTransport implements LocalSyncTransport {
  _ProbeTransport(
    this._inner, {
    bool holdDownlink = false,
    this.loseFirstUplinkResponse = false,
  }) : _holdingDownlink = holdDownlink;

  final LocalSyncTransport _inner;
  final bool loseFirstUplinkResponse;
  final StreamController<DownlinkTransportEvent> _events =
      StreamController<DownlinkTransportEvent>.broadcast();
  final List<DownlinkPageReceived> _heldPages = [];
  final Completer<void> _downlinkReleased = Completer<void>();
  final Completer<void> _firstResponseLost = Completer<void>();
  final Completer<void> _retryArrived = Completer<void>();
  final Completer<void> _retryAllowed = Completer<void>();
  final List<Uint8List> uplinkBodies = [];
  final List<List<String>> uplinkNames = [];
  StreamSubscription<DownlinkTransportEvent>? _subscription;
  bool _holdingDownlink;
  bool _lostResponse = false;
  bool _closed = false;

  Future<void> get firstResponseLost => _firstResponseLost.future;
  Future<void> get retryArrived => _retryArrived.future;

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => _events.stream;

  @override
  Future<void> start() async {
    _subscription = _inner.downlinkEvents.listen((event) {
      if (_holdingDownlink && event is DownlinkPageReceived) {
        _heldPages.add(event);
      } else {
        _events.add(event);
      }
    }, onError: _events.addError);
    await _inner.start();
  }

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    final copied = Uint8List.fromList(body);
    uplinkBodies.add(copied);
    uplinkNames.add(_mutationNames(copied));
    if (loseFirstUplinkResponse && !_lostResponse) {
      _lostResponse = true;
      await _inner.sendUplink(copied, cancellation: cancellation);
      if (!_firstResponseLost.isCompleted) _firstResponseLost.complete();
      throw const LocalSyncRetryableTransportFailure(
        'the host response was deliberately lost',
      );
    }
    if (loseFirstUplinkResponse && uplinkBodies.length == 2) {
      if (!_retryArrived.isCompleted) _retryArrived.complete();
      await _retryAllowed.future;
    }
    return _inner.sendUplink(copied, cancellation: cancellation);
  }

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    if (_holdingDownlink) await _downlinkReleased.future;
    return _inner.fetchDownlink(body, cancellation: cancellation);
  }

  void releaseDownlink() {
    if (!_holdingDownlink) return;
    _holdingDownlink = false;
    if (!_downlinkReleased.isCompleted) _downlinkReleased.complete();
    for (final page in _heldPages) {
      _events.add(page);
    }
    _heldPages.clear();
  }

  void allowRetry() {
    if (!_retryAllowed.isCompleted) _retryAllowed.complete();
  }

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) =>
      _inner.sendDownlinkFrame(frame);

  @override
  Future<void> restartDownlinkConnection() =>
      _inner.restartDownlinkConnection();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    allowRetry();
    releaseDownlink();
    await _inner.close();
    await _subscription?.cancel();
    await _events.close();
  }

  static List<String> _mutationNames(Uint8List body) {
    final envelope = (jsonDecode(utf8.decode(body)) as Map)
        .cast<String, Object?>();
    return [
      for (final raw in envelope['mutations']! as List<Object?>)
        ((raw! as Map)['name']! as String),
    ];
  }
}
