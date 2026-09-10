import 'model_schema.dart';
import 'model_registry.dart';

/// One declared reference, seen from the Model it points at.
final class IncomingRelation {
  const IncomingRelation({required this.source, required this.relation});

  /// The Model that declares the reference — the one holding the stored key.
  final ModelRegistryEntry source;

  /// The declaration itself; [ModelRelationSchema.localFields] is the key on
  /// [source], [ModelRelationSchema.referencedFields] the target's identity.
  final ModelRelationSchema relation;
}

/// The reverse of the emitted model graph.
///
/// A reference names its target, so nothing in the generated schemas can answer
/// "what points at this Model?". That question is the whole of a cascade walk
/// and of the drop's closure, so the index inverts *every* reference and leaves
/// the filtering to whoever is walking: a cascade follows only the
/// [ModelRelationSchema.deleteOnTarget] edges, and the drop all of them.
///
/// It is a structural index, never a scheduler. An ordinary reference is
/// followed by neither walk, and nothing here decides what the Uplink sends
/// first (CAP-437).
final class RelationIndex {
  RelationIndex._(this._incoming);

  factory RelationIndex.of(ModelRegistry registry) {
    final incoming = <String, List<IncomingRelation>>{};
    for (final entry in registry.entries) {
      for (final relation in entry.schema.relations) {
        (incoming[relation.targetModel] ??= <IncomingRelation>[]).add(
          IncomingRelation(source: entry, relation: relation),
        );
      }
    }
    return RelationIndex._({
      for (final target in incoming.keys)
        target: List.unmodifiable(incoming[target]!),
    });
  }

  final Map<String, List<IncomingRelation>> _incoming;

  /// Every relation that points at [targetModelName], in registry order.
  List<IncomingRelation> incoming(String targetModelName) =>
      _incoming[targetModelName] ?? const [];
}
