import 'package:local_sync/src/downlink/scopes.dart';
import 'package:test/test.dart';

void main() {
  test('sorts and deduplicates arbitrary text', () {
    expect(normalizeScopes(['Book:z', '', 'User:A', 'Book:z']), [
      '',
      'Book:z',
      'User:A',
    ]);
  });

  test('does not interpret or normalize scope text', () {
    expect(normalizeScopes(['user:not-a-uuid', ' User:A ', 'User:a']), [
      ' User:A ',
      'User:a',
      'user:not-a-uuid',
    ]);
  });

  test('requires at least one scope at the public boundary', () {
    expect(() => normalizeScopes(const []), throwsFormatException);
  });
}
