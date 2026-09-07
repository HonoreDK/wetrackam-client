import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wetrackam_client/l10n/app_localizations.dart';
import 'package:wetrackam_client/preferences.dart';

class PasswordService {
  static final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  static const String _passwordKey = 'password';

  /// Correction sécurité : cette méthode déplaçait autrefois le mot de passe
  /// HORS du stockage sécurisé chiffré vers SharedPreferences en clair — une
  /// régression, pas une migration (toute sauvegarde du téléphone ou lecture
  /// sur un appareil rooté récupérait alors le mot de passe en clair). Le
  /// sens est inversé ici : si un mot de passe existe dans l'ancien
  /// emplacement en clair (installation antérieure à ce correctif), il est
  /// rapatrié dans le stockage sécurisé puis effacé de l'emplacement en
  /// clair — jamais l'inverse.
  static Future<void> migrate() async {
    final plaintextPassword = Preferences.instance.getString(_passwordKey);
    if (plaintextPassword != null) {
      await _secureStorage.write(key: _passwordKey, value: plaintextPassword);
      await Preferences.instance.remove(_passwordKey);
    }
  }

  static Future<bool> authenticate(BuildContext context) async {
    final storedPassword = await _secureStorage.read(key: _passwordKey);
    if (storedPassword == null || storedPassword.isEmpty) return true;
    final controller = TextEditingController();
    bool? result;
    if (context.mounted) {
      result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(labelText: AppLocalizations.of(context)!.passwordLabel),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: Text(AppLocalizations.of(context)!.cancelButton),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context, _constantTimeEquals(storedPassword, controller.text));
              },
              child: Text(AppLocalizations.of(context)!.okButton),
            ),
          ],
        ),
      );
    }
    // `null` = boîte annulée ou fermée sans choix ; distinct de `false` (mot
    // de passe saisi mais incorrect) — l'un ne doit pas afficher le message
    // d'erreur de l'autre (bug corrigé : Annuler affichait "mot de passe
    // incorrect" comme une vraie erreur de saisie).
    if (result == null) return false;
    if (result == false && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.passwordError)),
      );
      return false;
    }
    return result;
  }

  /// Comparaison à temps constant : la longueur de la boucle ne dépend
  /// jamais du nombre de caractères corrects trouvés, contrairement à `==`
  /// qui peut retourner dès le premier octet différent (attaque par
  /// mesure de temps, à faible impact ici puisque la boîte de dialogue
  /// locale ne peut de toute façon pas être automatisée à grande vitesse,
  /// mais sans coût à corriger).
  static bool _constantTimeEquals(String expected, String actual) {
    final expectedBytes = utf8.encode(expected);
    final actualBytes = utf8.encode(actual);
    var diff = expectedBytes.length ^ actualBytes.length;
    final length = expectedBytes.length > actualBytes.length ? expectedBytes.length : actualBytes.length;
    for (var i = 0; i < length; i++) {
      final a = i < expectedBytes.length ? expectedBytes[i] : 0;
      final b = i < actualBytes.length ? actualBytes[i] : 0;
      diff |= a ^ b;
    }
    return diff == 0;
  }

  static Future<void> setPassword(String password) async {
    if (password.isNotEmpty) {
      await _secureStorage.write(key: _passwordKey, value: password);
    } else {
      await _secureStorage.delete(key: _passwordKey);
    }
  }
}
