// lib/wetrackam/api_client.dart
//
// Contrat v4 — catalogue exhaustif §12. Aucun autre endpoint que ceux
// listés ici n'est appelé (v1 appelait /api/geofences et
// /api/reports/driver-score : retirés, hors périmètre v4).
//
// Gestion centralisée des 401 (§13.1) : la purge correcte (token seul ou
// tout) est appliquée UNE SEULE FOIS, ici, plutôt que dupliquée dans
// chaque écran — c'est la source du bug corrigé en v1 (dérive tenant
// oubliée dans un des deux écrans de score).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_logger.dart';
import 'device_identity.dart';
import 'discovery_service.dart';
import 'driver_identity_service.dart';
import 'state_sync_service.dart';
import 'tls_pinning.dart';

class ApiException implements Exception {
  final int? statusCode;
  final String error;
  final String? reason;
  final int? retryAfterMs;
  final int? retryAfterSeconds;
  final String? scope; // 'driver' | 'tenant' (429)
  const ApiException(this.statusCode, this.error,
      {this.reason, this.retryAfterMs, this.retryAfterSeconds, this.scope});

  @override
  String toString() => 'ApiException($statusCode, $error, reason=$reason)';
}

/// Levée APRÈS que la purge correcte (§13.1) ait déjà été exécutée. L'UI
/// n'a qu'à naviguer vers l'écran indiqué par [reason] via ErrorCatalog.
class SessionInvalidException extends ApiException {
  const SessionInvalidException(String? reason)
      : super(401, 'unauthorized', reason: reason);
}

/// §15.2 : NE PURGE JAMAIS l'état local (suspension réversible).
class TenantDisabledException extends ApiException {
  const TenantDisabledException() : super(503, 'mobile_disabled');
}

class RateLimitedException extends ApiException {
  const RateLimitedException({int? retryAfterSeconds, String? scope})
      : super(429, 'rate_limited', retryAfterSeconds: retryAfterSeconds, scope: scope);
}

/// Aucune réponse du tout (timeout, DNS, etc.) — distinct d'une réponse
/// HTTP d'erreur, pour la politique de retry (§3.4).
class NetworkException extends ApiException {
  const NetworkException() : super(null, 'network_error');
}

class WetrackamApiClient {
  WetrackamApiClient._();

  // Lot 1 (§20.1/20.4 du contrat v5) : deux minuteurs distincts.
  //  - connectTimeout (10 s) : le paquet http n'expose pas cette notion
  //    directement ; on configure le HttpClient dart:io sous-jacent, qui la
  //    supporte nativement au niveau socket.
  //  - readTimeout (15 s) : posé sur chaque appel via .timeout(...) — couvre
  //    connexion + envoi + lecture de la réponse. Comme connectTimeout (10s)
  //    est strictement inférieur, un blocage à la connexion échoue à 10 s ;
  //    un blocage pendant la lecture de la réponse échoue à 15 s. Les deux
  //    couches sont donc réellement distinctes, pas une seule valeur dupliquée.
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _readTimeout = Duration(seconds: 15);
  // ARCHITECTURE-VPN-TLS.md §5 : client REST épinglé par clé publique —
  // remplace le HttpClient nu utilisé jusqu'ici, qui ne vérifiait que la
  // chaîne de confiance standard, pas l'identité précise du serveur.
  static final http.Client _client =
      TlsPinning.pinnedHttpClient(connectionTimeout: _connectTimeout);

