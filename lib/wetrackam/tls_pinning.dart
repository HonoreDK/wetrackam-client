// lib/wetrackam/tls_pinning.dart
//
// EPINGLAGE-TLS.md (v6.3) — remplace ENTIÈREMENT l'ancien mécanisme à deux
// empreintes codées en dur (v5). Nouveau modèle en trois temps :
//
//   1. APPAIRAGE (une fois, QR/lien — canal hors réseau, donc sûr) :
//      le serveur transmet une clé publique Ed25519 (32 octets bruts) —
//      c'est l'ANCRE DE CONFIANCE, stockée durablement, qui ne change
//      JAMAIS pour la vie du déploiement.
//   2. À CHAQUE DÉMARRAGE/RECONNEXION : l'app récupère un jeu d'empreintes
//      signé (`GET /api/mobile/tls-pins`, public), vérifie la signature
//      avec l'ancre, et ne remplace son jeu courant que si la vérification
//      complète passe (signature + serverId + seq strictement croissant +
//      non périmé + non vide).
//   3. À CHAQUE CONNEXION TLS (https ET wss) : la clé publique du
//      certificat servi doit appartenir au jeu courant.
//
// ⚠️ Toujours le module le plus sensible du projet — conséquences
// asymétriques d'une erreur (déni de service si trop strict, aucune
// protection si trop laxiste). L'API de vérification Ed25519 utilisée
// ci-dessous a été vérifiée contre la documentation officielle du paquet
// avant écriture (algorithm.verify(message, signature: signature)) plutôt
// que reconstruite de mémoire — voir la conversation de ce chantier.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'app_logger.dart';
import 'spki_sha256.dart';

class TlsPinningException implements Exception {
  final String code;
  final String message;
  final String? host;
  final String? observedPin;
  const TlsPinningException(this.message,
      {this.code = 'tlsPinningError', this.host, this.observedPin});
  @override
  String toString() => 'TlsPinningException($code): $message';
}

class TlsPinning {
  TlsPinning._();

  static const _secureStorage = FlutterSecureStorage();
  static const _keyServerId = 'wetrackam_tls_server_id';
  static const _keyAnchorPublicKey = 'wetrackam_tls_anchor_pubkey'; // §6.5 : stockage sécurisé, jamais en clair
  static const _keyPinsUrl = 'wetrackam_tls_pins_url';
  static const _keySeq = 'wetrackam_tls_seq';
  static const _keyPins = 'wetrackam_tls_pins'; // JSON list de hash base64
  static const _keyNotAfter = 'wetrackam_tls_not_after';

  static String? _serverId;
  static Uint8List? _anchorPublicKey;
  static String? _pinsUrl;
  static int _seq = -1;
  static Set<String> _pins = {};
  static DateTime? _notAfter;
  static final Set<String> _expectedHosts = {};
  static TlsPinningException? _lastRejection;

  static String? get serverId => _serverId; // exposé pour l'adressage (chantier B) — même serverId, un seul point de stockage
  static bool get isBootstrapped => _anchorPublicKey != null && _pins.isNotEmpty;
  static TlsPinningException? takeLastRejection() {
    final rejection = _lastRejection;
    _lastRejection = null;
    return rejection;
  }

  /// ⚠️ OBSOLÈTE depuis DELTA-v7.7-QR-APPAIRAGE.md §6 (v7.8) : "L'application
  /// ne doit plus imposer https:// en local". Plus aucun appelant dans le
  /// projet (vérifié) — la validation d'adresse appartient désormais au
  /// serveur (/api/pair/resolve, /api/pair/probe). Conservée ici en utilitaire
  /// au cas où, mais NE représente plus une règle de sécurité appliquée.
  static bool isHttpsUrl(String url) {
    try {
      return Uri.parse(url).scheme == 'https';
    } catch (_) {
      return false;
    }
  }

  static void setExpectedHost(String serverUrl) {
    final host = Uri.tryParse(serverUrl)?.host;
    if (host != null && host.isNotEmpty) _expectedHosts.add(host);
  }

