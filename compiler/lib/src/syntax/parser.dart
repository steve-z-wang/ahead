import 'ast.dart';
import 'lexer.dart';
import 'source.dart';
import 'token.dart';

ModelDocumentSyntax parseModel(ModelSource source) =>
    _Parser(source, lex(source)).parse();

final class _Parser {
  _Parser(this.source, this.tokens);

  final ModelSource source;
  final List<Token> tokens;
  int _current = 0;

  ModelDocumentSyntax parse() {
    final enums = <EnumSyntax>[];
    final models = <ModelSyntax>[];
    final mutations = <MutationSyntax>[];
    final prerequisites = <PrerequisiteSyntax>[];
    while (!_check(TokenKind.eof)) {
      if (_checkIdentifierValue('enum')) {
        enums.add(_enum());
      } else if (_checkIdentifierValue('model')) {
        models.add(_model());
      } else if (_checkIdentifierValue('mutation')) {
        mutations.add(_mutation());
      } else if (_checkIdentifierValue('prerequisite')) {
        prerequisites.add(_prerequisite());
      } else {
        throw _error(
          _peek,
          'expected "enum", "model", "mutation", or "prerequisite" declaration',
        );
      }
    }
    return ModelDocumentSyntax(
      source: source,
      enums: List.unmodifiable(enums),
      models: List.unmodifiable(models),
      mutations: List.unmodifiable(mutations),
      prerequisites: List.unmodifiable(prerequisites),
    );
  }

  PrerequisiteSyntax _prerequisite() {
    final start = _expectIdentifierValue(
      'prerequisite',
      'expected "prerequisite" declaration',
    );
    final name = _identifier('expected prerequisite name');
    _expect(TokenKind.leftParen, 'expected "(" after prerequisite name');
    if (_check(TokenKind.rightParen)) {
      throw _error(_peek, 'expected prerequisite parameter');
    }
    final parameters = <PrerequisiteParameterSyntax>[];
    do {
      final parameterName = _identifier('expected prerequisite parameter name');
      final typeName = _identifier('expected prerequisite parameter type');
      parameters.add(
        PrerequisiteParameterSyntax(
          name: parameterName,
          typeName: typeName,
          span: SourceSpan(
            start: parameterName.span.start,
            end: typeName.span.end,
          ),
        ),
      );
    } while (_match(TokenKind.comma));
    final end = _expect(
      TokenKind.rightParen,
      'expected ")" after prerequisite parameters',
    );
    return PrerequisiteSyntax(
      name: name,
      parameters: List.unmodifiable(parameters),
      span: SourceSpan(start: start.span.start, end: end.span.end),
    );
  }

  MutationSyntax _mutation() {
    final start = _expectIdentifierValue(
      'mutation',
      'expected "mutation" declaration',
    );
    final name = _identifier('expected mutation name');
    _expect(TokenKind.leftBrace, 'expected "{" after mutation name');
    final slots = <MutationSlotSyntax>[];
    final annotations = <AnnotationSyntax>[];
    while (!_check(TokenKind.rightBrace)) {
      if (_check(TokenKind.eof)) {
        throw _error(_peek, 'expected slot, mutation annotation, or "}"');
      }
      if (_check(TokenKind.doubleAt)) {
        annotations.add(_modelAnnotation());
      } else {
        slots.add(_mutationSlot());
      }
    }
    final end = _advance();
    return MutationSyntax(
      name: name,
      slots: List.unmodifiable(slots),
      annotations: List.unmodifiable(annotations),
      span: SourceSpan(start: start.span.start, end: end.span.end),
    );
  }

