import 'package:flutter/material.dart';

class TacticalPalette {
  const TacticalPalette._();

  static const Color panel = Color(0xFF0E1411);
  static const Color panelTranslucent = Color(0xD90E1411);
  static const Color accent = Color(0xFF39FF14);
  static const Color error = Color(0xFFFF3B30);
  static const Color textDim = Color(0xFF9AD9A0);
}

ThemeData buildFalconMapTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1F6FEB),
    brightness: Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFEFEFEF),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: TacticalPalette.panel,
      contentTextStyle: TextStyle(color: TacticalPalette.accent),
    ),
  );
}
