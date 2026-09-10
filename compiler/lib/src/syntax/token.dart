import 'source.dart';

enum TokenKind {
  identifier,
  integer,
  string,
  leftBrace,
  rightBrace,
  leftParen,
  rightParen,
  question,
  at,
  doubleAt,
  comma,
  colon,
  dot,
  leftAngle,
  rightAngle,
  leftBracket,
  rightBracket,
  eof,
}

final class Token {
  const Token({required this.kind, required this.lexeme, required this.span});

  final TokenKind kind;
  final String lexeme;
  final SourceSpan span;
}
