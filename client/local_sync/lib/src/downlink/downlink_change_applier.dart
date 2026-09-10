import '../schema/model_id.dart';
import '../schema/model_registry.dart';
import '../schema/relation_index.dart';
import '../storage/cascade_expansion.dart';
import 'downlink_protocol.dart';
import 'downlink_changes.dart';
import 'model_change_decoder.dart';
import 'scope_row_ledger.dart';

/// Applies one decoded Downlink change to canonical truth.
final class DownlinkChangeApplier {
  DownlinkChangeApplier({
    required ModelRegistry registry,
    required ScopeRowLedger claims,
  }) : _claims = claims,
       _expansion = CascadeExpansion(RelationIndex.of(registry));

  final ScopeRowLedger _claims;
  final CascadeExpansion _expansion;

  Future<List<CanonicalDownlinkChange>> apply(
    String scope,
    DecodedModelChange change,
  ) async {
    if (change.operation == DownlinkOperation.upsert) {
      final previous = await change.entry.readCanonicalTruth(change.id);
      await _claims.claim(scope, change.entry, change.id);
      await _replaceTruth(change.entry, change.id, change.values);
      final row = await change.entry.readCanonicalTruth(change.id);
      if (row == null) {
        throw StateError('canonical Upsert did not materialize its row');
      }
      return List.unmodifiable([
        CanonicalDownlinkUpsert(
          entry: change.entry,
          scope: scope,
          syncId: change.syncId,
          previous: previous,
          row: row,
        ),
      ]);
    }

    await _claims.release(scope, change.entry, change.id);
    if (await _claims.hasClaims(change.entry, change.id)) return const [];

    final removed = <CanonicalDownlinkChange>[];
    final parent = await change.entry.readCanonicalTruth(change.id);
    await _replaceTruth(change.entry, change.id, null);
    if (parent != null) {
      removed.add(
        CanonicalDownlinkDelete(
          entry: change.entry,
          scope: scope,
          syncId: change.syncId,
          row: parent,
        ),
      );
    }
    final fallen = await _expansion.descendantsOf(
      change.entry,
      change.id,
      sources: CascadeScanSource.mainAndBefore,
    );
    for (final (entry, id) in fallen) {
      final row = await entry.readCanonicalTruth(id);
      await _claims.releaseAll(entry, id);
      await _replaceTruth(entry, id, null);
      if (row != null) {
        removed.add(
          CanonicalDownlinkDelete(
            entry: entry,
            scope: scope,
            syncId: change.syncId,
            row: row,
          ),
        );
      }
    }
    return List.unmodifiable(removed);
  }

  Future<void> _replaceTruth(
    ModelRegistryEntry entry,
    ModelId id,
    Map<String, Object?>? values,
  ) async {
    await entry.replaceTruth(id, values);
    await entry.rebuild(id);
  }
}
