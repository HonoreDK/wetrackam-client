// lib/wetrackam/pin_auth_screen.dart
//
// §5 — Règles de sécurité mobiles respectées :
//  1. Le PIN n'est jamais persisté (variable locale, effacée après usage).
//  2. Champ masqué, clavier numérique, pas de suggestion.
//  3. Le verrouillage 423/429 survit au redémarrage (DriverIdentityService
//     .setPinLockout, basé sur une échéance absolue persistée).
//  4. Jamais de distinction visuelle "identifiant inconnu" vs "PIN faux"
//     (les deux passent par ErrorCatalog.driverAuth('invalidCredentials')).
//
// Note : FLAG_SECURE (anti-capture d'écran Android) est "conseillé" par le
// contrat mais non implémenté ici (nécessiterait un plugin/canal de
// plateforme dédié) — à ajouter en amélioration ultérieure si requis.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api_client.dart';
import 'app_logger.dart';
import 'driver_identity_service.dart';
import 'eligibility_screen.dart';
import 'error_catalog.dart';
import 'geolocation_bridge.dart';
import 'provisioning_screen.dart';
import 'push_notifications_service.dart';
import 'rtc_config_service.dart';
import 'tls_pinning.dart';
import 'theme.dart';

class PinAuthScreen extends StatefulWidget {
  const PinAuthScreen({super.key});

  @override
  State<PinAuthScreen> createState() => _PinAuthScreenState();
}

