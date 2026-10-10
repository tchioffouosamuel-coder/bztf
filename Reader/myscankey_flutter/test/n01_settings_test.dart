import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/models/n01_settings.dart';

void main() {
  test('envoie seulement les paramètres modifiés et conserve le snapshot', () {
    final snapshot = <String, Object?>{
      'rfid': {'region': 'EUR', 'session': 1},
      'identity': {
        'readerId': 'N01',
        'hardwareVersion': ['1', '2', '3'],
      },
      'capabilities': ['reboot'],
    };
    final draft = N01SettingsDraft(snapshot);
    expect(draft.patch, isEmpty);
    draft.set(['rfid', 'session'], 2);
    expect(draft.patch, {
      'rfid': {'session': 2},
    });
    expect((snapshot['rfid'] as Map)['session'], 1);
    draft.set(['rfid', 'session'], 1);
    expect(draft.patch, isEmpty);
  });

  test('convertit le réseau dans l’ordre attendu par le setter Android', () {
    final draft = N01SettingsDraft({
      'network': {
        'ethConfig': ['0', '192.168.1.10', '255.255.255.0', '192.168.1.1'],
        'wifiDhcp': ['1', '10.0.0.10', '255.0.0.0', '10.0.0.1'],
      },
    });
    draft.set(['network', 'ethConfig', 1], '192.168.1.20');
    draft.set(['network', 'wifiDhcp', 1], '10.0.0.20');
    expect(draft.patch, {
      'network': {
        'ethConfig': ['192.168.1.20', '255.255.255.0', '192.168.1.1'],
        'wifiDhcp': ['10.0.0.20', '255.0.0.0', '10.0.0.1'],
      },
    });
  });

  test('convertit l’heure et conserve les champs groupés non modifiés', () {
    final draft = N01SettingsDraft({
      'network': {'time': '2026-10-07 12:34:56'},
      'reporting': {
        'autoInvCfg': {'stopdelay': 3, 'synctimeout': 200, 'trigpo': 2},
      },
      'antennas': [
        {'ant': 1, 'read': 25, 'write': 20},
      ],
    });
    expect(draft.patch, isEmpty);
    draft.set(['network', 'time', 4], 35);
    draft.set(['reporting', 'autoInvCfg', 'stopdelay'], 4);
    draft.set(['reporting', 'autoInvCfg', 'syncinterv'], 500);
    draft.set(['antennas', 0, 'read'], 26);
    expect(draft.patch, {
      'network': {
        'time': [2026, 10, 7, 12, 35, 56],
      },
      'reporting': {
        'autoInvCfg': {
          'stopdelay': 4,
          'synctimeout': 200,
          'trigpo': 2,
          'syncinterv': 500,
        },
      },
      'antennas': [
        {'ant': 1, 'read': 26, 'write': 20},
      ],
    });
  });
}