  /// `name Model.op<fields>` with optional `(relation: slot, …)` bindings and
  /// an optional `?` or `[]` — the whole of a slot. Only update has a patch
  /// projection; create and delete retain their closed operation shapes.
  MutationSlotSyntax _mutationSlot() {
    final name = _identifier('expected slot name');
    final modelName = _identifier('expected slot Model');
    _expect(TokenKind.dot, 'expected "." after slot Model');
    final operation = _identifier('expected slot operation');
    final patchFields = <LocatedIdentifier>[];
    final bindings = <MutationSlotBindingSyntax>[];
    var cardinality = MutationSlotCardinalitySyntax.single;
    var end = operation.span.end;
    if (operation.value == 'update') {
      _expect(TokenKind.leftAngle, 'expected "<" after update operation');
      if (_check(TokenKind.rightAngle)) {
        throw _error(_peek, 'expected field in update projection');
      }
      do {
        patchFields.add(_identifier('expected field in update projection'));
      } while (_match(TokenKind.comma));
      end = _expect(
        TokenKind.rightAngle,
        'expected ">" after update projection',
      ).span.end;
    } else if (_check(TokenKind.leftAngle)) {
      throw _error(_peek, 'only update slots may declare a patch projection');
    }
    if (_match(TokenKind.leftParen)) {
      if (_check(TokenKind.rightParen)) {
        throw _error(_peek, 'expected a "relation: slot" binding');
      }
      do {
        final relation = _identifier('expected relation name in binding');
        _expect(TokenKind.colon, 'expected ":" after binding relation name');
        final slot = _identifier('expected slot name in binding');
        bindings.add(
          MutationSlotBindingSyntax(
            relation: relation,
            slot: slot,
            span: SourceSpan(start: relation.span.start, end: slot.span.end),
          ),
        );
      } while (_match(TokenKind.comma));
      end = _expect(
        TokenKind.rightParen,
        'expected ")" after bindings',
      ).span.end;
    }
    if (_check(TokenKind.leftBracket)) {
      _advance();
      end = _expect(
        TokenKind.rightBracket,
        'expected "]" after slot operation',
      ).span.end;
      cardinality = MutationSlotCardinalitySyntax.list;
      if (_check(TokenKind.question)) {
        throw _error(_peek, 'a slot list cannot also be optional');
      }
    } else if (_check(TokenKind.question)) {
      end = _advance().span.end;
      cardinality = MutationSlotCardinalitySyntax.optional;
    }
    return MutationSlotSyntax(
      name: name,
      modelName: modelName,
      operation: operation,
      patchFields: List.unmodifiable(patchFields),
      bindings: List.unmodifiable(bindings),
      cardinality: cardinality,
      span: SourceSpan(start: name.span.start, end: end),
    );
  }

  EnumSyntax _enum() {
    final start = _expectIdentifierValue('enum', 'expected "enum" declaration');
    final name = _identifier('expected enum name');
    _expect(TokenKind.leftBrace, 'expected "{" after enum name');
    final values = <LocatedIdentifier>[];
    while (!_check(TokenKind.rightBrace)) {
      if (_check(TokenKind.eof)) {
        throw _error(_peek, 'expected enum value or "}"');
      }
      values.add(_identifier('expected enum value'));
    }
    final end = _advance();
    return EnumSyntax(
      name: name,
      values: List.unmodifiable(values),
      span: SourceSpan(start: start.span.start, end: end.span.end),
    );
  }

  ModelSyntax _model() {
    final start = _expectIdentifierValue(
      'model',
      'expected "model" declaration',
    );
    final name = _identifier('expected Model name');
    _expect(TokenKind.leftBrace, 'expected "{" after Model name');
    final fields = <FieldSyntax>[];
    final annotations = <AnnotationSyntax>[];
    while (!_check(TokenKind.rightBrace)) {
      if (_check(TokenKind.eof)) {
        throw _error(_peek, 'expected field, Model annotation, or "}"');
      }
      if (_check(TokenKind.doubleAt)) {
        annotations.add(_modelAnnotation());
      } else {
        fields.add(_field());
      }
    }
    final end = _advance();
    return ModelSyntax(
      name: name,
      fields: List.unmodifiable(fields),
      annotations: List.unmodifiable(annotations),
      span: SourceSpan(start: start.span.start, end: end.span.end),
    );
  }

  FieldSyntax _field() {
    final name = _identifier('expected field name');
    final typeName = _identifier('expected field type');
    final list = _match(TokenKind.leftBracket);
    if (list) {
      _expect(TokenKind.rightBracket, 'expected "]" after list element type');
      if (_check(TokenKind.leftBracket)) {
        throw _error(_peek, 'nested lists are not supported');
      }
      if (_check(TokenKind.question)) {
        throw _error(_peek, 'scalar lists cannot be nullable');
      }
    }
    final nullable = _match(TokenKind.question);
    final annotations = <AnnotationSyntax>[];
    while (_check(TokenKind.at)) {
      annotations.add(_fieldAnnotation());
    }
    final end = annotations.isEmpty
        ? (nullable ? tokens[_current - 1].span.end : typeName.span.end)
        : annotations.last.span.end;
    return FieldSyntax(
      name: name,
      typeName: typeName,
      list: list,
      nullable: nullable,
      annotations: List.unmodifiable(annotations),
      span: SourceSpan(start: name.span.start, end: end),
    );
  }

