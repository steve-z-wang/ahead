String dartFileName(String name) {
  final buffer = StringBuffer();
  for (var index = 0; index < name.length; index += 1) {
    final codeUnit = name.codeUnitAt(index);
    final upper = codeUnit >= 65 && codeUnit <= 90;
    if (upper && index > 0) buffer.write('_');
    buffer.write(String.fromCharCode(upper ? codeUnit + 32 : codeUnit));
  }
  return buffer.toString();
}

String lowerCamel(String name) =>
    '${name.substring(0, 1).toLowerCase()}${name.substring(1)}';
