import 'package:local_sync_database/local_sync_database.dart';

import '../schema/model_id.dart';
import '../schema/model_registry.dart';
import '../storage/canonical_store.dart';
import '../storage/database_scope.dart';
import 'local_sync_mutation_scope.dart';
import 'model_mutation_writer.dart';
import 'model_operation.dart';
import 'mutation_dependency_writer.dart';
import 'slot_binding_verifier.dart';
import 'transaction_context_factory.dart';

abstract interface class MutationTarget {
  Future<void> create(
    ModelId id,
    Map<String, Object?> values, {
    required int mutationOrdinal,
    required String slotName,
  });

  Future<void> update(
    ModelId id,
    Map<String, Object?> patch, {
    required int mutationOrdinal,
    required String slotName,
  });

  Future<void> delete(
    ModelId id, {
    required int mutationOrdinal,
    required String slotName,
  });
}

final class TypedMutationTarget<I extends ModelId> implements MutationTarget {
  const TypedMutationTarget({required this.model, required this.writer});

  final String model;
  final ModelMutationWriter<I> writer;

  @override
  Future<void> create(
    ModelId id,
    Map<String, Object?> values, {
    required int mutationOrdinal,
    required String slotName,
  }) => writer.create(
    _narrow(id),
    values,
    mutationOrdinal: mutationOrdinal,
    wire: true,
    slotName: slotName,
  );

  @override
  Future<void> update(
    ModelId id,
    Map<String, Object?> patch, {
    required int mutationOrdinal,
    required String slotName,
  }) => writer.update(
    _narrow(id),
    patch,
    mutationOrdinal: mutationOrdinal,
    wire: true,
    slotName: slotName,
  );

  @override
  Future<void> delete(
    ModelId id, {
    required int mutationOrdinal,
    required String slotName,
  }) => writer.delete(
    _narrow(id),
    mutationOrdinal: mutationOrdinal,
    wire: true,
    slotName: slotName,
  );

  I _narrow(ModelId id) {
    if (id is! I) {
      throw LocalStorageException(
        '$model identity has an unexpected generated type',
      );
    }
    return id;
  }
}

MapEntry<String, MutationTarget> mutationTarget<I extends ModelId>(
  String model,
  ModelMutationWriter<I> writer,
) => MapEntry(model, TypedMutationTarget<I>(model: model, writer: writer));

final class _NoOperationPerformed implements Exception {
  const _NoOperationPerformed();
}

/// Runs one named Mutation as a savepoint inside its caller's outer database
/// transaction.
final class MutationScopeExecutor<M> {
  const MutationScopeExecutor({
    required this.database,
    required this.registry,
    required this.targets,
    required this.context,
    required this.scope,
  });

  final LocalDatabaseScope database;
  final ModelRegistry registry;
  final Map<String, MutationTarget> targets;
  final TransactionFateContext context;
  final LocalSyncMutationScope<M> scope;

  Future<void> run<R extends Object>({
    required String name,
    required Future<R?> Function(LocalSyncMutationScope<M> mutation) build,
    required MutationRecord Function(R result) record,
  }) => context.runMutation(() async {
    try {
      await database.savepoint(() async {
        final ordinal = await _appendRecord(name);
        await context.bindMutation(ordinal, () async {
          final result = await build(scope);
          if (result == null) throw const _NoOperationPerformed();
          final built = record(result);
          if (built.name != name ||
              built.version < 1 ||
              built.version > 9007199254740991) {
            throw ArgumentError(
              'mutation name/version does not match its declaration',
            );
          }
          await database.current.execute(
            DatabaseStatement(
              sql: 'UPDATE pending_mutations SET version = ? WHERE ordinal = ?',
              variables: [built.version, ordinal],
            ),
          );
          if (built.operations.isEmpty) {
            throw ArgumentError('mutation "$name" returned no operations');
          }
          for (final operation in built.operations) {
            if (targets[operation.model] == null) {
              throw StateError(
                'mutation "$name" names unknown Model "${operation.model}"',
              );
            }
          }
          _verifyPatchProjections(name, built);
          await SlotBindingVerifier(registry: registry).verify(built);
          final applied = <AppliedMutationOperation>[];
          for (final slot in built.slotOperations) {
            final operation = slot.operation;
            final target = targets[operation.model]!;
            final entry = registry[operation.model]!;
            final before = await entry.readMain(operation.id);
            switch (operation) {
              case ModelCreateOperation():
                await target.create(
                  operation.id,
                  operation.values,
                  mutationOrdinal: ordinal,
                  slotName: slot.slotName,
                );
              case ModelUpdateOperation():
                await target.update(
                  operation.id,
                  operation.patch,
                  mutationOrdinal: ordinal,
                  slotName: slot.slotName,
                );
              case ModelDeleteOperation():
                await target.delete(
                  operation.id,
                  mutationOrdinal: ordinal,
                  slotName: slot.slotName,
                );
            }
            applied.add(
              AppliedMutationOperation(
                operation: operation,
                before: before,
                after: await entry.readMain(operation.id),
              ),
            );
          }
          await MutationDependencyWriter(
            database: database,
            registry: registry,
          ).freeze(
            mutationOrdinal: ordinal,
            record: built,
            appliedOperations: applied,
          );
        });
      });
    } on _NoOperationPerformed {
      return;
    }
  });

  void _verifyPatchProjections(String mutationName, MutationRecord record) {
    for (final slot in record.slotOperations) {
      final operation = slot.operation;
      if (operation is! ModelUpdateOperation) {
        if (slot.allowedPatchFields != null) {
          throw StateError(
            'mutation "$mutationName" slot "${slot.slotName}" attaches an '
            'update patch projection to a non-update operation',
          );
        }
        continue;
      }
      final allowed = slot.allowedPatchFields;
      if (allowed == null || allowed.isEmpty) {
        throw StateError(
          'mutation "$mutationName" update slot "${slot.slotName}" has no '
          'generated patch projection',
        );
      }
      if (operation.patch.isEmpty) {
        throw ArgumentError(
          'mutation "$mutationName" slot "${slot.slotName}" update requires '
          'at least one field',
        );
      }
      for (final field in operation.patch.keys) {
        if (!allowed.contains(field)) {
          throw ArgumentError(
            'mutation "$mutationName" slot "${slot.slotName}" cannot patch '
            'field "$field"',
          );
        }
      }
    }
  }

  Future<int> _appendRecord(String name) async {
    final result = await database.current.execute(
      DatabaseStatement(
        sql: 'INSERT INTO pending_mutations (name) VALUES (?)',
        variables: [name],
      ),
    );
    final ordinal = result.lastInsertRowId;
    if (result.affectedRows != 1 || ordinal == null) {
      throw StateError('could not queue mutation "$name"');
    }
    return ordinal;
  }
}
