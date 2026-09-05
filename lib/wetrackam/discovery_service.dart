// lib/wetrackam/discovery_service.dart
//
// DELTA-v6-vers-v7-ADRESSAGE.md — chantier B. L'app ne compose plus aucune
// URL : GET /api/discovery fournit endpoints.api/rtcWs/media, utilisés
// tels quels. serverId (posé à l'appairage, voir tls_pinning.dart — même
// valeur, une seule source) est le SEUL élément qui autorise l'adoption
// d'une nouvelle adresse.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'driver_identity_service.dart';
import 'tls_pinning.dart';

class DiscoveryService {
  DiscoveryService._();

  static const _keyApiBase = 'wetrackam_disc_api_base';
  static const _keyRtcWs = 'wetrackam_disc_rtc_ws';
  static const _keyRtcHttp = 'wetrackam_disc_rtc_http';
  static const _keyMedia = 'wetrackam_disc_media';
  static const _keyOrigins = 'wetrackam_disc_origins';
  static const _keyRebasedAt = 'wetrackam_disc_rebased_at';
  static const _keyPreviousBase = 'wetrackam_disc_previous_base';

  static String? _apiBase;
  static String? _rtcWs;
  static String? _rtcHttp;
  static String? _media;
  static List<String> _origins = [];
  static String? _rebasedAt;
  static String? _previousBase;

  /// Consommé par api_client.dart::_uri() — repli sur l'adresse de
  /// provisionnement tant qu'aucune découverte n'a encore réussi (tout
  /// premier lancement, avant le premier /api/discovery).
  static String? get apiBase => _apiBase;
  static String? get rtcWs => _rtcWs;
  static String? get media => _media;

  static final _rebaseController = StreamController<void>.broadcast();
  /// Signal "l'adresse a changé" — realtime_service.dart s'y abonne pour
  /// rouvrir la socket sur le nouveau rtcWs, sans jamais couper la session.
  static Stream<void> get onRebase => _rebaseController.stream;

