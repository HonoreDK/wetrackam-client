// lib/wetrackam/push_notifications_service.dart
//
// Lot 4 (contrat v5 §7.5, §8, §8.5) + v6.1 (FLUX-JETON-FCM.md) — cycle de
// vie complet du jeton FCM.
//
// Trois précisions du contrat v5 qui évitent des bugs difficiles à
// reproduire (§8.5), toujours valables :
//  1. En API v1, TOUTES les valeurs de `data` sont des chaînes — `silent`
//     vaut "true"/"false", jamais un booléen. Vrai aussi pour `epoch`/`seq`
//     des messages `control` livrés par push (voir plus bas).
//  2. Types silencieux (`call`, `shift_auto_end`) : bloc `notification`
//     absent, message data-only, l'app décide seule de l'affichage.
//  3. `data.channel` désigne le canal Android à créer au premier lancement.
//
// v6.1 — ce que ce fichier NE fait PAS, par choix explicite du document :
//  - pas de réenregistrement en boucle (un minuteur périodique de
//    quelques minutes) — uniquement les 4 déclencheurs + le filet 24h ;
//  - `control.push.stale` ne recharge JAMAIS l'écran d'accueil (aucune
//    information métier) — traité ici, jamais transmis à
//    state_sync_service.dart pour cet effet ;
//  - jamais de comparaison de jetons complets entre appareils, seulement
//    des empreintes (SHA-256 tronqué à 12 caractères hexadécimaux) ;
//  - `deviceKey` n'est JAMAIS dérivée de l'IMEI ou d'un identifiant
//    publicitaire — UUID v4 généré une fois, sans rapport avec le
//    matériel.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'app_logger.dart';
import 'call_ui_service.dart';
import 'peer_name_cache.dart';
import 'driver_identity_service.dart';
import 'local_notifications_service.dart';
import 'realtime_service.dart';
import 'state_sync_service.dart';

/// §8.5 — les 7 canaux Android, avec l'importance documentée par le
/// contrat. Créés une fois au premier lancement ; recréer un canal
/// existant avec les mêmes paramètres est un no-op côté Android.
class _PushChannel {
  final String id;
  final String label;
  final Importance importance;
  const _PushChannel(this.id, this.label, this.importance);
}

const _kChannels = [
  _PushChannel('calls', 'Appels', Importance.max),
  _PushChannel('chat', 'Messages', Importance.high),
  _PushChannel('safety', 'Sécurité', Importance.high),
  _PushChannel('alerts', 'Alertes véhicule', Importance.high),
  _PushChannel('compliance', 'Conformité', Importance.defaultImportance),
  _PushChannel('coaching', 'Conseils éco-conduite', Importance.low),
  _PushChannel('service', 'Service', Importance.defaultImportance),
];

/// §8.5 — catalogue fermé des 20 types documentés + `control` (v6, plan
/// de contrôle — pas un type "métier" au sens du catalogue d'origine,
/// mais doit être routé, pas ignoré comme un type inconnu).
const _kKnownTypes = {
  'call', 'message', 'missed_call',
  'fatigue', 'fatigue_warning', 'speeding', 'eco_driving', 'speed_jump',
  'fuel_theft', 'fuel_leak', 'fuel_glitch', 'night_driving',
  'license_expired', 'idle_engine', 'out_of_bounds',
  'vehicle_unavailable', 'no_vehicle',
  'shift_reminder', 'shift_auto_end', 'manager_alert',
  'control',
};

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // Point d'entrée séparé exigé par firebase_messaging pour le traitement
  // en arrière-plan/application terminée (isolate distinct, aucun état en
  // mémoire du reste de l'app n'est disponible ici).
  await Firebase.initializeApp();
  AppLogger.breadcrumb('push_background:${message.data['type']}');

  // CORRECTIF v13 — LE défaut majeur de la version précédente. Un isolate
  // d'arrière-plan ne peut effectivement pas naviguer dans l'arbre de
  // widgets… mais il PEUT demander au système d'afficher l'écran d'appel
  // natif (CallKit sur iOS, notification plein écran sur Android). Sans
  // cela, un appel reçu application fermée ou écran verrouillé n'était
  // JAMAIS signalé : le chauffeur découvrait un appel manqué. C'est la
  // cause première du « la VoIP ne fonctionne pas ».
  if (message.data['type'] == 'call') {
    final callId = message.data['callId'] as String?;
    if (callId == null || callId.isEmpty) {
      // Push d'une version serveur antérieure au correctif : sans callId on
      // ne peut pas corréler l'acceptation. On ne sonne pas dans le vide.
      AppLogger.breadcrumb('push_call_without_callid');
      return;
    }
    final callerId = int.tryParse('${message.data['callerId'] ?? ''}') ?? 0;
    final timeout = int.tryParse('${message.data['ringTimeoutSeconds'] ?? ''}') ?? 30;
    await CallUiService.showIncoming(
      callId: callId,
      callerName: await PeerNameCache.displayName(callerId),
      ringTimeoutSeconds: timeout,
    );
    return;
  }

  // Pour `control`, le traitement se fera à la prochaine ouverture (resync
  // socket ou /state, §9.3/§5 du delta).
}

