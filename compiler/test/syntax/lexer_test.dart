import 'package:local_sync_compiler/src/syntax/lexer.dart';
import 'package:local_sync_compiler/src/syntax/source.dart';
import 'package:local_sync_compiler/src/syntax/token.dart';
import 'package:test/test.dart';

void main() {
  test('tokenizes the complete minimal definition language', () {
    const source = ModelSource(
      path: 'models/star.model',
      contents: '''// composite identity\r
model Star {
  user User? @sendWhenReady
  moment Moment
  @@id(user, moment)
  @@shape(version: 1)
}
''',
    );

    final tokens = lex(source);

    expect(tokens.map((token) => token.kind), [
      TokenKind.identifier,
      TokenKind.identifier,
      TokenKind.leftBrace,
      TokenKind.identifier,
      TokenKind.identifier,
      TokenKind.question,
      TokenKind.at,
      TokenKind.identifier,
      TokenKind.identifier,
      TokenKind.identifier,
      TokenKind.doubleAt,
      TokenKind.identifier,
      TokenKind.leftParen,
      TokenKind.identifier,
      TokenKind.comma,
      TokenKind.identifier,
      TokenKind.rightParen,
      TokenKind.doubleAt,
      TokenKind.identifier,
      TokenKind.leftParen,
      TokenKind.identifier,
      TokenKind.colon,
      TokenKind.integer,
      TokenKind.rightParen,
      TokenKind.rightBrace,
      TokenKind.eof,
    ]);
    expect(
      tokens
          .where((token) => token.kind == TokenKind.identifier)
          .map((token) => token.lexeme),
      [
        'model',
        'Star',
        'user',
        'User',
        'sendWhenReady',
        'moment',
        'Moment',
        'id',
        'user',
        'moment',
        'shape',
        'version',
      ],
    );
    expect(tokens.first.span.start.line, 2);
    expect(tokens.first.span.start.column, 1);
    expect(tokens.last.span.start.line, 8);
    expect(tokens.last.span.start.column, 1);
  });

  test('tokenizes Prisma-shaped relation argument punctuation', () {
    const source = ModelSource(
      path: 'models/star.model',
      contents: '@reference(via: [userId])',
    );

    expect(lex(source).map((token) => token.kind), [
      TokenKind.at,
      TokenKind.identifier,
      TokenKind.leftParen,
      TokenKind.identifier,
      TokenKind.colon,
      TokenKind.leftBracket,
      TokenKind.identifier,
      TokenKind.rightBracket,
      TokenKind.rightParen,
      TokenKind.eof,
    ]);
  });

  test('tokenizes update patch projection punctuation', () {
    const source = ModelSource(
      path: 'models/moment.model',
      contents: 'moment Moment.update<text, placedAt>',
    );

    expect(lex(source).map((token) => token.kind), [
      TokenKind.identifier,
      TokenKind.identifier,
      TokenKind.dot,
      TokenKind.identifier,
      TokenKind.leftAngle,
      TokenKind.identifier,
      TokenKind.comma,
      TokenKind.identifier,
      TokenKind.rightAngle,
      TokenKind.eof,
    ]);
  });

  test('invalid characters report an exact source location', () {
    const source = ModelSource(
      path: 'models/space.model',
      contents: 'model Space {\n  id UUID #bad\n}',
    );

    expect(
      () => lex(source),
      throwsA(
        isA<DefinitionException>()
            .having(
              (error) => error.location.path,
              'path',
              'models/space.model',
            )
            .having((error) => error.location.line, 'line', 2)
            .having((error) => error.location.column, 'column', 11)
            .having(
              (error) => error.message,
              'message',
              'unexpected character "#"',
            ),
      ),
    );
  });
}
