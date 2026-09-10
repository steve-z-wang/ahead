List<String> normalizeScopes(Iterable<String> scopes) {
  final normalized = scopes.toSet().toList()..sort();
  if (normalized.isEmpty) {
    throw const FormatException('active Scope set must be nonempty');
  }
  return List.unmodifiable(normalized);
}
