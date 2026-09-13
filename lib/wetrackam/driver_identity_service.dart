// lib/wetrackam/driver_identity_service.dart
//
// Contrat v4 — deux niveaux de données distincts, avec deux portées de
// purge différentes (§13.1) :
//
//  PROVISIONNEMENT (durable) : serverUrl, tenantId, driverUniqueId,
//    driverName. Survit à une session PIN expirée (`tokenExpired`,
//    `accountSuspended`, `assignmentRemoved`) : l'app revient à l'écran
//    PIN, PAS à l'écran de scan.
//
//  SESSION (révocable) : token Bearer, expiresAt. Effacée par toute fin de
//    session normale. Une purge "tout" (accountArchived, deviceReplaced,
//    dérive tenant, déliaison) efface les deux niveaux et l'app revient à
//    l'écran de scan.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'discovery_service.dart';
import 'tls_pinning.dart';

class ProvisioningData {
  final String serverUrl; // sans slash final (contrat §3.1)
  final String tenantId;
  final String driverUniqueId;
  final String? driverName;
  // EPINGLAGE-TLS.md §3 — champs ajoutés à la charge utile d'appairage.
  // Nullable uniquement pour relire puis purger proprement un ancien stockage.
  // V17 ne persiste jamais un nouveau provisionnement sans ces champs.
  final String? tlsPinsetPublicKey; // base64 standard, 32 octets bruts
  final String? tlsPinsUrl;
  final List<String>? tlsPins;
  final int? tlsPinsSeq;
  final String? serverId;

  const ProvisioningData({
    required this.serverUrl,
    required this.tenantId,
    required this.driverUniqueId,
    this.driverName,
    this.tlsPinsetPublicKey,
    this.tlsPinsUrl,
    this.tlsPins,
    this.tlsPinsSeq,
    this.serverId,
  });
}

class AuthSession {
  final String token;
  final DateTime? expiresAt;
  final int? sessionEpoch;
  const AuthSession({required this.token, this.expiresAt, this.sessionEpoch});
}

typedef PurgeHook = Future<void> Function();

class DriverIdentityService {
  DriverIdentityService._();

  static const _storage = FlutterSecureStorage();

  static const _keyServerUrl = 'wetrackam_server_url';
  static const _keyTenantId = 'wetrackam_tenant_id';
  static const _keyDriverUniqueId = 'wetrackam_driver_unique_id';
  static const _keyDriverName = 'wetrackam_driver_name';
  static const _keyToken = 'wetrackam_token';
  static const _keyExpiresAt = 'wetrackam_expires_at';
  static const _keySessionEpoch = 'wetrackam_session_epoch';
  static const _flagHasRunBefore = 'wetrackam_has_run_before';

  static ProvisioningData? _provisioning;
  static AuthSession? _session;

  static final List<PurgeHook> _tokenPurgeHooks = [];
  static final List<PurgeHook> _fullPurgeHooks = [];
  static final List<PurgeHook> _postPurgeHooks = [];

  static ProvisioningData? get provisioning => _provisioning;
  static AuthSession? get session => _session;
  static bool get isProvisioned => _provisioning != null;
  static bool get isAuthenticated => _session != null;

  /// Hooks appelés dès que le token disparaît, que ce soit une purge
  /// "session seule" ou "tout" (ex. arrêter le tracking en cours).
  static void registerTokenPurgeHook(PurgeHook hook) => _tokenPurgeHooks.add(hook);

  /// Hooks appelés uniquement lors d'une purge "tout" (provisionnement
  /// compris) — ex. vider le cache d'éligibilité, la file de positions.
  static void registerFullPurgeHook(PurgeHook hook) => _fullPurgeHooks.add(hook);

  /// Hooks nécessitant que l'état soit déjà vidé (ex. reconstruire la
  /// config de géolocalisation sans deviceUniqueId).
  static void registerPostPurgeHook(PurgeHook hook) => _postPurgeHooks.add(hook);

  static Future<void> _safe(PurgeHook hook) async {
    try {
      await hook();
    } catch (error) {
      AppLogger.error('purge_hook_failed', error);
    }
  }

  /// Checklist QA #20 : le Keychain iOS survit à une désinstallation,
  /// contrairement à SharedPreferences. Sans ce traitement, une
  /// réinstallation retrouverait les données du précédent utilisateur de
  /// l'appareil. Cf. scénario 32 du contrat : une réinstallation doit
  /// forcer un nouveau cycle de provisionnement complet.
  static Future<void> _purgeOrphanedKeychainIfReinstalled() async {
    final prefs = await SharedPreferences.getInstance();
    final hasRunBefore = prefs.getBool(_flagHasRunBefore) ?? false;
    if (!hasRunBefore) {
      final orphaned = await _storage.read(key: _keyDriverUniqueId);
      if (orphaned != null) {
        await _storage.deleteAll();
        AppLogger.breadcrumb('keychain_orphan_purged_on_reinstall');
      }
      await prefs.setBool(_flagHasRunBefore, true);
    }
  }

