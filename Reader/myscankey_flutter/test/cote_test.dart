import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/core/cote.dart';

void main() {
  test('documentaire : indice Dewey et code auteur', () {
    expect(
      generateCote(
        author: 'NGOË',
        documentType: 'Documentaire',
        dewey: '966.71',
      ),
      '966.71 NGO',
    );
  });
  test('fiction : préfixe par genre', () {
    expect(
      generateCote(author: 'Dumas, Alexandre', documentType: 'Fiction'),
      'R DUM',
    );
    expect(
      generateCote(
        author: 'Hergé',
        documentType: 'Fiction',
        genre: 'Bande dessinée',
      ),
      'BD HER',
    );
  });
  test('accents, ligatures et accents combinés', () {
    expect(authorCode('Émile'), 'EMI');
    expect(authorCode('E\u0301mile'), 'EMI');
    expect(authorCode('Œster'), 'OES');
  });
  test('particules initiales ignorées : de La Fontaine donne FON', () {
    expect(authorCode('de La Fontaine'), 'FON');
    expect(authorCode('d’Alembert'), 'ALE');
    expect(authorCode('van Gogh'), 'GOG');
  });
  test('anonyme et noms courts', () {
    expect(authorCode('Anonyme'), 'ANO');
    expect(authorCode(''), 'ANO');
    expect(authorCode('Li'), 'LI');
    expect(authorCode('Ô'), 'O');
  });
  test('règles personnalisées', () {
    expect(
      generateCote(
        author: 'Dumas',
        documentType: 'Fiction',
        genre: 'Roman',
        prefixes: {'Roman': 'ROM'},
      ),
      'ROM DUM',
    );
  });
}
