/// Normalisation commune à la recherche et aux comparaisons bibliographiques.
String foldCatalogueText(String value) {
  var text = value.toLowerCase().replaceAll('œ', 'oe').replaceAll('æ', 'ae');
  const groups = {
    'a': 'àáâãäå',
    'c': 'ç',
    'e': 'èéêë',
    'i': 'ìíîï',
    'n': 'ñ',
    'o': 'òóôõöø',
    'u': 'ùúûü',
    'y': 'ýÿ',
  };
  for (final entry in groups.entries) {
    for (final rune in entry.value.runes) {
      text = text.replaceAll(String.fromCharCode(rune), entry.key);
    }
  }
  return text
      .replaceAll(RegExp(r'[\u0300-\u036f]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String normalizeBibliography(String value) => foldCatalogueText(
  value,
).replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

Set<String> catalogueTrigrams(String value) => {
  for (var i = 0; i + 3 <= value.length; i++) value.substring(i, i + 3),
};
