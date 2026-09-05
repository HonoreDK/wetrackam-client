// lib/wetrackam/shift_service.dart
//
// Possède le cycle de vie du service (§7-9) : prise de service idempotente
// (X-Request-Id réutilisé sur retry réseau/500), battement de cœur
// /shift/current (5 min), configuration dynamique avec ETag (15 min), et
// l'obligation de vidage de la file avant purge en fin de service (§9).
import 'dart:async';

import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'app_logger.dart';
import 'driver_identity_service.dart';
import 'geolocation_bridge.dart';
import 'local_notifications_service.dart';

class ShiftThresholds {
  final int idleMinutes;
  final int fatigueMinutes;
  final int nightStartHour;
  final int nightEndHour;
  final bool nightAllowed;
  const ShiftThresholds({
    required this.idleMinutes,
    required this.fatigueMinutes,
    required this.nightStartHour,
    required this.nightEndHour,
    required this.nightAllowed,
  });

  factory ShiftThresholds.fromConfig(Map<String, dynamic> config) {
    final t = config['thresholds'] as Map<String, dynamic>? ?? {};
    final night = config['night'] as Map<String, dynamic>? ?? {};
    return ShiftThresholds(
      idleMinutes: (t['idleMinutes'] as num?)?.toInt() ?? 5,
      fatigueMinutes: (t['fatigueMinutes'] as num?)?.toInt() ?? 240,
      nightStartHour: (t['nightStartHour'] as num?)?.toInt() ?? 21,
      nightEndHour: (t['nightEndHour'] as num?)?.toInt() ?? 5,
      nightAllowed: night['allowed'] != false,
    );
  }
}

class ShiftService {
  ShiftService._();

  static String? _currentDeviceUniqueId;
  static String? _pendingRequestId; // §7 : rejoué tel quel sur retry
  static Timer? _heartbeatTimer;
  static Timer? _configTimer;
  static String? _configEtag;
  static ShiftThresholds? thresholds;
  static void Function(bool active)? onForcedClosure;

  static bool get isActive => _currentDeviceUniqueId != null;
  static String? get currentDeviceUniqueId => _currentDeviceUniqueId;

  /// §7 : idempotence stricte — le MÊME X-Request-Id est réutilisé pour
  /// toute nouvelle tentative tant que la précédente n'a pas définitivement
  /// échoué (erreur non retryable) ou réussi.
  static Future<Map<String, dynamic>> start({String? deviceUniqueId}) async {
    _pendingRequestId ??= const Uuid().v4();
    try {
      final response = await WetrackamApiClient.shiftStart(
        requestId: _pendingRequestId!,
        deviceUniqueId: deviceUniqueId,
      );
      // Garde-fou trouvé en audit de cohérence croisée : entre le départ
      // de cette requête et sa résolution, une purge (401 sur un tout
      // autre appel concurrent, "Réinitialiser l'appareil", dérive
      // tenant...) a pu invalider la session. Sans cette vérification, un
      // /shift/start qui aboutit APRÈS coup "ressusciterait" silencieusement
      // deviceUniqueId et l'envoi de positions pour une session déjà morte.
      if (!DriverIdentityService.isAuthenticated) {
        AppLogger.breadcrumb('shift_start_discarded_session_purged_meanwhile');
        return response;
      }
      _pendingRequestId = null; // succès (ou replay) : plus besoin de le rejouer
      _currentDeviceUniqueId = response['deviceUniqueId'] as String;
      await GeolocationBridge.refreshDriverIdentity();
      _startHeartbeat();
      await _pollConfig();
      _startConfigPolling();
      AppLogger.breadcrumb('shift_service_started:${response['replay']}');
      return response;
    } on NetworkException {
      // Lot 1 (delta §2.3) : un échec réseau (timeout, coupure) ne clôt pas
      // la tentative logique — l'utilisateur ou une logique de retry pourra
      // rejouer avec le MÊME X-Request-Id. Bug trouvé en vérification : la
      // version précédente le libérait ici, contredisant "réutilisé sur
      // tous les retours réseau de cette tentative".
      rethrow;
    } on ApiException catch (error) {
      // §7 : seul 500 shiftStartFailed est retryable AVEC le même id ; tout
      // refus métier définitif (400/403/404/409) clôt la tentative, on
      // libère l'id pour qu'une nouvelle tentative en génère un autre.
      if (error.statusCode != 500) _pendingRequestId = null;
      rethrow;
    }
  }

