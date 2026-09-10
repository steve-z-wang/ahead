import '../mutation/model_mutation_writer.dart';
import '../mutation/mutation_store.dart';
import '../schema/model_id.dart';
import '../schema/model_registry.dart';
import '../storage/before_image_store.dart';
import '../storage/canonical_model_reader.dart';
import '../storage/canonical_store.dart';
import '../storage/database_scope.dart';
import '../storage/direct_model_writer.dart';
import '../storage/model_database_descriptor.dart';
import 'model_runtime_stores.dart';

/// One Model's storage, reads and both write lanes (CAP-488).
///
/// Every Model has exactly this: a main table holding what the user sees, a
/// before-image twin holding what it last diverged from, a queue store, a
/// reader, and two writers. Which lane a write takes is the call site's choice
/// — `write` for a device-only edit that is final at commit, a named act for
/// one the Backend answers for — never the Model's, because a Model describes
/// a row shape and says nothing about replication.
final class ModelRuntime<I extends ModelId> {
  ModelRuntime({
    required LocalDatabaseScope database,
    required ModelDatabaseDescriptor<I> descriptor,
    required ModelDatabaseDescriptor<I> beforeDescriptor,
    required ModelRegistry registry,
  }) : _stores = ModelRuntimeStores(
         database: database,
         descriptor: descriptor,
         beforeDescriptor: beforeDescriptor,
       ) {
    direct = _stores.directWriter(registry, descriptor.schema.name);
    queued = _stores.queuedWriter(registry, descriptor.schema.name);
  }

  final ModelRuntimeStores<I> _stores;

  CanonicalStore<I> get canonical => _stores.canonical;
  BeforeImageStore<I> get before => _stores.before;
  MutationStore<I> get mutations => _stores.mutations;
  CanonicalModelReader<I> get reader => _stores.reader;

  /// The direct lane: final at commit, no queue, no wire.
  late final DirectModelWriter<I> direct;

  /// The queued lane: provisional until the act it belongs to settles.
  late final ModelMutationWriter<I> queued;
}
