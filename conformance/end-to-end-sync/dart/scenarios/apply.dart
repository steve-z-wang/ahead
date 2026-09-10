import 'package:local_sync_conformance/src/support/wire_scenario.dart';
import 'package:local_sync_database/local_sync_database.dart';

import 'support.dart';

/// The founding journey (CAP-428): the page a real host emits, decoded by the
/// strict Model decoder and APPLIED into the real local database, then read
/// back out with SQL.
///
/// Every protocol scenario stops at the envelope, and the envelope codec
/// renames keys without judging them — which is how the server could carry
/// identity fields inside `state` and omit nulls for six days with a green
/// gate. This is where that fails.
Future<Map<String, Object?>> runApply(WireSession session) async {
  await session.settle(1, accountStateFamily());
  final page = await session.pull(0);
  final applied = await applyPage(session.scope, page, afterSyncId: 0);
  final account = await session.scope.current.query(
    DatabaseQuery(
      sql: 'SELECT "space_order", "inbox_seen_at" FROM "model_account_state"',
    ),
  );
  final space = await session.scope.current.query(
    DatabaseQuery(sql: 'SELECT "kind" FROM "model_space"'),
  );
  return {
    // A change the store refuses is reported rather than thrown, so the
    // harness names the disagreement instead of failing on a missing row.
    'failures': [for (final failure in applied.failures) failure.toString()],
    // A list, an enum and a null: the three shapes a page can spell wrong,
    // read back out of the database rather than off the wire.
    'spaceOrder': account.singleOrNull?['space_order'],
    'inboxSeenAtIsNull': account.singleOrNull?['inbox_seen_at'] == null,
    'kind': space.singleOrNull?['kind'],
  };
}
