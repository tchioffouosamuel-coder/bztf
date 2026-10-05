/// Préfixes éditables dans les paramètres de catalogage.
const defaultGenrePrefixes = <String, String>{
  'Roman': 'R',
  'Bande dessinée': 'BD',
  'Poésie': 'P',
  'Théâtre': 'T',
  'Conte': 'C',
};

String _fold(String value) {
  const groups = {
    'A': 'ÀÁÂÃÄÅ',
    'C': 'Ç',
    'E': 'ÈÉÊË',
    'I': 'ÌÍÎÏ',
    'N': 'Ñ',
    'O': 'ÒÓÔÕÖØ',
    'U': 'ÙÚÛÜ',
    'Y': 'ÝŸ',
  };
  var result = value.toUpperCase().replaceAll('Œ', 'OE').replaceAll('Æ', 'AE');
  for (final entry in groups.entries) {
    for (final rune in entry.value.runes) {
      result = result.replaceAll(String.fromCharCode(rune), entry.key);
    }
  }
  return result.replaceAll(RegExp(r'[\u0300-\u036f]'), '');
}

/// Les particules initiales sont ignorées, y compris « de La » :
/// « de La Fontaine » donne FON. Une forme « Nom, Prénom » utilise le nom.
/// Un nom court reste court (Li → LI), un auteur absent/anonyme donne ANO.
String authorCode(String author) {
  var name = _fold(author.split(';').first.split(',').first.trim());
  if (name.isEmpty || name == 'ANONYME' || name == 'ANONYMOUS') return 'ANO';
  name = name.replaceAll(RegExp(r"['’\-]"), ' ');
  final words = name.split(RegExp(r'\s+')).toList();
  const particles = {
    'DE',
    'DU',
    'DES',
    'LA',
    'LE',
    'LES',
    'D',
    'VAN',
    'VON',
    'DA',
    'DI',
  };
  while (words.length > 1 && particles.contains(words.first)) {
    words.removeAt(0);
  }
  name = words.join().replaceAll(RegExp('[^A-Z]'), '');
  return name.isEmpty ? 'ANO' : name.substring(0, name.length.clamp(0, 3));
}

String generateCote({
  required String author,
  required String documentType,
  String dewey = '',
  String genre = 'Roman',
  Map<String, String> prefixes = defaultGenrePrefixes,
}) {
  final code = authorCode(author);
  final prefix = _fold(documentType.trim()) == 'DOCUMENTAIRE'
      ? dewey.trim()
      : (prefixes[genre] ?? 'R').trim();
  return [if (prefix.isNotEmpty) prefix, code].join(' ');
}
