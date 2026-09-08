import 'package:flutter/material.dart';

abstract final class AppColors {
  static const black = Color(0xFF000000);
  static const background = Color(0xFF1C1F21);
  static const surface = Color(0xFF181A1B);
  static const surfaceHigh = Color(0xFF232729);
  static const border = Color(0xFF404547);
  static const muted = Color(0xFF888D8F);
  static const text = Color(0xFFE1E2E3);
  static const blue = Color(0xFF1F94FF);
  static const blueDark = Color(0xFF0F3557);
  static const red = Color(0xFFFF4600);
  static const green = Color(0xFF0D9C53);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.blue,
    brightness: Brightness.dark,
    surface: AppColors.surface,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: scheme.copyWith(
      primary: AppColors.blue,
      secondary: AppColors.red,
      surface: AppColors.surface,
      outline: AppColors.border,
    ),
    fontFamily: 'Arial',
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        color: AppColors.text,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      titleLarge: TextStyle(color: AppColors.text, fontWeight: FontWeight.w700),
      bodyLarge: TextStyle(color: AppColors.text, height: 1.45),
      bodyMedium: TextStyle(color: AppColors.muted, height: 1.4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      labelStyle: const TextStyle(color: AppColors.muted),
      hintStyle: TextStyle(color: AppColors.muted.withValues(alpha: 0.75)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.blue, width: 1.5),
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
