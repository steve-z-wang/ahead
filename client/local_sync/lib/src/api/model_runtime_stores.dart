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
import 'cascade_deleter.dart';

/// The stores every Model runtime stands on, assembled once.
///
/// One substrate for every Model — a main table, a before-image twin, a queue
/// store, a reader — because replication is a write-path choice and not a
/// property of the Model (CAP-488).
final class ModelRuntimeStores<I extends ModelId> {
  ModelRuntimeStores({
    required LocalDatabaseScope database,
    required ModelDatabaseDescriptor<I> descriptor,
    required ModelDatabaseDescriptor<I> beforeDescriptor,
  }) : canonical = SqlCanonicalStore(
         database: database,
         descriptor: descriptor,
       ),
       before = BeforeImageStore(
         database: database,
         main: descriptor,
         before: beforeDescriptor,
       ),
       mutations = SqlMutationStore(
         database: database,
         schema: descriptor.schema,
       ) {
    reader = CanonicalModelReader(
      canonical: canonical,
      database: database,
      descriptor: descriptor,
    );
  }

  final SqlCanonicalStore<I> canonical;
  final BeforeImageStore<I> before;
  final MutationStore<I> mutations;
  late final CanonicalModelReader<I> reader;

  /// The direct operation path over these stores — used outside a named act.
  ///
  /// It walks the same schema cascade the queued path does, because the Model
  /// decides what a delete means and the lane decides only whether it is
  /// synchronized (CAP-488) — but finally, since nothing local will undo it.
  DirectModelWriter<I> directWriter(ModelRegistry registry, String model) {
    final cascade = CascadeDeleter(registry);
    return DirectModelWriter(
      canonical,
      before: before,
      mutations: mutations,
      cascadeDescendants: (id) => cascade.deleteDescendantsFinally(model, id),
    );
  }

  /// The queued write path over these stores — what a named act's returned
  /// operations and its device-only companions both take.
  ModelMutationWriter<I> queuedWriter(ModelRegistry registry, String model) {
    final cascade = CascadeDeleter(registry);
    return ModelMutationWriter(
      mutations,
      before: before,
      main: canonical,
      cascadeDescendants: (id) => cascade.deleteDescendants(model, id),
    );
  }
}
