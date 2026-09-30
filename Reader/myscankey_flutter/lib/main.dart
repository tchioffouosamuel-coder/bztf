import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'screens/device_role_screen.dart';
import 'screens/gate_screen.dart';
import 'screens/kiosk_screen.dart';
import 'screens/login_screen.dart';
import 'services/library_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  runApp(BiblioRfidApp(controller: LibraryController()));
}

class BiblioRfidApp extends StatefulWidget {
  const BiblioRfidApp({required this.controller, super.key});

  final LibraryController controller;

  @override
  State<BiblioRfidApp> createState() => _BiblioRfidAppState();
}

class _BiblioRfidAppState extends State<BiblioRfidApp> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Bibliothèque ZTF',
      themeMode: widget.controller.darkTheme ? ThemeMode.dark : ThemeMode.light,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      home: widget.controller.startupError != null
          ? _StartupErrorScreen(controller: widget.controller)
          : !widget.controller.initialized
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : widget.controller.currentUser == null
          ? LoginScreen(controller: widget.controller)
          : switch (widget.controller.deviceRole) {
              null => DeviceRoleScreen(controller: widget.controller),
              'kiosk' => KioskScreen(
                controller: widget.controller,
                asHome: true,
              ),
              'gate' => GateScreen(controller: widget.controller, asHome: true),
              _ => BiblioShell(controller: widget.controller),
            },
    ),
  );
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 56,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              const Text(
                'L’application n’a pas pu s’ouvrir.',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 8),
              SelectableText(
                controller.startupError ?? '',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: controller.initialize,
                icon: const Icon(Icons.refresh),
                label: const Text('Réessayer'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// Thèmes construits une seule fois : l'application se reconstruit à chaque
// rafraîchissement du contrôleur (lecture RFID en cours comprise).
final ThemeData _lightTheme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Montserrat',
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF0B659E),
        brightness: Brightness.light,
      ).copyWith(
        primary: const Color(0xFF0B659E),
        surface: Colors.white,
        onSurface: const Color(0xFF152B3B),
        onSurfaceVariant: const Color(0xFF637685),
      ),
  scaffoldBackgroundColor: const Color(0xFFF4F7FA),
  cardTheme: const CardThemeData(
    color: Colors.white,
    elevation: 0,
    margin: EdgeInsets.zero,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFFD6E1E8)),
    ),
  ),
);

final ThemeData _darkTheme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Montserrat',
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF55AFE1),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFF55AFE1),
        surface: const Color(0xFF17232D),
        onSurface: const Color(0xFFEEF5F9),
        onSurfaceVariant: const Color(0xFFA1B1BC),
      ),
  scaffoldBackgroundColor: const Color(0xFF0E171F),
  cardTheme: const CardThemeData(
    color: Color(0xFF17232D),
    elevation: 0,
    margin: EdgeInsets.zero,
  ),
);