  static Future<void> restoreFromStorage() async {
    await _purgeOrphanedKeychainIfReinstalled();
    final serverUrl = await _storage.read(key: _keyServerUrl);
    final tenantId = await _storage.read(key: _keyTenantId);
    final driverUniqueId = await _storage.read(key: _keyDriverUniqueId);
    if (serverUrl != null && tenantId != null && driverUniqueId != null) {
      _provisioning = ProvisioningData(
        serverUrl: serverUrl,
        tenantId: tenantId,
        driverUniqueId: driverUniqueId,
        driverName: await _storage.read(key: _keyDriverName),
      );
      // ARCHITECTURE-VPN-TLS.md §5 : l'hôte attendu doit être connu de
      // TlsPinning AVANT toute connexion réseau — y compris au redémarrage
      // de l'app avec une session déjà provisionnée, pas seulement au
      // moment du provisionnement initial (voir completeProvisioning
      // ci-dessous pour ce second point d'appel).
      TlsPinning.setExpectedHost(serverUrl);
      // Idem restauration de l'ancre TLS : nécessaire avant toute
      // connexion réseau, pas seulement à l'appairage initial.
      await TlsPinning.restoreFromStorage();
      // Chantier B : restaure la dernière adresse connue AVANT tout appel
      // réseau — api_client.dart::_uri() en dépend dès le premier appel.
      await DiscoveryService.restoreFromStorage();
    }
    final token = await _storage.read(key: _keyToken);
    if (token != null) {
      final expiresAtStr = await _storage.read(key: _keyExpiresAt);
      _session = AuthSession(
        token: token,
        expiresAt: expiresAtStr != null ? DateTime.tryParse(expiresAtStr) : null,
        sessionEpoch: int.tryParse(
            await _storage.read(key: _keySessionEpoch) ?? ''),
      );
    }
    AppLogger.breadcrumb('identity_restored:prov=$isProvisioned,auth=$isAuthenticated');
  }

  /// Étape 1 réussie (§4) : le téléphone est lié au chauffeur. Persiste
  /// AVANT tout appel PIN — la liaison survit à une session expirée.
  static Future<void> completeProvisioning(ProvisioningData data) async {
    // DELTA-v7.7-QR-APPAIRAGE.md §6 (v7.8) : "L'application ne doit plus
    // imposer https:// en local" — l'ancien garde-fou fail-close d'ici a
    // été RETIRÉ (bug trouvé en vérification croisée : il aurait fait
    // échouer silencieusement tout appairage LAN HTTP pourtant validé en
    // amont). La validation d'adresse appartient désormais entièrement au
    // serveur — /api/pair/resolve ou /api/pair/probe ont déjà tranché
    // avant que serverUrl n'arrive jusqu'ici (provisioning_screen.dart).
    // serverUrl sans slash final (§3.1) — normalisation défensive, même si
    // le serveur est censé déjà le renvoyer ainsi.
    final normalizedUrl = data.serverUrl.endsWith('/')
        ? data.serverUrl.substring(0, data.serverUrl.length - 1)
        : data.serverUrl;
    await _storage.write(key: _keyServerUrl, value: normalizedUrl);
    await _storage.write(key: _keyTenantId, value: data.tenantId);
    await _storage.write(key: _keyDriverUniqueId, value: data.driverUniqueId);
    if (data.driverName != null) {
      await _storage.write(key: _keyDriverName, value: data.driverName);
    }
    _provisioning = ProvisioningData(
      serverUrl: normalizedUrl,
      tenantId: data.tenantId,
      driverUniqueId: data.driverUniqueId,
      driverName: data.driverName,
      tlsPinsetPublicKey: data.tlsPinsetPublicKey,
      tlsPinsUrl: data.tlsPinsUrl,
      tlsPins: data.tlsPins,
      tlsPinsSeq: data.tlsPinsSeq,
      serverId: data.serverId,
    );
    TlsPinning.setExpectedHost(normalizedUrl);
    // EPINGLAGE-TLS.md §3 : amorçage de l'ancre de confiance dès
    // l'appairage — TOFU explicite, sûr parce que le QR est scanné en
    // présence du gestionnaire (§6.6). Sans ces quatre champs (flux de
    // test antérieur à ce document, ou écart serveur), TlsPinning reste
    // non amorcé : voir le fail-close dans _acceptCertificate().
    if (data.serverId == null || data.tlsPinsetPublicKey == null ||
        data.tlsPinsUrl == null || data.tlsPins == null ||
        data.tlsPinsSeq == null) {
      await _storage.delete(key: _keyServerUrl);
      await _storage.delete(key: _keyTenantId);
      await _storage.delete(key: _keyDriverUniqueId);
      await _storage.delete(key: _keyDriverName);
      _provisioning = null;
      throw const TlsPinningException(
          'Réponse d’appairage incomplète : ancre TLS absente');
    }
    try {
      await TlsPinning.bootstrapFromPairing(
        serverId: data.serverId!,
        publicKeyBase64: data.tlsPinsetPublicKey!,
        pinsUrl: data.tlsPinsUrl!,
        initialPins: data.tlsPins!,
        initialSeq: data.tlsPinsSeq!,
      );
    } catch (_) {
      // Une écriture d'identité ne doit jamais survivre à un amorçage TLS
      // refusé : sinon le prochain lancement ouvrirait l'écran PIN avec une
      // identité inutilisable et donnerait l'impression d'une panne réseau.
      await _storage.delete(key: _keyServerUrl);
      await _storage.delete(key: _keyTenantId);
      await _storage.delete(key: _keyDriverUniqueId);
      await _storage.delete(key: _keyDriverName);
      _provisioning = null;
      await TlsPinning.reset();
      rethrow;
    }
    // Chantier B : amorce l'adresse vivante sur celle du pairage — la
    // première découverte réussie la remplacera par endpoints.api.
    await DiscoveryService.bootstrap(normalizedUrl);
    AppLogger.breadcrumb('provisioning_completed');
  }

