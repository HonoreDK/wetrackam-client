// lib/wetrackam/disabled_tenant_screen.dart
//
// Contrat v4 §8.2 : mobileDisabled=true côté tenant → 503 mobile_disabled
// sur toute requête authentifiée. Écran plein écran NON-dismissable avec
// bouton "Réessayer" — pas de bouton retour, pas de fermeture au tap
// extérieur. §15.2 : cette suspension est réversible, NE PURGE JAMAIS
// l'état local (ni token, ni provisionnement).
import 'package:flutter/material.dart';

import 'api_client.dart';
import 'driver_identity_service.dart';
import 'main_navigation_gate.dart';
import 'theme.dart';

class DisabledTenantScreen extends StatefulWidget {
  const DisabledTenantScreen({super.key});

  @override
  State<DisabledTenantScreen> createState() => _DisabledTenantScreenState();
}

class _DisabledTenantScreenState extends State<DisabledTenantScreen> {
  bool _checking = false;

  Future<void> _retry() async {
    setState(() => _checking = true);
    try {
      // /config exige une session authentifiée ; si on ne l'est pas (le
      // kill-switch a pu survenir dès le provisionnement dans certains
      // déploiements), on se contente de retourner à la passerelle, qui
      // relancera l'étape appropriée et re-détectera un 503 le cas échéant.
      if (DriverIdentityService.isAuthenticated) {
        await WetrackamApiClient.fetchConfig();
      }
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainNavigationGate()),
          (route) => false,
        );
      }
    } on TenantDisabledException {
      if (mounted) setState(() => _checking = false);
    } catch (_) {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // non-dismissable, conforme contrat §13.5
      child: Scaffold(
        backgroundColor: WetrackamColors.ink,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.pause_circle_outline, size: 72, color: WetrackamColors.lilacTint),
                const SizedBox(height: 24),
                const Text(
                  'Service temporairement indisponible',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Contactez votre gestionnaire pour plus d\'informations.',
                  style: TextStyle(color: WetrackamColors.slate),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: _checking ? null : _retry,
                  child: _checking
                      ? const SizedBox(height: 18, width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Réessayer'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
