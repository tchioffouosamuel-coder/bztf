import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/widgets/n01_settings_form.dart';

void main() {
  Future<void> openForm(
    WidgetTester tester,
    Map<String, Object?> settings,
    Future<void> Function(Map<String, Object?>) onApply,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: N01SettingsForm(settings: settings, onApply: onApply),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field(String path) => find.byKey(ValueKey('n01-0-$path'));

  testWidgets(
    'champs SDK, validation numérique et patch limité aux modifications',
    (tester) async {
      Map<String, Object?>? submitted;
      await openForm(tester, {
        'rfid': {
          'region': 'EUR',
          'qValue': 4,
          'session': 1,
          'gen2RfMode': 107,
          'uniByAnt': true,
        },
      }, (patch) async => submitted = patch);
      expect(find.text('Configuration JSON'), findsNothing);
      expect(
        tester
            .widget<DropdownButtonFormField<Object>>(field('rfid.session'))
            .initialValue,
        1,
      );
      final numberInput = find.descendant(
        of: field('rfid.qValue'),
        matching: find.byType(EditableText),
      );
      expect(
        tester.widget<EditableText>(numberInput).keyboardType,
        const TextInputType.numberWithOptions(signed: true),
      );
      expect(
        tester.widget<SwitchListTile>(field('rfid.uniByAnt')).value,
        isTrue,
      );
      final apply = find.text('Appliquer les modifications N01');
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(of: apply, matching: find.byType(FilledButton)),
            )
            .onPressed,
        isNull,
      );

      await tester.enterText(field('rfid.qValue'), '17');
      await tester.pumpAndSettle();
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(submitted, isNull);
      expect(find.text('Maximum : 16'), findsOneWidget);

      await tester.enterText(field('rfid.qValue'), '8');
      await tester.pumpAndSettle();
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(submitted, {
        'rfid': {'qValue': 8},
      });

      await tester.tap(find.byTooltip('Annuler les modifications'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('n01-1-rfid.qValue')),
            )
            .initialValue,
        '4',
      );
    },
  );

  testWidgets(
    'IP validée et convertie pour le SDK sans toucher au mot de passe',
    (tester) async {
      Map<String, Object?>? submitted;
      await openForm(tester, {
        'network': {
          'ethConfig': ['0', '192.168.1.10', '255.255.255.0', '192.168.1.1'],
          'wifiSsidPassw': ['Bibliothèque', 'secret'],
        },
      }, (patch) async => submitted = patch);
      await tester.tap(find.text('Réseau et horloge'));
      await tester.pumpAndSettle();
      final password = find.descendant(
        of: field('network.wifiSsidPassw.1'),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(password).obscureText, isTrue);
      await tester.enterText(field('network.ethConfig.1'), '999.168.1.20');
      await tester.pumpAndSettle();
      final apply = find.text('Appliquer les modifications N01');
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(submitted, isNull);
      expect(find.text('Adresse IPv4 invalide.'), findsOneWidget);

      await tester.enterText(field('network.ethConfig.1'), '192.168.1.20');
      await tester.pumpAndSettle();
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(submitted, {
        'network': {
          'ethConfig': ['192.168.1.20', '255.255.255.0', '192.168.1.1'],
        },
      });
    },
  );

  testWidgets(
    'exige l’intervalle omis par le getter avant de modifier AutoInvCfg',
    (tester) async {
      Map<String, Object?>? submitted;
      await openForm(tester, {
        'reporting': {
          'autoInvCfg': {'stopdelay': 0, 'synctimeout': 200},
        },
      }, (patch) async => submitted = patch);
      await tester.tap(find.text('Rapports et inventaire automatique'));
      await tester.pumpAndSettle();
      await tester.enterText(field('reporting.autoInvCfg.stopdelay'), '2');
      await tester.pumpAndSettle();
      final apply = find.text('Appliquer les modifications N01');
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(submitted, isNull);
      expect(find.text('Entrez un nombre entier.'), findsOneWidget);
      await tester.enterText(field('reporting.autoInvCfg.syncinterv'), '500');
      await tester.pumpAndSettle();
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(submitted, {
        'reporting': {
          'autoInvCfg': {'stopdelay': 2, 'synctimeout': 200, 'syncinterv': 500},
        },
      });
    },
  );

  for (final width in [360.0, 1024.0]) {
    testWidgets('toutes les rubriques tiennent sur un écran de $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openForm(tester, {
        'identity': {
          'readerId': 'N01',
          'hardwareVersion': ['1', '2', '3'],
          'license': ['true', 'key'],
        },
        'rfid': {
          'region': 'EUR',
          'hopTable': [865000, 866000],
          'session': 1,
          'qValue': 4,
          'target': 'A-B',
          'gen2RfMode': 107,
          'rfidLevel': 0,
          'uniByAnt': true,
          'uniByBank': false,
          'maxRssi': true,
          'invAntennas': [1, 2],
        },
        'antennas': [
          {'ant': 1, 'read': 25, 'write': 20},
          {'ant': 2, 'read': 25, 'write': 20},
        ],
        'io': {
          'gpiLevels': {'1': 0, '2': 1, '3': 0, '4': 0},
          'exGet': [1, 2, 30, 1, 0],
          'tagInfoEx': [0, 1, 0],
          'tagGpo': [1, 1, 2, 0, 'E280', true],
          'indicatorGpo': [1, 2, 0, 3, 1, -1],
        },
        'network': {
          'localTcpPort': 8080,
          'ethConfig': ['0', '192.168.1.10', '255.255.255.0', '192.168.1.1'],
          'wifiDhcp': ['1', '10.0.0.10', '255.0.0.0', '10.0.0.1'],
          'wifiSsidPassw': ['Bibliothèque', 'secret'],
          'timezone': 'GMT+1',
          'time': '2026-10-07 12:34:56',
        },
        'reporting': {
          'reportCfg': [0, 10, 1, 10, 30, 2],
          'autoInv': ['TCP_FAST', '5', 'NONE', 'NONE', 'NONE', 'NONE'],
          'autoInvCfg': {
            'stopdelay': 0,
            'synctimeout': 200,
            'trigpo': 0,
            'epc0gpo': 0,
            'epc1gpo': 1,
            'legalgpo': 0,
            'illegalgpo': 2,
            'errgpo': 0,
            'gpodur': 2,
            'ingpi': 1,
            'outgpi': 2,
            'tagFilter': {
              'bank': 1,
              'startBit': 32,
              'mask': 'E280',
              'match': true,
            },
            'bankData': {
              'bank': 2,
              'startWord': 0,
              'wordCount': 6,
              'password': '',
            },
          },
        },
      }, (_) async {});
      for (final label in [
        'Identification',
        'Antennes',
        'Entrées / sorties GPI et GPO',
        'Réseau et horloge',
        'Rapports et inventaire automatique',
      ]) {
        final title = find.text(label);
        await tester.ensureVisible(title);
        await tester.tap(title);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      final licenseKey = find.descendant(
        of: field('identity.license.1'),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(licenseKey).obscureText, isTrue);
    });
  }
}
