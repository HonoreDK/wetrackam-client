// lib/wetrackam/provisioning_screen.dart
//
// DELTA-v7.7-QR-APPAIRAGE.md — remplace l'ancien parseur local strict
// (wetrackam://... OU https://.../provision/<token>, https uniquement).
//
// Deux flux distincts, dispatchés par forme du contenu :
//  1. QR scanné / lien collé (contient un token) → POST /api/pair/resolve,
//     "la voie recommandée" du document — le serveur résout tous les
//     formats (canonique, ancien lien v6, deep-link, JSON hérité).
//     Simplification assumée : je n'implémente PAS le parsing local du
//     lien canonique (§1-§2 du document offrent explicitement resolve
//     comme alternative complète — "si tu préfères ne rien parser").
//  2. Adresse tapée à la main (pas de token) → POST /api/pair/probe,
//     §6/v7.8 : plus aucune règle https:// locale, le serveur tranche.
//
// ⚠️ Incohérence trouvée dans le document lui-même, signalée à Victor :
// l'exemple JSON de /api/pair/resolve montre un champ "base", mais le
// texte juste après dit de ne retenir que "useBase" (nom qui n'apparaît
// que dans l'exemple de /api/pair/probe). Les deux noms sont lus ici,
// useBase préféré s'il est présent.
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'api_client.dart';
import 'app_logger.dart';
import 'driver_identity_service.dart';
import 'error_catalog.dart';
import 'pin_auth_screen.dart';
import 'theme.dart';
import 'tls_pinning.dart';

class ProvisioningScreen extends StatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  State<ProvisioningScreen> createState() => _ProvisioningScreenState();
}

class _ProvisioningScreenState extends State<ProvisioningScreen> {
  final _inputController = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _info; // message neutre (ex. adresse confirmée), pas une erreur
  bool _offerReset = false;
  bool _showScanner = true;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  // ===================================================================
  // Dispatch : contenu de pairage (a un token) vs adresse nue (pas de
  // token) — heuristique simple sur la forme, pas une tentative de tout
  // deviner : un schéma wetrackam:// ou un chemin après l'hôte signale un
  // lien de pairage ; un hôte seul (avec ou sans port) est une adresse.
  // ===================================================================
  bool _looksLikePairingContent(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return false;
    if (uri.scheme == 'wetrackam') return true;
    if (uri.pathSegments.where((s) => s.isNotEmpty).isNotEmpty) return true;
    return false;
  }

  void _submitInput(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    if (_looksLikePairingContent(trimmed)) {
      _submitPairingContent(trimmed);
    } else {
      _submitManualAddress(trimmed);
    }
  }

  // ===================================================================
  // Flux 1 — QR scanné ou lien de pairage collé
  // ===================================================================

  /// Détermine l'hôte à interroger pour /api/pair/resolve — "l'hôte lu
  /// dans la chaîne" (§3 étape 3), jamais un annuaire central.
  String? _hostHintForResolve(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.hasAuthority && uri.host.isNotEmpty) {
      final scheme = uri.scheme.isNotEmpty ? uri.scheme : 'https';
      return '$scheme://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    }
    // wetrackam://provision?...&s=<url> (ancien format v6, toujours
    // accepté par le serveur, §2) : l'hôte réel est dans le paramètre s.
    final s = uri.queryParameters['s'];
    if (s != null) {
      final sUri = Uri.tryParse(s);
      if (sUri != null && sUri.host.isNotEmpty) return s;
    }
    return null;
  }