  static Uri _uri(String path, [Map<String, String>? query]) {
    // Chantier B : endpoints.api (DiscoveryService) est désormais
    // l'adresse vivante — le serverUrl de provisionnement ne sert plus
    // que de repli avant la toute première découverte réussie.
    final base = DiscoveryService.apiBase ?? DriverIdentityService.provisioning?.serverUrl;
    if (base == null) {
      throw StateError('Appel API sans provisionnement — bug d\'app.');
    }
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  static Future<Map<String, String>> _authHeaders() async {
    final session = DriverIdentityService.session;
    final driverId = DriverIdentityService.provisioning?.driverUniqueId;
    if (session == null || driverId == null) {
      throw StateError('Appel authentifié sans session — bug d\'app.');
    }
    return {
      'Accept': 'application/json',
      'Authorization': 'Bearer ${session.token}',
      'X-Driver-Id': driverId,
    };
  }

  /// §13.1 — Applique la bonne portée de purge selon `reason`, puis lève
  /// SessionInvalidException. Centralisé pour ne jamais l'oublier dans un
  /// écran (bug constaté en v1).
  static Future<Never> _handleUnauthorized(http.Response response) async {
    String? reason;
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      reason = body['reason'] as String?;
    } catch (_) {
      // Corps illisible ⇒ traité comme tokenExpired, le plus doux (§13.1).
    }
    const fullPurgeReasons = {'accountArchived', 'deviceReplaced'};
    if (reason != null && fullPurgeReasons.contains(reason)) {
      await DriverIdentityService.purgeAll();
    } else {
      // tokenExpired, accountSuspended, assignmentRemoved, ou absent.
      await DriverIdentityService.purgeTokenOnly();
    }
    AppLogger.breadcrumb('session_invalid:$reason');
    throw SessionInvalidException(reason);
  }

  static Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      final response = await request();
      // v6 §9.1 : l'epoch est désormais sur TOUTE réponse /api/mobile/*,
      // pas seulement /state — lu ici, au point de passage unique de
      // toutes les requêtes, plutôt que dupliqué dans chaque méthode.
      StateSyncService.onEpochHeader(response.headers['x-driver-epoch']);
      if (response.statusCode == 401) {
        await _handleUnauthorized(response);
      }
      if (response.statusCode == 503) {
        Map<String, dynamic> body = {};
        try {
          body = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {}
        if (body['error'] == 'mobile_disabled') {
          throw const TenantDisabledException();
        }
        throw ApiException(503, body['error']?.toString() ?? 'server_busy');
      }
      if (response.statusCode == 429) {
        Map<String, dynamic> body = {};
        try {
          body = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {}
        final retryAfterHeader = response.headers['retry-after'];
        throw RateLimitedException(
          retryAfterSeconds: retryAfterHeader != null
              ? int.tryParse(retryAfterHeader)
              : (body['retryAfterMs'] != null ? (body['retryAfterMs'] as num) ~/ 1000 : null),
          scope: response.headers['x-ratelimit-scope'] ?? body['scope'] as String?,
        );
      }
      return response;
    } on TimeoutException {
      throw const NetworkException();
    } on http.ClientException {
      throw const NetworkException();
    }
  }

