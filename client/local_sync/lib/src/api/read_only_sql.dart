import 'dart:async';

import 'package:collection/collection.dart';
import 'package:local_sync_database/local_sync_database.dart';

/// Reads the local database directly, in SQL.
///
/// This is the door CAP-393 opens: because the main tables hold the merged
/// view, a raw query returns exactly what the typed readers return —
/// optimistic edits included — so a product reader can join, group and filter
/// across Models without anyone hand-merging pending mutations first.
///
/// Read-only by three layers, not by convention: there is no write or execute
/// method here, statements run on the read connection pool, and those
/// connections carry `PRAGMA query_only = ON`. A write attempt is a database
/// error, not a silent success.
///
/// The only semantic rule is committed-rows isolation: a write inside an open
/// `localSync.transaction(...)` is invisible here until that transaction
/// commits.
abstract interface class LocalSyncReadOnlySql {
  Future<DatabaseQueryResult> query(
    String sql, [
    List<Object?> variables = const [],
  ]);

  /// Re-runs [sql] whenever any of [tables] changes.
  ///
  /// Emits once immediately, then on each change that yields a different
  /// result, latest-only — a query the change did not actually affect stays
  /// silent rather than redrawing the screen. The invalidation set is given,
  /// never inferred: guessing it from the SQL would be a parser, and a parser
  /// that guessed wrong would silently stop updating the screen. The stream
  /// closes when it is cancelled and when the database closes.
  Stream<DatabaseQueryResult> watch(
    String sql, {
    List<Object?> variables = const [],
    required Set<String> tables,
  });
}

final class DatabaseReadOnlySql implements LocalSyncReadOnlySql {
  DatabaseReadOnlySql(this._database);

  final Database _database;
  final _watchers = <StreamController<DatabaseQueryResult>>{};

  /// Ends every watcher this seam opened. The database is going away, and a
  /// watcher that outlived it would go on querying a closed handle.
  Future<void> close() async {
    final open = _watchers.toList();
    _watchers.clear();
    for (final controller in open) {
      if (!controller.isClosed) await controller.close();
    }
  }

  static List<List<Object?>> _values(DatabaseQueryResult result) => [
    for (final row in result.rows)
      [
        for (var index = 0; index < result.columns.length; index += 1)
          row.valueAt(index),
      ],
  ];

  @override
  Future<DatabaseQueryResult> query(
    String sql, [
    List<Object?> variables = const [],
  ]) => _database.query(DatabaseQuery(sql: sql, variables: variables));

  @override
  Stream<DatabaseQueryResult> watch(
    String sql, {
    List<Object?> variables = const [],
    required Set<String> tables,
  }) {
    if (tables.isEmpty) {
      throw ArgumentError.value(
        tables,
        'tables',
        'a watched query must name the tables that invalidate it',
      );
    }
    late final StreamController<DatabaseQueryResult> controller;
    StreamSubscription<void>? invalidations;
    var pending = Future<void>.value();
    var cancelled = false;
    var delivered = false;
    List<List<Object?>>? previous;

    void reload() {
      pending = pending.then((_) async {
        if (cancelled) return;
        try {
          final result = await query(sql, variables);
          if (cancelled) return;
          final values = _values(result);
          if (delivered &&
              const DeepCollectionEquality().equals(previous, values)) {
            return;
          }
          delivered = true;
          previous = values;
          controller.add(result);
        } on DatabaseException catch (error, stackTrace) {
          if (cancelled) return;
          // A closed database is the end of the stream, not a fault to report
          // to a screen that is going away with it.
          if (error.kind == DatabaseErrorKind.closed) {
            await controller.close();
            return;
          }
          controller.addError(error, stackTrace);
        } catch (error, stackTrace) {
          if (!cancelled) controller.addError(error, stackTrace);
        }
      });
    }

    controller = StreamController<DatabaseQueryResult>(
      onListen: () {
        _watchers.add(controller);
        invalidations = _database
            .watchTables(tables)
            .listen(
              (_) => reload(),
              onError: controller.addError,
              onDone: () => pending.whenComplete(controller.close),
            );
        reload();
      },
      onPause: () => invalidations?.pause(),
      onResume: () => invalidations?.resume(),
      onCancel: () async {
        cancelled = true;
        _watchers.remove(controller);
        await invalidations?.cancel();
      },
    );
    return controller.stream;
  }
}
