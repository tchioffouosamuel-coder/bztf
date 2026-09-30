import 'dart:math';
import 'dart:typed_data';

const _prefix = [0x42, 0x43, 0x4D, 0x01];

/// "BCM" + format 2 : carte d'abonné.
const _cardPrefix = [0x42, 0x43, 0x4D, 0x02];

/// "BCM" + format 3 : badge du personnel.
const _badgePrefix = [0x42, 0x43, 0x4D, 0x03];

int crc16Ccitt(List<int> bytes) {
  var crc = 0xFFFF;
  for (final byte in bytes) {
    crc ^= byte << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 0x8000 != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

String generateEpc(int year, int sequence) =>
    _encodeEpc(_prefix, year, sequence);

/// EPC de carte d'abonné : préfixe + 48 bits aléatoires + CRC. L'aléa (et
/// non un identifiant local) évite les collisions entre appareils synchronisés.
String generateCardEpc([Random? random]) => _randomEpc(_cardPrefix, random);

/// EPC de badge du personnel : même construction, préfixe « BCM » 3.
String generateBadgeEpc([Random? random]) => _randomEpc(_badgePrefix, random);

String _randomEpc(List<int> prefix, Random? random) {
  final source = random ?? Random.secure();
  final payload = Uint8List(12);
  payload.setRange(0, 4, prefix);
  for (var index = 4; index < 10; index++) {
    payload[index] = source.nextInt(256);
  }
  ByteData.sublistView(
    payload,
  ).setUint16(10, crc16Ccitt(payload.sublist(0, 10)), Endian.big);
  return payload
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

String _encodeEpc(List<int> prefix, int year, int sequence) {
  if (year < 0 || year > 0xFFFF) throw ArgumentError('Année EPC invalide.');
  if (sequence < 1 || sequence > 0xFFFFFFFF) {
    throw ArgumentError('Séquence EPC invalide.');
  }
  final payload = Uint8List(12);
  payload.setRange(0, 4, prefix);
  final data = ByteData.sublistView(payload);
  data.setUint16(4, year, Endian.big);
  data.setUint32(6, sequence, Endian.big);
  data.setUint16(10, crc16Ccitt(payload.sublist(0, 10)), Endian.big);
  return payload
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

String formatAccession(int year, int sequence) =>
    'BCM-$year-${sequence.toString().padLeft(6, '0')}';

bool isValidEpc(String value) => _hasPrefixAndCrc(value, _prefix);

bool isCardEpc(String value) => _hasPrefixAndCrc(value, _cardPrefix);

bool isBadgeEpc(String value) => _hasPrefixAndCrc(value, _badgePrefix);

bool _hasPrefixAndCrc(String value, List<int> prefix) {
  if (!RegExp(r'^[0-9A-Fa-f]{24}$').hasMatch(value)) return false;
  final bytes = <int>[
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ];
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  final expected = (bytes[10] << 8) | bytes[11];
  return expected == crc16Ccitt(bytes.sublist(0, 10));
}
