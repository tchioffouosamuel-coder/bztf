class Isbn {
  const Isbn._();

  static String normalize(String value) {
    final compact = value.replaceAll(RegExp(r'[-\s]'), '').trim();
    if (compact.endsWith('x')) {
      return '${compact.substring(0, compact.length - 1)}X';
    }
    return compact;
  }

  static bool isValid(String value) {
    final normalized = normalize(value);
    if (normalized.length == 10) return isValid10(normalized);
    if (normalized.length == 13) return isValid13(normalized);
    return false;
  }

  static bool isValid10(String value) {
    final normalized = normalize(value);
    if (!RegExp(r'^\d{9}[\dX]$').hasMatch(normalized)) return false;
    var sum = 0;
    for (var index = 0; index < 10; index++) {
      final char = normalized[index];
      final digit = char == 'X' ? 10 : int.parse(char);
      sum += (10 - index) * digit;
    }
    return sum % 11 == 0;
  }

  static bool isValid13(String value) {
    final normalized = normalize(value);
    if (!RegExp(r'^\d{13}$').hasMatch(normalized)) return false;
    var sum = 0;
    for (var index = 0; index < 12; index++) {
      final digit = int.parse(normalized[index]);
      sum += index.isEven ? digit : digit * 3;
    }
    final check = (10 - (sum % 10)) % 10;
    return check == int.parse(normalized[12]);
  }

  static String toIsbn13(String value) {
    final normalized = normalize(value);
    if (normalized.length == 13 && isValid13(normalized)) return normalized;
    if (normalized.length != 10 || !isValid10(normalized)) {
      throw const FormatException('ISBN invalide.');
    }
    final body = '978${normalized.substring(0, 9)}';
    return '$body${_isbn13CheckDigit(body)}';
  }

  static String? toIsbn10(String value) {
    final normalized = normalize(value);
    if (normalized.length == 10 && isValid10(normalized)) return normalized;
    if (normalized.length != 13 ||
        !normalized.startsWith('978') ||
        !isValid13(normalized)) {
      return null;
    }
    final body = normalized.substring(3, 12);
    return '$body${_isbn10CheckDigit(body)}';
  }

  static int _isbn13CheckDigit(String twelveDigits) {
    var sum = 0;
    for (var index = 0; index < 12; index++) {
      final digit = int.parse(twelveDigits[index]);
      sum += index.isEven ? digit : digit * 3;
    }
    return (10 - (sum % 10)) % 10;
  }

  static String _isbn10CheckDigit(String nineDigits) {
    var sum = 0;
    for (var index = 0; index < 9; index++) {
      sum += (10 - index) * int.parse(nineDigits[index]);
    }
    final check = (11 - (sum % 11)) % 11;
    return check == 10 ? 'X' : check.toString();
  }
}
