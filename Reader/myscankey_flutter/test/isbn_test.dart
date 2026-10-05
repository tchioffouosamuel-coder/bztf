import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/core/isbn.dart';

void main() {
  test('normalise les tirets, espaces et X final', () {
    expect(Isbn.normalize('2-07-036002-x'), '207036002X');
    expect(Isbn.normalize('978 2 07 036002 4'), '9782070360024');
  });

  test('valide les clés ISBN-10 et ISBN-13', () {
    expect(Isbn.isValid('2-07-036002-4'), isTrue);
    expect(Isbn.isValid('0-8044-2957-X'), isTrue);
    expect(Isbn.isValid('978-2-07-036002-4'), isTrue);
    expect(Isbn.isValid('2-07-036002-5'), isFalse);
    expect(Isbn.isValid('978-2-07-036002-5'), isFalse);
  });

  test('convertit ISBN-10 vers ISBN-13', () {
    expect(Isbn.toIsbn13('2-07-036002-4'), '9782070360024');
    expect(Isbn.toIsbn13('0-8044-2957-X'), '9780804429573');
  });

  test('convertit ISBN-13 vers ISBN-10 quand le préfixe le permet', () {
    expect(Isbn.toIsbn10('978-2-07-036002-4'), '2070360024');
    expect(Isbn.toIsbn10('9791090636071'), isNull);
  });

  test('refuse une conversion depuis un ISBN invalide', () {
    expect(() => Isbn.toIsbn13('9782070360025'), throwsFormatException);
  });
}