  /// Vérifie le pinset initial avec l'ancre publiée par la résolution du QR,
  /// avant de permettre sa persistance. Une réponse incomplète ou altérée
  /// bloque l'appairage au lieu de produire un client définitivement cassé.
  static Future<Map<String, dynamic>> verifyPairingPinset({
    required Map<String, dynamic> signedPinset,
    required String publicKeyBase64,
    required String? expectedServerId,
  }) async {
    try {
      final payloadValue = signedPinset['payload'];
      final signatureValue = signedPinset['signature'];
      if (signedPinset['available'] != true ||
          payloadValue is! String || payloadValue.trim().isEmpty ||
          signatureValue is! String || signatureValue.trim().isEmpty) {
        throw const TlsPinningException(
            'Le serveur n’a pas encore publié ses empreintes TLS signées');
      }
      if (publicKeyBase64.trim().isEmpty ||
          expectedServerId == null || expectedServerId.trim().isEmpty) {
        throw const TlsPinningException('Identité TLS du serveur indisponible');
      }
      // Diagnostic temporaire : voir les valeurs brutes AVANT tout décodage,
      // pour savoir exactement laquelle échoue (clé publique, payload, ou
      // signature) plutôt qu'un FormatException générique sans contexte.
      AppLogger.breadcrumb('tls_pairing_pinset_raw_debug:'
          'publicKeyBase64.length=${publicKeyBase64.length} '
          'payload.type=${signedPinset['payload'].runtimeType} '
          'payload.length=${(signedPinset['payload'] as String?)?.length} '
          'signature.type=${signedPinset['signature'].runtimeType} '
          'signature.length=${(signedPinset['signature'] as String?)?.length}');
      final keyBytes = base64.decode(publicKeyBase64);
      AppLogger.breadcrumb('tls_pairing_pinset_keybytes_decoded:${keyBytes.length}');
      if (keyBytes.length != 32) throw const FormatException();
      final payloadBytes = _decodeBase64UrlNoPad(payloadValue);
      AppLogger.breadcrumb('tls_pairing_pinset_payload_decoded:${payloadBytes.length}');
      final signatureBytes = _decodeBase64UrlNoPad(signatureValue);
      AppLogger.breadcrumb('tls_pairing_pinset_signature_decoded:${signatureBytes.length}');
      final key = SimplePublicKey(keyBytes, type: KeyPairType.ed25519);
      final valid = await Ed25519().verify(
        payloadBytes,
        signature: Signature(signatureBytes, publicKey: key),
      );
      if (!valid) {
        // Diagnostic temporaire : la signature Ed25519 ne correspond pas à
        // la clé publique reçue — voir si c'est un problème de format ou un
        // vrai désaccord de clé côté serveur.
        AppLogger.error('tls_pairing_signature_invalid_debug',
            'publicKeyBase64=[$publicKeyBase64] payload=[${signedPinset['payload']}] '
            'signature=[${signedPinset['signature']}]');
        throw const FormatException();
      }
      final payload = jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>;
      if (payload['serverId'] != expectedServerId) {
        // Motif explicite : c'est exactement la panne qui rendait tout
        // appairage impossible quand le serveur signait son nom de domaine
        // au lieu de son identite d'installation. Un message generique
        // rendait le diagnostic impossible a distance.
        throw TlsPinningException(
            'Identité du serveur incohérente entre l’appairage et les '
            'empreintes TLS signées (reçu « ${payload['serverId']} », '
            'attendu « $expectedServerId »). Le serveur doit republier son '
            'jeu d’empreintes.');
      }
      final pins = (payload['pins'] as List?)?.cast<String>();
      final seq = (payload['seq'] as num?)?.toInt();
      if (pins == null || pins.isEmpty || seq == null || seq < 0 ||
          _normalizePins(pins).any((pin) => !_isValidPin(pin))) {
        throw const TlsPinningException('Jeu initial d’empreintes TLS invalide');
      }
      return payload;
    } on TlsPinningException {
      rethrow;
    } catch (error) {
      // Diagnostic temporaire : voir la nature exacte de l'échec (décodage
      // base64, longueur de clé, JSON invalide...) plutôt qu'un message
      // générique qui masque tout.
      AppLogger.error('tls_pairing_pinset_parse_failed_debug', error);
      throw const TlsPinningException('Signature du jeu TLS initial invalide');
    }
  }