class PushNotificationsService {
  PushNotificationsService._();

  static const _secureStorage = FlutterSecureStorage();
  static const _keyDeviceKey = 'wetrackam_push_device_key';
  static const _keyPendingRegistration = 'wetrackam_push_pending_registration';
  static const _keyLastConfirmedAt = 'wetrackam_push_last_confirmed_at';
  static const _keyLastConfirmedFingerprint = 'wetrackam_push_last_fingerprint';

  static String? _currentToken;
  static String? _deviceKey;
  static final _seenCorrelationIds = <String>{};
  static StreamSubscription<RemoteMessage>? _foregroundSub;
  static StreamSubscription<String>? _refreshSub;
  static StreamSubscription<Map<String, dynamic>>? _controlSub;
  static Timer? _queueRetryTimer;
  static int _queueRetryAttempt = 0;

  static Future<void> init() async {
    // §3.1 : deviceKey — UUID v4 généré une seule fois, stockage sécurisé
    // séparé de X-Device-Id (device_identity.dart). Les deux identifient
    // "cet appareil" mais avec des cycles de vie différents : X-Device-Id
    // sert au provisionnement et ne s'efface jamais ; deviceKey est
    // propre au push et s'efface à la déliaison (§3.1, §3.6) — les
    // confondre romprait l'une des deux garanties.
    _deviceKey = await _getOrCreateDeviceKey();
    try {
      await Firebase.initializeApp();
    } catch (error) {
      AppLogger.error('firebase_init_failed', error);
      return;
    }
    await _createAndroidChannels();
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
    _foregroundSub = FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    _refreshSub = FirebaseMessaging.instance.onTokenRefresh.listen(_onTokenRefresh);
    // v6.1 §3.4 — écoute indépendante de state_sync_service.dart : ce
    // fichier a besoin de champs (`pushRegistered`) que la logique
    // epoch/reload de StateSyncService ne conserve pas. Pattern déjà
    // utilisé partout ailleurs dans le projet (chat_service.dart,
    // call_service.dart...) : plusieurs services écoutent le même flux
    // RealtimeService.messages, chacun pour son propre besoin.
    _controlSub = RealtimeService.messages.listen(_onSocketControlMessage);
    // Reprend une éventuelle entrée en file laissée par un arrêt brutal de
    // l'app (crash, tué par l'OS) avant sa confirmation.
    unawaited(_retryPendingRegistrationIfAny());
    AppLogger.breadcrumb('push_service_init');
  }

  static Future<String> _getOrCreateDeviceKey() async {
    var key = await _secureStorage.read(key: _keyDeviceKey);
    if (key == null) {
      key = const Uuid().v4();
      await _secureStorage.write(key: _keyDeviceKey, value: key);
    }
    return key;
  }

  static Future<void> _createAndroidChannels() async {
    if (!Platform.isAndroid) return;
    final plugin = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (plugin == null) return;
    for (final channel in _kChannels) {
      await plugin.createNotificationChannel(AndroidNotificationChannel(
        channel.id,
        channel.label,
        importance: channel.importance,
      ));
    }
  }

  // -----------------------------------------------------------------
  // §3.2 — Les quatre déclencheurs d'enregistrement
  // -----------------------------------------------------------------

