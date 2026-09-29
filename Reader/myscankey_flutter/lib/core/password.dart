import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Itérations PBKDF2 des nouveaux mots de passe (stockées avec chaque compte
/// pour pouvoir les augmenter plus tard).
const passwordIterations = 60000;

/// PBKDF2-HMAC-SHA256 (RFC 8018).
Uint8List pbkdf2Sha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int length,
) {
  final hmac = Hmac(sha256, password);
  final output = BytesBuilder();
  for (var block = 1; output.length < length; block++) {
    var digest = hmac.convert([
      ...salt,
      (block >> 24) & 0xFF,
      (block >> 16) & 0xFF,
      (block >> 8) & 0xFF,
      block & 0xFF,
    ]).bytes;
    final result = Uint8List.fromList(digest);
    for (var round = 1; round < iterations; round++) {
      digest = hmac.convert(digest).bytes;
      for (var index = 0; index < result.length; index++) {
        result[index] ^= digest[index];
      }
    }
    output.add(result);
  }
  return Uint8List.sublistView(output.toBytes(), 0, length);
}

/// Empreinte hexadécimale, calculée hors du fil de l'interface.
Future<String> hashPassword(String password, String saltHex, int iterations) =>
    Isolate.run(
      () => _hex(
        pbkdf2Sha256(utf8.encode(password), _unhex(saltHex), iterations, 32),
      ),
    );

String newPasswordSalt() {
  final random = Random.secure();
  return _hex(List<int>.generate(16, (_) => random.nextInt(256)));
}

/// Comparaison en temps constant.
bool sameDigest(String left, String right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
  }
  return difference == 0;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String value) => [
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
];
