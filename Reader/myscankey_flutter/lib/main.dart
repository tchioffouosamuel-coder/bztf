import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
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
      theme: ThemeData(
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
      ),
      darkTheme: ThemeData(
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
      ),
      home: BiblioShell(controller: widget.controller),
    ),
  );
}
