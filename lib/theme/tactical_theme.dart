import 'package:flutter/material.dart';

class TacticalPalette {
  const TacticalPalette._();

  static const Color scaffold = Color(0xFFF4F6FA);
  static const Color panel = Color(0xFFFFFFFF);
  static const Color panelTranslucent = Color(0xE6FFFFFF);
  static const Color accent = Color(0xFF2563EB);
  static const Color accentSoft = Color(0xFFEEF2FF);
  static const Color error = Color(0xFFDC2626);
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textDim = Color(0xFF64748B);
  static const Color divider = Color(0xFFE2E8F0);
}

ThemeData buildFalconMapTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: TacticalPalette.accent,
    brightness: Brightness.light,
  ).copyWith(
    surface: TacticalPalette.panel,
    onSurface: TacticalPalette.textPrimary,
    primary: TacticalPalette.accent,
    error: TacticalPalette.error,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: TacticalPalette.scaffold,
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: TacticalPalette.panel,
      foregroundColor: TacticalPalette.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: TacticalPalette.panel,
    ),
    dividerColor: TacticalPalette.divider,
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: TacticalPalette.textPrimary,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: TacticalPalette.panel,
      foregroundColor: TacticalPalette.accent,
      elevation: 3,
    ),
  );
}