  Future<void> _submitPairingContent(String raw) async {
    final hostHint = _hostHintForResolve(raw);
    if (hostHint == null) {
      setState(() => _error = 'Lien ou QR code non reconnu.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
      _offerReset = false;
    });
    try {
      final resolved = await WetrackamApiClient.resolvePairing(
        scanned: raw,
        hostHint: hostHint,
      );
      final token = resolved['token'] as String?;
      // Voir avertissement d'en-tête de fichier — useBase préféré, base en repli.
      final useBase = (resolved['useBase'] ?? resolved['base']) as String?;
      if (token == null || token.trim().isEmpty ||
          useBase == null || useBase.trim().isEmpty) {
        setState(() => _error = 'Réponse du serveur incomplète. Réessayez.');
        return;
      }
      await _exchangeAndComplete(
        serverUrl: useBase,
        token: token,
        expectedServerId: resolved['serverId'] as String?,
        expectedPinsetPublicKey: resolved['tlsPinsetPublicKey'] as String?,
      );
    } on NetworkException {
      setState(() => _error = 'Connexion impossible. Vérifiez le réseau et réessayez.');
    } on ApiException catch (error) {
      setState(() {
        // §2 : "Un format inconnu renvoie 400 pairingUnrecognized... jamais
        // un plantage" — traité par le catalogue comme les autres erreurs
        // de provisionnement, même famille de messages.
        _error = ErrorCatalog.provisioning(error.error);
        _offerReset = error.error == 'deviceBoundToOtherDriver';
      });
    } catch (error) {
      AppLogger.error('pairing_resolve_unexpected', error);
      setState(() => _error = 'Une erreur est survenue. Réessayez.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Commun aux deux voies d'obtention d'un token (resolve, ou l'ancien
  /// format déjà résolu) — inchangé du Chantier A : c'est cette réponse
  /// qui amorce réellement l'ancre TLS complète (§3 EPINGLAGE-TLS.md),
  /// resolve/probe n'en donnent qu'un aperçu partiel.
  Future<void> _exchangeAndComplete({
    required String serverUrl,
    required String token,
    required String? expectedServerId,
    required String? expectedPinsetPublicKey,
  }) async {
    final response = await WetrackamApiClient.exchangeProvisioningToken(
      serverUrl: serverUrl,
      token: token,
      expectedServerId: expectedServerId,
      expectedPinsetPublicKey: expectedPinsetPublicKey,
    );
    final signedPinset = response['tlsPinset'] as Map<String, dynamic>?;
    final responseServerId = response['serverId'] as String?;
    final responsePublicKey = response['tlsPinsetPublicKey'] as String?;
    final pinsUrl = response['tlsPinsUrl'] as String?;
    if (expectedServerId == null || expectedServerId.trim().isEmpty ||
        expectedPinsetPublicKey == null || expectedPinsetPublicKey.trim().isEmpty ||
        responseServerId == null || responseServerId.trim().isEmpty ||
        responsePublicKey == null || responsePublicKey.trim().isEmpty ||
        signedPinset == null || pinsUrl == null) {
      throw const TlsPinningException('Réponse d’appairage TLS incomplète');
    }
    if (responseServerId != expectedServerId ||
        responsePublicKey != expectedPinsetPublicKey) {
      // Diagnostic temporaire : voir les valeurs exactes en jeu pour
      // distinguer un vrai désaccord serveur d'un problème de format
      // (casse, espaces, encodage) côté client.
      AppLogger.error('tls_identity_mismatch_debug',
          'expectedServerId=[$expectedServerId] responseServerId=[$responseServerId] '
          'expectedPinsetPublicKey=[$expectedPinsetPublicKey] responsePublicKey=[$responsePublicKey]');
      throw const TlsPinningException('Identité du serveur incohérente');
    }
    if (signedPinset['available'] != true ||
        (signedPinset['payload'] as String?)?.trim().isEmpty != false ||
        (signedPinset['signature'] as String?)?.trim().isEmpty != false) {
      throw const TlsPinningException(
          'Le serveur n’a pas encore publié ses empreintes TLS signées');
    }
    final initialPinset = await TlsPinning.verifyPairingPinset(
      signedPinset: signedPinset,
      publicKeyBase64: expectedPinsetPublicKey,
      expectedServerId: expectedServerId,
    );
    await DriverIdentityService.completeProvisioning(ProvisioningData(
      serverUrl: response['serverUrl'] as String? ?? serverUrl,
      tenantId: response['tenantId'] as String,
      driverUniqueId: response['driverUniqueId'] as String,
      driverName: response['driverName'] as String?,
      serverId: responseServerId,
      tlsPinsetPublicKey: responsePublicKey,
      tlsPinsUrl: pinsUrl,
      tlsPins: (initialPinset['pins'] as List).cast<String>(),
      tlsPinsSeq: (initialPinset['seq'] as num).toInt(),
    ));
    AppLogger.breadcrumb('provisioning_success:replay=${response['replay']}');
    if (mounted) {
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const PinAuthScreen()));
    }
  }

  // ===================================================================
  // Flux 2 — Adresse tapée à la main (v7.8, §6)
  // ===================================================================

  /// §6 : "l'échelle de repli" — classification purement LOCALE et
  /// indicative, utilisée uniquement pour CHOISIR quelles adresses
  /// essayer en cas d'échec de transport. Ne remplace jamais le verdict
  /// du serveur (/api/pair/probe) : celui-ci reste seul juge de ce qui
  /// est autorisé.
  bool _looksPrivateHost(String host) {
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(host);
    if (ipv4 != null) {
      final a = int.parse(ipv4.group(1)!);
      final b = int.parse(ipv4.group(2)!);
      if (a == 10) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 169 && b == 254) return true; // lien-local
    }
    final h = host.toLowerCase();
    if (h.endsWith('.local')) return true;
    if (h.startsWith('fd') || h.startsWith('fc') || h.startsWith('fe80')) return true; // IPv6 ULA/lien-local, best-effort
    if (!h.contains('.') && !h.contains(':')) return true; // nom sans point (serveur-atelier)
    return false;
  }

