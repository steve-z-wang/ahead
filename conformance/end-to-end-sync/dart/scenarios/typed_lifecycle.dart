import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

/// A row's whole life, one page at a time: created, updated to an explicit
/// null, then deleted — each written on the host, pulled as its own page, and
/// applied before the next one is written.
///
/// The reads are the generated typed ones, because that is the only reader the
/// app has. A `caption` that arrives as absent rather than null decodes to the
/// same `null` in SQL and to a very different thing in a product: the strict
/// decoder is what tells them apart, and it only speaks when a page is
/// applied.
Future<Map<String, Object?>> runTypedLifecycle(WireSession session) async {
  final models = typedModels(session.scope);
  final id = momentIdOf(conformanceMomentId);
  final failures = <String>[];
  final cursors = <int>[];

  Future<void> settleAndApply(
    int batchSequence,
    List<StoredMutationOperation> mutations,
  ) async {
    await session.settle(batchSequence, mutations);
    final cursor = await readCursor(session.scope);
    final page = await session.pull(cursor);
    final applied = await applyPage(session.scope, page, afterSyncId: cursor);
    failures.addAll(applied.failures.map((failure) => failure.toString()));
    cursors.add(await readCursor(session.scope));
  }

  await settleAndApply(1, momentFamily());
  final created = await models.moment.get(id);

  // An explicit null, which is the shape a page most easily loses: dropped on
  // the way down it reads as "unchanged", and the row keeps a caption its
  // author cleared.
  await settleAndApply(2, [
    momentUpdate(1, values: {'caption': null}),
  ]);
  final updated = await models.moment.get(id);

  await settleAndApply(3, [momentDelete(1)]);
  final deleted = await models.moment.get(id);

  return {
    'failures': failures,
    'createdCaption': created?.caption,
    'updatedRowPresent': updated != null,
    'updatedCaptionIsNull': updated != null && updated.caption == null,
    'deletedRowAbsent': deleted == null,
    'cursors': cursors,
  };
}
