// lib/wetrackam/server_unreachable_screen.dart
//
// Lot 2 (contrat v5 §20.1, delta §2.1) : distinct de l'écran PIN et du
// kill-switch tenant (disabled_tenant_screen.dart). Ici, aucune tentative
// d'authentification n'a même pu être faite — le serveur configuré au
// provisionnement ne répond pas du tout à GET /api/mobile/ping.
//
// Contrairement au kill-switch (suspension déclarée par le serveur),
// c'est un problème réseau ordinaire, potentiellement transitoire : bouton
// Réessayer sans notion de "non-dismissable".
import 'package:flutter/material.dart';

import 'theme.dart';

class ServerUnreachableScreen extends StatefulWidget {
  final Future<bool> Function() onRetry;
  final VoidCallback onReachable;

  const ServerUnreachableScreen({
    super.key,
    required this.onRetry,
    required this.onReachable,
  });

  @override
  State<ServerUnreachableScreen> createState() => _ServerUnreachableScreenState();
}

class _ServerUnreachableScreenState extends State<ServerUnreachableScreen> {
  bool _checking = false;

  Future<void> _retry() async {
    setState(() => _checking = true);
    final reachable = await widget.onRetry();
    if (!mounted) return;
    if (reachable) {
      widget.onReachable();
    } else {
      setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WetrackamColors.lilacTint,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 64, color: WetrackamColors.slate),
                const SizedBox(height: 24),
                Text('Serveur injoignable',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                const Text(
                  'Vérifiez votre connexion internet. Si le problème '
                  'persiste, contactez votre gestionnaire.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: WetrackamColors.slate),
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
