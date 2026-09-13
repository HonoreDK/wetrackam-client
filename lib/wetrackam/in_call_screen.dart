// lib/wetrackam/in_call_screen.dart
//
// Lot 8 — écran d'appel en cours + mode conduite (contrat v5 §18,
// PROMPT-MOBILE-HONORE.md §8). Au-dessus de `speedLockKmh` : interface
// réduite à un bouton, saisie désactivée.
//
// Hystérésis : sortie du mode conduite seulement après 10s CONTINUES sous
// le seuil, pour éviter un clignotement de l'interface à chaque
// ralentissement (§8, exemple donné : un feu rouge).
//
// v17 — L'ÉCRAN DIT LA VÉRITÉ, ET NE NAVIGUE PLUS.
//  - « Appel en cours… » tant que le pair n'a pas décroché ;
//  - « Connexion… » une fois décroché, tant que le chemin média n'est pas
//    établi (ICE) ;
//  - le chronomètre démarre sur l'instant réel de connexion
//    (CallService.connectedAt), jamais sur la construction de l'écran — il
//    incluait la sonnerie ;
//  - « Reconnexion… » quand le pair a perdu sa socket ou que le média se
//    rétablit (le serveur et la pile WebRTC tiennent l'appel, l'écran le
//    montre au lieu d'un chronomètre qui ment) ;
//  - la fermeture est faite par le répartiteur (call_navigator.dart), qui
//    retire cette route et elle seule — plus de `popUntil(isFirst)` qui
//    dépilait la conversation ou l'annuaire d'où l'appel était parti.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_service.dart';
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
  Timer? _ticker;
  Timer? _driveModeTicker;
  bool _driveMode = false;
  DateTime? _belowThresholdSince;
  StreamSubscription<void>? _uiSub;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && CallService.connectedAt != null) setState(() {});
    });
    _driveModeTicker = Timer.periodic(const Duration(seconds: 2), (_) => _evaluateDriveMode());
    _evaluateDriveMode();
    _uiSub = CallService.uiChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _driveModeTicker?.cancel();
    _uiSub?.cancel();
    super.dispose();
  }

  Duration get _elapsed {
    final since = CallService.connectedAt;
    if (since == null) return Duration.zero;
    return DateTime.now().difference(since);
  }

  void _evaluateDriveMode() {
    final speedKmh = LocationCache.get()?.speedKmh ?? 0;
    final threshold = RtcConfigService.current.policy.speedLockKmh;
    if (threshold <= 0) return; // seuil non configuré = mode conduite désactivé
    final above = speedKmh > threshold;
    if (above) {
      _belowThresholdSince = null;
      if (!_driveMode && mounted) setState(() => _driveMode = true);
    } else {
      _belowThresholdSince ??= DateTime.now();
      // §8 : hystérésis — sortie seulement après 10s continues sous le seuil.
      if (_driveMode &&
          DateTime.now().difference(_belowThresholdSince!) >= const Duration(seconds: 10) &&
          mounted) {
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
    Helper.setSpeakerphoneOn(_speakerOn);
  }

  String _formatDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hh = d.inHours;
    return hh > 0 ? '$hh:$mm:$ss' : '$mm:$ss';
  }

  /// Ligne d'état sous le nom : la vérité de l'appel, pas une supposition.
  String _statusLine(CallPhase phase) {
    if (phase == CallPhase.outgoingRinging) return 'Appel en cours…';
    if (phase != CallPhase.connected) return '';
    if (CallService.peerReconnecting) return 'Reconnexion…';
    if (!CallService.mediaUp) return 'Connexion…';
    return _formatDuration(_elapsed);
  }

  @override
  Widget build(BuildContext context) {
    final phase = CallService.phase;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: WetrackamColors.ink,
        body: SafeArea(
          child: phase == CallPhase.connected
              ? (_driveMode ? _driveModeView(phase) : _normalView(phase))
              : _ringingView(),
        ),
      ),
    );
  }

  /// Appel sortant, pas encore décroché — pas de contrôles mute/haut-parleur
  /// tant que la communication n'est pas établie. Couvre aussi l'instant de
  /// préparation (ticket, TURN, micro) : jamais un chronomètre avant la
  /// sonnerie.
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
              const Text('Appel en cours…', style: TextStyle(color: WetrackamColors.slate)),
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
  /// répondre / raccrocher." Ici uniquement raccrocher.
  Widget _driveModeView(CallPhase phase) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.speed, color: WetrackamColors.warning, size: 40),
          const SizedBox(height: 12),
          const Text('Mode conduite', style: TextStyle(color: Colors.white, fontSize: 20)),
          const SizedBox(height: 8),
          Text(_statusLine(phase), style: const TextStyle(color: WetrackamColors.slate)),
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

  Widget _normalView(CallPhase phase) {
    final reconnecting = CallService.peerReconnecting || !CallService.mediaUp;
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
              Text(
                _statusLine(phase),
                style: TextStyle(
                  color: reconnecting ? WetrackamColors.warning : WetrackamColors.slate,
                ),
              ),
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