class _PinAuthScreenState extends State<PinAuthScreen> {
  final _pinController = TextEditingController();
  bool _loading = false;
  String? _error;
  /// Vrai quand l'échec ne se réglera pas en réessayant : le téléphone
  /// doit être réappairé. On propose alors le scan plutôt que de laisser
  /// le chauffeur retaper son code indéfiniment.
  bool _offerRepairing = false;
  DateTime? _lockedUntil;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _checkExistingLockout();
  }

  @override
  void dispose() {
    _pinController.clear(); // §5.1 — le PIN ne doit survivre nulle part
    _pinController.dispose();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _checkExistingLockout() async {
    final until = await DriverIdentityService.getPinLockout();
    if (until != null && mounted) {
      setState(() => _lockedUntil = until);
      _startTicking();
    }
  }

  void _startTicking() {
    _tick?.cancel();
    // Tick à 1 s (pas 250 ms comme la référence useDriverAuth.js) : notre
    // affichage est en mm:ss, pas en millisecondes brutes — un tick plus
    // fin ne changerait rien à l'écran et réveillerait l'app pour rien.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_lockedUntil == null) return;
      if (DateTime.now().isAfter(_lockedUntil!)) {
        setState(() => _lockedUntil = null);
        _tick?.cancel();
      } else {
        setState(() {}); // rafraîchit juste le mm:ss affiché
      }
    });
  }

  String _formatCountdown() {
    if (_lockedUntil == null) return '';
    final remaining = _lockedUntil!.difference(DateTime.now());
    if (remaining.isNegative) return '00:00';
    final mm = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  Future<void> _submit() async {
    final pin = _pinController.text;
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      setState(() => _error = 'Le code doit contenir 4 à 8 chiffres.');
      return;
    }
    final driverUniqueId = DriverIdentityService.provisioning?.driverUniqueId;
    if (driverUniqueId == null) {
      // Ne devrait jamais arriver (cet écran suppose un provisionnement
      // déjà fait) — repli défensif vers le scan.
      if (mounted) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const ProvisioningScreen()));
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _offerRepairing = false;
    });
    try {
      final response = await WetrackamApiClient.driverAuth(
        driverUniqueId: driverUniqueId, pin: pin);
      _pinController.clear(); // §5.1
      final tenantId = response['tenantId']?.toString();
      if (tenantId != null) {
        final drifted = await DriverIdentityService.checkTenantDrift(tenantId);
        if (drifted) {
          if (mounted) {
            Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const ProvisioningScreen()));
          }
          return;
        }
      }
      await DriverIdentityService.completeAuthentication(AuthSession(
        token: response['token'] as String,
        expiresAt: response['expiresAt'] != null
            ? DateTime.tryParse(response['expiresAt'] as String)
            : null,
        sessionEpoch: (response['sessionEpoch'] as num).toInt(),
      ));
      await DriverIdentityService.clearPinLockout();
      AppLogger.breadcrumb('pin_auth_success');
      // Anomalie corrigée : sans cet appel, le plugin de géolocalisation
      // n'était jamais démarré (voir geolocation_service.dart::start) —
      // aucune position n'était donc jamais capturée, même en service actif.
      unawaited(GeolocationBridge.start());
      // §9.1 ACTIVATION-FCM.md : enregistrer le jeton FCM juste après
      // authentification réussie. Ne bloque jamais la navigation — un
      // échec ici est journalisé en interne, pas affiché au chauffeur.
      unawaited(PushNotificationsService.registerAfterAuth());
      // Lot 5 (§2) : "à appeler avant tout le reste" — démarré au même
      // moment, sans bloquer la navigation non plus (les écrans Lots 6-8
      // consulteront RtcConfigService.isAvailable une fois prêts).
      unawaited(RtcConfigService.start());
      // EPINGLAGE-TLS.md §4-5 : "à chaque démarrage/reconnexion" —
      // l'authentification réussie en est une, au même titre que le
      // démarrage de l'app (déjà couvert dans main.dart).
      unawaited(TlsPinning.refreshPinsIfPossible());
      if (mounted) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const EligibilityScreen()));
      }
    }
    // ⚠️ ORDRE CRITIQUE — les blocs les plus SPÉCIFIQUES d'abord.
    // TlsTrustException, NetworkException, SessionInvalidException et
    // RateLimitedException héritent toutes d'ApiException : tant que
    // `on ApiException` figurait en premier, il les interceptait toutes et
    // leurs messages dédiés n'étaient jamais atteints. Une coupure réseau
    // affichait donc, elle aussi, « Une erreur est survenue ».
    on TlsTrustException catch (error) {
      _pinController.clear();
      AppLogger.error('pin_auth_tls_refused',
          '${error.code} pin=${error.observedPin ?? "-"}');
      if (mounted) {
        setState(() {
          _error = ErrorCatalog.tls(error.code);
          _offerRepairing = ErrorCatalog.tlsNeedsRepairing(error.code);
        });
      }
    } on NetworkException {
      _pinController.clear();
      if (mounted) setState(() => _error = 'Connexion impossible. Vérifiez le réseau.');
    } on ApiException catch (error) {
      _pinController.clear(); // §5.1 — jamais conservé, même après échec
      if (error.statusCode == 423 || error.statusCode == 429) {
        final seconds = error.retryAfterSeconds ??
            (error.retryAfterMs != null ? (error.retryAfterMs! / 1000).ceil() : 60);
        final until = DateTime.now().add(Duration(seconds: seconds));
        await DriverIdentityService.setPinLockout(until);
        if (mounted) {
          setState(() {
            _lockedUntil = until;
            _error = error.statusCode == 429
                ? 'Trop de tentatives depuis ce réseau.'
                : null;
          });
        }
        _startTicking();
      } else {
        // Le délai n'est mis en forme que s'il est réellement parlant :
        // le serveur renvoie couramment retryAfterMs=400, et « réessayez
        // dans 1 s » n'apporte rien au chauffeur.
        final seconds = error.retryAfterSeconds ??
            (error.retryAfterMs != null
                ? (error.retryAfterMs! / 1000).ceil()
                : null);
        if (mounted) {
          setState(() => _error = ErrorCatalog.driverAuth(error.error,
              retryAfterSeconds:
                  (seconds != null && seconds >= 2) ? seconds : null));
        }
      }
    } catch (error) {
      _pinController.clear();
      AppLogger.error('pin_auth_unexpected', error);
      // On nomme la nature de l'incident : un message strictement
      // identique pour toutes les causes est précisément ce qui a rendu
      // ce défaut indiagnosticable à distance.
      if (mounted) {
        setState(() => _error =
            'Une erreur inattendue est survenue (${error.runtimeType}). '
            'Réessayez ; si cela persiste, montrez ce message à votre '
            'gestionnaire.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Efface l'appairage local (aucun appel serveur : l'écran PIN est
  /// atteint AVANT toute session authentifiée, donc `unbind()` n'est pas
  /// utilisable ici) et revient à l'écran de scan QR.
  Future<void> _forgetPairing() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Oublier cet appairage ?'),
        content: const Text(
            'Vous devrez scanner à nouveau le code QR fourni par votre gestionnaire.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirmer')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DriverIdentityService.purgeAll();
    AppLogger.breadcrumb('pairing_forgotten_from_pin_screen');
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ProvisioningScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final driverName = DriverIdentityService.provisioning?.driverName;
    final locked = _lockedUntil != null;
    return Scaffold(
      backgroundColor: WetrackamColors.lilacTint,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Oublier cet appairage et rescanner',
          onPressed: _loading ? null : _forgetPairing,
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_outline, size: 64, color: WetrackamColors.purple),
              const SizedBox(height: 16),
              Text(
                driverName != null ? 'Bonjour $driverName' : 'Identification',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text('Saisissez votre code PIN pour continuer.',
                  textAlign: TextAlign.center, style: TextStyle(color: WetrackamColors.slate)),
              const SizedBox(height: 24),
              TextField(
                controller: _pinController,
                enabled: !_loading && !locked,
                keyboardType: TextInputType.numberWithOptions(decimal: false),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 8),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              if (locked)
                Text('Trop de tentatives. Réessayez dans ${_formatCountdown()}.',
                    style: const TextStyle(color: WetrackamColors.error),
                    textAlign: TextAlign.center)
              else if (_error != null)
                Text(_error!,
                    style: const TextStyle(color: WetrackamColors.error),
                    textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: (_loading || locked) ? null : _submit,
                child: _loading
                    ? const SizedBox(height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Valider'),
              ),
              // Sortie de secours : sans elle, un téléphone dont l'ancre
              // TLS ne correspond plus reste bloqué sur cet écran, à
              // retaper un code qui ne pourra jamais aboutir.
              if (_offerRepairing)
                TextButton.icon(
                  onPressed: _loading
                      ? null
                      : () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                              builder: (_) => const ProvisioningScreen())),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Rescanner le QR d\'appairage'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
