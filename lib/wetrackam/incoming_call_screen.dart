// lib/wetrackam/incoming_call_screen.dart
//
// Lot 8 — écran d'appel entrant. Affiché automatiquement par le
// répartiteur global (voir call_navigator.dart) dès `call.incoming`.
//
// Bug trouvé en vérification : la première version ne réagissait à aucun
// changement de phase — si l'appelant raccrochait avant que l'appelé ne
// décroche (call.cancel/call.ended reçu pendant l'affichage de cet
// écran), l'écran de sonnerie restait affiché indéfiniment, sans bouton
// retour possible (PopScope canPop:false). Converti en StatefulWidget
// pour écouter CallService.phaseChanges et se fermer tout seul.
import 'dart:async';

import 'package:flutter/material.dart';

import 'call_service.dart';
import 'in_call_screen.dart';
import 'theme.dart';

class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<CallPhase>? _phaseSub;

  @override
  void initState() {
    super.initState();
    _phaseSub = CallService.phaseChanges.listen((phase) {
      if (!mounted) return;
      // L'appelant a raccroché/annulé avant que cet écran n'ait été
      // fermé par un accepter/refuser explicite — se ferme tout seul,
      // silencieusement (pas de message : c'est un scénario normal, pas
      // une erreur).
      if (phase == CallPhase.idle) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _phaseSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                    const Text('Appel entrant...', style: TextStyle(color: WetrackamColors.slate)),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _actionButton(
                        icon: Icons.call_end,
                        color: WetrackamColors.error,
                        label: 'Refuser',
                        // Pas de pop() ici : CallService.declineCall()
                        // déclenche _cleanup() → phase idle → le
                        // _phaseSub ci-dessus ferme déjà cet écran. Un
                        // second pop() ici aurait fermé une route de trop
                        // (bug trouvé en vérification).
                        onTap: () => CallService.declineCall(),
                      ),
                      _actionButton(
                        icon: Icons.call,
                        color: WetrackamColors.success,
                        label: 'Accepter',
                        onTap: () async {
                          await CallService.acceptCall();
                          // Vérifie la phase RÉELLE plutôt que de supposer
                          // le succès : si acceptCall() a échoué en
                          // interne (micro refusé, PeerConnection...), il
                          // s'est déjà repositionné sur idle via
                          // _cleanup() — pousser vers InCallScreen dans ce
                          // cas aurait affiché un écran d'appel pour un
                          // appel déjà terminé (bug trouvé en vérification).
                          if (context.mounted && CallService.phase == CallPhase.connected) {
                            Navigator.of(context).pushReplacement(
                                MaterialPageRoute(builder: (_) => const InCallScreen()));
                          }
                        },
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
