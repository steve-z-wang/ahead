import '../mutation/model_mutation.dart';
import '../mutation/mutation_store.dart';
import '../projection/effective_mutations.dart';
import '../projection/model_record.dart';
import '../projection/mutation_reducer.dart';
import '../storage/before_image_store.dart';
import '../storage/canonical_store.dart';
import '../storage/row_rebuilder.dart';
import 'model_id.dart';
import 'model_schema.dart';
import 'mutation_input_contracts.dart';

abstract interface class ModelRegistryEntry {
  /// The Model itself. Every generated Model has an entry: a Model describes a
  /// row shape and says nothing about replication (CAP-488), so there is
  /// nothing else for an entry to carry about it.
  ModelSchema<ModelId> get schema;

  Future<void> upsert(ModelId id, Map<String, Object?> values);

  Future<void> create(ModelId id, Map<String, Object?> values);

  Future<void> update(ModelId id, Map<String, Object?> patch);

  Future<void> delete(ModelId id);

  /// Deletes the row because an ancestor of it was deleted.
  ///
  /// Truth is held aside if it is not held already and the row has nothing
  /// pending — a row whose divergence began with a create has no truth to
  /// hold, and one already carrying edits holds the server's state, not the
  /// drifted one. The queue is never touched: the whole cascade is one action,
  /// and the action's single entry belongs to the row the user named.
  Future<void> deleteByCascade(ModelId id);

  /// Deletes the row because an ancestor of it was FINALLY deleted.
  ///
  /// A direct transaction delete is final at commit, and the schema decides how
  /// far a delete reaches (CAP-488) — so a descendant of one ends exactly
  /// where the named row does: gone from main, and holding no truth, because
  /// nonexistence IS its truth now. A pending edit of its own cannot bring it
  /// back: with no base to rebuild from, a rejection recomputes the same
  /// absence. Canonical state may of course speak for the row again later.
  Future<void> deleteFinallyByCascade(ModelId id);

  /// The row as the user sees it, or null when main holds none.
  Future<ModelRecord<ModelId>?> readMain(ModelId id);

  /// The truth held aside for the row, or null when it holds none.
  Future<ModelRecord<ModelId>?> readBefore(ModelId id);

  /// Canonical truth beneath pending optimism. A pending create deliberately
  /// answers null even though main already contains its optimistic row.
  Future<ModelRecord<ModelId>?> readCanonicalTruth(ModelId id);

  /// The row's own queue entries, oldest first.
  Future<List<ModelMutation<ModelId>>> pendingMutations(ModelId id);

  /// Identities of the main-table rows whose [fieldValues] all match.
  Future<List<ModelId>> identitiesInMain(Map<String, Object?> fieldValues);

  /// Identities of the before-image rows whose [fieldValues] all match.
  ///
  /// A row already deleted locally has left main but still holds its truth
  /// aside, so a cascade that only read main would walk straight past it.
  Future<List<ModelId>> identitiesInBefore(Map<String, Object?> fieldValues);

  /// Records new server truth for a dirty row, leaving main to be rebuilt on
  /// top of it (the rebase of spec §5).
  Future<void> replaceTruth(ModelId id, Map<String, Object?>? values);

  /// Recomputes main from held truth plus the edits that still stand, undoing
  /// an edit that has left the queue.
  Future<void> rebuild(ModelId id);

  /// Forgets the truth held for a row that fell with an ancestor whose delete
  /// the server has accepted.
  ///
  /// Only when nothing still stands for the row: main is already empty and
  /// truth is absent too, so holding the twin any longer would break the
  /// sparsity that makes a before-image mean divergence. A row with an edit
  /// of its own — doomed, and waiting for its rejection — keeps it.
  Future<void> settleByCascade(ModelId id);

  /// Settles an edit the server accepted.
  ///
  /// Unlike [rebuild] this must never undo anything: an accepted create holds
  /// no before-image, and its row in the main table is now the server's own,
  /// so there is nothing to recompute and rebuilding it would delete exactly
  /// the row that was just confirmed.
  Future<void> settle(ModelId id);

