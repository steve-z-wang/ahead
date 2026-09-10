final class UplinkDataException implements FormatException {
  const UplinkDataException(this.message, [this.source, this.offset]);

  @override
  final String message;
  @override
  final Object? source;
  @override
  final int? offset;

  @override
  String toString() => 'UplinkDataException: $message';
}

final class UplinkMutationRejection {
  const UplinkMutationRejection({required this.mutationId, required this.code});

  final int mutationId;
  final String code;
}

final class UplinkCheckpoint {
  const UplinkCheckpoint({required this.scope, required this.syncId});

  final String scope;
  final int syncId;
}

final class UplinkResponse {
  UplinkResponse({
    required List<UplinkCheckpoint> requiredCheckpoints,
    required this.legacyPrincipalCheckpoint,
    required List<UplinkMutationRejection> rejections,
  }) : requiredCheckpoints = List.unmodifiable(requiredCheckpoints),
       rejections = List.unmodifiable(rejections);

  final List<UplinkCheckpoint> requiredCheckpoints;
  final UplinkCheckpoint legacyPrincipalCheckpoint;
  final List<UplinkMutationRejection> rejections;
}

final class BatchExecutionResult {
  BatchExecutionResult({
    required this.batchSequence,
    required List<UplinkCheckpoint> requiredCheckpoints,
    required this.legacyPrincipalCheckpoint,
    required List<UplinkMutationRejection> rejections,
  }) : requiredCheckpoints = List.unmodifiable(requiredCheckpoints),
       rejections = List.unmodifiable(rejections);

  final int batchSequence;
  final List<UplinkCheckpoint> requiredCheckpoints;
  final UplinkCheckpoint legacyPrincipalCheckpoint;
  final List<UplinkMutationRejection> rejections;
}
