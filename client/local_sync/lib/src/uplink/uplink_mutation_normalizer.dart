import 'dart:convert';

import '../mutation/model_mutation.dart';
import '../mutation/mutation_store.dart';
import '../schema/model_id.dart';
import '../schema/model_schema.dart';
import '../schema/model_registry.dart';
import '../storage/local_value_codec.dart';
import 'uplink_protocol.dart';

const maxSafeUplinkInteger = 9007199254740991;

/// One durable mutation row, validated and reduced to canonical wire values.
/// Both wire formats start here, so a rule about what a mutation may say lives
/// in exactly one place.
final class NormalizedUplinkMutation {
  NormalizedUplinkMutation({
    required this.position,
    required this.entry,
    required this.operation,
    required Map<String, Object?> identity,
    required Map<String, Object?> values,
    required this.mutationOrdinal,
  }) : identity = Map.unmodifiable(identity),
       values = Map.unmodifiable(values);

  final int position;
  final ModelRegistryEntry entry;
  final MutationOperation operation;

  /// The named act this operation belongs to.
  final int mutationOrdinal;
  final Map<String, Object?> identity;
  final Map<String, Object?> values;

  String get model => entry.schema.name;
}

/// Validates the Uplink envelope and every mutation in it.
final class UplinkMutationNormalizer {
  const UplinkMutationNormalizer({
    required this.registry,
    this.codec = const LocalValueCodec(),
  });

  final ModelRegistry registry;
  final LocalValueCodec codec;

  List<NormalizedUplinkMutation> normalizeBatch({
    required String clientId,
    required int batchSequence,
    required List<StoredMutationOperation> mutations,
    Map<int, StoredMutation> records = const {},
  }) {
    requireUuid(clientId, 'clientId');
    requirePositiveSafeInteger(batchSequence, 'batchSequence');
    // The ceiling is in MUTATIONS: a named act is one of them however many
    // operations spell it, so a 42-operation page needs no reinterpretation
    // of the limit (CAP-439).
    final acts = mutations.map((row) => row.mutationOrdinal).toSet();
    if (mutations.isEmpty || acts.length > 20) {
      throw const UplinkDataException(
        'mutations must contain 1 through 20 acts',
      );
    }
    final seen = <MutationPosition>{};
    final normalized = <NormalizedUplinkMutation>[];
    for (final row in mutations) {
      requirePositiveSafeInteger(row.mutationOrdinal, 'mutationId');
      if (row.position < 0) {
        throw const UplinkDataException(
          'operation position must be a non-negative integer',
        );
      }
      if (!seen.add(row.order)) {
        throw UplinkDataException('duplicate operation position ${row.order}');
      }
      if (records[row.mutationOrdinal] == null) {
        throw UplinkDataException(
          'missing mutation record ${row.mutationOrdinal}',
        );
      }
      final record = records[row.mutationOrdinal]!;
      requirePositiveSafeInteger(record.effectiveVersion, 'mutation version');
      normalized.add(normalize(row, mutation: record));
    }
    return normalized;
  }

  NormalizedUplinkMutation normalize(
    StoredMutationOperation row, {
    StoredMutation? mutation,
  }) {
    final entry = registry[row.model];
    if (entry == null) {
      throw UplinkDataException('unknown Model "${row.model}"');
    }
    if (!row.isUplink) {
      // A companion rides the queue for the act's fate but never the wire —
      // the codec filtered it out before this point, so meeting one here is a
      // defect, not a state.
      throw UplinkDataException('companion operation on "${row.model}"');
    }
    final schema = registry.inputSchema(row, mutation: mutation);
    final operation = MutationOperation.values
        .where((value) => value.name == row.operation)
        .firstOrNull;
    if (operation == null) {
      throw UplinkDataException(
        'unknown mutation operation "${row.operation}"',
      );
    }
    final identity = _normalizedIdentity(schema, row.identityJson);
    final values = _normalizedValues(schema, row.valuesJson);
    final identityFields = schema.identity.toSet();
    final valueFields = schema.fields
        .where((field) => !identityFields.contains(field.name))
        .toList(growable: false);

    switch (operation) {
      case MutationOperation.create:
        if (valueFields.any(
          (field) => !field.nullable && !values.containsKey(field.name),
        )) {
          throw UplinkDataException(
            '${row.model} create data is missing a required field',
          );
        }
      case MutationOperation.update:
        if (values.isEmpty) {
          throw UplinkDataException('${row.model} update data is empty');
        }
      case MutationOperation.delete:
        if (values.isNotEmpty) {
          throw UplinkDataException('${row.model} delete must not have data');
        }
    }

    return NormalizedUplinkMutation(
      position: row.position,
      entry: entry,
      operation: operation,
      identity: identity,
      values: values,
      mutationOrdinal: row.mutationOrdinal,
    );
  }

  Map<String, Object?> _normalizedIdentity(
    ModelSchema<ModelId> schema,
    String source,
  ) {
    try {
      final id = codec.decodeIdentity(schema, source);
      return decodeWireObject(codec.encodeIdentity(schema, id));
    } on LocalDataException catch (error) {
      throw UplinkDataException(error.message, source);
    }
  }

  Map<String, Object?> _normalizedValues(
    ModelSchema<ModelId> schema,
    String source,
  ) {
    try {
      final values = codec.decodeValues(schema, source);
      return decodeWireObject(codec.encodeValues(schema, values));
    } on LocalDataException catch (error) {
      throw UplinkDataException(error.message, source);
    }
  }
}

Map<String, Object?> decodeWireObject(String source) =>
    (jsonDecode(source) as Map).cast<String, Object?>();

void requireUuid(String value, String path) {
  try {
    UUID.withValidation(value);
  } on FormatException catch (error) {
    throw UplinkDataException('$path is invalid: ${error.message}');
  }
}

void requirePositiveSafeInteger(int value, String path) {
  if (value <= 0 || value > maxSafeUplinkInteger) {
    throw UplinkDataException('$path must be a positive safe integer');
  }
}