  /// Advances a COMPANION row's held truth past the operations a batch
  /// settled, before those operations leave the queue.
  ///
  /// A wire operation's row has its truth advanced over the Downlink — the
  /// server speaks its new state and [replaceTruth] records it. A companion
  /// never reaches the server, so acceptance itself is what moves its truth:
  /// the settled operations (always the oldest pending, since a batch is a
  /// queue prefix) are replayed over the held truth, and what they compute is
  /// what a later rejection of a still-pending act must restore. The caller
  /// visits only the rows this batch settled by companion alone (CAP-488).
  Future<void> advanceTruth(ModelId id, Set<int> settledOrdinals);
}

final class TypedModelRegistryEntry<I extends ModelId>
    implements ModelRegistryEntry {
  TypedModelRegistryEntry({
    required this.schema,
    required this.canonical,
    required this.before,
    required this.mutations,
  });

  @override
  final ModelSchema<I> schema;
  final CanonicalStore<I> canonical;
  final BeforeImageStore<I> before;
  final MutationStore<I> mutations;

  /// Every Model in one place, which no per-Model entry can see for itself.
  ///
  /// The registry sets this as it is built (see [ModelRegistry]) — a row
  /// cannot know what it inherits without knowing its ancestors' Models.
  ModelRegistry? _registry;

  RowRebuilder<I> get _rebuilder => RowRebuilder(
    main: canonical,
    before: before,
    mutations: _surviving,
    replay: MutationReducer(schema),
  );

  /// What a rebuild replays: the row's own queue entries, plus — for a Model
  /// that has an ancestor to inherit from — the ancestors' pending deletes.
  SurvivingMutations<I> get _surviving {
    final registry = _registry;
    if (registry == null) {
      if (schema.relations.any((relation) => relation.deleteOnTarget)) {
        // Silence here would under-cascade: the row would rebuild as though
        // the book it lives in were never deleted.
        throw StateError(
          '${schema.name} declares an onTargetDelete: delete reference and must be '
          'rebuilt through a ModelRegistry',
        );
      }
      return mutations;
    }
    return EffectiveMutations<I>(
      registry: registry,
      entry: this,
      own: mutations,
    );
  }

  @override
  Future<void> upsert(ModelId id, Map<String, Object?> values) async {
    await canonical.upsert(_identity(id), values);
  }

  @override
  Future<void> create(ModelId id, Map<String, Object?> values) async {
    await canonical.create(_identity(id), values);
  }

  @override
  Future<void> update(ModelId id, Map<String, Object?> patch) async {
    await canonical.update(_identity(id), patch);
  }

  @override
  Future<void> delete(ModelId id) async {
    await canonical.purge(_identity(id));
  }

  @override
  Future<void> deleteByCascade(ModelId id) async {
    final identity = _identity(id);
    if (!await before.exists(identity) &&
        (await mutations.read(identity)).isEmpty) {
      await before.copyAside(identity);
    }
    // Purge, not delete: the row may already be gone from main, found by the
    // truth it left behind.
    await canonical.purge(identity);
  }

  @override
  Future<void> deleteFinallyByCascade(ModelId id) async {
    final identity = _identity(id);
    await canonical.purge(identity);
    await before.drop(identity);
  }

  @override
  Future<ModelRecord<ModelId>?> readMain(ModelId id) =>
      canonical.get(_identity(id));

  @override
  Future<ModelRecord<ModelId>?> readBefore(ModelId id) =>
      before.read(_identity(id));

  @override
  Future<ModelRecord<ModelId>?> readCanonicalTruth(ModelId id) async {
    final identity = _identity(id);
    if ((await mutations.read(identity)).isNotEmpty) {
      return before.read(identity);
    }
    final held = await before.read(identity);
    return held ?? canonical.get(identity);
  }

  @override
  Future<List<ModelMutation<ModelId>>> pendingMutations(ModelId id) =>
      mutations.read(_identity(id));

  @override
  Future<List<ModelId>> identitiesInMain(Map<String, Object?> fieldValues) =>
      canonical.identitiesMatching(fieldValues);

  @override
  Future<List<ModelId>> identitiesInBefore(Map<String, Object?> fieldValues) =>
      before.identitiesMatching(fieldValues);

  @override
  Future<void> replaceTruth(ModelId id, Map<String, Object?>? values) async {
    final identity = _identity(id);
    if (values == null) {
      // Truth is now nonexistence; main is rebuilt by replaying what stands
      // on top of nothing.
      await before.drop(identity);
    } else {
      await before.updateTruth(identity, values);
    }
  }

  @override
  Future<void> rebuild(ModelId id) => _rebuilder.rebuild(_identity(id));

  @override
  Future<void> settleByCascade(ModelId id) async {
    final identity = _identity(id);
    if ((await _surviving.read(identity)).isEmpty) {
      await before.drop(identity);
    }
  }

  @override
  Future<void> settle(ModelId id) async {
    final identity = _identity(id);
    // Nothing held aside means main is already the server's own only when no
    // later edit still stands. Non-FIFO scheduling can settle an earlier act
    // while a later act on the same row remains queued; replay that survivor
    // over nonexistence even though there is no before-image.
    if (!await before.exists(identity) &&
        (await _surviving.read(identity)).isEmpty) {
      return;
    }
    await _rebuilder.rebuild(identity);
  }

  @override
  Future<void> advanceTruth(ModelId id, Set<int> settledOrdinals) async {
    final identity = _identity(id);
    final pending = await mutations.read(identity);
    final settled = [
      for (final mutation in pending)
        if (settledOrdinals.contains(mutation.position.mutationOrdinal))
          mutation,
    ];
    if (settled.isEmpty) return;
    if (settled.length == pending.length) {
      // Nothing will still stand once these leave the queue: the main row IS
      // the accepted state, and holding truth for a clean row would break the
      // sparsity that makes a before-image mean divergence.
      await before.drop(identity);
      return;
    }
    final ModelRecord<I>? advanced;
    try {
      advanced = MutationReducer<I>(
        schema,
      ).reduce(await before.read(identity), settled);
    } on ProjectionIntegrityException {
      // The settled prefix no longer replays against the held truth — a
      // `write` FINAL delete purged it while these edits were pending
      // (an accepted CREATE over purged truth replays fine and stands a new
      // row up; an accepted UPDATE has nothing beneath it and lands here).
      // Truth stays nonexistence, the same fallback a rebuild takes.
      await before.drop(identity);
      return;
    }
    if (advanced == null) {
      // The settled prefix ends in a delete: truth is now nonexistence.
      await before.drop(identity);
    } else {
      await before.updateTruth(identity, advanced.fields);
    }
  }

  I _identity(ModelId id) {
    if (id is! I) {
      throw LocalStorageException(
        '${schema.name} identity has an unexpected generated type',
      );
    }
    return id;
  }
}