  static Map<String, dynamic> _parseError(http.Response response) {
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return {'error': 'unknown'};
    }
  }

  // -----------------------------------------------------------------
  // Lot 2 (§20.1 du contrat v5) — sonde de joignabilité, publique, sans
  // authentification, à appeler avant l'écran PIN. Timeout dédié de 5 s :
  // volontairement plus court que _readTimeout (15 s) des autres appels,
  // pour ne pas faire attendre le chauffeur avant même d'avoir vu le
  // clavier PIN si le serveur est clairement injoignable.
  // -----------------------------------------------------------------
  static Future<bool> ping() async {
    final base = DriverIdentityService.provisioning?.serverUrl;
    if (base == null) return false; // pas encore provisionné — appelant ne devrait pas appeler ping() dans ce cas
    try {
      final uri = Uri.parse('$base/api/mobile/ping');
      final response = await _client
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return false;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return json['ok'] == true;
    } catch (_) {
      // Timeout, DNS, connexion refusée... : toute exception ici veut dire
      // "injoignable", pas la peine de distinguer la cause pour l'écran.
      return false;
    }
  }

  // -----------------------------------------------------------------
  // DELTA-v7.7-QR-APPAIRAGE.md — appairage universel (avant tout amorçage
  // TLS : ces deux appels utilisent volontairement un client NON épinglé,
  // la vérification de clé publique standard du système suffit ici. Il
  // n'existe structurellement aucune ancre à vérifier avant que l'un de
  // ces deux appels n'en fournisse une — épingler ici serait un
  // non-sens, pas un oubli.
  // -----------------------------------------------------------------
  static final http.Client _bootstrapClient = http.Client();

  /// §2 : "la voie recommandée" — envoie la chaîne brute scannée/collée
  /// telle quelle, le serveur résout tous les formats (canonique, ancien
  /// lien v6, deep-link, JSON hérité). `hostHint` est l'hôte lu dans la
  /// chaîne elle-même (§3 étape 3 : "sur l'hôte lu dans la chaîne") —
  /// PAS un serveur central, il n'en existe pas.
  static Future<Map<String, dynamic>> resolvePairing({
    required String scanned,
    required String hostHint,
  }) async {
    final uri = Uri.parse('$hostHint/api/pair/resolve');
    final response = await _bootstrapClient
        .post(uri,
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({'scanned': scanned}))
        .timeout(_readTimeout);
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  /// §6 : vérification d'une adresse tapée à la main — "à l'adresse
  /// tapée elle-même", pas de résolution DNS/annuaire préalable.
  /// `ok: false` (422) n'est PAS une ApiException ici : c'est un verdict
  /// de règle métier normal, pas une erreur technique — retourné tel
  /// quel pour que l'appelant distingue "règle qui tranche" d'"échec
  /// transport" (§6, "L'échelle de repli").
  static Future<Map<String, dynamic>> probeAddress({
    required String candidateBase,
  }) async {
    final uri = Uri.parse('$candidateBase/api/pair/probe');
    final response = await _bootstrapClient
        .post(uri,
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({'input': candidateBase}))
        .timeout(const Duration(seconds: 4)); // §6 : "4 s de délai chacun"
    // 200 (ok:true) et 422 (ok:false) sont TOUS DEUX des réponses valides
    // du point de vue transport — seule l'absence de réponse (timeout,
    // DNS, TLS refusé) doit être traitée différemment par l'appelant.
    if (response.statusCode == 200 || response.statusCode == 422) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // §4.2 — Provisionnement (non authentifié)
  // -----------------------------------------------------------------
  static final RegExp _tokenFormat = RegExp(r'^[A-Za-z0-9_-]{20,80}$');

  static bool isValidProvisioningToken(String token) => _tokenFormat.hasMatch(token);

  static Future<Map<String, dynamic>> exchangeProvisioningToken({
    required String serverUrl,
    required String token,
    String? expectedServerId,
    String? expectedPinsetPublicKey,
  }) async {
    final normalizedBase = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    final deviceId = await DeviceIdentity.get();
    final uri = Uri.parse('$normalizedBase/api/mobile/provisioning/$token');
    // Première requête uniquement : aucune empreinte n'est encore installée,
    // donc le client épinglé échoue volontairement. On utilise la validation
    // TLS système puis on compare l'identité/ancre à celles reçues pendant la
    // résolution du QR. Tous les appels suivants utilisent `_client` épinglé.
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const ApiException(null, 'invalidServerUrl');
    }
    final response = await _send(() => _bootstrapClient.get(uri, headers: {
      'Accept': 'application/json',
      'X-Device-Id': deviceId,
      'User-Agent': DeviceIdentity.userAgent(),
    }).timeout(_readTimeout));
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (expectedPinsetPublicKey != null &&
          body['tlsPinsetPublicKey'] != expectedPinsetPublicKey) {
        throw const ApiException(409, 'tlsAnchorMismatch');
      }
      return body;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // §5 — Authentification PIN (non authentifié par Bearer)
  // -----------------------------------------------------------------
  static Future<Map<String, dynamic>> driverAuth({
    required String driverUniqueId,
    required String pin,
  }) async {
    final base = DriverIdentityService.provisioning?.serverUrl;
    if (base == null) throw StateError('Provisionnement manquant — bug d\'app.');
    final uri = Uri.parse('$base/api/mobile/driver-auth');
    final response = await _send(() => _client
        .post(uri,
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({'driverUniqueId': driverUniqueId, 'pin': pin}))
        .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(
      response.statusCode,
      body['error']?.toString() ?? 'unknown',
      retryAfterMs: (body['retryAfterMs'] as num?)?.toInt(),
      retryAfterSeconds: (body['retryAfter'] as num?)?.toInt(),
    );
  }

  // -----------------------------------------------------------------
  // §6 — Éligibilité (source unique de l'écran d'accueil)
  // -----------------------------------------------------------------
  static Future<Map<String, dynamic>> fetchEligibility() async {
    final headers = await _authHeaders();
    final response = await _send(() =>
        _client.get(_uri('/api/mobile/shift/eligibility'), headers: headers)
            .timeout(_readTimeout));
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tenantId = json['tenantId']?.toString();
      if (tenantId != null) {
        await DriverIdentityService.checkTenantDrift(tenantId);
      }
      return json;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // §7 — Prise de service (idempotente via X-Request-Id)
  // -----------------------------------------------------------------
  static Future<Map<String, dynamic>> shiftStart({
    required String requestId,
    String? deviceUniqueId, // uniquement en mode FREE_POOL
  }) async {
    final headers = await _authHeaders();
    headers['Content-Type'] = 'application/json';
    headers['X-Request-Id'] = requestId;
    final body = deviceUniqueId != null ? {'deviceUniqueId': deviceUniqueId} : <String, dynamic>{};
    final response = await _send(() => _client
        .post(_uri('/api/mobile/shift/start'), headers: headers, body: jsonEncode(body))
        .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final errorBody = _parseError(response);
    throw ApiException(response.statusCode, errorBody['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // §8.5 — Battement de cœur pendant le service
  // -----------------------------------------------------------------
  static Future<Map<String, dynamic>> shiftCurrent() async {
    final headers = await _authHeaders();
    final response = await _send(() =>
        _client.get(_uri('/api/mobile/shift/current'), headers: headers)
            .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // §9 — Fin de service
  // -----------------------------------------------------------------
  static Future<Map<String, dynamic>> shiftEnd() async {
    final headers = await _authHeaders();
    headers['Content-Type'] = 'application/json';
    final response = await _send(() => _client
        .post(_uri('/api/mobile/shift/end'), headers: headers, body: jsonEncode({}))
        .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // §10 — Alerter le manager
  // -----------------------------------------------------------------
  static Future<Map<String, dynamic>> notifyManager(String reason) async {
    final headers = await _authHeaders();
    headers['Content-Type'] = 'application/json';
    final response = await _send(() => _client
        .post(_uri('/api/mobile/shift/notify-manager'),
            headers: headers, body: jsonEncode({'reason': reason}))
        .timeout(_readTimeout));
    // §10 : HTTP 200 même si sent:false — ce n'est pas une erreur technique.
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // V16 — SOS idempotent raccordé au socle de détresse serveur
  // -----------------------------------------------------------------
  static Future<Map<String, dynamic>> raiseDistress({
    required String alertId,
    double? latitude,
    double? longitude,
    String kind = 'sos',
    String? note,
  }) async {
    final headers = await _authHeaders();
    headers['Content-Type'] = 'application/json';
    final response = await _send(() => _client
        .post(_uri('/api/distress'), headers: headers, body: jsonEncode({
          'alertId': alertId,
          'kind': kind,
          'source': 'app',
          if (latitude != null) 'latitude': latitude,
          if (longitude != null) 'longitude': longitude,
          if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        }))
        .timeout(_readTimeout));
    if (response.statusCode == 200 || response.statusCode == 201) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown',
        reason: body['reason']?.toString());
  }

  // -----------------------------------------------------------------
  // §8.2 — Config dynamique (ETag, cache 60s, appelé au démarrage puis /15min)
  // -----------------------------------------------------------------
  /// Retourne `null` si `304 Not Modified` (l'appelant garde sa dernière
  /// valeur connue). Retourne `(json, etag)` sinon.
  static Future<(Map<String, dynamic>, String?)?> fetchConfig({String? etag}) async {
    final headers = await _authHeaders();
    if (etag != null) headers['If-None-Match'] = etag;
    final response = await _send(() =>
        _client.get(_uri('/api/mobile/config'), headers: headers)
            .timeout(_readTimeout));
    if (response.statusCode == 304) return null;
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return (json, response.headers['etag']);
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // §8.3 — Accusé de vidage de file (purement informatif, ne bloque jamais)
  // -----------------------------------------------------------------
  static Future<void> ack({required DateTime lastFlushedTs, required int count}) async {
    try {
      final headers = await _authHeaders();
      headers['Content-Type'] = 'application/json';
      await _client
          .post(_uri('/api/mobile/ack'),
              headers: headers,
              body: jsonEncode({
                'lastFlushedTs': lastFlushedTs.toUtc().toIso8601String(),
                'count': count,
              }))
          .timeout(_readTimeout);
    } catch (error) {
      // §8.3 : un échec d'ACK ne doit jamais bloquer le tracking.
      AppLogger.error('ack_failed', error);
    }
  }

  // -----------------------------------------------------------------
  // §8.4 — État du véhicule (204 = aucun véhicule, pas une erreur)
  // -----------------------------------------------------------------
  static Future<Map<String, dynamic>?> fetchVehicleStatus() async {
    final headers = await _authHeaders();
    final response = await _send(() =>
        _client.get(_uri('/api/mobile/vehicle-status'), headers: headers)
            .timeout(_readTimeout));
    if (response.statusCode == 204) return null;
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // Lot 4 + v6.1 (contrat v5 §8, FLUX-JETON-FCM.md) — cycle de vie du jeton FCM
  // -----------------------------------------------------------------

  /// FLUX-JETON-FCM.md §2 : idempotent — répéter cet appel à chaque
  /// démarrage tant que rien n'a changé est explicitement voulu et gratuit
  /// (`unchanged: true`, aucune écriture serveur). Retourne la réponse
  /// complète (pas juste void comme en v5/Lot 4) : l'appelant a besoin de
  /// `tokenFingerprint`/`unchanged` pour la logique de vérification §3.4.
  static Future<Map<String, dynamic>> registerPushToken({
    required String token,
    required String platform, // 'android' | 'ios'
    required String deviceKey,
    String? label,
  }) async {
    final headers = await _authHeaders();
    headers['Content-Type'] = 'application/json';
    final response = await _send(() => _client
        .post(_uri('/api/mobile/push/token'),
            headers: headers,
            body: jsonEncode({
              'token': token,
              'platform': platform,
              'deviceKey': deviceKey,
              if (label != null) 'label': label,
            }))
        .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  /// FLUX-JETON-FCM.md §2 — vérification sans écriture, utilisée par la
  /// logique de reconnexion (§3.4) et le filet de sécurité 24h (§3.5).
  static Future<Map<String, dynamic>> fetchPushStatus(String deviceKey) async {
    final headers = await _authHeaders();
    final response = await _send(() => _client
        .get(_uri('/api/mobile/push/status', {'deviceKey': deviceKey}), headers: headers)
        .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  /// §3.6 : la spécification v6.1 tranche l'ambiguïté laissée par les
  /// documents précédents (contrat v5 vs ACTIVATION-FCM.md, voir chantier
  /// TLS/épinglage) — `deviceKey` est désormais le champ canonique et
  /// unique documenté pour ce DELETE. Best-effort volontaire : un jeton
  /// déjà invalide ne doit jamais bloquer la purge locale en cours.
  static Future<void> revokePushToken(String deviceKey) async {
    try {
      final headers = await _authHeaders();
      headers['Content-Type'] = 'application/json';
      await _client
          .delete(_uri('/api/mobile/push/token'),
              headers: headers, body: jsonEncode({'deviceKey': deviceKey}))
          .timeout(_readTimeout);
    } catch (error) {
      AppLogger.error('revoke_push_token_failed', error);
    }
  }

  // -----------------------------------------------------------------
  // Lot 5 (contrat v5 §4) — configuration du module communication
  // -----------------------------------------------------------------
  /// Point d'entrée du module, à appeler avant tout le reste (§2). Ne
  /// traduit PAS elle-même le 503 rtcNotConfigured en état "masqué" — ça
  /// reste une ApiException normale ici, c'est à l'appelant
  /// (rtc_config_service.dart) de décider que ce cas précis signifie
  /// "fonctionnalité absente", pas "erreur". Garde cette méthode cohérente
  /// avec le reste du client : une couche HTTP fine, pas de logique
  /// métier de masquage ici.
  static Future<Map<String, dynamic>> fetchRtcConfig() async {
    final headers = await _authHeaders();
    final response = await _send(() =>
        _client.get(_uri('/api/mobile/rtc/config'), headers: headers)
            .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // Lot 6 (contrat v5 §5) — ticket d'accès au service temps réel
  // -----------------------------------------------------------------
  /// §5 règle impérative : jamais stocké, jamais journalisé, demandé au
  /// dernier moment. Le retour de cette méthode ne doit JAMAIS transiter
  /// par autre chose qu'une variable locale immédiatement consommée par
  /// realtime_service.dart.
  static Future<Map<String, dynamic>> requestRtcTicket({
    String mode = 'presence', // 'presence' | 'chat' | 'call'
    int? peerDriverId,
  }) async {
    final headers = await _authHeaders();
    headers['Content-Type'] = 'application/json';
    final response = await _send(() => _client
        .post(_uri('/api/mobile/rtc/ticket'),
            headers: headers,
            body: jsonEncode({
              'mode': mode,
              if (peerDriverId != null) 'peerDriverId': peerDriverId,
            }))
        .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // Lot 6/7 — carte des collègues et annuaire (contrat v5 §6, §7)
  // -----------------------------------------------------------------
  /// §6 : cadence conseillée 10s, UNIQUEMENT écran carte visible et app au
  /// premier plan — c'est à l'appelant (l'écran) de respecter ce rythme et
  /// d'arrêter les requêtes en arrière-plan, pas à cette méthode.
  static Future<Map<String, dynamic>> fetchFleetLive() async {
    final headers = await _authHeaders();
    final response = await _send(() =>
        _client.get(_uri('/api/mobile/fleet/live'), headers: headers)
            .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  /// §7 : contrairement à la carte, inclut les chauffeurs hors service.
  static Future<Map<String, dynamic>> fetchDirectory({String? query}) async {
    final headers = await _authHeaders();
    final response = await _send(() => _client
        .get(_uri('/api/mobile/directory', query != null && query.isNotEmpty ? {'q': query} : null),
            headers: headers)
        .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  // -----------------------------------------------------------------
  // v6 — synchronisation bilatérale (DELTA-v5-vers-v6-TEMPS-REEL.md)
  // -----------------------------------------------------------------

  /// §5 : appel léger, filet de sécurité sans socket temps réel.
  static Future<Map<String, dynamic>> fetchState() async {
    final headers = await _authHeaders();
    final response = await _send(() =>
        _client.get(_uri('/api/mobile/state'), headers: headers)
            .timeout(_readTimeout));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final body = _parseError(response);
    throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
  }

  /// §6 : déliaison propre depuis l'application (changement de téléphone,
  /// revente). Après un 200, l'appelant fait une purge totale.
  static Future<void> unbind() async {
    final headers = await _authHeaders();
    headers['Content-Type'] = 'application/json';
    final response = await _send(() => _client
        .post(_uri('/api/mobile/unbind'), headers: headers, body: jsonEncode({}))
        .timeout(_readTimeout));
    if (response.statusCode != 200) {
      final body = _parseError(response);
      throw ApiException(response.statusCode, body['error']?.toString() ?? 'unknown');
    }
  }
}
