// lib/wetrackam/call_ui_service.dart
//
// v13 — LE chaînon manquant des appels entrants. Jusqu'ici, un appel n'était
// visible que si l'application était déjà au premier plan : le push `call`
// se contentait de rouvrir la socket, et l'isolate d'arrière-plan Dart ne
// pouvait de toute façon pas afficher d'écran. Résultat en exploitation :
// « la VoIP ne fonctionne pas » — elle fonctionnait, mais personne ne voyait
// jamais l'appel sonner téléphone en poche.
//
// v17 — UNE SEULE SURFACE À LA FOIS, ET ELLE OBÉIT.
//
// Ce que la v13 faisait de travers, reproduit sur téléphone :
//  - la notification native d'appel entrant était affichée EN PLUS de la page
//    Flutter (deux surfaces qui sonnent) ;
//  - après un décrochage sur la page Flutter, cette notification survivait
//    (seul le son était coupé), restait « en haut », puis EXPIRAIT — et son
//    expiration était traitée comme un refus : l'appel décroché se
//    raccrochait tout seul au bout de 20 s, avec une notification « appel
//    manqué » en prime ;
//  - `setCallConnected` ajoutait une TROISIÈME notification (« appel en cours »
//    du plugin) à côté de celle du service de premier plan.
//
// Règles v17, toutes appliquées ici :
//  1. Android AU PREMIER PLAN : la page Flutter est la seule surface d'appel
//     entrant ; elle sonne via CallRinger (natif, canal wetrackam/call_fgs).
//     Aucune notification native n'est affichée.
//  2. Android EN ARRIÈRE-PLAN / écran verrouillé / application tuée : la
//     notification plein écran du plugin est la seule surface (c'est le seul
//     moyen de réveiller l'écran). Elle est FERMÉE dès que l'appel est
//     accepté, refusé, terminé ou manqué — par `dismissIncoming`, jamais par
//     son propre délai.
//  3. iOS : CallKit toujours (c'est l'interface d'appel du système).
//  4. Pendant la communication, UNE notification : celle du service de
//     premier plan « microphone » (obligatoire Android 14+), avec le nom du
//     collègue. Le plugin n'affiche pas la sienne (`callingNotification`
//     désactivée).
//  5. `activeCalls()` du plugin est la SEULE source de vérité inter-isolates :
//     le push (isolate d'arrière-plan) et la socket (isolate principal) ne
//     partagent aucune variable Dart. Une notification déjà affichée par le
//     push n'est jamais réaffichée par la socket — c'est ce doublon qui
//     relançait la sonnerie en pleine communication.
//
// Invariant : ce fichier ne connaît RIEN de WebRTC ni du protocole. Il ne
// décide jamais d'accepter ou de refuser : il remonte l'intention de
// l'utilisateur via des callbacks, et CallService reste seul maître de la
// machine à états (une seule source de vérité).
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'app_logger.dart';

/// Point d'entrée d'arrière-plan du plugin d'appel : appelé par le système
/// quand l'utilisateur agit sur l'écran d'appel alors que l'application est
/// tuée. On ne peut rien faire d'utile ici (aucun état, pas d'arbre de
/// widgets) — mais l'acceptation est mémorisée nativement par le plugin
/// (`activeCalls()`), et `CallUiService.consumeExternalAcceptance()` la relit
/// au démarrage. C'est ce relais qui rend l'appel « application tuée »
/// réellement fonctionnel.
@pragma('vm:entry-point')
Future<void> callkitBackgroundHandler(CallEvent event) async {
  AppLogger.breadcrumb('callkit_background:${event.eventName.split('.').last}');
}

typedef CallUiIntent = void Function(String callId);

class CallUiService {
  CallUiService._();

  static const _channel = MethodChannel('wetrackam/call_fgs');

  static StreamSubscription<CallEvent?>? _sub;
  static CallUiIntent? _onAccept;
  static CallUiIntent? _onDecline;
  static CallUiIntent? _onEnd;
  static CallUiIntent? _onTimeout;

  static Future<void> init({
    required CallUiIntent onAccept,
    required CallUiIntent onDecline,
    required CallUiIntent onEnd,
    required CallUiIntent onTimeout,
  }) async {
    _onAccept = onAccept;
    _onDecline = onDecline;
    _onEnd = onEnd;
    _onTimeout = onTimeout;
    if (_sub != null) return;
    _sub = FlutterCallkitIncoming.onEvent.listen(_onEvent);
    try {
      await FlutterCallkitIncoming.onBackgroundMessage(callkitBackgroundHandler);
    } catch (error) {
      AppLogger.error('callkit_background_register_failed', error);
    }
    AppLogger.breadcrumb('call_ui_init');
  }

