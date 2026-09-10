import 'dart:typed_data';

import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

void main() {
  group('DatabaseQuery', () {
    test('is an immutable SQLite query description', () {
      final bytes = Uint8List.fromList([1, 2]);
      final variables = <Object?>[1, 2.5, 'three', null, bytes];

      final query = DatabaseQuery(
        sql: 'SELECT * FROM spaces WHERE id = ?',
        variables: variables,
      );

      variables[0] = 9;
      bytes[0] = 9;

      expect(query.variables.take(4), [1, 2.5, 'three', null]);
      expect(query.variables[4], Uint8List.fromList([1, 2]));
      expect(() => query.variables.add('four'), throwsUnsupportedError);
    });

    test('rejects values outside the SQLite boundary', () {
      for (final unsupported in <Object>[
        true,
        DateTime.utc(2026),
        double.nan,
        double.infinity,
        BigInt.one,
      ]) {
        expect(
          () => DatabaseQuery(sql: 'SELECT ?', variables: [unsupported]),
          throwsA(
            isA<DatabaseException>().having(
              (error) => error.kind,
              'kind',
              DatabaseErrorKind.invalidArgument,
            ),
          ),
        );
      }
    });
  });

  group('DatabaseStatement', () {
    test('is an immutable SQLite statement description', () {
      final variables = <Object?>['Family', 'space-id'];
      final statement = DatabaseStatement(
        sql: 'UPDATE spaces SET name = ? WHERE id = ?',
        variables: variables,
      );

      variables[0] = 'Changed';

      expect(statement.variables, ['Family', 'space-id']);
      expect(() => statement.variables.add('extra'), throwsUnsupportedError);
    });
  });

  group('DatabaseQueryResult', () {
    test('materializes immutable rows with named and indexed access', () {
      final columns = <String>['id', 'payload'];
      final payload = Uint8List.fromList([4, 5]);
      final values = <List<Object?>>[
        <Object?>[7, payload],
      ];

      final result = DatabaseQueryResult(columns: columns, rows: values);

      columns[0] = 'changed';
      values.single[0] = 8;
      payload[0] = 9;

      expect(result.columns, ['id', 'payload']);
      expect(result.singleOrNull?['id'], 7);
      expect(result[0].valueAt(1), Uint8List.fromList([4, 5]));
      expect(() => result.columns.add('extra'), throwsUnsupportedError);
    });

    test('rejects duplicate columns and row width mismatches', () {
      for (final create in <DatabaseQueryResult Function()>[
        () => DatabaseQueryResult(columns: const ['id', 'id'], rows: const []),
        () => DatabaseQueryResult(
          columns: const ['id'],
          rows: const [
            <Object?>[1, 2],
          ],
        ),
      ]) {
        expect(
          create,
          throwsA(
            isA<DatabaseException>().having(
              (error) => error.kind,
              'kind',
              DatabaseErrorKind.invalidArgument,
            ),
          ),
        );
      }
    });

    test('singleOrNull accepts zero or one row only', () {
      expect(
        DatabaseQueryResult(columns: const ['id'], rows: const []).singleOrNull,
        isNull,
      );
      expect(
        DatabaseQueryResult(
          columns: const ['id'],
          rows: const [
            <Object?>[1],
          ],
        ).singleOrNull?['id'],
        1,
      );
      expect(
        () => DatabaseQueryResult(
          columns: const ['id'],
          rows: const [
            <Object?>[1],
            <Object?>[2],
          ],
        ).singleOrNull,
        throwsA(
          isA<DatabaseException>().having(
            (error) => error.kind,
            'kind',
            DatabaseErrorKind.invalidArgument,
          ),
        ),
      );
    });
  });
}
