import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/cote.dart';

class CataloguingPreferences {
  const CataloguingPreferences({
    this.prefixes = defaultGenrePrefixes,
    this.labelWidthMm = 60,
    this.labelHeightMm = 40,
  });

  final Map<String, String> prefixes;
  final double labelWidthMm;
  final double labelHeightMm;

  static Future<CataloguingPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('cataloguing_prefixes');
    return CataloguingPreferences(
      prefixes: raw == null
          ? defaultGenrePrefixes
          : Map<String, String>.from(jsonDecode(raw) as Map),
      labelWidthMm: prefs.getDouble('cataloguing_label_width') ?? 60,
      labelHeightMm: prefs.getDouble('cataloguing_label_height') ?? 40,
    );
  }

  Future<void> save() async {
    if (!labelWidthMm.isFinite ||
        !labelHeightMm.isFinite ||
        labelWidthMm < 20 ||
        labelWidthMm > 200 ||
        labelHeightMm < 20 ||
        labelHeightMm > 200) {
      throw const FormatException(
        'Les dimensions doivent être comprises entre 20 et 200 mm.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cataloguing_prefixes', jsonEncode(prefixes));
    await prefs.setDouble('cataloguing_label_width', labelWidthMm);
    await prefs.setDouble('cataloguing_label_height', labelHeightMm);
  }
}
