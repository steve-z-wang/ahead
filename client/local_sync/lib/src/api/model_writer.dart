import '../schema/model_id.dart';

/// The three ways a row can move, as one interface.
///
/// Which fate a writer uses is selected from the active transaction context:
/// outer operations are direct and final at commit, while a named act callback
/// binds companion operations to that act's ordinal (CAP-488/616). A call site
/// states what it wants by which transaction scope it is in
/// holding, never by a flag it has to remember to pass.
abstract interface class ModelWriter<I extends ModelId> {
  Future<void> create(I id, Map<String, Object?> values);

  Future<void> update(I id, Map<String, Object?> patch);

  Future<void> delete(I id);
}