  Future<void> _submitManualAddress(String raw) async {
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      // §6 étape 1 : "ne rien valider localement au-delà de champ non
      // vide" — déjà garanti par l'appelant (_submitInput). Étape 2 :
      // sonder l'adresse telle quelle en premier.
      final firstResult = await _probeWithFallback(raw);
      if (firstResult == null) {
        setState(() => _error =
            'Serveur introuvable à cette adresse. Vérifiez que le téléphone est sur le même réseau Wi-Fi que le serveur.');
        return;
      }
      final (ok, body) = firstResult;
      if (!ok) {
        // §6 étape 4 : verdict de règle — message serveur affiché tel
        // quel, saisie conservée, aucun réessai automatique.
        setState(() => _error = body['message'] as String? ?? 'Adresse refusée.');
        return;
      }
      final serverId = body['serverId'] as String?;
      final useBase = body['useBase'] as String?;
      if (serverId == null || useBase == null) {
        setState(() => _error = 'Réponse du serveur incomplète. Réessayez.');
        return;
      }
      // §6 ne décrit aucune suite (pas de token obtenu par cette voie) —
      // "cet écran reste un dernier recours : le scan du QR demeure le
      // mode normal". Une fois l'adresse confirmée joignable, on
      // renvoie donc vers le scanner plutôt que d'inventer une suite non
      // documentée.
      setState(() {
        _info = 'Adresse confirmée ($useBase). Scannez maintenant le QR fourni '
            'par votre gestionnaire.';
        _showScanner = true;
      });
      AppLogger.breadcrumb('manual_address_probe_confirmed:$serverId');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// §6 "L'échelle de repli" : jusqu'à 3 tentatives, 4s chacune. Retourne
  /// (ok, corpsDeRéponse) dès qu'une tentative RÉPOND (200 ou 422 —
  /// verdict de règle) ; retourne null si toutes les tentatives
  /// applicables échouent au niveau transport (aucune réponse).
  Future<(bool, Map<String, dynamic>)?> _probeWithFallback(String raw) async {
    final candidates = <String>[];
    // 1. La saisie telle quelle, schéma déduit si absent.
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(raw);
    if (hasScheme) {
      candidates.add(raw);
    } else {
      // Déduction minimale pour pouvoir émettre une requête HTTP —
      // /api/pair/probe reste seul juge de ce qui est réellement permis,
      // cette déduction ne fait que choisir où frapper en premier.
      final hostOnly = raw.split('/').first.split('?').first;
      final hostPart = hostOnly.contains(':') && !hostOnly.startsWith('[')
          ? hostOnly.split(':').first
          : hostOnly;
      candidates.add(_looksPrivateHost(hostPart) ? 'http://$raw' : 'https://$raw');
    }
    // Hôte nu, pour construire les repènes 2/3 ci-dessous.
    final probeHost = Uri.tryParse(candidates.first)?.host ?? raw;
    if (_looksPrivateHost(probeHost)) {
      candidates.add('http://$probeHost:8082'); // §6 étape 2
    } else {
      candidates.add('https://$probeHost'); // §6 étape 3
    }

    for (final candidate in candidates.toSet()) {
      try {
        final body = await WetrackamApiClient.probeAddress(candidateBase: candidate);
        return (body['ok'] == true, body);
      } catch (_) {
        continue; // échec transport sur CE candidat — essayer le suivant
      }
    }
    return null; // tous les candidats applicables ont échoué au transport
  }

  Future<void> _resetDevice() async {
    await DriverIdentityService.purgeAll();
    if (mounted) setState(() => _error = null);
  }

  void _onQrDetect(BarcodeCapture capture) {
    if (_loading) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    setState(() => _showScanner = false);
    _submitPairingContent(raw); // un QR est toujours un contenu de pairage, jamais une adresse nue
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WetrackamColors.lilacTint,
      body: SafeArea(child: _showScanner ? _buildScanner() : _buildManual()),
    );
  }