  /// Les événements natifs sont TOUS relayés avec leur `callId` : c'est
  /// CallService (call_policy.decideNativeEvent) qui décide s'ils concernent
  /// l'appel en cours et dans quelle phase ils ont un sens. Ici, aucune
  /// interprétation.
  static void _onEvent(CallEvent? event) {
    if (event == null) return;
    switch (event) {
      case CallEventActionCallAccept(:final callKitParams):
        AppLogger.breadcrumb('call_ui_accept');
        _onAccept?.call(callKitParams.id);
      case CallEventActionCallDecline(:final callKitParams):
        AppLogger.breadcrumb('call_ui_decline');
        _onDecline?.call(callKitParams.id);
      case CallEventActionCallEnded(:final callKitParams):
        AppLogger.breadcrumb('call_ui_ended');
        _onEnd?.call(callKitParams.id);
      case CallEventActionCallTimeout(:final id):
        AppLogger.breadcrumb('call_ui_timeout');
        _onTimeout?.call(id);
      default:
        break;
    }
  }

  // -----------------------------------------------------------------
  // Appel entrant — surface native (arrière-plan Android, iOS)
  // -----------------------------------------------------------------

  /// Affiche l'écran d'appel entrant natif. Idempotent ENTRE ISOLATES : si le
  /// plugin connaît déjà cet appel (affiché par le push dans l'isolate
  /// d'arrière-plan), rien n'est réaffiché — réafficher relançait la
  /// sonnerie, y compris après un décrochage.
  static Future<void> showNativeIncoming({
    required String callId,
    required String callerName,
    int ringTimeoutSeconds = 30,
  }) async {
    try {
      if (await _knownByPlugin(callId)) {
        AppLogger.breadcrumb('call_ui_incoming_already_shown');
        return;
      }
      await FlutterCallkitIncoming.showCallkitIncoming(
        _params(callId: callId, callerName: callerName, ringTimeoutSeconds: ringTimeoutSeconds),
      );
      AppLogger.breadcrumb('call_ui_incoming_shown');
    } catch (error) {
      AppLogger.error('call_ui_show_failed', error);
    }
  }

  /// Ferme l'écran d'appel entrant natif (sonnerie, vibration, notification
  /// et son minuteur d'expiration). À appeler dès que l'appel n'est plus « en
  /// train de sonner » : accepté, refusé, manqué, annulé par l'appelant.
  /// Idempotent, jamais bloquant.
  static Future<void> dismissIncoming(String callId) async {
    try {
      await FlutterCallkitIncoming.hideCallkitIncoming(
        _params(callId: callId, callerName: '', ringTimeoutSeconds: 30),
      );
    } catch (error) {
      AppLogger.error('call_ui_dismiss_failed', error);
    }
  }

  // -----------------------------------------------------------------
  // Appel entrant — sonnerie applicative (Android au premier plan)
  // -----------------------------------------------------------------

  static bool _ringing = false;

  static Future<void> ringInApp() async {
    if (!Platform.isAndroid) return;
    _ringing = true;
    try {
      await _channel.invokeMethod<void>('ringStart');
    } catch (error) {
      AppLogger.error('call_ring_start_failed', error);
    }
  }

  static Future<void> stopInAppRing() async {
    if (!Platform.isAndroid || !_ringing) return;
    _ringing = false;
    try {
      await _channel.invokeMethod<void>('ringStop');
    } catch (error) {
      AppLogger.error('call_ring_stop_failed', error);
    }
  }

  // -----------------------------------------------------------------
  // Communication établie
  // -----------------------------------------------------------------

  /// Passage en communication. iOS : CallKit est informé (chronomètre
  /// système, journal). Android : le service de premier plan micro devient
  /// l'unique notification, avec le nom du collègue.
  static Future<void> markConnected({required String callId, required String peerName}) async {
    await stopInAppRing();
    if (Platform.isIOS) {
      try {
        await FlutterCallkitIncoming.setCallConnected(callId);
      } catch (error) {
        AppLogger.error('call_ui_connected_failed', error);
      }
    }
    await startMicService(peerName: peerName);
  }

  /// Appel sortant sur iOS : CallKit doit connaître l'appel pour que l'audio
  /// survive au verrouillage et que le système affiche l'appel en cours.
  /// Android : rien à afficher avant la connexion (l'écran Flutter suffit),
  /// le service micro démarre dès l'émission (le micro est déjà ouvert).
  static Future<void> markOutgoing({required String callId, required String peerName}) async {
    if (Platform.isIOS) {
      try {
        await FlutterCallkitIncoming.startCall(
          _params(callId: callId, callerName: peerName, ringTimeoutSeconds: 30),
        );
      } catch (error) {
        AppLogger.error('call_ui_outgoing_failed', error);
      }
    }
    await startMicService(peerName: peerName);
  }

  // -----------------------------------------------------------------
  // Fin d'appel
  // -----------------------------------------------------------------

