import 'package:flutter/material.dart';

/// Definisce i due temi (chiaro/scuro) usati dall'app.
/// Il colore "accent" è usato come seed per generare l'intera palette
/// tramite Material 3 (ColorScheme.fromSeed).
class AppTheme {
  static const Color accent = Color(0xFF4CAF50);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.light,
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF121212),
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
      ),
    );
  }
}