/// Every Model the client stores, and the only place the graph between them
/// exists at runtime.
///
/// Entries are built one Model at a time, so an entry on its own cannot see
/// the ancestors whose deletes it inherits. Assembling the registry is what
/// closes that: each entry is handed the registry it now belongs to.
final class ModelRegistry {
  ModelRegistry(Iterable<ModelRegistryEntry> entries, {this.mutationInputs})
    : _entries = _build(entries) {
    for (final entry in _entries.values) {
      if (entry is TypedModelRegistryEntry) entry._registry = this;
    }
  }

  final Map<String, ModelRegistryEntry> _entries;
  final MutationInputContracts? mutationInputs;

  ModelSchema<ModelId> inputSchema(
    StoredMutationOperation operation, {
    StoredMutation? mutation,
  }) {
    final inputs = mutationInputs;
    if (inputs == null) {
      final entry = this[operation.model];
      if (entry == null) throw StateError('unknown Model ${operation.model}');
      return entry.schema;
    }
    final name = mutation?.name ?? operation.mutationName;
    if (name == null) throw StateError('queued operation has no mutation name');
    return inputs.schema(
      name,
      mutation?.effectiveVersion ?? operation.mutationVersion ?? 1,
      operation.model,
    );
  }

  ModelRegistryEntry? operator [](String name) => _entries[name];

  /// Every Model the client stores, in declaration order.
  Iterable<ModelRegistryEntry> get entries => _entries.values;

  static Map<String, ModelRegistryEntry> _build(
    Iterable<ModelRegistryEntry> entries,
  ) {
    final result = <String, ModelRegistryEntry>{};
    for (final entry in entries) {
      if (result.containsKey(entry.schema.name)) {
        throw StateError('duplicate Model "${entry.schema.name}"');
      }
      result[entry.schema.name] = entry;
    }
    return Map.unmodifiable(result);
  }
}
