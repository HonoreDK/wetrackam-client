// lib/wetrackam/wetro/wetro_binding.dart
//
// v17 — cycle de vie de Wetro dans l'application chauffeur.
//
// L'application repose sur des services statiques (DriverIdentityService,
// CallService, RealtimeService…). Wetro suit la SESSION du chauffeur :
//   - `start()` après une authentification réussie (écran PIN) ou au
//     démarrage si la session est déjà restaurée ;
//   - `stop()` à toute purge de session (hook enregistré dans main.dart) :
//     conversation effacée, micro fermé, bouton retiré.
// Rien de Wetro ne survit à la session : la conversation contient des noms
// de collègues et de responsables.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app_logger.dart';
import '../call_service.dart';
import '../driver_identity_service.dart';
import '../realtime_service.dart';
import 'wetro_app_host.dart';
import 'wetro_controller.dart';
import 'wetro_runtime.dart';
import 'wetro_service.dart';
import 'wetro_voice_engine.dart';

class WetroBinding {
  WetroBinding._();

  static WetroController? _controller;
  static StreamSubscription<Map<String, dynamic>>? _controlSub;
  static GlobalKey<NavigatorState>? _navigatorKey;

  static WetroController? get controller => _controller;

  /// Marque de build lisible sur le téléphone (écran Diagnostic) : si cette
  /// ligne n'apparaît pas, l'application installée vient d'un autre dossier
  /// ou d'une autre version — Wetro n'y est simplement pas.
  static const String buildMark = 'v17.1.0 (171) — Wetro chauffeur inclus';

  /// État de l'assistant pour l'écran Diagnostic, sans rien révéler de la
  /// conversation : présence du contrôleur, réponse du serveur, voix.
  static Map<String, String> diagnostic() {
    final c = _controller;
    if (c == null) {
      return {
        'Build': buildMark,
        'Contrôleur': DriverIdentityService.isAuthenticated
            ? 'absent (start() non appelé)'
            : 'absent (aucune session chauffeur)',
      };
    }
    return {
      'Build': buildMark,
      'Contrôleur': 'présent',
      'État serveur lu': c.stateLoaded ? 'oui' : 'pas encore',
      'Assistant disponible': c.available ? 'oui' : 'non',
      'Dernière erreur d’état': c.lastStateError.isEmpty ? '—' : c.lastStateError,
      'Bouton visible': (c.available && !c.inCall && !WetroRuntime.instance.modalOpen) ? 'oui' : 'non',
      'À l’oreille': c.wakeEnabled ? 'activé' : 'désactivé',
      'Voix (dictée)': c.voiceAvailable ? 'prête' : 'pas encore ouverte',
    };
  }

  /// À appeler une fois, avec la clé du navigateur racine.
  static void configure(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
  }

  /// Crée l'assistant pour la session courante (no-op si déjà là ou si
  /// aucune session n'est authentifiée).
  static Future<void> start() async {
    if (_controller != null) return;
    if (!DriverIdentityService.isAuthenticated) return;
    final navigatorKey = _navigatorKey;
    if (navigatorKey == null) return;
    final controller = WetroController(
      service: const ApiWetroService(),
      voice: WetroDeviceVoiceEngine(),
      callSignal: CallService.phaseChanges,
    )..host = WetroAppHost(navigatorKey: navigatorKey);
    _controller = controller;
    WetroRuntime.instance.attach(controller);
    // Un changement d'état du chauffeur poussé par le serveur (affectation,
    // statut, site, réglages de l'espace) relit l'assistant : sa conversation
    // repart si l'époque a bougé.
    _controlSub ??= RealtimeService.messages.listen((message) {
      if (message['type'] == 'control') _controller?.onDriverStateChanged();
    });
    AppLogger.breadcrumb('wetro_start');
    await controller.init();
  }

  /// Détruit l'assistant (purge de session, déliaison).
  static Future<void> stop() async {
    final controller = _controller;
    _controller = null;
    await _controlSub?.cancel();
    _controlSub = null;
    WetroRuntime.instance.attach(null);
    if (controller != null) {
      controller.dispose();
      AppLogger.breadcrumb('wetro_stop');
    }
  }
}
