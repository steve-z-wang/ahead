import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';
import 'package:local_sync_database/local_sync_database.dart';

import 'support.dart';

/// The row and the cursor move together, or neither moves.
///
/// This is the one promise a passing test cannot show by succeeding: a client
/// that wrote the row but not the cursor applies the same change again on the
/// next page, and one that wrote the cursor but not the row loses the change
/// for good. So the cursor is made unwritable — a trigger the database
/// enforces, not a stub standing in for one — and what matters is what is left
/// behind afterwards.
const _blockName = 'conformance_block_cursor';

Future<Map<String, Object?>> runAtomicLocalFailure(WireSession session) async {
  await session.settle(1, momentFamily());
  final page = await session.pull(0);

  Object? failure;
  int blockedRows;
  int blockedCursor;
  await _install(session.scope);
  try {
    try {
      await applyPage(session.scope, page, afterSyncId: 0);
    } catch (error) {
      failure = error;
    }
    blockedRows = await _syncedRows(session.scope);
    blockedCursor = await readCursor(session.scope);
  } finally {
    await _remove(session.scope);
  }

  final applied = await applyPage(session.scope, page, afterSyncId: 0);
  final moment = await typedModels(
    session.scope,
  ).moment.get(momentIdOf(conformanceMomentId));

  return {
    'failure': failure?.toString(),
    'blockedRows': blockedRows,
    'blockedCursor': blockedCursor,
    'retriedFailures': [
      for (final failure in applied.failures) failure.toString(),
    ],
    'retriedCaption': moment?.caption,
    'retriedRows': await _syncedRows(session.scope),
    'retriedCursor': await readCursor(session.scope),
    'pageThrough': page.throughSyncId,
  };
}

/// Everything the page carries, counted where it lands. The first change of
/// the page is the User, so a transaction that wrote its row and then failed
/// on the cursor is visible here as a row that should not exist.
Future<int> _syncedRows(LocalDatabaseScope scope) async =>
    await countRows(scope, 'model_user') +
    await countRows(scope, 'model_space') +
    await countRows(scope, 'model_moment');

Future<void> _install(LocalDatabaseScope scope) => scope.current.execute(
  DatabaseStatement(
    sql:
        '''
          CREATE TRIGGER $_blockName
          BEFORE UPDATE OF last_applied_sync_id ON downlink_scope_state
          BEGIN
            SELECT RAISE(ABORT, 'the Downlink cursor cannot be written');
          END
        ''',
  ),
);

Future<void> _remove(LocalDatabaseScope scope) => scope.current.execute(
  DatabaseStatement(sql: 'DROP TRIGGER IF EXISTS $_blockName'),
);
