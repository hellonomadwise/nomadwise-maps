import 'package:flutter/material.dart';

/// Nomadwise design tokens, from the "Nomad Maps Polish" handoff.
/// Legacy names (red/charcoal/amber/lightGrey/gradient) are kept as
/// aliases so older code keeps compiling; they now point at the new
/// palette.
class Brand {
  // ---- ink (text) ----
  static const ink = Color(0xFF142032);
  static const inkSecondary = Color(0xFF5C6773);
  static const inkMuted = Color(0xFF96A0AC);
  static const inkFaint = Color(0xFFB6BEC7);

  // ---- accent (the one red) ----
  static const accent = Color(0xFFE0442E);
  static const accentTint = Color(0xFFFCEEEC);

  // ---- gold (everything coins) ----
  static const gold = Color(0xFFF4B23E);
  static const goldTint = Color(0xFFFDF3DF);
  static const goldTextDark = Color(0xFF8A6A1F); // on goldTint chips
  static const violet = Color(0xFF7B5BD6); // unscreened/discovered pins
  static const goldLink = Color(0xFFB8860B); // gold links/labels

  // ---- feedback ----
  static const success = Color(0xFF3AA657);
  static const successTint = Color(0xFFE8F4EC);

  // ---- surfaces ----
  static const surface = Colors.white;
  static const bg = Color(0xFFF7F8F9);
  static const field = Color(0xFFF3F5F7);
  static const border = Color(0x1A142032); // rgba(20,32,50,.10)
  static const hairline = Color(0x12142032); // rgba(20,32,50,.07)

  // ---- avatar tints (bg, initial) ----
  static const avatarTints = [
    (Color(0xFFDBE7EE), Color(0xFF5C7D92)), // blue
    (Color(0xFFFDF3DF), Color(0xFFA67C1F)), // warm
    (Color(0xFFEEF1F5), Color(0xFF5C6773)), // gray
    (Color(0xFFE3EFE6), Color(0xFF5F8A6B)), // green
  ];

  // ---- shadows ----
  static const shadowResting = [
    BoxShadow(
        color: Color(0x14142032), blurRadius: 4, offset: Offset(0, 1)),
  ];
  static const shadowFloating = [
    BoxShadow(
        color: Color(0x24142032), blurRadius: 10, offset: Offset(0, 2)),
  ];
  static const shadowSheet = [
    BoxShadow(
        color: Color(0x2E142032), blurRadius: 32, offset: Offset(0, 8)),
  ];
  static const shadowRedCta = [
    BoxShadow(
        color: Color(0x4DE0442E), blurRadius: 14, offset: Offset(0, 4)),
  ];
  static const shadowNavyCta = [
    BoxShadow(
        color: Color(0x38142032), blurRadius: 14, offset: Offset(0, 4)),
  ];

  // ---- legacy aliases (older code) ----
  static const red = accent;
  static const charcoal = ink;
  static const amber = gold;
  static const lightGrey = field;
  static const gradientStart = Color(0xFFE8563F);
  static const gradientEnd = Color(0xFFD63A24);
  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gradientStart, gradientEnd],
  );
}

ThemeData nomadwiseTheme() {
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: 'InstrumentSans',
    colorScheme: ColorScheme.fromSeed(
      seedColor: Brand.accent,
      primary: Brand.accent,
      secondary: Brand.gold,
      surface: Brand.surface,
    ),
    scaffoldBackgroundColor: Brand.bg,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: Brand.ink,
      displayColor: Brand.ink,
      // If Instrument Sans ever fails on a device, fall back to
      // Roboto instead of invisible text.
      fontFamilyFallback: ['Roboto'],
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Brand.surface,
      foregroundColor: Brand.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: Border(bottom: BorderSide(color: Brand.hairline)),
      titleTextStyle: TextStyle(
        fontFamily: 'InstrumentSans',
        fontWeight: FontWeight.w700,
        fontSize: 19,
        color: Brand.ink,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      selectedColor: Brand.ink,
      backgroundColor: Brand.surface,
      labelStyle: const TextStyle(
          fontWeight: FontWeight.w600, fontSize: 13, color: Brand.ink),
      side: const BorderSide(color: Brand.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: Brand.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(
            fontFamily: 'InstrumentSans',
            fontWeight: FontWeight.w600,
            fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Brand.ink,
        side: const BorderSide(color: Brand.border),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(
            fontFamily: 'InstrumentSans',
            fontWeight: FontWeight.w600,
            fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Brand.accent,
        textStyle: const TextStyle(
            fontFamily: 'InstrumentSans',
            fontWeight: FontWeight.w600,
            fontSize: 14),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Brand.surface,
      foregroundColor: Brand.accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Brand.surface,
      hintStyle: const TextStyle(color: Brand.inkMuted, fontSize: 14),
      labelStyle: const TextStyle(
          color: Brand.inkSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600),
      helperStyle: const TextStyle(color: Brand.inkMuted, fontSize: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Brand.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Brand.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Brand.ink, width: 1.4),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    ),
    cardTheme: base.cardTheme.copyWith(
      color: Brand.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Brand.border),
      ),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: Brand.surface,
      titleTextStyle: const TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Brand.ink),
      contentTextStyle: const TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 14,
          height: 1.5,
          color: Brand.inkSecondary),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: Brand.ink,
      contentTextStyle: const TextStyle(
          fontFamily: 'InstrumentSans', color: Colors.white, fontSize: 14),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