  Widget _buildScanner() {
    return Column(
      children: [
        AppBar(
          title: const Text('Scanner mon QR'),
          actions: [
            TextButton(
              onPressed: () => setState(() => _showScanner = false),
              child: const Text('Saisie manuelle', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
        Expanded(child: MobileScanner(onDetect: _onQrDetect)),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null || _info != null) _messageBlock(),
      ],
    );
  }

  Widget _buildManual() {
    // Anomalie corrigée : ce contenu débordait (RenderFlex overflowed) sur
    // petit écran ou avec une échelle de texte système agrandie, faute de
    // pouvoir défiler. `mainAxisSize: min` évite qu'un Column désormais
    // scrollable ne tente de forcer une hauteur infinie.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.qr_code_2, size: 64, color: WetrackamColors.purple),
          const SizedBox(height: 16),
          Text('Bienvenue sur WeTrackam',
              style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text(
            'Scannez le QR fourni par votre gestionnaire pour lier ce téléphone.',
            textAlign: TextAlign.center,
            style: TextStyle(color: WetrackamColors.slate),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _loading ? null : () => setState(() => _showScanner = true),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scanner le QR'),
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          // v7.8 : un seul champ, lien de pairage OU adresse de serveur —
          // plus de placeholder suggérant un domaine https obligatoire.
          const Text(
            'Ou collez un lien reçu par WhatsApp/e-mail, ou saisissez '
            'l\'adresse de votre serveur (ex. 192.168.1.20:8082) :',
            style: TextStyle(color: WetrackamColors.slate),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _inputController,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            enabled: !_loading,
            autocorrect: false,
          ),
          const SizedBox(height: 16),
          if (_error != null || _info != null) _messageBlock(),
          FilledButton(
            onPressed: _loading ? null : () => _submitInput(_inputController.text),
            child: _loading
                ? const SizedBox(height: 20, width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Valider'),
          ),
        ],
      ),
    );
  }

  Widget _messageBlock() {
    final isError = _error != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(children: [
        Text(
          (isError ? _error : _info)!,
          style: TextStyle(color: isError ? WetrackamColors.error : WetrackamColors.slate),
          textAlign: TextAlign.center,
        ),
        if (_offerReset)
          TextButton(
            onPressed: _resetDevice,
            child: const Text('Réinitialiser cet appareil'),
          ),
      ]),
    );
  }
}
