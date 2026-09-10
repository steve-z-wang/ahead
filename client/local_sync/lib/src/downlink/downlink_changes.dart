import '../projection/model_record.dart';
import '../schema/model_id.dart';
import '../schema/model_registry.dart';

typedef CanonicalDownlinkHook =
    Future<void> Function(List<CanonicalDownlinkChange> changes);

/// One canonical application performed by the Downlink applier.
sealed class CanonicalDownlinkChange {
  const CanonicalDownlinkChange({
    required this.entry,
    required this.scope,
    required this.syncId,
  });

  final ModelRegistryEntry entry;
  final String scope;
  final int syncId;
}

final class CanonicalDownlinkUpsert extends CanonicalDownlinkChange {
  const CanonicalDownlinkUpsert({
    required super.entry,
    required super.scope,
    required super.syncId,
    required this.previous,
    required this.row,
  });

  final ModelRecord<ModelId>? previous;
  final ModelRecord<ModelId> row;
}

final class CanonicalDownlinkDelete extends CanonicalDownlinkChange {
  const CanonicalDownlinkDelete({
    required super.entry,
    required super.scope,
    required super.syncId,
    required this.row,
  });

  final ModelRecord<ModelId> row;
}
