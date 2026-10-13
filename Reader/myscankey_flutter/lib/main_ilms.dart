import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'screens/ilms_app.dart';

// Separate target: never constructs the legacy controller or Render sync.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  runApp(const IlmsApp());
}