  /// Fin d'appel, quel que soit le motif. TOUJOURS appelé depuis le point de
  /// nettoyage unique de CallService — jamais ailleurs, sinon l'écran natif
  /// et l'état applicatif pourraient diverger. Ferme TOUT : sonnerie
  /// applicative, écran natif (entrant ou en cours), service de premier plan.
  static Future<void> endAll(String? callId) async {
    await stopInAppRing();
    await stopMicService();
    try {
      if (callId != null) {
        await dismissIncoming(callId);
        await FlutterCallkitIncoming.endCall(callId);
      }
      // Filet : un écran orphelin (push affiché puis appel annulé avant la
      // socket, appel d'une session précédente) ne doit jamais rester à
      // sonner. On ne touche au plugin que s'il a encore quelque chose.
      final calls = await FlutterCallkitIncoming.activeCalls();
      if (calls.isNotEmpty) {
        await FlutterCallkitIncoming.endAllCalls();
      }
    } catch (error) {
      AppLogger.error('call_ui_end_failed', error);
    }
  }

  /// v17 — fin d'un appel qui sonnait PAR PUSH (l'appelant a raccroché avant
  /// le décrochage, ou le serveur a clos la sonnerie), reçue par push
  /// `call_ended` : l'écran natif est fermé tout de suite au lieu de sonner
  /// jusqu'à son propre délai, et « appel manqué » est affiché. Utilisable
  /// depuis l'isolate d'arrière-plan (aucun état Dart requis).
  static Future<void> endFromPush({
    required String callId,
    required String reason,
    required String callerName,
  }) async {
    try {
      if (!await _knownByPlugin(callId)) {
        // Déjà fermé (délai natif écoulé, appel décroché entre-temps) :
        // rien à faire, et surtout pas un second « appel manqué ».
        return;
      }
      await dismissIncoming(callId);
      await FlutterCallkitIncoming.endCall(callId);
      if (reason == 'cancelled' || reason == 'timeout') {
        await FlutterCallkitIncoming.showMissCallNotification(
          _params(callId: callId, callerName: callerName, ringTimeoutSeconds: 30),
        );
      }
      AppLogger.breadcrumb('call_ui_ended_from_push:$reason');
    } catch (error) {
      AppLogger.error('call_ui_end_from_push_failed', error);
    }
  }

  /// Au démarrage : l'utilisateur a-t-il accepté un appel alors que
  /// l'application était tuée ? Renvoie le `callId` accepté, une seule fois.
  static Future<String?> consumeExternalAcceptance() async {
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      for (final call in calls) {
        final id = call.id;
        if (call.isAccepted && id.isNotEmpty) {
          AppLogger.breadcrumb('call_ui_external_acceptance');
          return id;
        }
      }
    } catch (error) {
      AppLogger.error('call_ui_active_calls_failed', error);
    }
    return null;
  }

  static Future<bool> _knownByPlugin(String callId) async {
    final calls = await FlutterCallkitIncoming.activeCalls();
    return calls.any((call) => call.id == callId);
  }

  static CallKitParams _params({
    required String callId,
    required String callerName,
    required int ringTimeoutSeconds,
  }) {
    return CallKitParams(
      id: callId,
      nameCaller: callerName,
      appName: 'WeTrackam',
      handle: callerName,
      type: 0, // audio uniquement — le contrat §19 exclut la vidéo
      duration: ringTimeoutSeconds * 1000,
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: 'Appel manqué',
      ),
      // v17 : le plugin n'affiche PAS sa notification « appel en cours ».
      // Le service de premier plan micro (CallForegroundService) est la
      // seule notification pendant la communication.
      callingNotification: const NotificationParams(
        showNotification: false,
        isShowCallback: false,
      ),
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        isShowCallID: false,
        // Réveille l'écran verrouillé : c'est précisément ce qui manquait.
        isShowFullLockedScreen: true,
        isImportant: true,
        isBot: false,
        incomingCallNotificationChannelName: 'Appels',
        missedCallNotificationChannelName: 'Appels manqués',
        backgroundColor: '#2F1B57',
        actionColor: '#7C4DFF',
        textAccept: 'Répondre',
        textDecline: 'Refuser',
      ),
      ios: const IOSParams(
        handleType: 'generic',
        supportsVideo: false,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        includesCallsInRecents: false, // pas de trace d'appel métier dans le journal perso
        configureAudioSession: true,
        audioSessionMode: 'voiceChat',
        audioSessionActive: true,
      ),
    );
  }

  // -----------------------------------------------------------------
  // Service de premier plan micro (Android 14+)
  // -----------------------------------------------------------------
  static bool _fgsRunning = false;

  static Future<void> startMicService({String? peerName}) async {
    if (!Platform.isAndroid || _fgsRunning) return;
    try {
      await _channel.invokeMethod<void>('start', {'peer': peerName ?? 'Appel en cours'});
      _fgsRunning = true;
      AppLogger.breadcrumb('call_fgs_start');
    } catch (error) {
      AppLogger.error('call_fgs_start_failed', error);
    }
  }

  static Future<void> stopMicService() async {
    if (!Platform.isAndroid || !_fgsRunning) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (error) {
      AppLogger.error('call_fgs_stop_failed', error);
    }
    _fgsRunning = false;
  }
}
