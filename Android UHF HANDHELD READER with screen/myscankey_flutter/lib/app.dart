import 'dart:async';

import 'package:flutter/material.dart';

import 'models/book.dart';
import 'screens/catalogue_screen.dart';
import 'screens/book_search_delegate.dart';
import 'screens/dashboard_screen.dart';
import 'screens/history_screen.dart';
import 'screens/inventory_screen.dart';
import 'screens/locator_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/station_screen.dart';
import 'services/library_controller.dart';
import 'widgets/reader_connection_dialog.dart';

class BiblioShell extends StatelessWidget {
  const BiblioShell({required this.controller, super.key});

  final LibraryController controller;

  static const _destinations = <(String, String, IconData, IconData)>[
    ('dashboard', 'Accueil', Icons.dashboard_outlined, Icons.dashboard),
    (
      'catalogue',
      'Catalogue',
      Icons.library_books_outlined,
      Icons.library_books,
    ),
    ('station', 'Station', Icons.radar_outlined, Icons.radar),
    ('inventory', 'Inventaire', Icons.fact_check_outlined, Icons.fact_check),
    ('history', 'Historique', Icons.history, Icons.history),
    ('settings', 'Réglages', Icons.tune_outlined, Icons.tune),
  ];

  String _title(String view) => switch (view) {
    'catalogue' => 'Catalogue',
    'station' => 'Station RFID',
    'inventory' => 'Inventaire RFID',
    'locator' => 'Localisation RFID',
    'history' => 'Historique',
    'settings' => 'Paramètres',
    _ => 'BiblioRFID',
  };

  Future<void> _connect(BuildContext context) async {
    final config = await ReaderConnectionDialog.show(
      context,
      transport: controller.transport,
      endpoint: controller.endpoint,
    );
    if (config == null || !context.mounted) return;
    try {
      await controller.connectReader(
        nextTransport: config.$1,
        nextEndpoint: config.$2,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Lecteur connecté.')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _searchBook(BuildContext context) async {
    final book = await showSearch<Book?>(
      context: context,
      delegate: BookSearchDelegate(controller.database, encodedOnly: true),
    );
    if (book == null || !context.mounted) return;
    try {
      await controller.locateBook(book);
    } catch (error) {
      if (context.mounted) showMessage(context, error.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedView = controller.view == 'locator'
        ? 'station'
        : controller.view;
    final index = _destinations
        .indexWhere((item) => item.$1 == selectedView)
        .clamp(0, _destinations.length - 1);
    final colors = Theme.of(context).colorScheme;
    return PopScope<Object?>(
      canPop: !controller.canNavigateBack,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(controller.navigateBack());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: controller.view == 'locator'
              ? IconButton(
                  tooltip: 'Retour',
                  onPressed: controller.navigateBack,
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'BiblioRFID',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              Text(
                _title(controller.view),
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Localiser un livre',
              onPressed: () => _searchBook(context),
              icon: const Icon(Icons.search),
            ),
            if (controller.busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                tooltip: controller.readerConnected
                    ? 'Lecteur connecté'
                    : 'Connecter le lecteur',
                onPressed: () => _connect(context),
                icon: Icon(
                  controller.readerConnected
                      ? Icons.sensors
                      : Icons.sensors_off,
                  color: controller.readerConnected
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
              ),
            IconButton(
              tooltip: 'Changer le thème',
              onPressed: controller.toggleTheme,
              icon: Icon(
                controller.darkTheme
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: switch (controller.view) {
            'catalogue' => CatalogueScreen(controller: controller),
            'station' => StationScreen(controller: controller),
            'inventory' => InventoryScreen(controller: controller),
            'locator' => LocatorScreen(
              controller: controller,
              onChooseBook: () => _searchBook(context),
            ),
            'history' => HistoryScreen(controller: controller),
            'settings' => SettingsScreen(controller: controller),
            _ => DashboardScreen(controller: controller),
          },
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
          destinations: [
            for (final item in _destinations)
              NavigationDestination(
                icon: Icon(item.$3),
                selectedIcon: Icon(item.$4),
                label: item.$2,
              ),
          ],
          onDestinationSelected: (selected) =>
              controller.setView(_destinations[selected].$1),
        ),
      ),
    );
  }
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirmer',
  bool destructive = false,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Icon(
            destructive ? Icons.warning_amber_rounded : Icons.info_outline,
          ),
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

void showMessage(BuildContext context, String message, {bool error = false}) {
  final platformError = RegExp(
    r'^PlatformException\([^,]+,\s*(.*),\s*null,\s*null\)$',
  ).firstMatch(message);
  final displayMessage = (platformError?.group(1) ?? message).replaceFirst(
    RegExp(r'^(Bad state|Invalid argument\(s\)):?\s*'),
    '',
  );
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(displayMessage),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ),
  );
}

Widget buildBookSummary(BuildContext context, Book book) {
  return ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
    leading: Container(
      width: 38,
      height: 42,
      decoration: BoxDecoration(
        color: const Color(0xFFE5F0ED),
        borderRadius: BorderRadius.circular(5),
      ),
      child: const Icon(Icons.menu_book_outlined, color: Color(0xFF187C6D)),
    ),
    title: Text(
      book.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
    subtitle: Text(
      '${book.author.isEmpty ? 'Auteur non renseigné' : book.author} · ${book.accession}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Icon(
      Icons.chevron_right,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
