// lib/wetrackam/device_identity.dart
//
// Contrat v4 §3.2/§4.5 : X-Device-Id est un UUID généré au PREMIER
// lancement et persisté À VIE (ne doit jamais changer, y compris entre
// mises à jour de l'app — seule une réinstallation en génère un nouveau,
// scénario 32 explicitement accepté par le contrat).
//
// Stocké en SharedPreferences (non sensible : c'est une empreinte
// d'installation, pas un secret) plutôt qu'en secure storage, pour éviter
// toute confusion avec le token (qui, lui, DOIT être en stockage chiffré).
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceIdentity {
  DeviceIdentity._();

  static const _key = 'wetrackam_device_id';
  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_key, id);
    }
    _cached = id;
    return id;
  }

  static String userAgent() {
    final platform = Platform.isAndroid ? 'Android' : Platform.isIOS ? 'iOS' : 'Unknown';
    return 'WeTrackamClient/1.0 ($platform)';
  }
}