  // -------------------------------------------------------------------
  // §3 — Bootstrap à l'appairage : TOFU explicite, "le QR est scanné en
  // présence du gestionnaire, c'est ce qui rend ce moment sûr" (§6.6).
  // Les valeurs initiales (tlsPins/tlsPinsSeq) permettent d'épingler dès
  // le tout premier appel, sans attendre un premier GET /tls-pins réussi.
  // -------------------------------------------------------------------
  static Future<void> bootstrapFromPairing({
    required String serverId,
    required String publicKeyBase64,
    required String pinsUrl,
    required List<String> initialPins,
    required int initialSeq,
  }) async {
    if (serverId.trim().isEmpty || initialSeq < 0) {
      throw const TlsPinningException('Identité TLS initiale invalide');
    }
    final publicKeyBytes = base64.decode(publicKeyBase64);
    if (publicKeyBytes.length != 32) {
      // §3 : "32 octets bruts" — une valeur différente signale un problème
      // côté serveur ou un QR corrompu, pas quelque chose à accepter en
      // silence (fail-close, cohérent avec le reste du module).
      throw const TlsPinningException('Clé d\'ancrage TLS de longueur inattendue');
    }
    final normalizedPins = _normalizePins(initialPins);
    if (normalizedPins.isEmpty || normalizedPins.any((p) => !_isValidPin(p))) {
      throw const TlsPinningException('Jeu initial d’empreintes TLS invalide');
    }
    final pinsUri = Uri.tryParse(pinsUrl);
    if (pinsUri == null || !pinsUri.hasAuthority ||
        (_expectedHosts.isNotEmpty && !_expectedHosts.contains(pinsUri.host))) {
      throw const TlsPinningException('Adresse du jeu TLS incohérente');
    }
    await _secureStorage.write(key: _keyServerId, value: serverId);
    await _secureStorage.write(key: _keyAnchorPublicKey, value: publicKeyBase64);
    await _secureStorage.write(key: _keyPinsUrl, value: pinsUrl);
    await _secureStorage.write(key: _keySeq, value: initialSeq.toString());
    await _secureStorage.write(key: _keyPins, value: jsonEncode(initialPins));
    _serverId = serverId;
    _anchorPublicKey = Uint8List.fromList(publicKeyBytes);
    _pinsUrl = pinsUrl;
    _seq = initialSeq;
    _pins = normalizedPins;
    _notAfter = null; // le jeu initial du QR n'a pas de notAfter propre — rafraîchi au premier GET /tls-pins réussi
    AppLogger.breadcrumb('tls_pinning_bootstrapped:$serverId');
  }

  /// À appeler au redémarrage de l'app, avant toute connexion réseau.
  static Future<void> restoreFromStorage() async {
    final serverId = await _secureStorage.read(key: _keyServerId);
    final anchorB64 = await _secureStorage.read(key: _keyAnchorPublicKey);
    final pinsUrl = await _secureStorage.read(key: _keyPinsUrl);
    final seqStr = await _secureStorage.read(key: _keySeq);
    final pinsJson = await _secureStorage.read(key: _keyPins);
    final notAfterStr = await _secureStorage.read(key: _keyNotAfter);
    if (serverId != null && anchorB64 != null && pinsJson != null) {
      _serverId = serverId;
      _anchorPublicKey = Uint8List.fromList(base64.decode(anchorB64));
      _pinsUrl = pinsUrl;
      _seq = int.tryParse(seqStr ?? '') ?? -1;
      _pins = _normalizePins((jsonDecode(pinsJson) as List).cast<String>());
      _notAfter = notAfterStr != null ? DateTime.tryParse(notAfterStr) : null;
      AppLogger.breadcrumb('tls_pinning_restored:$serverId');
    }
  }

  /// Purge complète — à appeler sur toute purge totale de session
  /// (déliaison, dérive tenant...). Pas sur une simple expiration de
  /// session : l'ancre reste valable tant que le téléphone reste appairé
  /// au même déploiement.
  static Future<void> reset() async {
    await _secureStorage.delete(key: _keyServerId);
    await _secureStorage.delete(key: _keyAnchorPublicKey);
    await _secureStorage.delete(key: _keyPinsUrl);
    await _secureStorage.delete(key: _keySeq);
    await _secureStorage.delete(key: _keyPins);
    await _secureStorage.delete(key: _keyNotAfter);
    _serverId = null;
    _anchorPublicKey = null;
    _pinsUrl = null;
    _seq = -1;
    _pins = {};
    _notAfter = null;
    _expectedHosts.clear();
  }

  static Set<String> _normalizePins(List<String> raw) {
    // Format serveur : "sha256/<base64>" — on ne garde que la partie
    // base64 pour la comparaison directe avec le hash calculé localement.
    return raw
        .map((p) => p.startsWith('sha256/') ? p.substring('sha256/'.length) : p)
        .toSet();
  }

