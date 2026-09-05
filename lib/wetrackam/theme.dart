// lib/wetrackam/theme.dart
//
// Thème visuel WeTrackam Client, isolé du code upstream Traccar Client.
// Palette = celle du rebranding déjà validé (WeTrackam_Brand_Spec), pas la
// variante du contrat d'intégration (légère différence de teinte notée et
// tranchée par le porteur de projet en faveur de cette palette-ci).
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class WetrackamColors {
  WetrackamColors._();

  static const purple = Color(0xFF5E30B4); // WeTrackam Purple — primaire
  static const deepViolet = Color(0xFF3A1B73); // headers, gradients, hover
  static const signalViolet = Color(0xFF9B6DFF); // accent, live states, pins
  static const lilacTint = Color(0xFFF4F0FB); // surfaces claires
  static const ink = Color(0xFF1C1530); // texte, fond sombre
  static const slate = Color(0xFF6B6478); // texte secondaire

  // Couleurs sémantiques (score), non fournies par la charte logo/couleur —
  // reprises des conventions usuelles du produit (à ajuster si le design web
  // définit des valeurs exactes différentes).
  static const success = Color(0xFF2E9E6B); // score >= 80
  static const warning = Color(0xFFE2A03F); // score 50-79
  static const error = Color(0xFFE0533D); // score < 50, vol carburant

  static Color scoreColor(int score) {
    if (score >= 80) return success;
    if (score >= 50) return warning;
    return error;
  }
}

class WetrackamRadii {
  WetrackamRadii._();
  static const double base = 14;
  static final BorderRadius borderRadius = BorderRadius.circular(base);
}

class WetrackamShadows {
  WetrackamShadows._();

  /// Ombre douce teintée violet, élévation 1.
  static List<BoxShadow> elevation1 = [
    BoxShadow(
      color: WetrackamColors.purple.withValues(alpha: 0.35),
      blurRadius: 22,
      offset: const Offset(0, 6),
      spreadRadius: -12,
    ),
  ];
}

class WetrackamTheme {
  WetrackamTheme._();

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      colorScheme: const ColorScheme.light(
        primary: WetrackamColors.purple,
        onPrimary: Colors.white,
        secondary: WetrackamColors.deepViolet,
        onSecondary: Colors.white,
        tertiary: WetrackamColors.signalViolet,
        onTertiary: Colors.white,
        surface: WetrackamColors.lilacTint,
        onSurface: WetrackamColors.ink,
        onSurfaceVariant: WetrackamColors.slate,
        error: WetrackamColors.error,
      ),
      scaffoldBackgroundColor: Colors.white,
      textTheme: _textTheme(base.textTheme, WetrackamColors.ink),
      appBarTheme: const AppBarTheme(
        backgroundColor: WetrackamColors.purple,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: WetrackamRadii.borderRadius),
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: WetrackamColors.purple,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: WetrackamRadii.borderRadius),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? WetrackamColors.signalViolet : null),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? WetrackamColors.purple : null),
      ),
    );
  }

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      colorScheme: const ColorScheme.dark(
        primary: WetrackamColors.signalViolet,
        onPrimary: WetrackamColors.ink,
        secondary: WetrackamColors.purple,
        onSecondary: Colors.white,
        tertiary: WetrackamColors.signalViolet,
        onTertiary: WetrackamColors.ink,
        surface: Color(0xFF211A2E), // Ink légèrement élevé
        onSurface: WetrackamColors.lilacTint,
        onSurfaceVariant: Color(0xFFB8B0C8),
        error: Color(0xFFCF6679),
      ),
      scaffoldBackgroundColor: WetrackamColors.ink,
      textTheme: _textTheme(base.textTheme, WetrackamColors.lilacTint),
      appBarTheme: const AppBarTheme(
        backgroundColor: WetrackamColors.deepViolet,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF211A2E),
        shape: RoundedRectangleBorder(borderRadius: WetrackamRadii.borderRadius),
        elevation: 0,
      ),
    );
  }

  static TextTheme _textTheme(TextTheme fallback, Color onColor) {
    return GoogleFonts.manropeTextTheme(fallback).copyWith(
      headlineMedium: GoogleFonts.poppins(
          fontWeight: FontWeight.w600, color: onColor, letterSpacing: -0.5),
      headlineSmall: GoogleFonts.poppins(
          fontWeight: FontWeight.w600, color: onColor, letterSpacing: -0.5),
      titleLarge: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: onColor),
    );
  }

  /// Police pour l'affichage des scores/chiffres en grand (JetBrains Mono),
  /// à utiliser explicitement sur les widgets de score / coordonnées.
  static TextStyle scoreDigits({double size = 48, Color? color}) {
    return GoogleFonts.jetBrainsMono(
        fontSize: size, fontWeight: FontWeight.w700, color: color ?? WetrackamColors.ink);
  }
}