  /// §9 : "avant de purger l'état local, vider la file de positions
  /// hors-ligne. Si le réseau manque, conserver la file et la rejouer au
  /// prochain service."
  static Future<Map<String, dynamic>> end() async {
    await GeolocationBridge.flushPendingBuffer(); // best-effort, non bloquant
    final response = await WetrackamApiClient.shiftEnd();
    _stopHeartbeat();
    _stopConfigPolling();
    _currentDeviceUniqueId = null;
    await GeolocationBridge.refreshDriverIdentity();
    // §9 : le champ `tokenRevoked` est renvoyé tel quel dans la réponse —
    // c'est à l'appelant (eligibility_screen.dart::_endShift) de purger le
    // token localement et de renaviguer vers l'écran PIN. Bug trouvé en
    // vérification checklist C7 : ce commentaire décrivait cette
    // responsabilité sans qu'elle soit jamais réellement implémentée côté
    // appelant — corrigé dans eligibility_screen.dart.
    AppLogger.breadcrumb('shift_service_ended:tokenRevoked=${response['tokenRevoked']}');
    return response;
  }

  /// §8.5 : battement de cœur léger, détecte une clôture forcée côté
  /// serveur (manager, ou auto-close H+16) sans attendre un 401.
  static void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      try {
        final current = await WetrackamApiClient.shiftCurrent();
        if (current['active'] != true && isActive) {
          AppLogger.breadcrumb('shift_force_closed_detected');
          _currentDeviceUniqueId = null;
          _stopHeartbeat();
          _stopConfigPolling();
          await GeolocationBridge.refreshDriverIdentity();
          onForcedClosure?.call(false);
        }
      } catch (error) {
        // Un heartbeat manqué (réseau) n'est pas une clôture — on ignore.
        AppLogger.error('shift_heartbeat_failed', error);
      }
    });
  }

  static void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// v6 (§3, `settings.changed`) : rafraîchissement à la demande, hors du
  /// cycle de service actif — un changement de réglages côté manager doit
  /// se refléter même si le chauffeur n'a pas encore pris son service.
  static Future<void> refreshConfigNow() => _pollConfig();

  /// §8.2 : au démarrage du service puis toutes les 15 min, avec ETag.
  static Future<void> _pollConfig() async {
    try {
      final result = await WetrackamApiClient.fetchConfig(etag: _configEtag);
      if (result == null) return; // 304 : rien de neuf, on garde les seuils actuels
      final (json, etag) = result;
      _configEtag = etag;
      thresholds = ShiftThresholds.fromConfig(json);
      if (json['mobileDisabled'] == true) {
        await LocalNotificationsService.tenantDisabled();
      }
      AppLogger.breadcrumb('config_refreshed');
    } catch (error) {
      // Les seuils précédents restent valides — pas de blocage du tracking.
      AppLogger.error('config_poll_failed', error);
    }
  }

  static void _startConfigPolling() {
    _configTimer?.cancel();
    _configTimer = Timer.periodic(const Duration(minutes: 15), (_) => _pollConfig());
  }

  static void _stopConfigPolling() {
    _configTimer?.cancel();
    _configTimer = null;
  }

  /// À enregistrer comme hook de purge de token (DriverIdentityService) :
  /// si la session devient invalide (401 quelconque) pendant un service
  /// actif, on ne peut plus appeler /shift/end proprement (pas de token
  /// valide) — on arrête donc le tracking localement pour respecter "aucun
  /// envoi hors service" plutôt que de continuer à émettre des positions
  /// pour un chauffeur qui n'est plus authentifié. Le serveur considérera
  /// le service comme abandonné et le clôturera à terme (auto-close H+16,
  /// §7bis) ou via une action manager.
  static Future<void> forceLocalStop() async {
    if (!isActive) return;
    AppLogger.breadcrumb('shift_force_local_stop_session_lost');
    _currentDeviceUniqueId = null;
    _pendingRequestId = null;
    _stopHeartbeat();
    _stopConfigPolling();
    await GeolocationBridge.refreshDriverIdentity();
  }
}
