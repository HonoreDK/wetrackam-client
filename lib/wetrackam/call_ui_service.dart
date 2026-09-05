// lib/wetrackam/call_ui_service.dart
//
// v13 — LE chaînon manquant des appels entrants. Jusqu'ici, un appel n'était
// visible que si l'application était déjà au premier plan : le push `call`
// se contentait de rouvrir la socket, et l'isolate d'arrière-plan Dart ne
// pouvait de toute façon pas afficher d'écran. Résultat en exploitation :
// « la VoIP ne fonctionne pas » — elle fonctionnait, mais personne ne voyait
// jamais l'appel sonner téléphone en poche.
//
// Ce service encapsule TOUT le natif d'appel, et rien d'autre :
//   - Android : notification plein écran (full-screen intent) qui réveille
//     l'écran verrouillé, plus un service de premier plan de type
//     `microphone` pendant la communication (obligatoire depuis Android 14 :
//     sans lui, le système coupe l'accès micro d'une app en arrière-plan et
//     l'appel devient muet au bout de quelques secondes).
//   - iOS : CallKit (écran d'appel système). ⚠️ Le socle est ici complet et
//     configuré, mais la chaîne PushKit/VoIP iOS exige un certificat VoIP
//     Apple et une compilation sur Mac — voir BUILD-IOS.md. Sur iOS, tant que
//     PushKit n'est pas activé côté serveur, l'appel entrant s'affiche
//     lorsque l'application est au premier plan ou en arrière-plan récent.
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

  static const _fgsChannel = MethodChannel('wetrackam/call_fgs');

  static StreamSubscription<CallEvent?>? _sub;
  static CallUiIntent? _onAccept;
  static CallUiIntent? _onDecline;
  static CallUiIntent? _onEnd;

  /// Identifiant affiché par l'écran natif. Tant que le `callId` réel n'est
  /// pas connu (push reçu AVANT `call.incoming` sur la socket), on utilise
  /// l'identifiant du push, puis on réconcilie via [rebind].
  static String? _shownCallId;
  static String? get shownCallId => _shownCallId;

  static Future<void> init({
    required CallUiIntent onAccept,
    required CallUiIntent onDecline,
    required CallUiIntent onEnd,
  }) async {
    _onAccept = onAccept;
    _onDecline = onDecline;
    _onEnd = onEnd;
    if (_sub != null) return;
    _sub = FlutterCallkitIncoming.onEvent.listen(_onEvent);
    try {
      await FlutterCallkitIncoming.onBackgroundMessage(callkitBackgroundHandler);
    } catch (error) {
      AppLogger.error('callkit_background_register_failed', error);
    }
    AppLogger.breadcrumb('call_ui_init');
  }

  static void _onEvent(CallEvent? event) {
    if (event == null) return;
    switch (event) {
      case CallEventActionCallAccept(:final callKitParams):
        final id = callKitParams.id;
        _shownCallId = id;
        AppLogger.breadcrumb('call_ui_accept');
        _onAccept?.call(id);
      case CallEventActionCallDecline(:final callKitParams):
        AppLogger.breadcrumb('call_ui_decline');
        _onDecline?.call(callKitParams.id);
        _shownCallId = null;
      case CallEventActionCallEnded(:final callKitParams):
        AppLogger.breadcrumb('call_ui_ended');
        _onEnd?.call(callKitParams.id);
        _shownCallId = null;
      case CallEventActionCallTimeout(:final id):
        // Anomalie corrigée : contrairement aux autres cas de ce switch,
        // CallEventActionCallTimeout expose un champ `id` (String) direct,
        // pas `callKitParams` — cette erreur de compilation empêchait
        // l'app entière de builder (undefined_getter).
        // Sonnerie non décrochée : traité EXACTEMENT comme un refus côté
        // protocole (le serveur, lui, a son propre minuteur de 30 s) —
        // surtout pas comme un silence, sinon l'appelant resterait pendu.
        AppLogger.breadcrumb('call_ui_timeout');
        _onDecline?.call(id);
        _shownCallId = null;
      default:
        break;
    }
  }

  // -----------------------------------------------------------------
  // Affichage
  // -----------------------------------------------------------------

  /// Affiche l'écran d'appel entrant natif. Idempotent : rappeler avec le
  /// même `callId` ne crée pas une seconde sonnerie.
  static Future<void> showIncoming({
    required String callId,
    required String callerName,
    int ringTimeoutSeconds = 30,
  }) async {
    if (_shownCallId == callId) return;
    // Un seul appel visible à la fois — sinon deux sonneries superposées
    // après un push suivi du `call.incoming` socket sur un callId différent.
    if (_shownCallId != null) await hide(_shownCallId!);
    _shownCallId = callId;
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(
        _params(callId: callId, callerName: callerName, ringTimeoutSeconds: ringTimeoutSeconds),
      );
      AppLogger.breadcrumb('call_ui_incoming_shown');
    } catch (error) {
      AppLogger.error('call_ui_show_failed', error);
      _shownCallId = null;
    }
  }

  /// Le push arrive avant la socket : l'écran natif a été affiché avec le
  /// `callId` du push. Si le `call.incoming` reçu ensuite porte un autre
  /// identifiant (cas d'un push perdu puis d'un nouvel appel), on remplace
  /// l'écran plutôt que de laisser deux appels divergents.
  static Future<void> rebind({
    required String realCallId,
    required String callerName,
    required int ringTimeoutSeconds,
  }) async {
    if (_shownCallId == realCallId) return;
    await showIncoming(
      callId: realCallId,
      callerName: callerName,
      ringTimeoutSeconds: ringTimeoutSeconds,
    );
  }

  /// Passage en communication : bascule l'écran natif en « appel en cours »
  /// et démarre le service de premier plan micro (Android).
  static Future<void> setConnected(String callId) async {
    try {
      await FlutterCallkitIncoming.setCallConnected(callId);
    } catch (error) {
      AppLogger.error('call_ui_connected_failed', error);
    }
    await startMicService();
  }

  /// Appel sortant : l'écran natif sert ici à tenir le service de premier
  /// plan et à afficher l'appel dans l'historique système (iOS).
  static Future<void> showOutgoing({
    required String callId,
    required String peerName,
  }) async {
    _shownCallId = callId;
    try {
      await FlutterCallkitIncoming.startCall(_params(
        callId: callId,
        callerName: peerName,
        ringTimeoutSeconds: 30,
      ));
    } catch (error) {
      AppLogger.error('call_ui_outgoing_failed', error);
    }
    await startMicService();
  }

  /// Fin d'appel, quel que soit le motif. TOUJOURS appelé depuis le point de
  /// nettoyage unique de CallService — jamais ailleurs, sinon l'écran natif
  /// et l'état applicatif pourraient diverger.
  static Future<void> hide(String? callId) async {
    await stopMicService();
    try {
      if (callId != null) {
        await FlutterCallkitIncoming.endCall(callId);
      }
      // Filet : un écran orphelin (push affiché puis appel annulé avant la
      // socket) ne doit jamais rester à sonner sur le téléphone.
      await FlutterCallkitIncoming.endAllCalls();
    } catch (error) {
      AppLogger.error('call_ui_hide_failed', error);
    }
    _shownCallId = null;
  }

  /// Au démarrage : l'utilisateur a-t-il accepté un appel alors que
  /// l'application était tuée ? Renvoie le `callId` accepté, une seule fois.
  static Future<String?> consumeExternalAcceptance() async {
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      for (final call in calls) {
        if (call.isAccepted) {
          _shownCallId = call.id;
          AppLogger.breadcrumb('call_ui_external_acceptance');
          return call.id;
        }
      }
    } catch (error) {
      AppLogger.error('call_ui_active_calls_failed', error);
    }
    return null;
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
      // Anomalie corrigée (erreur de compilation) : `textAccept`/
      // `textDecline` n'existent plus au niveau racine de CallKitParams
      // dans flutter_callkit_incoming 3.1.5 — déplacés dans AndroidParams.
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

  static Future<void> startMicService() async {
    if (!Platform.isAndroid || _fgsRunning) return;
    try {
      await _fgsChannel.invokeMethod<void>('start');
      _fgsRunning = true;
      AppLogger.breadcrumb('call_fgs_start');
    } catch (error) {
      AppLogger.error('call_fgs_start_failed', error);
    }
  }

  static Future<void> stopMicService() async {
    if (!Platform.isAndroid || !_fgsRunning) return;
    try {
      await _fgsChannel.invokeMethod<void>('stop');
    } catch (error) {
      AppLogger.error('call_fgs_stop_failed', error);
    }
    _fgsRunning = false;
  }
}
