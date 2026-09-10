import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';

void main() {
  test('a row remains claimed until its last scope releases it', () async {
    final fixture = await TestLocalDatabase.open();
    addTearDown(fixture.close);
    final ledger = ScopeRowLedger(fixture.scope);
    const entry = _Entry();
    final id = _Id(UUID.withValidation(_uuid));

    await ledger.claim('Book:A', entry, id);
    await ledger.claim('Book:B', entry, id);
    await ledger.release('Book:A', entry, id);

    expect(await ledger.hasClaims(entry, id), isTrue);

    await ledger.release('Book:B', entry, id);

    expect(await ledger.hasClaims(entry, id), isFalse);
  });

  test(
    'claim and release are convergent and Model names isolate identities',
    () async {
      final fixture = await TestLocalDatabase.open();
      addTearDown(fixture.close);
      final ledger = ScopeRowLedger(fixture.scope);
      const first = _Entry();
      const second = _OtherEntry();
      final id = _Id(UUID.withValidation(_uuid));

      await ledger.claim('Book:A', first, id);
      await ledger.claim('Book:A', first, id);
      await ledger.claim('Book:A', second, id);
      await ledger.release('Book:A', first, id);
      await ledger.release('Book:A', first, id);

      expect(await ledger.hasClaims(first, id), isFalse);
      expect(await ledger.hasClaims(second, id), isTrue);

      await ledger.releaseAll(second, id);
      expect(await ledger.hasClaims(second, id), isFalse);
    },
  );
}

const _uuid = '550e8400-e29b-41d4-a716-000000000001';

final class _Id extends ModelId {
  const _Id(this.id);

  final UUID id;

  @override
  Map<String, Object> get components => {'id': id};
}

const _fields = [
  ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
];

final class _Entry implements ModelRegistryEntry {
  const _Entry();

  @override
  ModelSchema<_Id> get schema => _schema;

  static final _schema = ModelSchema<_Id>(
    name: 'First',
    identity: const ['id'],
    fields: _fields,
    uniqueConstraints: const [],
    relations: const [],
    createId: (parts) => _Id(parts['id']! as UUID),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _OtherEntry implements ModelRegistryEntry {
  const _OtherEntry();

  @override
  ModelSchema<_Id> get schema => _schema;

  static final _schema = ModelSchema<_Id>(
    name: 'Second',
    identity: const ['id'],
    fields: _fields,
    uniqueConstraints: const [],
    relations: const [],
    createId: (parts) => _Id(parts['id']! as UUID),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