  static Future<void> restoreFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    _apiBase = prefs.getString(_keyApiBase);
    _rtcWs = prefs.getString(_keyRtcWs);
    _rtcHttp = prefs.getString(_keyRtcHttp);
    _media = prefs.getString(_keyMedia);
    _origins = prefs.getStringList(_keyOrigins) ?? [];
    _rebasedAt = prefs.getString(_keyRebasedAt);
    _previousBase = prefs.getString(_keyPreviousBase);
    // Ces adresses ont été adoptées antérieurement depuis une réponse
    // /api/discovery reçue sur un canal épinglé et avec le bon serverId.
    // Les réautoriser au redémarrage est indispensable avant le premier GET ;
    // le contrôle SPKI reste appliqué à chaque connexion.
    for (final value in [
      if (_apiBase != null) _apiBase!,
      if (_rtcWs != null) _rtcWs!,
      if (_rtcHttp != null) _rtcHttp!,
      if (_media != null) _media!,
      if (_previousBase != null) _previousBase!,
      ..._origins,
    ]) {
      TlsPinning.setExpectedHost(value);
    }
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [_keyApiBase, _keyRtcWs, _keyRtcHttp, _keyMedia, _keyOrigins, _keyRebasedAt, _keyPreviousBase]) {
      await prefs.remove(k);
    }
    _apiBase = null;
    _rtcWs = null;
    _rtcHttp = null;
    _media = null;
    _origins = [];
    _rebasedAt = null;
    _previousBase = null;
  }

  /// À appeler une fois, juste après le provisionnement (driver_identity_
  /// service.dart::completeProvisioning) : amorce l'adresse API sur
  /// l'adresse de pairage, en attendant la première découverte réussie.
  static Future<void> bootstrap(String pairingBase) async {
    _apiBase ??= pairingBase;
    await refresh();
  }

  /// "Au démarrage, et après des erreurs réseau répétées." Utilise
  /// systématiquement le client épinglé (tls_pinning.dart) : /api/discovery
  /// est un endpoint public, mais reste servi par le même serveur/la même
  /// clé que le reste — pas de raison de le sortir de l'épinglage.
  static Future<void> refresh() async {
    final candidates = <String>[
      if (_apiBase != null) _apiBase!,
      ..._origins,
      if (_previousBase != null) _previousBase!,
      if (DriverIdentityService.provisioning?.serverUrl != null)
        DriverIdentityService.provisioning!.serverUrl,
    ];
    for (final candidate in candidates.toSet()) {
      try {
        final client = TlsPinning.pinnedHttpClient(connectionTimeout: const Duration(seconds: 10));
        late final http.Response response;
        try {
          response = await client
              .get(Uri.parse('$candidate/api/discovery'), headers: {'Accept': 'application/json'})
              .timeout(const Duration(seconds: 15));
        } finally {
          client.close();
        }
        if (response.statusCode != 200) continue;
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        await _applyDiscovery(body, source: candidate);
        return;
      } catch (error) {
        AppLogger.error('discovery_candidate_failed', '$candidate: $error');
        continue; // §6 échelle de repli : ce candidat a échoué, essayer le suivant
      }
    }
    AppLogger.error('discovery_all_candidates_failed', candidates.join(','));
  }

  static Future<void> _applyDiscovery(Map<String, dynamic> body, {required String source}) async {
    final serverId = body['serverId'] as String?;
    // §2/§8 : serverId est LE seul élément qui autorise d'adopter cette
    // réponse — un serveur qui répondrait sur cette adresse sans porter le
    // bon serverId n'est structurellement pas le nôtre.
    if (TlsPinning.serverId == null || serverId != TlsPinning.serverId) {
      AppLogger.error('discovery_server_id_mismatch', '$serverId != ${TlsPinning.serverId}');
      return;
    }
    final endpoints = body['endpoints'] as Map<String, dynamic>? ?? {};
    _previousBase = _apiBase != source ? _apiBase : _previousBase;
    final nextApi = (endpoints['api'] as String?) ?? source;
    final nextRtcWs = endpoints['rtcWs'] as String?;
    final nextRtcHttp = endpoints['rtcHttp'] as String?;
    final nextMedia = endpoints['media'] as String?;
    final nextOrigins = (endpoints['origins'] as List?)?.cast<String>() ?? _origins;
    final urls = [nextApi, if (nextRtcWs != null) nextRtcWs,
      if (nextRtcHttp != null) nextRtcHttp, if (nextMedia != null) nextMedia,
      ...nextOrigins];
    if (urls.any((value) {
      final uri = Uri.tryParse(value);
      return uri == null || !uri.hasAuthority ||
          !const {'https', 'http', 'wss', 'ws'}.contains(uri.scheme);
    })) {
      AppLogger.error('discovery_invalid_endpoint', source);
      return;
    }
    // La réponse vient d'un hôte déjà épinglé et porte le bon serverId : ses
    // autres origines deviennent autorisées, mais resteront soumises au même
    // jeu d'empreintes SPKI lors de leur première connexion.
    for (final value in urls) {
      TlsPinning.setExpectedHost(value);
    }
    _apiBase = nextApi;
    _rtcWs = nextRtcWs;
    _rtcHttp = nextRtcHttp;
    _media = nextMedia;
    _origins = nextOrigins;
    final newRebasedAt = body['rebasedAt'] as String?;
    final changed = newRebasedAt != null && newRebasedAt != _rebasedAt;
    _rebasedAt = newRebasedAt;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiBase, _apiBase!);
    if (_rtcWs != null) await prefs.setString(_keyRtcWs, _rtcWs!);
    if (_rtcHttp != null) await prefs.setString(_keyRtcHttp, _rtcHttp!);
    if (_media != null) await prefs.setString(_keyMedia, _media!);
    await prefs.setStringList(_keyOrigins, _origins);
    if (_rebasedAt != null) await prefs.setString(_keyRebasedAt, _rebasedAt!);
    if (_previousBase != null) await prefs.setString(_keyPreviousBase, _previousBase!);

    AppLogger.breadcrumb('discovery_applied:base=$_apiBase,changed=$changed');
    if (changed) _rebaseController.add(null);
  }

  /// §8.a — message `control` `server.rebased` reçu sur la socket ouverte.
  /// "Sans déconnecter le chauffeur, sans interrompre le service en
  /// cours" : ne touche NI à la session NI au service actif — seule
  /// l'adresse réseau change, silencieusement pour le chauffeur.
  static Future<void> handleRebasedEvent(Map<String, dynamic> message) async {
    final serverId = message['serverId'] as String?;
    if (TlsPinning.serverId != null && serverId != TlsPinning.serverId) {
      // §8.a : "Si le serverId diffère, ignorer et journaliser." Ce n'est
      // pas notre serveur qui parle — traiter comme un incident, pas
      // comme une bascule légitime.
      AppLogger.error('server_rebased_ignored_wrong_serverId', serverId ?? 'null');
      return;
    }
    final newBase = message['base'] as String?;
    if (newBase == null) return;
    final newUri = Uri.tryParse(newBase);
    if (newUri == null || !newUri.hasAuthority ||
        !const {'https', 'http'}.contains(newUri.scheme)) {
      AppLogger.error('server_rebased_ignored_invalid_base', newBase);
      return;
    }
    // Message reçu sur la socket déjà épinglée et lié au serverId attendu.
    // Autorise l'hôte avant la découverte, sans jamais désactiver le pin SPKI.
    TlsPinning.setExpectedHost(newBase);
    _previousBase = message['previousBase'] as String? ?? _apiBase;
    _apiBase = newBase;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiBase, _apiBase!);
    if (_previousBase != null) await prefs.setString(_keyPreviousBase, _previousBase!);
    AppLogger.breadcrumb('server_rebased_applied:$newBase');
    // Récupère le jeu complet d'endpoints (rtcWs notamment) à la nouvelle
    // adresse avant de signaler le changement — realtime_service.dart a
    // besoin du nouveau rtcWs pour rouvrir la socket au bon endroit.
    await refresh();
  }
}