  AnnotationSyntax _fieldAnnotation() {
    final start = _expect(TokenKind.at, 'expected field annotation');
    final name = _identifier('expected field annotation name');
    if (!_match(TokenKind.leftParen)) {
      return AnnotationSyntax(
        name: name,
        arguments: const [],
        span: SourceSpan(start: start.span.start, end: name.span.end),
      );
    }

    if (_check(TokenKind.rightParen)) {
      throw _error(_peek, 'expected field annotation argument');
    }
    final arguments = <AnnotationArgumentSyntax>[];
    if (_check(TokenKind.identifier) && _checkNext(TokenKind.leftParen)) {
      arguments.add(_invocationFieldAnnotationArgument());
      final end = _expect(TokenKind.rightParen, 'expected ")"');
      return AnnotationSyntax(
        name: name,
        arguments: List.unmodifiable(arguments),
        span: SourceSpan(start: start.span.start, end: end.span.end),
      );
    }
    // One positional argument is allowed, and only in first place: the quoted
    // relation name. Everything after it is named.
    if (_check(TokenKind.string)) {
      arguments.add(_stringFieldAnnotationArgument());
      if (!_check(TokenKind.comma)) {
        final end = _expect(TokenKind.rightParen, 'expected ")"');
        return AnnotationSyntax(
          name: name,
          arguments: List.unmodifiable(arguments),
          span: SourceSpan(start: start.span.start, end: end.span.end),
        );
      }
      _advance();
    }
    do {
      arguments.add(_namedFieldAnnotationArgument());
    } while (_match(TokenKind.comma));
    final end = _expect(TokenKind.rightParen, 'expected ")"');
    return AnnotationSyntax(
      name: name,
      arguments: List.unmodifiable(arguments),
      span: SourceSpan(start: start.span.start, end: end.span.end),
    );
  }

  InvocationArgumentSyntax _invocationFieldAnnotationArgument() {
    final name = _identifier('expected prerequisite name');
    _expect(TokenKind.leftParen, 'expected "(" after prerequisite name');
    if (_check(TokenKind.rightParen)) {
      throw _error(_peek, 'expected prerequisite argument');
    }
    final arguments = <NamedArgumentSyntax>[];
    do {
      arguments.add(_namedFieldAnnotationArgument());
    } while (_match(TokenKind.comma));
    final end = _expect(
      TokenKind.rightParen,
      'expected ")" after prerequisite arguments',
    );
    return InvocationArgumentSyntax(
      name: name,
      arguments: List.unmodifiable(arguments),
      span: SourceSpan(start: name.span.start, end: end.span.end),
    );
  }

  StringArgumentSyntax _stringFieldAnnotationArgument() {
    final token = _expect(TokenKind.string, 'expected a quoted name');
    return StringArgumentSyntax(
      value: token.lexeme.substring(1, token.lexeme.length - 1),
      span: token.span,
    );
  }

  NamedArgumentSyntax _namedFieldAnnotationArgument() {
    final name = _identifier('expected field annotation argument name');
    _expect(
      TokenKind.colon,
      'expected ":" after field annotation argument name',
    );
    final value = _fieldAnnotationValue();
    return NamedArgumentSyntax(
      name: name,
      value: value,
      span: SourceSpan(start: name.span.start, end: value.span.end),
    );
  }

  AnnotationValueSyntax _fieldAnnotationValue() {
    if (_check(TokenKind.identifier)) {
      final value = _identifier('expected field annotation argument value');
      return IdentifierValueSyntax(value: value, span: value.span);
    }

    final start = _expect(
      TokenKind.leftBracket,
      'expected identifier or "[" for field annotation argument value',
    );
    if (_check(TokenKind.rightBracket)) {
      throw _error(
        _peek,
        'expected identifier in field annotation argument list',
      );
    }
    final values = <LocatedIdentifier>[];
    do {
      values.add(
        _identifier('expected identifier in field annotation argument list'),
      );
    } while (_match(TokenKind.comma));
    final end = _expect(
      TokenKind.rightBracket,
      'expected "]" after field annotation argument list',
    );
    return IdentifierListValueSyntax(
      values: values,
      span: SourceSpan(start: start.span.start, end: end.span.end),
    );
  }

  AnnotationSyntax _modelAnnotation() {
    final start = _expect(TokenKind.doubleAt, 'expected Model annotation');
    final name = _identifier('expected Model annotation name');
    // A bare annotation is a flag (`@@id`); the semantic layer decides
    // which names may go without arguments.
    if (!_check(TokenKind.leftParen)) {
      return AnnotationSyntax(
        name: name,
        arguments: const [],
        span: SourceSpan(start: start.span.start, end: name.span.end),
      );
    }
    _expect(TokenKind.leftParen, 'expected "(" after Model annotation');
    if (_check(TokenKind.rightParen)) {
      throw _error(_peek, 'expected annotation argument');
    }
    final arguments = <AnnotationArgumentSyntax>[];
    do {
      arguments.add(_annotationArgument());
    } while (_match(TokenKind.comma));
    final end = _expect(TokenKind.rightParen, 'expected ")"');
    return AnnotationSyntax(
      name: name,
      arguments: List.unmodifiable(arguments),
      span: SourceSpan(start: start.span.start, end: end.span.end),
    );
  }

