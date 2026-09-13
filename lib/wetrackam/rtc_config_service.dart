// lib/wetrackam/rtc_config_service.dart
//
// Lot 5 (contrat v5 §4, §2, ANALYSE-temps-reel-voip.md §7.14/§7.15).
//
// Deux états d'échec à ne pas confondre :
//  - §7.15 "module non configuré" (503 rtcNotConfigured sur /rtc/config
//    lui-même) → `isAvailable == false`, masquage SILENCIEUX. C'est le cas
//    géré ici.
//  - §7.14 "service temps réel arrêté" (/rtc/config répond enabled:true,
//    mais la connexion WebSocket échoue ensuite) → bannière visible
//    "Communication indisponible", PAS un masquage. Ce cas relève du
//    Lot 6 (connexion WebSocket elle-même) ; ce service expose déjà
//    correctement `enabled: true` dans cette situation, comme il se doit.
import 'dart:async';

import 'api_client.dart';
import 'app_logger.dart';

class RtcPolicy {
  final bool callsEnabled;
  final bool chatEnabled;
  final String fleetVisibility; // 'onDuty' | 'tenant' | 'none'
  final String directoryScope; // 'tenant' | 'onDuty'
  final bool showPhone;
  final int speedLockKmh;
  final int voiceMaxSeconds;
  final int retentionDays;

  const RtcPolicy({
    required this.callsEnabled,
    required this.chatEnabled,
    required this.fleetVisibility,
    required this.directoryScope,
    required this.showPhone,
    required this.speedLockKmh,
    required this.voiceMaxSeconds,
    required this.retentionDays,
  });

  /// Correctif v13 — INCOHÉRENCE MORTELLE trouvée en audit croisé : le
  /// serveur envoie les énumérations en SCREAMING_SNAKE_CASE
  /// (`ON_DUTY`, `NONE`, `TENANT` — voir CommSettings.java §52-53), alors
  /// que tout le client comparait des valeurs camelCase (`'none'`,
  /// `'onDuty'`). Conséquences réelles observées : un tenant qui coupait la
  /// carte des collègues (`NONE`) la voyait rester active côté chauffeur,
  /// et l'annuaire ignorait la portée demandée. Aucune erreur n'était
  /// journalisée : les comparaisons échouaient simplement toujours.
  ///
  /// La normalisation est faite ICI, au seul point d'entrée des données
  /// serveur, et non dans chaque écran : c'est la seule façon de garantir
  /// qu'un futur écran ne réintroduise pas le bug. Le reste de
  /// l'application ne manipule QUE du camelCase.
  static String normalizeEnum(Object? raw, {required String fallback}) {
    if (raw is! String || raw.trim().isEmpty) return fallback;
    final v = raw.trim();
    switch (v.toUpperCase()) {
      case 'ON_DUTY':
      case 'ONDUTY':
        return 'onDuty';
      case 'NONE':
        return 'none';
      case 'TENANT':
        return 'tenant';
      case 'ALL':
        return 'tenant'; // synonyme historique côté console
      default:
        // Valeur inconnue : fail-close explicite plutôt qu'un affichage
        // au hasard — et une trace, car c'est un signe de désynchronisation
        // entre versions serveur et mobile.
        AppLogger.breadcrumb('rtc_policy_unknown_enum:$v');
        return fallback;
    }
  }

  factory RtcPolicy.fromJson(Map<String, dynamic> json) => RtcPolicy(
        callsEnabled: json['callsEnabled'] == true,
        chatEnabled: json['chatEnabled'] == true,
        fleetVisibility: normalizeEnum(json['fleetVisibility'], fallback: 'none'),
        directoryScope: normalizeEnum(json['directoryScope'], fallback: 'tenant'),
        showPhone: json['showPhone'] == true,
        speedLockKmh: (json['speedLockKmh'] as num?)?.toInt() ?? 0,
        voiceMaxSeconds: (json['voiceMaxSeconds'] as num?)?.toInt() ?? 120,
        retentionDays: (json['retentionDays'] as num?)?.toInt() ?? 90,
      );

