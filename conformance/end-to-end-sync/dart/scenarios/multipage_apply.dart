import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

/// More rows than one page holds, walked from the client's own cursor until
/// there is nothing left to ask for.
///
/// A stream that fits in a single page proves nothing about where the second
/// one starts. Fifty-one rows is the smallest that does not fit, and what it
/// costs to be wrong about the boundary is a row applied twice or never — so
/// the count is taken from the client's own tables at the end, not from the
/// pages on the way.
const _rowsToPublish = 51;
const _mutationsPerBatch = 20;

Future<Map<String, Object?>> runMultipageApply(WireSession session) async {
  var batchSequence = 0;
  for (final batch in _batches()) {
    batchSequence += 1;
    await session.settle(batchSequence, batch);
  }

  final failures = <String>[];
  final pageFrom = <int>[];
  final pageThrough = <int>[];
  final pageChanges = <int>[];
  while (true) {
    final cursor = await readCursor(session.scope);
    final page = await session.pull(cursor);
    if (page.changes.isEmpty) break;
    final applied = await applyPage(session.scope, page, afterSyncId: cursor);
    failures.addAll(applied.failures.map((failure) => failure.toString()));
    pageFrom.add(page.fromSyncId);
    pageThrough.add(page.throughSyncId);
    pageChanges.add(page.changes.length);
  }

  final models = typedModels(session.scope);
  final moments = await models.moment.query().get();
  final user = await models.user.get(
    UserId(UUID.withValidation(conformanceUserId)),
  );
  final space = await models.space.get(
    SpaceId(UUID.withValidation(conformanceSpaceId)),
  );

  return {
    'failures': failures,
    'pageFrom': pageFrom,
    'pageThrough': pageThrough,
    'pageChanges': pageChanges,
    'syncedRows':
        moments.length + (user == null ? 0 : 1) + (space == null ? 0 : 1),
    'distinctMoments': moments.map((moment) => moment.id.value).toSet().length,
    'cursor': await readCursor(session.scope),
  };
}

/// The rows, cut into batches the protocol will take: the User and the Space
/// every Moment hangs off, then Moments until there are 51 rows in all.
List<List<StoredMutationOperation>> _batches() {
  final rows = <StoredMutationOperation>[
    conformanceUserRow(),
    conformanceSpaceRow(),
    for (var index = 3; index <= _rowsToPublish; index += 1)
      momentCreate(index, id: _momentId(index), caption: 'page $index'),
  ];
  return [
    for (var start = 0; start < rows.length; start += _mutationsPerBatch)
      [
        for (
          var index = start;
          index < start + _mutationsPerBatch && index < rows.length;
          index += 1
        )
          // Ordinals are positional within their batch, which is the only
          // scope the protocol gives them.
          _withOrdinal(rows[index], index - start + 1),
      ],
  ];
}

StoredMutationOperation _withOrdinal(
  StoredMutationOperation row,
  int ordinal,
) => StoredMutationOperation(
  // One operation, one act: the fixture's acts are numbered with it.
  mutationOrdinal: ordinal,
  position: 0,
  slotName: row.slotName,
  model: row.model,
  identityJson: row.identityJson,
  operation: row.operation,
  valuesJson: row.valuesJson,
  isUplink: row.isUplink,
);

String _momentId(int index) =>
    '550e8400-e29b-41d4-a716-${index.toString().padLeft(12, '0')}';
