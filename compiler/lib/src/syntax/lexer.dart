import 'source.dart';
import 'token.dart';

List<Token> lex(ModelSource source) => _Lexer(source).scan();

final class _Lexer {
  _Lexer(this.source);

  final ModelSource source;
  final List<Token> _tokens = [];
  int _offset = 0;
  int _line = 1;
  int _column = 1;

  List<Token> scan() {
    while (!_isAtEnd) {
      final character = _current;
      if (_isIdentifierStart(character)) {
        _identifier();
      } else if (_isAsciiDigit(character)) {
        _integer();
      } else if (character == ' ' || character == '\t' || character == '\r') {
        _advance();
      } else if (character == '\n') {
        _newline();
      } else if (character == '/' && _next == '/') {
        _comment();
      } else if (character == '{') {
        _punctuation(TokenKind.leftBrace);
      } else if (character == '}') {
        _punctuation(TokenKind.rightBrace);
      } else if (character == '(') {
        _punctuation(TokenKind.leftParen);
      } else if (character == ')') {
        _punctuation(TokenKind.rightParen);
      } else if (character == '?') {
        _punctuation(TokenKind.question);
      } else if (character == ',') {
        _punctuation(TokenKind.comma);
      } else if (character == ':') {
        _punctuation(TokenKind.colon);
      } else if (character == '.') {
        _punctuation(TokenKind.dot);
      } else if (character == '<') {
        _punctuation(TokenKind.leftAngle);
      } else if (character == '>') {
        _punctuation(TokenKind.rightAngle);
      } else if (character == '[') {
        _punctuation(TokenKind.leftBracket);
      } else if (character == ']') {
        _punctuation(TokenKind.rightBracket);
      } else if (character == '@') {
        _at();
      } else if (character == '"') {
        _string();
      } else {
        throw DefinitionException(
          location: _location,
          message: 'unexpected character "$character"',
        );
      }
    }

    final location = _location;
    _tokens.add(
      Token(
        kind: TokenKind.eof,
        lexeme: '',
        span: SourceSpan(start: location, end: location),
      ),
    );
    return List.unmodifiable(_tokens);
  }

  void _identifier() {
    final start = _location;
    final startOffset = _offset;
    while (!_isAtEnd && _isIdentifierPart(_current)) {
      _advance();
    }
    _tokens.add(
      Token(
        kind: TokenKind.identifier,
        lexeme: source.contents.substring(startOffset, _offset),
        span: SourceSpan(start: start, end: _location),
      ),
    );
  }

  void _integer() {
    final start = _location;
    final startOffset = _offset;
    while (!_isAtEnd && _isAsciiDigit(_current)) {
      _advance();
    }
    _tokens.add(
      Token(
        kind: TokenKind.integer,
        lexeme: source.contents.substring(startOffset, _offset),
        span: SourceSpan(start: start, end: _location),
      ),
    );
  }

  /// A double-quoted relation name. There are no escapes and no multi-line
  /// strings: the only thing the language spells this way is a name, and a name
  /// that needs escaping is a name nobody should be reading twice.
  void _string() {
    final start = _location;
    final startOffset = _offset;
    _advance();
    while (!_isAtEnd && _current != '"') {
      if (_current == '\n') {
        throw DefinitionException(
          location: _location,
          message: 'unterminated string',
        );
      }
      _advance();
    }
    if (_isAtEnd) {
      throw DefinitionException(
        location: _location,
        message: 'unterminated string',
      );
    }
    _advance();
    _tokens.add(
      Token(
        kind: TokenKind.string,
        lexeme: source.contents.substring(startOffset, _offset),
        span: SourceSpan(start: start, end: _location),
      ),
    );
  }

  void _comment() {
    while (!_isAtEnd && _current != '\n') {
      _advance();
    }
  }

  void _at() {
    final start = _location;
    final startOffset = _offset;
    _advance();
    final kind = _currentOrNull == '@' ? TokenKind.doubleAt : TokenKind.at;
    if (kind == TokenKind.doubleAt) _advance();
    _tokens.add(
      Token(
        kind: kind,
        lexeme: source.contents.substring(startOffset, _offset),
        span: SourceSpan(start: start, end: _location),
      ),
    );
  }

  void _punctuation(TokenKind kind) {
    final start = _location;
    final lexeme = _current;
    _advance();
    _tokens.add(
      Token(
        kind: kind,
        lexeme: lexeme,
        span: SourceSpan(start: start, end: _location),
      ),
    );
  }

  void _advance() {
    _offset += 1;
    _column += 1;
  }

  void _newline() {
    _offset += 1;
    _line += 1;
    _column = 1;
  }

  bool _isIdentifierStart(String character) =>
      _isAsciiLetter(character) || character == '_';

  bool _isIdentifierPart(String character) =>
      _isIdentifierStart(character) || _isAsciiDigit(character);

  bool _isAsciiLetter(String character) {
    final code = character.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }

  bool _isAsciiDigit(String character) {
    final code = character.codeUnitAt(0);
    return code >= 48 && code <= 57;
  }

  bool get _isAtEnd => _offset >= source.contents.length;
  String get _current => source.contents[_offset];
  String? get _currentOrNull => _isAtEnd ? null : _current;
  String? get _next => _offset + 1 >= source.contents.length
      ? null
      : source.contents[_offset + 1];
  SourceLocation get _location => SourceLocation(
    path: source.path,
    offset: _offset,
    line: _line,
    column: _column,
  );
}
