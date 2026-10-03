import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/services/log_shipper.dart';
import 'package:myscankey_flutter/services/sync_service.dart';

void main() {
  test(
    'les logs sont envoyés par lots et gardés si le serveur échoue',
    () async {
      final sync = SyncService(LibraryDatabase.instance)
        ..serverUrl = 'https://exemple.test/'
        ..apiKey = 'secret'
        ..deviceId = 'gate-1'
        ..deviceName = 'Portail';
      final received = <Map<String, Object?>>[];
      var online = false;
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://exemple.test/api/v1/logs');
        expect(request.headers['X-Device-Key'], 'secret');
        if (!online) return http.Response('indisponible', 503);
        received.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response('{"accepted":2}', 200);
      });
      final lines = StreamController<String>();
      final shipper = LogShipper(
        sync,
        lines: lines.stream,
        client: client,
        interval: const Duration(hours: 1),
      )..start();

      lines
        ..add('I/BiblioGate: Gate tag seen')
        ..add('I/flutter: Portail : tag → alarme');
      await Future<void>.delayed(Duration.zero);
      expect(shipper.pending, 2);

      // Serveur indisponible : les lignes restent en attente.
      await shipper.flush();
      expect(shipper.pending, 2);
      expect(received, isEmpty);

      online = true;
      await shipper.flush();
      expect(shipper.pending, 0);
      expect(received.single['deviceId'], 'gate-1');
      expect(received.single['name'], 'Portail');
      expect(
        (received.single['lines'] as List).map((line) => (line as Map)['line']),
        ['I/BiblioGate: Gate tag seen', 'I/flutter: Portail : tag → alarme'],
      );

      shipper.dispose();
      await lines.close();
    },
  );
}
