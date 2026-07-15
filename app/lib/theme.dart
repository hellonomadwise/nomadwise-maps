import 'package:flutter/material.dart';

/// Nomadwise brand palette — from brandfinal (locked).
class Brand {
  static const red = Color(0xFFFF444F); // Nomadwise Red
  static const gradientStart = Color(0xFFFF5A63); // icon gradient
  static const gradientEnd = Color(0xFFF4303C);
  static const charcoal = Color(0xFF1F2C3D);
  static const lightGrey = Color(0xFFF7F7F7);
  static const amber = Color(0xFFF8B34B); // coins & stars

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gradientStart, gradientEnd],
  );
}

ThemeData nomadwiseTheme() {
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: 'Roboto',
    colorScheme: ColorScheme.fromSeed(
      seedColor: Brand.red,
      primary: Brand.red,
      secondary: Brand.amber,
      surface: Colors.white,
    ),
    scaffoldBackgroundColor: Colors.white,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Brand.charcoal,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Roboto',
        fontWeight: FontWeight.w900,
        fontSize: 20,
        color: Brand.charcoal,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      selectedColor: Brand.red,
      backgroundColor: Colors.white,
      labelStyle: const TextStyle(fontWeight: FontWeight.w500),
      side: const BorderSide(color: Color(0xFFE4E7EB)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: Brand.red,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Brand.red,
      foregroundColor: Colors.white,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Brand.lightGrey,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
  );
}
