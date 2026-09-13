// lib/wetrackam/incoming_call_screen.dart
//
// Lot 8 — écran d'appel entrant. Affiché par le répartiteur global
// (call_navigator.dart) quand l'appel sonne DANS l'application (Android au
// premier plan). La sonnerie, elle, est native (CallRinger) et pilotée par
// CallService : cet écran ne fait que montrer et transmettre les gestes.
//
// v17 — cet écran ne navigue plus. Le répartiteur le remplace par l'écran
// d'appel en cours dès que la phase passe à `connected` (décrochage ici OU
// sur l'écran natif), et le retire au retour au repos (refus, annulation
// par l'appelant, délai). Avant, un décrochage natif laissait cette page
// affichée avec ses boutons alors que la communication était établie.
//
// Le geste est immédiat : dès l'appui sur « Accepter », la sonnerie cesse et
// l'écran affiche « Connexion… » pendant l'ouverture du micro — comme un
// téléphone, pas comme un formulaire.
import 'dart:async';

import 'package:flutter/material.dart';

import 'call_service.dart';
import 'theme.dart';

class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<void>? _uiSub;

  @override
  void initState() {
    super.initState();
    _uiSub = CallService.uiChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _uiSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final answering = CallService.answering;
    return PopScope(
      canPop: false, // pas de retour accidentel — passer par accepter/refuser
      child: Scaffold(
        backgroundColor: WetrackamColors.ink,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SizedBox(height: 48),
                Column(
                  children: [
                    const CircleAvatar(radius: 56, child: Icon(Icons.person, size: 56)),
                    const SizedBox(height: 16),
                    Text(CallService.peerName ?? 'Appel entrant',
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(answering ? 'Connexion…' : 'Appel entrant…',
                        style: const TextStyle(color: WetrackamColors.slate)),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 32),
                  child: answering
                      ? const CircularProgressIndicator(color: Colors.white70)
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _actionButton(
                              icon: Icons.call_end,
                              color: WetrackamColors.error,
                              label: 'Refuser',
                              onTap: () => CallService.declineCall(),
                            ),
                            _actionButton(
                              icon: Icons.call,
                              color: WetrackamColors.success,
                              label: 'Accepter',
                              onTap: () => CallService.acceptCall(),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(40),
          child: CircleAvatar(radius: 32, backgroundColor: color, child: Icon(icon, color: Colors.white, size: 30)),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }
}
