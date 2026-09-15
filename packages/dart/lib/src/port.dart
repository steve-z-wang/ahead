/// Reads available on both a [Client] and a [Transaction].
abstract interface class ReadPort {
  Future<Map<String, dynamic>?> read(
    String model,
    Map<String, dynamic> identity,
  );
  Future<List<Map<String, dynamic>>> querySpec(
    String model,
    Map<String, dynamic> query,
  );
  Future<Map<String, dynamic>?> related(
    String model,
    Map<String, dynamic> identity,
    String relation,
  );
  Future<List<Map<String, dynamic>>> referencing(
    String model,
    Map<String, dynamic> identity,
    String source,
    String relation,
  );
}

/// Writes available inside a [Transaction].
abstract interface class WritePort implements ReadPort {
  Future<void> direct(Map<String, dynamic> operation);
  Future<int> mutate(Map<String, dynamic> mutation);
}
