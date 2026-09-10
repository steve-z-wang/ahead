import 'package:local_sync/local_sync.dart';

/// A registry entry for tests that only exercise encoding or decoding: it
/// knows its schema and refuses every storage call, so a test that
/// accidentally reaches storage fails loudly instead of quietly passing.
final class NeverModelRegistryEntry implements ModelRegistryEntry {
  const NeverModelRegistryEntry(this.schema);

  @override
  final ModelSchema<ModelId> schema;

  Never get _unused => throw StateError('${schema.name} storage is unused');

  @override
  Future<void> create(ModelId id, Map<String, Object?> values) => _unused;
  @override
  Future<void> upsert(ModelId id, Map<String, Object?> values) => _unused;
  @override
  Future<void> update(ModelId id, Map<String, Object?> patch) => _unused;
  @override
  Future<void> delete(ModelId id) => _unused;
  @override
  Future<void> deleteByCascade(ModelId id) => _unused;
  @override
  Future<void> deleteFinallyByCascade(ModelId id) => _unused;
  @override
  Future<void> advanceTruth(ModelId id, Set<int> settledOrdinals) => _unused;
  @override
  Future<ModelRecord<ModelId>?> readMain(ModelId id) => _unused;
  @override
  Future<ModelRecord<ModelId>?> readBefore(ModelId id) => _unused;
  @override
  Future<ModelRecord<ModelId>?> readCanonicalTruth(ModelId id) => _unused;
  @override
  Future<List<ModelMutation<ModelId>>> pendingMutations(ModelId id) => _unused;
  @override
  Future<List<ModelId>> identitiesInMain(Map<String, Object?> fieldValues) =>
      _unused;
  @override
  Future<List<ModelId>> identitiesInBefore(Map<String, Object?> fieldValues) =>
      _unused;
  @override
  Future<void> replaceTruth(ModelId id, Map<String, Object?>? values) =>
      _unused;
  @override
  Future<void> rebuild(ModelId id) => _unused;
  @override
  Future<void> settleByCascade(ModelId id) => _unused;
  @override
  Future<void> settle(ModelId id) => _unused;
}
