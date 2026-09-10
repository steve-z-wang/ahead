import 'package:local_sync_database/local_sync_database.dart';

import '../projection/model_record.dart';
import '../schema/model_id.dart';
import '../schema/model_schema.dart';
import 'canonical_store.dart';
import 'database_scope.dart';
import 'local_value_codec.dart';
import 'model_database_descriptor.dart';

/// The last server truth for exactly the rows that currently carry pending
/// edits (CAP-393 spec §2).
///
/// The main table holds what the user sees; this twin holds what the server
/// last said, so a rejection can restore it and new truth can be rebased under
/// it. Sparse by construction: a row lives here only while it diverges from
/// truth, so every twin is empty once the client is fully synchronized.
///
/// Copy-aside is a single statement — no row travels through Dart to get here.
final class BeforeImageStore<I extends ModelId> {
  BeforeImageStore({
    required this.database,
    required this.main,
    required this.before,
    this.codec = const LocalValueCodec(),
  }) : _twin = SqlCanonicalStore(database: database, descriptor: before) {
    if (!identical(main.schema, before.schema)) {
      throw StateError('a before-image twin must share its Model schema');
    }
  }

  final LocalDatabaseScope database;

  /// The table the user reads.
  final ModelDatabaseDescriptor<I> main;

  /// Its twin — same schema and columns, a different name.
  final ModelDatabaseDescriptor<I> before;

  final LocalValueCodec codec;

  final SqlCanonicalStore<I> _twin;

  ModelSchema<I> get schema => before.schema;

  Future<bool> exists(I id) async => await _twin.get(id) != null;

  /// Copies the row out of the main table as it currently stands.
  ///
  /// Refuses to overwrite truth already held: the held row is the only copy of
  /// the server's state, and by the second edit the main row has already
  /// drifted, so copying again would destroy exactly what this table exists to
  /// keep. Callers guard with [exists] — the first edit of a row copies, later
  /// edits do not. Copying an absent row writes nothing: a pending create has
  /// no before-image, because the queue's create *is* the marker that prior
  /// truth was nonexistence.
  Future<void> copyAside(I id) async {
    final columns = schema.fields
        .map((field) => quoteSqlIdentifier(before.column(field.name)))
        .join(', ');
    final source = schema.fields
        .map((field) => quoteSqlIdentifier(main.column(field.name)))
        .join(', ');
    await database.current.execute(
      DatabaseStatement(
        sql:
            'INSERT INTO ${quoteSqlIdentifier(before.tableName)} '
            '($columns) SELECT $source '
            'FROM ${quoteSqlIdentifier(main.tableName)} '
            'WHERE $_identityPredicate',
        variables: _identityValues(id),
      ),
    );
  }

  /// Replaces the held truth — the server spoke again while the row was dirty.
  Future<void> updateTruth(I id, Map<String, Object?> values) =>
      _twin.upsert(id, values);

  /// Applies a patch to the held truth — the direct lane wrote a FINAL edit
  /// onto a dirty local row, and truth must carry it beneath the provisional
  /// edits standing on top. Callers guard with [exists].
  Future<void> patchTruth(I id, Map<String, Object?> patch) =>
      _twin.update(id, patch);

  Future<ModelRecord<I>?> read(I id) => _twin.get(id);

  /// Identities of the held rows whose [fieldValues] all match — the rows a
  /// cascade must still account for after main has been emptied of them.
  Future<List<I>> identitiesMatching(Map<String, Object?> fieldValues) =>
      _twin.identitiesMatching(fieldValues);

  /// Forgets the row's truth: main now equals it exactly.
  Future<void> drop(I id) => _twin.purge(id);

  String get _identityPredicate => schema.identity
      .map((field) => '${quoteSqlIdentifier(main.column(field))} = ?')
      .join(' AND ');

  List<Object?> _identityValues(I id) => [
    for (final field in schema.identity)
      codec.encodeSqlValue(schema.fieldsByName[field]!, id.components[field]),
  ];
}
