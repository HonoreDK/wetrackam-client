// lib/wetrackam/in_call_screen.dart
//
// Lot 8 — écran d'appel en cours + mode conduite (contrat v5 §18,
// PROMPT-MOBILE-HONORE.md §8). Au-dessus de `speedLockKmh` : interface
// réduite à un bouton, saisie désactivée (rien à saisir ici de toute
// façon — la saisie de conversation est également verrouillée par la même
// vitesse. La synthèse vocale des messages n'est pas annoncée comme une
// fonctionnalité : aucune dépendance TTS n'est incluse dans ce client.
//
// Hystérésis : sortie du mode conduite seulement après 10s CONTINUES sous
// le seuil, pour éviter un clignotement de l'interface à chaque
// ralentissement (§8, exemple donné : un feu rouge).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_service.dart';
import 'error_catalog.dart';
import '../location_cache.dart';
import 'rtc_config_service.dart';
import 'theme.dart';

class InCallScreen extends StatefulWidget {
  const InCallScreen({super.key});

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  bool _muted = false;
  bool _speakerOn = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  Timer? _driveModeTicker;
  Timer? _statsTimer;
  bool _driveMode = false;
  DateTime? _belowThresholdSince;
  StreamSubscription<CallPhase>? _phaseSub;

  @override
  void initState() {
    super.initState();
    // Anomalie corrigée : partait toujours de zéro, y compris quand l'appel
    // était déjà connecté depuis un moment (voir CallService.connectedAt).
    final connectedAt = CallService.connectedAt;
    if (connectedAt != null) {
      _elapsed = DateTime.now().difference(connectedAt);
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed += const Duration(seconds: 1));
    });
    // Règle 7 du contrat : remonter la qualité après établissement — 2s
    // de marge pour laisser la paire ICE se stabiliser.
    _statsTimer = Timer(const Duration(seconds: 2), CallService.reportCallStats);
    _driveModeTicker = Timer.periodic(const Duration(seconds: 2), (_) => _evaluateDriveMode());
    _evaluateDriveMode();
    _phaseSub = CallService.phaseChanges.listen((phase) {
      if (!mounted) return;
      if (phase == CallPhase.idle) {
        final reason = CallService.consumeLastErrorReason();
        // Bug trouvé en checklist H6 : `peerCrossTenant` a un message vide
        // dans le catalogue (masquage silencieux voulu, §16 — incident
        // d'isolation, jamais un texte métier) — sans ce garde-fou,
        // l'ancien code affichait quand même un SnackBar VIDE, visible à
        // l'écran comme un bandeau gris sans texte.
        if (reason != null && !ErrorCatalog.isSilentMask(reason)) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(ErrorCatalog.http(error: reason))));
        }
        Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      }
      // Bug trouvé en vérification : sans ce setState(), l'écran restait
      // bloqué sur la vue "sonnerie" même après le passage à connected —
      // seul idle déclenchait un rafraîchissement.
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _driveModeTicker?.cancel();
    _statsTimer?.cancel();
    _phaseSub?.cancel();
    super.dispose();
  }

  void _evaluateDriveMode() {
    final speedKmh = LocationCache.get()?.speedKmh ?? 0;
    final threshold = RtcConfigService.current.policy.speedLockKmh;
    if (threshold <= 0) return; // seuil non configuré = mode conduite désactivé
    final above = speedKmh > threshold;
    if (above) {
      _belowThresholdSince = null;
      if (!_driveMode) setState(() => _driveMode = true);
    } else {
      _belowThresholdSince ??= DateTime.now();
      // §8 : hystérésis — sortie seulement après 10s continues sous le seuil.
      if (_driveMode &&
          DateTime.now().difference(_belowThresholdSince!) >= const Duration(seconds: 10)) {
        setState(() => _driveMode = false);
      }
    }
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    // La PeerConnection/MediaStream est privée à call_service.dart — on
    // expose un contrôle minimal ici plutôt que de dupliquer l'état WebRTC.
    CallService.setMuted(_muted);
  }

  void _toggleSpeaker() {
    setState(() => _speakerOn = !_speakerOn);
    // Contrôle explicite du chauffeur — _applyCallAudioMode() (call_service
    // .dart) ne fixe que l'état PAR DÉFAUT à la connexion (écouteur), ce
    // bouton permet de basculer ensuite.
    Helper.setSpeakerphoneOn(_speakerOn);
  }

  String _formatDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final phase = CallService.phase;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: WetrackamColors.ink,
        body: SafeArea(
          child: phase == CallPhase.outgoingRinging
              ? _ringingView()
              : (_driveMode ? _driveModeView() : _normalView()),
        ),
      ),
    );
  }

  /// Appel sortant, pas encore décroché — pas de contrôles mute/haut-parleur
  /// tant que la communication n'est pas établie.
  Widget _ringingView() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const SizedBox(height: 48),
          Column(
            children: [
              const CircleAvatar(radius: 48, child: Icon(Icons.person, size: 48)),
              const SizedBox(height: 16),
              Text(CallService.peerName ?? 'Appel',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text('Appel en cours...', style: TextStyle(color: WetrackamColors.slate)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 32),
            child: InkWell(
              onTap: () => CallService.cancelOutgoing(),
              borderRadius: BorderRadius.circular(40),
              child: const CircleAvatar(
                radius: 32,
                backgroundColor: WetrackamColors.error,
                child: Icon(Icons.call_end, color: Colors.white, size: 30),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// §8 : "l'interface d'appel se réduit à un seul grand bouton :
  /// répondre / raccrocher." Ici uniquement raccrocher (l'appel est déjà
  /// en cours sur cet écran) — pas de clavier, pas de contrôles annexes.
  Widget _driveModeView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.speed, color: WetrackamColors.warning, size: 40),
          const SizedBox(height: 12),
          const Text('Mode conduite', style: TextStyle(color: Colors.white, fontSize: 20)),
          const SizedBox(height: 8),
          Text(_formatDuration(_elapsed), style: const TextStyle(color: WetrackamColors.slate)),
          const Spacer(),
          InkWell(
            onTap: () => CallService.hangUp(),
            borderRadius: BorderRadius.circular(60),
            child: const CircleAvatar(
              radius: 48,
              backgroundColor: WetrackamColors.error,
              child: Icon(Icons.call_end, color: Colors.white, size: 40),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _normalView() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const SizedBox(height: 48),
          Column(
            children: [
              const CircleAvatar(radius: 48, child: Icon(Icons.person, size: 48)),
              const SizedBox(height: 16),
              Text(CallService.peerName ?? 'Appel',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(_formatDuration(_elapsed), style: const TextStyle(color: WetrackamColors.slate)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _circleButton(
                      icon: _muted ? Icons.mic_off : Icons.mic,
                      active: _muted,
                      onTap: _toggleMute,
                    ),
                    _circleButton(
                      icon: Icons.volume_up,
                      active: _speakerOn,
                      onTap: _toggleSpeaker,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                InkWell(
                  onTap: () => CallService.hangUp(),
                  borderRadius: BorderRadius.circular(40),
                  child: const CircleAvatar(
                    radius: 32,
                    backgroundColor: WetrackamColors.error,
                    child: Icon(Icons.call_end, color: Colors.white, size: 30),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton({required IconData icon, required bool active, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(30),
      child: CircleAvatar(
        radius: 26,
        backgroundColor: active ? WetrackamColors.signalViolet : Colors.white24,
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}