  AnnotationArgumentSyntax _annotationArgument() {
    final token = _peek;
    if (_match(TokenKind.identifier)) {
      if (_match(TokenKind.colon)) {
        final value = _modelAnnotationValue();
        return NamedArgumentSyntax(
          name: LocatedIdentifier(value: token.lexeme, span: token.span),
          value: value,
          span: SourceSpan(start: token.span.start, end: value.span.end),
        );
      }
      return IdentifierArgumentSyntax(value: token.lexeme, span: token.span);
    }
    if (_match(TokenKind.integer)) {
      final int value;
      try {
        value = int.parse(token.lexeme);
      } on FormatException {
        throw _error(token, 'integer literal is out of range');
      }
      return IntegerArgumentSyntax(value: value, span: token.span);
    }
    throw _error(token, 'expected identifier or integer argument');
  }

  AnnotationValueSyntax _modelAnnotationValue() {
    final token = _peek;
    if (_match(TokenKind.integer)) {
      final int value;
      try {
        value = int.parse(token.lexeme);
      } on FormatException {
        throw _error(token, 'integer literal is out of range');
      }
      return IntegerValueSyntax(value: value, span: token.span);
    }
    if (_match(TokenKind.leftBracket)) {
      if (_check(TokenKind.rightBracket)) {
        throw _error(_peek, 'expected identifier path in annotation list');
      }
      if (_check(TokenKind.identifier) && _checkNext(TokenKind.leftParen)) {
        final selectors = <MutationSelectorSyntax>[];
        do {
          final mutation = _identifier('expected predecessor mutation name');
          _expect(
            TokenKind.leftParen,
            'expected "(" after predecessor mutation name',
          );
          final predecessor = _identifierPath('expected predecessor slot path');
          _expect(
            TokenKind.colon,
            'expected ":" between predecessor and current paths',
          );
          final current = _identifierPath('expected current slot path');
          final close = _expect(
            TokenKind.rightParen,
            'expected ")" after mutation sequence selector',
          );
          selectors.add(
            MutationSelectorSyntax(
              mutation: mutation,
              predecessor: predecessor,
              current: current,
              span: SourceSpan(start: mutation.span.start, end: close.span.end),
            ),
          );
        } while (_match(TokenKind.comma));
        final end = _expect(
          TokenKind.rightBracket,
          'expected "]" after mutation sequence selectors',
        );
        return MutationSelectorListValueSyntax(
          selectors: selectors,
          span: SourceSpan(start: token.span.start, end: end.span.end),
        );
      }
      final paths = <IdentifierPathSyntax>[];
      do {
        paths.add(_identifierPath('expected identifier in annotation path'));
      } while (_match(TokenKind.comma));
      final end = _expect(
        TokenKind.rightBracket,
        'expected "]" after annotation path list',
      );
      return IdentifierPathListValueSyntax(
        paths: paths,
        span: SourceSpan(start: token.span.start, end: end.span.end),
      );
    }
    throw _error(token, 'expected integer or "[" for Model annotation value');
  }

  IdentifierPathSyntax _identifierPath(String message) {
    final components = <LocatedIdentifier>[_identifier(message)];
    while (_match(TokenKind.dot)) {
      components.add(
        _identifier('expected identifier after "." in annotation path'),
      );
    }
    return IdentifierPathSyntax(
      components: components,
      span: SourceSpan(
        start: components.first.span.start,
        end: components.last.span.end,
      ),
    );
  }

  LocatedIdentifier _identifier(String message) {
    final token = _expect(TokenKind.identifier, message);
    return LocatedIdentifier(value: token.lexeme, span: token.span);
  }

  Token _expectIdentifierValue(String value, String message) {
    if (_check(TokenKind.identifier) && _peek.lexeme == value) {
      return _advance();
    }
    throw _error(_peek, message);
  }

  Token _expect(TokenKind kind, String message) {
    if (_check(kind)) return _advance();
    throw _error(_peek, message);
  }

  bool _match(TokenKind kind) {
    if (!_check(kind)) return false;
    _advance();
    return true;
  }

  bool _check(TokenKind kind) => _peek.kind == kind;

  bool _checkNext(TokenKind kind) =>
      _current + 1 < tokens.length && tokens[_current + 1].kind == kind;

  bool _checkIdentifierValue(String value) =>
      _check(TokenKind.identifier) && _peek.lexeme == value;

  Token _advance() {
    final token = _peek;
    if (!_check(TokenKind.eof)) _current += 1;
    return token;
  }

  Token get _peek => tokens[_current];

  DefinitionException _error(Token token, String message) =>
      DefinitionException(location: token.span.start, message: message);
}
