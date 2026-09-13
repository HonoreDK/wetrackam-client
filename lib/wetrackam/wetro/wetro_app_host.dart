import 'dart:async';

import 'package:flutter/material.dart';

import '../../location_cache.dart';
import '../app_logger.dart';
import '../call_service.dart';
import '../chat_service.dart';
import '../conversation_screen.dart';
import '../diagnostics_screen.dart';
import '../directory_screen.dart';
import '../distress_service.dart';
import '../fleet_screen.dart';
import '../peer_name_cache.dart';
import '../realtime_service.dart';
import '../rtc_config_service.dart';
import '../sos_screen.dart';
import 'wetro_host.dart';

/// Ce que l'application chauffeur prête à Wetro : les MÊMES écrans, les
/// MÊMES services et les MÊMES gardes que depuis l'écran d'accueil
/// (`EligibilityScreen`) — un appel de Wetro passe par `CallService.placeCall`,
/// un message par `ChatService.sendText`, une alerte par
/// `DistressService.raiseSos`. Une entrée que la politique de l'espace
/// masque à l'écran est masquée pour Wetro aussi, même si le serveur avait
/// laissé passer l'action (ce qui ne doit pas arriver, mais ne se suppose
/// jamais).
class WetroAppHost implements WetroHost {
  WetroAppHost({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  /// Délai d'attente de l'accusé serveur pour un message envoyé par Wetro.
  static const _delaiAccuse = Duration(seconds: 8);

  @override
  bool get inCall => CallService.phase != CallPhase.idle && CallService.phase != CallPhase.ended;

  /// Même règle que l'écran d'appel et la conversation (§8 : mode conduite).
  @override
  bool get driving {
    final threshold = RtcConfigService.current.policy.speedLockKmh;
    if (threshold <= 0) return false;
    return (LocationCache.get()?.speedKmh ?? 0) > threshold;
  }

  NavigatorState? get _nav => navigatorKey.currentState;

  RtcPolicy get _policy => RtcConfigService.current.policy;

  Future<bool> _pousse(Widget Function() construit) async {
    final nav = _nav;
    if (nav == null) return false;
    unawaited(nav.push(MaterialPageRoute(builder: (_) => construit())));
    return true;
  }

  @override
  Future<bool> openScreen(String screen) async {
    final nav = _nav;
    if (nav == null) return false;
    switch (screen) {
      case 'home':
        // L'accueil est la racine : on dépile jusqu'à lui.
        nav.popUntil((route) => route.isFirst);
        return true;
      case 'fleet':
        if (!RtcConfigService.isAvailable || _policy.fleetVisibility == 'none') return false;
        return _pousse(() => const FleetScreen());
      case 'directory':
        if (!RtcConfigService.isAvailable || _policy.directoryScope == 'none') return false;
        return _pousse(() => const DirectoryScreen());
      case 'sos':
        return _pousse(() => const SosScreen());
      case 'diagnostics':
        return _pousse(() => const DiagnosticsScreen());
      default:
        return false;
    }
  }

  @override
  Future<bool> openConversation(int driverId, String driverName) async {
    if (driverId <= 0) return false;
    if (!RtcConfigService.isAvailable || !_policy.chatEnabled) return false;
    await PeerNameCache.remember(driverId, driverName);
    return _pousse(() => ConversationScreen(peerId: driverId, peerName: driverName));
  }

  @override
  Future<bool> callDriver(int driverId, String driverName) async {
    if (driverId <= 0) return false;
    return _appelle(driverId, driverName);
  }

  @override
  Future<bool> callManager(int participantId, String managerName) async {
    if (participantId <= 0) return false;
    return _appelle(participantId, managerName);
  }

  /// Un appel Wetro est un appel ordinaire : mêmes conditions (appels
  /// activés dans l'espace, service temps réel, aucun appel en cours), même
  /// écran (ouvert par CallNavigator dès la phase de sonnerie).
  Future<bool> _appelle(int peerId, String peerName) async {
    if (!RtcConfigService.isAvailable || !_policy.callsEnabled) return false;
    if (CallService.phase != CallPhase.idle) return false;
    await PeerNameCache.remember(peerId, peerName);
    unawaited(CallService.placeCall(peerId: peerId, peerName: peerName));
    // La phase bascule tout de suite en sonnerie ; si la préparation échoue
    // (micro, réseau), CallNavigator annonce la cause — comme à la main.
    return CallService.phase == CallPhase.outgoingRinging;
  }

  @override
  Future<bool> messageDriver(int driverId, String driverName, String text) async {
    if (driverId <= 0 || text.trim().isEmpty) return false;
    if (!RtcConfigService.isAvailable || !_policy.chatEnabled) return false;
    if (!RealtimeService.canChat && RealtimeService.state == RealtimeState.connected) return false;
    try {
      await RealtimeService.ensureConnected();
    } catch (error) {
      AppLogger.error('wetro_message_offline', error);
      return false;
    }
    await PeerNameCache.remember(driverId, driverName);
    final envoye = await ChatService.sendText(driverId, text.trim());
    // On attend l'accusé du serveur : Wetro ne dit « c'est envoyé » que
    // quand c'est vrai. Sans accusé dans le délai, le message reste en file
    // (il partira à la reconnexion) mais Wetro le dit honnêtement.
    final completer = Completer<bool>();
    late final StreamSubscription<Map<String, dynamic>> sub;
    sub = ChatService.acks.listen((ack) {
      if (ack['clientMessageId'] != envoye.clientMessageId) return;
      final status = ack['status'] as String?;
      if (status == 'sent' || status == 'delivered' || status == 'read') {
        if (!completer.isCompleted) completer.complete(true);
      } else if (status == 'failed' || status == 'rejected') {
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    try {
      return await completer.future.timeout(_delaiAccuse, onTimeout: () => false);
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<bool> raiseSos(String kind) async {
    try {
      await DistressService.raiseSos(kind: kind);
      AppLogger.breadcrumb('wetro_sos_raised:$kind');
      // L'écran SOS montre l'alerte en cours et permet de la compléter.
      unawaited(_pousse(() => const SosScreen()));
      return true;
    } catch (error) {
      // L'alerte reste en file locale (DistressService.retryPending) : elle
      // partira au retour du réseau, mais on ne dit pas « envoyée ».
      AppLogger.error('wetro_sos_failed', error);
      unawaited(_pousse(() => const SosScreen()));
      return false;
    }
  }
}