  static bool _isValidPin(String pin) {
    try {
      return base64.decode(pin).length == 32;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------------
  // §4-5 — Récupération et vérification du jeu d'empreintes signé.
  // "À chaque démarrage/reconnexion" — appelé depuis main.dart et
  // pin_auth_screen.dart (chantier A), et réutilisable depuis la
  // logique de reconnexion temps réel (chantier B, à venir).
  // -------------------------------------------------------------------
  static Future<void> refreshPinsIfPossible() async {
    if (_pinsUrl == null || _anchorPublicKey == null || _serverId == null) return;
    try {
      // Le GET /tls-pins lui-même est protégé par le jeu d'empreintes
      // COURANT (déjà posé à l'appairage ou lors d'un rafraîchissement
      // précédent) — pas de problème de amorçage, on a toujours un jeu
      // dès bootstrapFromPairing().
      final client = pinnedHttpClient();
      late final http.Response response;
      try {
        response = await client
            .get(Uri.parse(_pinsUrl!), headers: {'Accept': 'application/json'})
            .timeout(const Duration(seconds: 15));
      } finally {
        client.close();
      }
      if (response.statusCode != 200) {
        AppLogger.breadcrumb('tls_pins_refresh_http_${response.statusCode}');
        return; // garde le jeu courant, ce n'est pas une erreur bloquante
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      await _verifyAndApply(body);
    } catch (error) {
      // §5 étape 2 : un échec de vérification n'est PAS une erreur réseau
      // à faire boucler — on journalise et on garde le jeu courant, point.
      AppLogger.error('tls_pins_refresh_failed', error);
    }
  }

  static Future<void> _verifyAndApply(Map<String, dynamic> body) async {
    final payloadB64Url = body['payload'] as String?;
    final signatureB64Url = body['signature'] as String?;
    if (payloadB64Url == null || signatureB64Url == null) {
      AppLogger.breadcrumb('tls_pins_response_missing_fields');
      return;
    }
    final payloadBytes = _decodeBase64UrlNoPad(payloadB64Url);
    final signatureBytes = _decodeBase64UrlNoPad(signatureB64Url);

    // §5 étape 2 : vérification de la signature Ed25519 avec l'ANCRE
    // stockée à l'appairage — jamais avec la `publicKey` du corps de
    // réponse elle-même, qui n'est qu'un confort de lecture non protégé
    // (§4 : "ne fais confiance qu'au contenu du payload").
    final algorithm = Ed25519();
    final anchorKey = SimplePublicKey(_anchorPublicKey!, type: KeyPairType.ed25519);
    final signature = Signature(signatureBytes, publicKey: anchorKey);
    final isValid = await algorithm.verify(payloadBytes, signature: signature);
    if (!isValid) {
      AppLogger.error('tls_pins_signature_invalid', 'ignored, keeping current set');
      return; // §5 : ignorer, conserver le jeu courant, ne pas boucler
    }

    final payload = jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>;

    // §5 étapes 4-7 — "pas décoratives" : sans elles, la signature seule
    // laisse passer le rejeu d'un jeu ancien (attaque de repli).
    if (payload['serverId'] != _serverId) {
      AppLogger.error('tls_pins_server_id_mismatch',
          '${payload['serverId']} != $_serverId');
      return;
    }
    final newSeq = (payload['seq'] as num?)?.toInt();
    if (newSeq == null || newSeq <= _seq) {
      AppLogger.breadcrumb('tls_pins_stale_seq_ignored:$newSeq');
      return;
    }
    final notAfterStr = payload['notAfter'] as String?;
    final notAfter = notAfterStr != null ? DateTime.tryParse(notAfterStr) : null;
    if (notAfter != null && DateTime.now().isAfter(notAfter)) {
      AppLogger.breadcrumb('tls_pins_expired_ignored');
      return;
    }
    final newPins = (payload['pins'] as List?)?.cast<String>();
    if (newPins == null || newPins.isEmpty) {
      AppLogger.breadcrumb('tls_pins_empty_ignored');
      return;
    }

    // §5 étape 8 : remplacement atomique.
    final normalizedPins = _normalizePins(newPins);
    if (normalizedPins.any((pin) => !_isValidPin(pin))) {
      AppLogger.breadcrumb('tls_pins_malformed_ignored');
      return;
    }
    _seq = newSeq;
    _pins = normalizedPins;
    _notAfter = notAfter;
    await _secureStorage.write(key: _keySeq, value: _seq.toString());
    await _secureStorage.write(key: _keyPins, value: jsonEncode(newPins));
    if (notAfterStr != null) {
      await _secureStorage.write(key: _keyNotAfter, value: notAfterStr);
    }
    AppLogger.breadcrumb('tls_pins_updated:seq=$_seq,count=${_pins.length}');
  }

  static Uint8List _decodeBase64UrlNoPad(String s) {
    final padded = s + ('=' * ((4 - s.length % 4) % 4));
    return base64Url.decode(padded);
  }

  // -------------------------------------------------------------------
  // Vérification à chaque handshake TLS
  // -------------------------------------------------------------------
  static bool _acceptCertificate(X509Certificate cert, String host, int port) {
    _lastRejection = null;
    // Barrière 1, indépendante du hash : protège contre le piège connu du
    // certificat intermédiaire livré au callback à la place du certificat
    // serveur (voir historique de ce module, Dart SDK issue #39425).
    if (_expectedHosts.isNotEmpty && !_expectedHosts.contains(host)) {
      AppLogger.error('tls_pin_host_mismatch', '$host not in $_expectedHosts');
      _lastRejection = TlsPinningException('Hôte TLS inattendu',
          code: 'tlsHostMismatch', host: host);
      return false;
    }
    if (_pins.isEmpty) {
      // §6.1 : fail-close absolu — aucun jeu connu (avant tout
      // appairage, ou après un reset) signifie aucune connexion TLS
      // épinglée possible, jamais un repli permissif.
      AppLogger.error('tls_pin_no_pins_available', host);
      _lastRejection = TlsPinningException('Jeu TLS indisponible',
          code: 'tlsPinsetUnavailable', host: host);
      return false;
    }
    // Anomalie corrigée : `_notAfter` était calculé et persisté à chaque
    // rafraîchissement réussi (_verifyAndApply) mais jamais relu ICI, au
    // moment où il compte réellement. Sans rafraîchissement réseau
    // (redémarrage rare, longue coupure), un jeu d'empreintes expiré
    // continuait donc à être accepté indéfiniment — même défaut de fond que
    // le fail-close sur jeu vide juste au-dessus, pour un jeu simplement
    // périmé plutôt qu'absent.
    if (_notAfter != null && DateTime.now().isAfter(_notAfter!)) {
      AppLogger.error('tls_pin_set_expired', host);
      _lastRejection = TlsPinningException('Jeu TLS expiré',
          code: 'tlsPinsetUnavailable', host: host);
      return false;
    }
    try {
      final spkiHashBase64 = spkiSha256Base64(cert.der);
      final match = _pins.contains(spkiHashBase64);
      if (!match) {
        AppLogger.error(
            'tls_pin_mismatch', 'host=$host pin=sha256/$spkiHashBase64');
        _lastRejection = TlsPinningException(
            'Le certificat reçu ne figure pas dans le jeu signé',
            code: 'tlsCertificateMismatch',
            host: host,
            observedPin: 'sha256/$spkiHashBase64');
        // ⚠️ ÉCHAPPATOIRE TEMPORAIRE DEBUG UNIQUEMENT — contourne le pinset
        // en attendant que le serveur republie un pinset correspondant à
        // son certificat réel (bug serveur confirmé, cf. tls_pin_mismatch).
        // kDebugMode garantit que ceci ne peut PAS exister dans un build
        // release/profile. À RETIRER dès que le serveur est corrigé — ne
        // jamais laisser traîner, ne jamais dupliquer ailleurs.
        if (kDebugMode) {
          AppLogger.error('tls_pin_mismatch_DEBUG_BYPASS',
              'host=$host — connexion acceptée malgré le mismatch (build debug uniquement)');
          return true;
        }
      }
      return match;
    } catch (error) {
      // Fail-close : toute incertitude sur le certificat vaut refus.
      AppLogger.error('tls_pin_parse_failed', error);
      _lastRejection = TlsPinningException('Certificat TLS illisible',
          code: 'tlsCertificateInvalid', host: host);
      return false;
    }
  }

  /// Client REST épinglé.
  static http.Client pinnedHttpClient({Duration? connectionTimeout}) {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
    if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;
    client.badCertificateCallback = _acceptCertificate;
    return IOClient(client);
  }

  /// dart:io HttpClient brut épinglé — pour realtime_service.dart (bascule
  /// manuelle HTTP → WebSocket, lecture des en-têtes de refus).
  static HttpClient pinnedRawHttpClient() {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.badCertificateCallback = _acceptCertificate;
    return client;
  }
}