  /// Repli total si le module est masqué : tout désactivé, jamais un champ
  /// à moitié initialisé qui laisserait un bouton actif par erreur.
  static const disabled = RtcPolicy(
    callsEnabled: false,
    chatEnabled: false,
    fleetVisibility: 'none',
    directoryScope: 'tenant',
    showPhone: false,
    speedLockKmh: 0,
    voiceMaxSeconds: 0,
    retentionDays: 0,
  );
}

class RtcIceServer {
  final List<String> urls;
  final String? username;
  final String? credential;
  final String? credentialType;
  final int? expiresAt; // epoch secondes

  const RtcIceServer({
    required this.urls,
    this.username,
    this.credential,
    this.credentialType,
    this.expiresAt,
  });

  factory RtcIceServer.fromJson(Map<String, dynamic> json) => RtcIceServer(
        urls: (json['urls'] as List).cast<String>(),
        username: json['username'] as String?,
        credential: json['credential'] as String?,
        credentialType: json['credentialType'] as String?,
        expiresAt: (json['expiresAt'] as num?)?.toInt(),
      );
}

class RtcConfig {
  final bool enabled;
  final String? wsUrl;
  final String? httpUrl;
  final RtcPolicy policy;
  final List<RtcIceServer> iceServers;

  const RtcConfig({
    required this.enabled,
    this.wsUrl,
    this.httpUrl,
    required this.policy,
    required this.iceServers,
  });

  factory RtcConfig.fromJson(Map<String, dynamic> json) => RtcConfig(
        enabled: json['enabled'] == true,
        wsUrl: json['wsUrl'] as String?,
        httpUrl: json['httpUrl'] as String?,
        policy: json['policy'] != null
            ? RtcPolicy.fromJson(json['policy'] as Map<String, dynamic>)
            : RtcPolicy.disabled,
        iceServers: (json['iceServers'] as List? ?? [])
            .map((e) => RtcIceServer.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// §7.15 : module non configuré ou tout autre échec de récupération —
  /// jamais un état "à moitié disponible".
  static const masked = RtcConfig(enabled: false, policy: RtcPolicy.disabled, iceServers: []);
}

class RtcConfigService {
  RtcConfigService._();

  static RtcConfig _current = RtcConfig.masked;
  static Timer? _pollTimer;

  static RtcConfig get current => _current;
  static bool get isAvailable => _current.enabled;

  /// À appeler après authentification (même timing que le push, Lot 4) :
  /// une récupération immédiate puis un polling toutes les ~10 min (§2).
  static Future<void> start() async {
    await _refresh();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(minutes: 10), (_) => _refresh());
  }

  /// À appeler sur purge (token ou totale) : plus de session valide pour
  /// interroger `/rtc/config`, et un module "disponible" affiché après
  /// déconnexion serait trompeur.
  static void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _current = RtcConfig.masked;
  }

  static Future<void> _refresh() async {
    try {
      final json = await WetrackamApiClient.fetchRtcConfig();
      _current = RtcConfig.fromJson(json);
      AppLogger.breadcrumb('rtc_config_refreshed:enabled=${_current.enabled}');
    } on ApiException catch (error) {
      // §7.15 : rtcNotConfigured n'est pas une erreur à remonter, c'est
      // l'état normal d'un tenant qui n'a pas activé le module — masquage
      // silencieux, aucune trace visible pour le chauffeur.
      if (error.error == 'rtcNotConfigured') {
        _current = RtcConfig.masked;
        return;
      }
      // Tout autre échec (réseau, 401, 500...) : on masque aussi par
      // prudence (fail-close, cohérent avec le reste du contrat) mais on
      // journalise, car ce n'est pas un cas normal contrairement au
      // précédent.
      AppLogger.error('rtc_config_refresh_failed', error);
      _current = RtcConfig.masked;
    } catch (error) {
      AppLogger.error('rtc_config_refresh_failed', error);
      _current = RtcConfig.masked;
    }
  }

  /// §4 règles : "Les iceServers expirent (expiresAt, 120 s). Les
  /// récupérer juste avant de créer une RTCPeerConnection, pas au
  /// lancement." — méthode dédiée pour le Lot 8, séparée du polling
  /// général ci-dessus qui ne doit PAS servir à alimenter un appel.
  static Future<List<RtcIceServer>> refreshIceServersForCall() async {
    await _refresh();
    return _current.iceServers;
  }
}
