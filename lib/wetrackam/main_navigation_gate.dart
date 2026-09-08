// lib/wetrackam/main_navigation_gate.dart
//
// Routage v5, trois états possibles au démarrage :
//  1. Pas provisionné            → ProvisioningScreen (scan QR)
//  2. Provisionné, pas de token  → PingGate → PinAuthScreen ou
//                                   ServerUnreachableScreen (Lot 2)
//  3. Authentifié                → EligibilityScreen (source de vérité)
//
// Aucune vérification locale d'expiration de session ici : en v4/v5, la
// validité du token est intégralement arbitrée par le serveur à chaque
// appel authentifié — un token expiré remonte en 401 et est intercepté de
// façon centralisée par api_client.dart, qui purge et lève
// SessionInvalidException. C'est EligibilityScreen qui réagit à cette
// exception pour revenir ici.
import 'package:flutter/material.dart';

import 'api_client.dart';
import 'driver_identity_service.dart';
import 'eligibility_screen.dart';
import 'pin_auth_screen.dart';
import 'provisioning_screen.dart';
import 'server_unreachable_screen.dart';

class MainNavigationGate extends StatelessWidget {
  const MainNavigationGate({super.key});

  @override
  Widget build(BuildContext context) {
    if (!DriverIdentityService.isProvisioned) {
      return const ProvisioningScreen();
    }
    if (!DriverIdentityService.isAuthenticated) {
      return const _PingGate();
    }
    return const EligibilityScreen();
  }
}

/// Lot 2 : GET /api/mobile/ping avant l'écran PIN (contrat v5 §20.1). Une
/// seule vérification à l'entrée sur cet écran, pas de sondage périodique
/// en arrière-plan — un échec propose un bouton Réessayer explicite plutôt
/// que de gaspiller de la batterie à re-sonder tout seul.
class _PingGate extends StatefulWidget {
  const _PingGate();

  @override
  State<_PingGate> createState() => _PingGateState();
}

class _PingGateState extends State<_PingGate> {
  bool? _reachable; // null = vérification en cours
  String? _securityError;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _reachable = null;
      _securityError = null;
    });
    try {
      final ok = await WetrackamApiClient.pingOrThrow();
      if (mounted) setState(() => _reachable = ok);
    } on TlsTrustException catch (error) {
      if (mounted) {
        setState(() {
          _reachable = false;
          _securityError = error.code;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _reachable = false;
          _securityError = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_reachable == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_reachable == false) {
      return ServerUnreachableScreen(
        message: _securityError == null
            ? null
            : 'La sécurité du serveur ne correspond plus à cet appairage. Contactez votre gestionnaire.',
        onRetry: WetrackamApiClient.ping,
        onReachable: () => setState(() => _reachable = true),
      );
    }
    return const PinAuthScreen();
  }
}
