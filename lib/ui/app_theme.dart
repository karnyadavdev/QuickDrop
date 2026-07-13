import 'package:flutter/material.dart';

class AppColors {
  static Color get background => const Color(0xFF020A0B);
  static Color get surface => const Color(0xFF091413);
  static Color get surfaceBright => const Color(0xFF12201D);
  static const accent = Color(0xFF72E596);
  static const darkAccent = Color(0xFF429E68);
  static const red = Color(0xFFFF6B7A);
  static const warning = Color(0xFFF2C35B);
  static const green = Color(0xFF72E596);
  static Color get text => const Color(0xFFF1F5F2);
  static Color get muted => const Color(0xFF91A29A);
  static Color get border => const Color(0xFF263A32);
  static Color get card => const Color(0xFF07110F);
  static final softLine = Colors.white.withAlpha(12);
  static final progressTrack = Colors.white.withAlpha(10);
}

ThemeData buildAppTheme() {
  final colors = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
    primary: AppColors.accent,
    secondary: AppColors.darkAccent,
    surface: AppColors.surface,
    error: AppColors.red,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colors,
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Manrope',
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerColor: Colors.white.withAlpha(18),
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: AppColors.green.withAlpha(8),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: const Color(0xFF062111),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
        side: BorderSide(color: Colors.white.withAlpha(35)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withAlpha(9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withAlpha(26)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
    ),
  );
}