  /// Déclencheur 1 (authentification réussie) — appelé aussi au
  /// démarrage si déjà authentifié (déclencheur 2, voir main.dart).
  static Future<void> registerAfterAuth() async {
    if (!DriverIdentityService.isAuthenticated) return;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true, badge: true, sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        AppLogger.breadcrumb('push_permission_denied');
        return;
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await _queueAndAttempt(token);
    } catch (error) {
      AppLogger.error('push_register_failed', error);
    }
  }

  /// Déclencheur 3 — immédiat, sans attendre une nouvelle authentification.
  static void _onTokenRefresh(String token) {
    unawaited(_queueAndAttempt(token));
  }

  // -----------------------------------------------------------------
  // §3.3 — File d'attente hors-ligne (obligatoire)
  // -----------------------------------------------------------------

  /// Persiste D'ABORD, tente ENSUITE — dans cet ordre précis (§3.3.1/2) :
  /// un `onNewToken` survient très souvent sans réseau, un enregistrement
  /// perdu à ce moment-là rend le chauffeur injoignable jusqu'au prochain
  /// redémarrage.
  static Future<void> _queueAndAttempt(String token) async {
    if (!DriverIdentityService.isAuthenticated) return;
    final deviceKey = _deviceKey ?? await _getOrCreateDeviceKey();
    final entry = {
      'token': token,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'deviceKey': deviceKey,
      'label': null,
      'queuedAt': DateTime.now().toIso8601String(),
    };
    final prefs = await SharedPreferences.getInstance();
    // §3.3 dernière ligne : "Une seule entrée en file : un nouveau jeton
    // remplace le précédent" — set() écrase simplement l'entrée existante.
    await prefs.setString(_keyPendingRegistration, jsonEncode(entry));
    _queueRetryAttempt = 0;
    await _attemptFromQueue();
  }

  static Future<void> _attemptFromQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyPendingRegistration);
    if (raw == null) return;
    final entry = jsonDecode(raw) as Map<String, dynamic>;
    try {
      final response = await WetrackamApiClient.registerPushToken(
        token: entry['token'] as String,
        platform: entry['platform'] as String,
        deviceKey: entry['deviceKey'] as String,
        label: entry['label'] as String?,
      );
      await prefs.remove(_keyPendingRegistration);
      await prefs.setString(_keyLastConfirmedAt, DateTime.now().toIso8601String());
      final fingerprint = response['tokenFingerprint'] as String? ??
          _fingerprint(entry['token'] as String);
      await prefs.setString(_keyLastConfirmedFingerprint, fingerprint);
      _currentToken = entry['token'] as String;
      _queueRetryTimer?.cancel();
      _queueRetryAttempt = 0;
      AppLogger.breadcrumb(
          'push_token_registered:unchanged=${response['unchanged']}');
    } on SessionInvalidException {
      // §3.3.4 : "401 → ne réessaie pas... rejouée après la nouvelle
      // authentification." Purge et message déjà gérés centralement par
      // api_client.dart. L'entrée reste en file, retentée par
      // registerAfterAuth() -> _retryPendingRegistrationIfAny().
      _queueRetryTimer?.cancel();
      AppLogger.breadcrumb('push_register_deferred_session_invalid');
    }
    // Sous-classes d'ApiException AVANT le cas général : placées après,
    // elles n'étaient jamais atteintes (l'analyseur le signalait en
    // « dead_code_on_catch_subtype »).
    on TlsTrustException catch (error) {
      // Cause non résoluble par un simple réessai : rejouer en boucle
      // n'aboutirait jamais et masquerait l'incident. L'entrée reste en
      // file, elle sera retentée après un réappairage.
      _queueRetryTimer?.cancel();
      AppLogger.error('push_register_tls_refused', error.toString());
    } on NetworkException {
      _scheduleQueueRetry();
    } on ApiException catch (error) {
      if (error.statusCode == 400) {
        await prefs.remove(_keyPendingRegistration);
        AppLogger.error('push_register_bad_request_dropped', error);
        return;
      }
      _scheduleQueueRetry();
    } catch (error) {
      AppLogger.error('push_register_unexpected_error', error);
      _scheduleQueueRetry();
    }
  }

  /// §3.3.3 : "même backoff que la socket" — repris à l'identique de
  /// realtime_service.dart pour rester cohérent dans tout le projet.
  static void _scheduleQueueRetry() {
    _queueRetryTimer?.cancel();
    _queueRetryAttempt++;
    final baseSeconds = min(30, pow(2, _queueRetryAttempt - 1).toInt());
    final jitter = baseSeconds * 0.2 * (Random().nextDouble() * 2 - 1);
    final delay = Duration(milliseconds: ((baseSeconds + jitter) * 1000).round());
    AppLogger.breadcrumb('push_register_retry_scheduled:${delay.inSeconds}s');
    _queueRetryTimer = Timer(delay, _attemptFromQueue);
  }

  static Future<void> _retryPendingRegistrationIfAny() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_keyPendingRegistration) &&
        DriverIdentityService.isAuthenticated) {
      await _attemptFromQueue();
    }
  }

  static String _fingerprint(String token) =>
      sha256.convert(utf8.encode(token)).toString().substring(0, 12);

  // -----------------------------------------------------------------
  // §3.4 — Vérification après reconnexion de la socket temps réel
  // -----------------------------------------------------------------
  static void _onSocketControlMessage(Map<String, dynamic> message) {
    if (message['type'] != 'control') return;
    final event = message['event'] as String?;
    if (event == 'push.stale') {
      _onPushStale(message);
    } else if (event == 'control.resync') {
      unawaited(_onControlResync(message['pushRegistered'] as bool?));
    }
  }

  /// §2 "control.push.stale" : jamais transmis à StateSyncService pour
  /// recharger l'écran (exclusion symétrique côté state_sync_service.dart).
  static void _onPushStale(Map<String, dynamic> message) {
    AppLogger.breadcrumb('push_stale_received:${message['reason']}');
    if (_currentToken != null) {
      unawaited(_queueAndAttempt(_currentToken!));
    } else {
      unawaited(registerAfterAuth());
    }
  }

  static Future<void> _onControlResync(bool? pushRegistered) async {
    if (pushRegistered == false) {
      if (_currentToken != null) {
        await _queueAndAttempt(_currentToken!);
      } else {
        await registerAfterAuth();
      }
      return;
    }
    if (pushRegistered == null) {
      await _verifyViaStatusEndpoint();
    }
    // pushRegistered == true : rien à faire, tout est déjà cohérent.
  }

  static Future<void> _verifyViaStatusEndpoint() async {
    if (_deviceKey == null || !DriverIdentityService.isAuthenticated) return;
    try {
      final status = await WetrackamApiClient.fetchPushStatus(_deviceKey!);
      if (status['registered'] != true) {
        if (_currentToken != null) {
          await _queueAndAttempt(_currentToken!);
        } else {
          await registerAfterAuth();
        }
        return;
      }
      final remoteFingerprint = status['tokenFingerprint'] as String?;
      final prefs = await SharedPreferences.getInstance();
      final localFingerprint = prefs.getString(_keyLastConfirmedFingerprint);
      if (remoteFingerprint != null && remoteFingerprint != localFingerprint) {
        if (_currentToken != null) await _queueAndAttempt(_currentToken!);
      }
    } catch (error) {
      AppLogger.error('push_status_check_failed', error);
    }
  }

  // -----------------------------------------------------------------
  // §3.5 — Filet de sécurité au premier plan (24h)
  // -----------------------------------------------------------------
  static Future<void> checkStalenessOnResume() async {
    if (!DriverIdentityService.isAuthenticated) return;
    final prefs = await SharedPreferences.getInstance();
    final lastConfirmedStr = prefs.getString(_keyLastConfirmedAt);
    final lastConfirmed = lastConfirmedStr != null ? DateTime.tryParse(lastConfirmedStr) : null;
    if (lastConfirmed == null ||
        DateTime.now().difference(lastConfirmed) > const Duration(hours: 24)) {
      await _verifyViaStatusEndpoint();
    }
  }

  // -----------------------------------------------------------------
  // §3.6 — Déliaison, dans l'ordre exact prescrit
  // -----------------------------------------------------------------
  /// À appeler par l'action de déliaison (pas encore d'écran dédié dans
  /// l'app — voir I1/limite notée au rapport de livraison v5) AVANT
  /// DriverIdentityService.purgeAll(), qui a besoin d'une session encore
  /// valide pour authentifier l'appel serveur.
  static Future<void> onUnbind() async {
    if (_deviceKey != null) {
      await WetrackamApiClient.revokePushToken(_deviceKey!);
    }
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (error) {
      AppLogger.error('push_delete_token_failed', error);
    }
    await _secureStorage.delete(key: _keyDeviceKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPendingRegistration);
    await prefs.remove(_keyLastConfirmedAt);
    await prefs.remove(_keyLastConfirmedFingerprint);
    _deviceKey = null;
    _currentToken = null;
    _queueRetryTimer?.cancel();
    AppLogger.breadcrumb('push_unbind_complete');
  }

  /// À appeler PRÉ-purge TOTALE uniquement (pas sur une simple expiration
  /// de session, voir main.dart). Ne fait PAS le nettoyage complet de
  /// `onUnbind()` : une purge déclenchée par le serveur (accountArchived,
  /// deviceReplaced...) n'est pas une déliaison volontaire — deviceKey n'a
  /// pas de raison de changer, seul le jeton serveur est revoqué.
  static Future<void> revokeCurrentToken() async {
    if (_deviceKey == null) return;
    await WetrackamApiClient.revokePushToken(_deviceKey!);
    _currentToken = null;
  }

  static void dispose() {
    _foregroundSub?.cancel();
    _refreshSub?.cancel();
    _controlSub?.cancel();
    _queueRetryTimer?.cancel();
  }

  // -----------------------------------------------------------------
  // Traitement des messages entrants — §8.5 règles 1 à 7 (v5) + control (v6)
  // -----------------------------------------------------------------

  static void _onForegroundMessage(RemoteMessage message) => _handle(message);

  static void _handle(RemoteMessage message) {
    final data = message.data;
    final type = data['type'] as String?;

    if (type == null || !_kKnownTypes.contains(type)) {
      AppLogger.breadcrumb('push_unknown_type:$type');
      return;
    }

    // v6 — canal 2 (§1, §4 du delta) : messages control livrés par push
    // quand la socket est fermée. Bug trouvé en vérification : cette
    // branche n'existait pas avant — un `control` reçu par push était
    // silencieusement rejeté comme "type inconnu" (control n'était pas
    // dans le catalogue fermé), alors que c'est justement LE canal de
    // repli pour l'app en arrière-plan.
    if (type == 'control') {
      final event = data['event'] as String?;
      if (event == 'push.stale') {
        _onPushStale(data);
      } else if (event == 'control.resync') {
        // pushRegistered arrive en chaîne ("true"/"false") ou absent —
        // jamais un booléen natif en API FCM v1 (règle 1, tête de fichier).
        final raw = data['pushRegistered'];
        final pushRegistered = raw == null ? null : raw == 'true';
        unawaited(_onControlResync(pushRegistered));
      }
      // Transmis à StateSyncService pour le suivi epoch/reload général —
      // sauf push.stale, exclu symétriquement des deux côtés.
      StateSyncService.handleControlMessageFromPush(data);
      return;
    }

    final correlationId = data['correlationId'] as String?;
    if (correlationId != null) {
      if (_seenCorrelationIds.contains(correlationId)) {
        AppLogger.breadcrumb('push_duplicate_ignored:$correlationId');
        return;
      }
      _seenCorrelationIds.add(correlationId);
      if (_seenCorrelationIds.length > 200) {
        _seenCorrelationIds.remove(_seenCorrelationIds.first);
      }
    }

    final silent = data['silent'] == 'true';

    if (type == 'call') {
      // Premier plan : la socket est la voie normale de signalisation, on la
      // rétablit d'abord. L'écran d'appel Flutter (CallNavigator) prendra le
      // relais sur `call.incoming` — pas d'écran natif ici, il ferait double
      // sonnerie avec l'écran applicatif déjà visible.
      RealtimeService.ensureConnected();
      AppLogger.breadcrumb('push_call_incoming_connecting');
      return;
    }

    if (type == 'shift_auto_end') {
      AppLogger.breadcrumb('push_shift_auto_end');
      return;
    }

    if (silent) {
      AppLogger.breadcrumb('push_silent:$type');
      return;
    }

    final title = message.notification?.title;
    final body = message.notification?.body;
    if (title == null && body == null) {
      AppLogger.breadcrumb('push_no_notification_block:$type');
      return;
    }

    LocalNotificationsService.showGeneric(
      title: title ?? 'WeTrackam',
      body: body ?? '',
      channelId: (data['channel'] as String?) ?? 'service',
    );
  }
}