  /// Étape 2 réussie (§5) : PIN validé, token Traccar obtenu.
  static Future<void> completeAuthentication(AuthSession session) async {
    await _storage.write(key: _keyToken, value: session.token);
    if (session.expiresAt != null) {
      await _storage.write(
          key: _keyExpiresAt, value: session.expiresAt!.toIso8601String());
    } else {
      await _storage.delete(key: _keyExpiresAt);
    }
    if (session.sessionEpoch != null) {
      await _storage.write(
          key: _keySessionEpoch, value: session.sessionEpoch.toString());
    } else {
      await _storage.delete(key: _keySessionEpoch);
    }
    _session = session;
    AppLogger.breadcrumb('authentication_completed');
  }

  /// §13.1 — purge "token uniquement" (tokenExpired, accountSuspended,
  /// assignmentRemoved) : retour à l'écran PIN, provisionnement conservé.
  static Future<void> purgeTokenOnly() async {
    for (final hook in _tokenPurgeHooks) {
      await _safe(hook);
    }
    await _storage.delete(key: _keyToken);
    await _storage.delete(key: _keyExpiresAt);
    await _storage.delete(key: _keySessionEpoch);
    _session = null;
    for (final hook in _postPurgeHooks) {
      await _safe(hook);
    }
    AppLogger.breadcrumb('token_purged');
  }

  /// §13.1 — purge "tout" (accountArchived, deviceReplaced, dérive tenant,
  /// déliaison) : retour à l'écran de scan.
  static Future<void> purgeAll() async {
    for (final hook in _tokenPurgeHooks) {
      await _safe(hook);
    }
    for (final hook in _fullPurgeHooks) {
      await _safe(hook);
    }
    await _storage.deleteAll();
    // Retour au scan QR = nouvel appairage à venir = nouvelle ancre TLS à
    // recevoir. Conserver l'ancienne ancre ici bloquerait le prochain
    // appairage (serverId différent) sans raison de le faire.
    await TlsPinning.reset();
    await DiscoveryService.reset();
    _session = null;
    _provisioning = null;
    for (final hook in _postPurgeHooks) {
      await _safe(hook);
    }
    AppLogger.breadcrumb('full_purge_done');
  }

  /// §14 — comparaison systématique du tenantId à chaque `/eligibility`.
  /// Une dérive est une anomalie grave : purge totale immédiate.
  static Future<bool> checkTenantDrift(String tenantIdFromServer) async {
    final current = _provisioning?.tenantId;
    if (current == null) return false;
    if (current != tenantIdFromServer) {
      AppLogger.error('tenant_drift_detected', 'local=$current server=$tenantIdFromServer');
      await purgeAll();
      return true;
    }
    return false;
  }

  /// §5 — compte à rebours de verrouillage PIN (423/429), doit survivre au
  /// redémarrage de l'app : persisté avec une échéance absolue calculée
  /// une seule fois, comparée ensuite au temps courant (simple et
  /// suffisant ici — la fenêtre est de quelques minutes, une éventuelle
  /// erreur d'horloge locale de cet ordre est sans conséquence pratique).
  static Future<void> setPinLockout(DateTime until) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wetrackam_pin_locked_until', until.toIso8601String());
  }

  static Future<DateTime?> getPinLockout() async {
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString('wetrackam_pin_locked_until');
    if (iso == null) return null;
    final until = DateTime.tryParse(iso);
    if (until == null || until.isBefore(DateTime.now())) return null;
    return until;
  }

  static Future<void> clearPinLockout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('wetrackam_pin_locked_until');
  }
}
