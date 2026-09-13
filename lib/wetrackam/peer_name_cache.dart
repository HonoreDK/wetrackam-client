// lib/wetrackam/peer_name_cache.dart
//
// v13 — cache persistant « driverId → nom affichable ».
//
// POURQUOI. Le protocole d'appel ne transporte AUCUN nom : ni
// `call.incoming` (callId, peerId, sdp, timeoutSeconds), ni le push FCM
// (callerId, callId, ringTimeoutSeconds). Le serveur ne peut pas les
// ajouter sans coût : les claims du ticket ne contiennent pas le nom, et
// aller le chercher en base à chaque invitation ajouterait une requête sur
// le chemin le plus sensible à la latence.
//
// Or l'écran d'appel plein écran natif s'affiche AVANT toute connexion
// (application tuée, écran verrouillé) : sans cache local, le chauffeur
// verrait « Appel entrant » sans savoir qui appelle — inacceptable en
// exploitation, où l'on décroche différemment selon l'interlocuteur.
//
// Le cache est alimenté à chaque fois qu'un nom transite légitimement
// (annuaire, carte des collègues, appel sortant) et relu par le handler
// push, y compris dans l'isolate d'arrière-plan où aucun état mémoire de
// l'application n'existe — d'où SharedPreferences plutôt qu'une variable.
//
// Il ne contient QUE des noms déjà visibles par ce chauffeur dans son
// tenant : aucune fuite inter-tenant possible, il est purgé à la
// déconnexion comme les autres données de session.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

class PeerNameCache {
  PeerNameCache._();

  static const _key = 'wetrackam_peer_names';
  static const _maxEntries = 300; // une flotte réaliste, borne mémoire

  static Map<String, String>? _memory;

  static Future<Map<String, String>> _load() async {
    if (_memory != null) return _memory!;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      _memory = raw == null
          ? <String, String>{}
          : Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (error) {
      AppLogger.error('peer_name_cache_load_failed', error);
      _memory = <String, String>{};
    }
    return _memory!;
  }

  /// Enregistre un nom. Ignore silencieusement les valeurs vides ou les
  /// tirets de remplissage : mieux vaut un repli générique qu'un « — »
  /// affiché en gros sur l'écran d'appel.
  static Future<void> remember(int driverId, String? name) async {
    final clean = (name ?? '').trim();
    if (driverId <= 0 || clean.isEmpty || clean == '—') return;
    final map = await _load();
    if (map['$driverId'] == clean) return; // rien à écrire
    if (map.length >= _maxEntries) map.remove(map.keys.first);
    map['$driverId'] = clean;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(map));
    } catch (error) {
      AppLogger.error('peer_name_cache_write_failed', error);
    }
  }

  /// Enregistre en lot (retours d'annuaire et de carte des collègues).
  static Future<void> rememberAll(
      Iterable<Map<String, dynamic>> rows, String nameField) async {
    for (final row in rows) {
      final id = row['driverId'];
      if (id is int) await remember(id, row[nameField]?.toString());
    }
  }

  /// Nom connu, ou `null`. Utilisable depuis l'isolate d'arrière-plan FCM.
  static Future<String?> lookup(int driverId) async {
    final map = await _load();
    return map['$driverId'];
  }

  /// Libellé toujours affichable pour l'écran d'appel natif.
  static Future<String> displayName(int driverId) async =>
      await lookup(driverId) ?? 'Collègue';

  /// Purge — branchée sur les hooks de purge de session : un nom de
  /// collègue est une donnée du tenant, elle ne survit pas à la session.
  static Future<void> purge() async {
    _memory = <String, String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (error) {
      AppLogger.error('peer_name_cache_purge_failed', error);
    }
  }
}
