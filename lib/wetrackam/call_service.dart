// lib/wetrackam/call_service.dart
//
// Lot 8 — appels WebRTC (contrat v5 §12-13, PROMPT-MOBILE-HONORE.md §7).
//
// Règles impératives du contrat, toutes appliquées ici :
//  1. iceServers récupérés JUSTE AVANT de créer la RTCPeerConnection
//     (RtcConfigService.refreshIceServersForCall(), jamais le cache du
//     polling général — les identifiants TURN expirent en 120s).
//  2. Trickle ICE obligatoire — chaque candidat envoyé dès sa découverte.
//  3. Un seul appel actif — call.incoming REFUSÉ (call.decline) si déjà en
//     communication, jamais ignoré en silence : sinon l'appelant sonne dans
//     le vide jusqu'au délai de garde.
//  4. Minuteur local de secours en sonnerie (filet si call.ended se perd).
//  5. Sur ENDED quel que soit le motif : audio coupé, PeerConnection
//     fermée, tout nettoyé — jamais de micro qui reste ouvert. L'état bascule
//     AVANT la libération native, qui ne doit jamais retenir l'interface.
//  6. restartIce() sur bascule réseau pendant CONNECTED, jamais un hangup.
//     Émis par le seul APPELANT (évite le « glare » de double offre).
//  7. call.stats{relayed} remonté après établissement.
//  8. L'état réel du média fait foi autant que la signalisation : une
//     PeerConnection qui tombe termine l'appel et prévient le pair.
//
// v17 — CE QUI A ÉTÉ CORRIGÉ, ET POURQUOI (recette sur téléphones réels)
//
//  A. « Le téléphone continue de sonner/vibrer après avoir décroché, la
//     notification reste en haut, et l'appel se coupe seul au bout de 20 s. »
//     La notification native d'appel entrant était affichée EN PLUS de la page
//     Flutter, survivait au décrochage, puis EXPIRAIT — et son expiration
//     était traitée comme un refus qui raccrochait la communication.
//     -> une seule surface de sonnerie (call_policy.shouldRingInApp), fermée
//        dès le décrochage (CallUiService.dismissIncoming), et chaque
//        événement natif validé par appel ET par phase
//        (call_policy.decideNativeEvent). Un délai natif n'est plus jamais un
//        raccrochage.
//
//  B. « L'autre a raccroché mais mon écran reste “en cours” » / « j'ai
//     raccroché mais il m'entend encore ». Les signaux d'appel envoyés
//     pendant une reconnexion de socket étaient jetés, et le serveur
//     raccrochait à la moindre coupure de socket sans prévenir le côté coupé.
//     -> file de signaux rejouée à la reconnexion (call_policy.CallSignalQueue
//        dans RealtimeService), `call.resume` à chaque `ready` (le serveur
//        répond l'état réel ou `call.ended{unknown}`), délai de grâce côté
//        serveur avec `call.peer{reconnecting|online}` affiché à l'écran.
//
//  C. « Décroché, mais muet, puis coupé. » Les candidats ICE distants reçus
//     avant la description distante (l'appelé les envoie dans la foulée de sa
//     réponse, et ils la doublaient côté serveur) étaient rejetés et perdus.
//     -> mise en file jusqu'à `setRemoteDescription` (`_remoteDescriptionSet`),
//        rejoués ensuite ; le serveur relaie aussi la réponse AVANT d'écrire
//        en base.
//
//  D. Décrochage sur l'écran natif : la page « Appel entrant » restait
//     affichée avec ses boutons ; application tuée : aucun écran d'appel.
//     -> CallNavigator suit la phase (call_policy.nextRouteAction) et tient
//        l'unique route d'appel ; les écrans ne naviguent plus eux-mêmes.
//
// NE PAS « améliorer » _openMicrophone() en passant une Map de contraintes :
// sur Android, `'audio': true` déclenche addDefaultAudioConstraints() (annulation
// d'écho, réduction de bruit) ; une Map les REMPLACE et, comme la couche native
// ne lit que `mandatory`/`optional`, des clés au format standard seraient
// ignorées — on perdrait l'annulation d'écho sans le voir.
import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'api_client.dart' show NetworkException;
import 'app_logger.dart';
import 'call_policy.dart';
import 'call_ui_service.dart';
import 'driver_identity_service.dart';
import 'local_notifications_service.dart';
import 'peer_name_cache.dart';
import 'realtime_service.dart';
import 'rtc_config_service.dart';

export 'call_policy.dart' show CallPhase;

class IncomingCallInfo {
  final String callId;
  final int peerId;
  final String sdp;
  const IncomingCallInfo({required this.callId, required this.peerId, required this.sdp});
}

class CallService {
  CallService._();

  static CallPhase _phase = CallPhase.idle;
  static String? _callId;
  static int? _peerId;
  static String? _peerName;
  static String? _pendingRemoteSdp; // offre reçue avec call.incoming
  static RTCPeerConnection? _pc;
  static MediaStream? _localStream;
  static Timer? _ringingSafetyTimer;
  static StreamSubscription<Map<String, dynamic>>? _sub;
  static StreamSubscription<void>? _readySub;
  static DateTime? _connectedAt;

  /// Instant de la connexion (signalisation). in_call_screen.dart démarre son
  /// chronomètre dessus plutôt que sur son propre initState : un écran
  /// (re)construit après coup afficherait sinon une durée fausse.
  static DateTime? get connectedAt => _connectedAt;

  /// v13 — durée de sonnerie ANNONCÉE PAR LE SERVEUR (`timeoutSeconds` de
  /// `call.incoming`, `ringTimeoutSeconds` du message `ready`).
  static int _ringTimeoutSeconds = 30;

  /// v17 — acceptation donnée sur l'écran natif AVANT l'arrivée de
  /// `call.incoming` (push plus rapide que la socket, application tuée).
  /// Identifiée par son `callId` : une acceptation ne peut plus être
  /// appliquée à un autre appel que le sien.
  static String? _pendingAcceptId;
  static Timer? _pendingAcceptTimer;
  static Timer? _statsTimer;
  static final List<RTCIceCandidate> _pendingLocalCandidates = [];

  /// Candidats ICE DISTANTS reçus avant que la description distante ne soit
  /// posée (appelé : pendant la sonnerie ; appelant : avant la réponse SDP).
  /// Jamais jetés — sur un réseau où seul le relais TURN passe, le premier
  /// candidat est souvent le seul qui compte.
  static final List<Map<String, dynamic>> _pendingRemoteCandidates = [];
  static const _maxPendingRemoteCandidates = 60;
  static bool _remoteDescriptionSet = false;

  /// Rôle dans CET appel. Seul l'appelant renégocie (redémarrage ICE).
  static bool _isCaller = false;

  /// Fenêtre de reprise média : un chemin ICE qui tombe passe par
  /// `disconnected` avant `failed`. On tente de recoller pendant ce délai.
  /// Inférieure au délai de grâce serveur (25 s) : le serveur ne raccroche
  /// jamais avant nous.
  static Timer? _recoveryTimer;
  static const _mediaRecoveryWindow = Duration(seconds: 15);

  /// v17 — état RÉEL du média (PeerConnection `connected`) et état du pair
  /// (`call.peer{reconnecting|online}`), pour que l'écran dise la vérité :
  /// « Connexion… », « Reconnexion… », ou le chronomètre.
  static bool _mediaUp = false;
  static bool _peerReconnecting = false;
  static bool _answering = false;
  static bool get mediaUp => _mediaUp;
  static bool get peerReconnecting => _peerReconnecting;
  static bool get answering => _answering;

  /// v17 — l'appelant a annulé AVANT que le serveur n'ait attribué le
  /// `callId` (invitation en vol). Sans ce drapeau, l'annulation ne partait
  /// jamais : le collègue sonnait 30 s pour un appel déjà abandonné, et s'il
  /// décrochait, il restait sur un appel mort.
  static bool _cancelWhenCallIdKnown = false;

  /// Identifiant de la surface native (CallKit / notification). Entrant :
  /// celui du serveur (le push l'utilise aussi). Sortant : local, attribué
  /// avant que le serveur n'ait répondu.
  static String? _nativeCallId;

  /// Application au premier plan (main.dart tient cette valeur à jour).
  static bool _foreground = true;

  static final _phaseController = StreamController<CallPhase>.broadcast();
  static Stream<CallPhase> get phaseChanges => _phaseController.stream;
  static final _uiController = StreamController<void>.broadcast();

  /// Tout changement visible (phase, média, pair, nom) : les écrans se
  /// redessinent dessus, sans connaître le détail.
  static Stream<void> get uiChanges => _uiController.stream;
  static CallPhase get phase => _phase;
  static int? get peerId => _peerId;
  static String? get peerName => _peerName;
  static bool get isForeground => _foreground;

  /// Écran d'appel entrant à afficher — alimenté par `call.incoming`.
  static final _incomingCallController = StreamController<IncomingCallInfo>.broadcast();
  static Stream<IncomingCallInfo> get incomingCalls => _incomingCallController.stream;

  static void init() {
    _sub ??= RealtimeService.messages.listen(_onMessage);
    _readySub ??= RealtimeService.readyEvents.listen((_) => _onSocketReady());
    unawaited(CallUiService.init(
      onAccept: (id) => _onNativeEvent(NativeCallEventKind.accept, id),
      onDecline: (id) => _onNativeEvent(NativeCallEventKind.decline, id),
      onEnd: (id) => _onNativeEvent(NativeCallEventKind.ended, id),
      onTimeout: (id) => _onNativeEvent(NativeCallEventKind.timeout, id),
    ));
  }

  /// main.dart : premier plan / arrière-plan. La surface de sonnerie d'un
  /// appel entrant suit ce changement (page Flutter au premier plan,
  /// notification native sinon) — toujours UNE seule surface.
  static void onAppForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!_stillRinging || _callId == null) return;
    if (!Platform.isAndroid) return;
    final callId = _callId!;
    if (foreground) {
      unawaited(CallUiService.dismissIncoming(callId));
      unawaited(CallUiService.ringInApp());
    } else {
      unawaited(CallUiService.stopInAppRing());
      unawaited(CallUiService.showNativeIncoming(
        callId: callId,
        callerName: _peerName ?? 'Collègue',
        ringTimeoutSeconds: _ringTimeoutSeconds,
      ));
    }
    _emitUi();
  }

  /// v13 — à appeler UNE FOIS au démarrage : reprend un appel accepté sur
  /// l'écran natif alors que l'application était tuée (le système relance
  /// l'app, il faut retrouver l'appel en cours plutôt que d'ouvrir l'accueil).
  static Future<void> resumeExternalAcceptanceAtStartup() async {
    final acceptedId = await CallUiService.consumeExternalAcceptance();
    if (acceptedId == null) return;
    AppLogger.breadcrumb('call_resume_external_acceptance');
    _rememberPendingAccept(acceptedId);
    // La socket est indispensable pour envoyer `call.accept` : le serveur
    // renvoie `call.incoming` (avec l'offre) au participant qui revient
    // pendant la sonnerie, et `_onIncoming` rejoue l'acceptation.
    try {
      await RealtimeService.ensureConnected();
    } catch (error) {
      AppLogger.error('call_resume_connect_failed', error);
    }
    if (_phase == CallPhase.incomingRinging && _callId == acceptedId) await acceptCall();
  }

  static void _rememberPendingAccept(String callId) {
    _pendingAcceptId = callId;
    _pendingAcceptTimer?.cancel();
    _pendingAcceptTimer = Timer(Duration(seconds: _ringTimeoutSeconds + 5), () {
      if (_pendingAcceptId == callId) {
        _pendingAcceptId = null;
        unawaited(CallUiService.endAll(callId));
      }
    });
  }

  static void _forgetPendingAccept() {
    _pendingAcceptId = null;
    _pendingAcceptTimer?.cancel();
    _pendingAcceptTimer = null;
  }

  /// TOUS les événements de l'écran natif passent par ici, et par la table de
  /// décision de call_policy.dart : un événement ne vaut que pour l'appel
  /// qu'il nomme, dans la phase où il a un sens.
  static void _onNativeEvent(NativeCallEventKind kind, String callId) {
    final action = decideNativeEvent(
      kind: kind,
      eventCallId: callId,
      phase: _phase,
      currentCallId: _nativeCallId ?? _callId,
      pendingAcceptId: _pendingAcceptId,
    );
    AppLogger.breadcrumb('call_native:${kind.name}:${action.name}');
    switch (action) {
      case NativeCallAction.accept:
        unawaited(acceptCall());
      case NativeCallAction.rememberAccept:
        _rememberPendingAccept(callId);
        unawaited(RealtimeService.ensureConnected().catchError((_) {}));
      case NativeCallAction.decline:
        unawaited(declineCall());
      case NativeCallAction.missed:
        _missed('timeout');
      case NativeCallAction.hangUp:
        unawaited(hangUp());
      case NativeCallAction.forgetPending:
        _forgetPendingAccept();
        unawaited(CallUiService.endAll(callId));
      case NativeCallAction.dismissOnly:
        unawaited(CallUiService.endAll(callId));
      case NativeCallAction.ignore:
        break;
    }
  }

  /// Vrai tant que l'appel entrant sonne ET que personne n'a encore
  /// décroché : dès l'appui sur « Accepter », plus aucune surface ne doit
  /// (re)sonner, même si la phase ne bascule qu'après l'ouverture du micro.
  static bool get _stillRinging => _phase == CallPhase.incomingRinging && !_accepting;

  static void _setPhase(CallPhase phase) {
    _phase = phase;
    _phaseController.add(phase);
    _emitUi();
  }

  static void _emitUi() {
    if (!_uiController.isClosed) _uiController.add(null);
  }

  // -----------------------------------------------------------------
  // Émission
  // -----------------------------------------------------------------
  static Future<void> placeCall({required int peerId, required String peerName}) async {
    if (_phase != CallPhase.idle) {
      AppLogger.breadcrumb('call_place_ignored_not_idle');
      return; // règle 3 : un seul appel actif
    }
    _peerId = peerId;
    _peerName = peerName;
    _isCaller = true;
    _cancelWhenCallIdKnown = false;
    _nativeCallId = 'out-${DateTime.now().millisecondsSinceEpoch}';
    // La phase bascule TOUT DE SUITE : l'écran d'appel affiche « Appel en
    // cours… » pendant la préparation (ticket, TURN, micro, offre) au lieu
    // d'un chronomètre qui démarre avant même la sonnerie ; et le filet de
    // sonnerie couvre aussi une préparation qui n'aboutirait pas.
    _setPhase(CallPhase.outgoingRinging);
    _armRingingSafetyTimer();
    try {
      await RealtimeService.ensureConnected();
      if (_phase != CallPhase.outgoingRinging) return; // annulé pendant la préparation
      final iceServers = await RtcConfigService.refreshIceServersForCall(); // règle 1
      if (_phase != CallPhase.outgoingRinging) return;
      final pc = await _buildPeerConnection(iceServers);
      if (_phase != CallPhase.outgoingRinging) {
        await pc.close();
        return;
      }
      _pc = pc;
      final stream = await _openMicrophone();
      if (_phase != CallPhase.outgoingRinging) {
        await _releaseMedia(stream, null);
        return;
      }
      _localStream = stream;
      for (final track in stream.getAudioTracks()) {
        await pc.addTrack(track, stream);
      }
      final offer = await pc.createOffer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 0});
      await pc.setLocalDescription(offer);
      if (!DriverIdentityService.isAuthenticated || _phase != CallPhase.outgoingRinging) {
        AppLogger.breadcrumb('call_place_discarded');
        await _cleanup();
        return;
      }
      RealtimeService.send({'type': 'call.invite', 'peerId': peerId, 'sdp': offer.sdp});
      // Android 14+ : sans service de premier plan de type `microphone`, le
      // système coupe la capture dès que l'application quitte l'écran.
      unawaited(CallUiService.markOutgoing(callId: _nativeCallId!, peerName: peerName));
      AppLogger.breadcrumb('call_invite_sent');
    } catch (error) {
      AppLogger.error('call_place_failed', error);
      _lastErrorReason ??= error is NetworkException ? 'networkUnavailable' : 'mediaUnavailable';
      await _cleanup();
    }
  }

  /// Verrou synchrone contre le double décrochage (écran natif ET page
  /// Flutter, ou double appui) — reproduit en direct sur téléphone.
  static bool _accepting = false;

  static Future<void> acceptCall() async {
    final remoteSdp = _pendingRemoteSdp;
    final callId = _callId;
    if (_phase != CallPhase.incomingRinging || remoteSdp == null || callId == null) return;
    if (_accepting) return;
    _accepting = true;
    // 1. LA SONNERIE S'ARRÊTE MAINTENANT — pas après l'ouverture du micro et
    //    la négociation, qui prennent une à deux secondes. C'est ce que fait
    //    un téléphone : le geste est immédiat, la connexion suit.
    _ringingSafetyTimer?.cancel();
    _ringingSafetyTimer = null;
    _forgetPendingAccept();
    unawaited(CallUiService.stopInAppRing());
    unawaited(CallUiService.dismissIncoming(callId));
    _answering = true;
    _emitUi();
    try {
      final iceServers = await RtcConfigService.refreshIceServersForCall(); // règle 1
      if (_callId != callId) return; // terminé pendant la préparation
      final pc = await _buildPeerConnection(iceServers);
      if (_callId != callId) {
        await pc.close();
        return;
      }
      _pc = pc;
      final stream = await _openMicrophone();
      if (_callId != callId) {
        await _releaseMedia(stream, null);
        return;
      }
      _localStream = stream;
      for (final track in stream.getAudioTracks()) {
        await pc.addTrack(track, stream);
      }
      await pc.setRemoteDescription(RTCSessionDescription(remoteSdp, 'offer'));
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      final answer = await pc.createAnswer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 0});
      await pc.setLocalDescription(answer);
      if (!DriverIdentityService.isAuthenticated || _callId != callId) {
        AppLogger.breadcrumb('call_accept_discarded');
        await _cleanup();
        return;
      }
      RealtimeService.send({'type': 'call.accept', 'callId': callId, 'sdp': answer.sdp});
      // §13 : le CALLEE passe à connected sur son propre call.accept, sans
      // attendre un message serveur supplémentaire.
      _markConnected();
      AppLogger.breadcrumb('call_accepted');
    } catch (error) {
      AppLogger.error('call_accept_failed', error);
      _lastErrorReason ??= 'mediaUnavailable';
      if (_callId == callId) {
        RealtimeService.send({'type': 'call.decline', 'callId': callId});
      }
      await _cleanup();
    } finally {
      _accepting = false;
      _answering = false;
      _emitUi();
    }
  }

  static Future<void> declineCall() async {
    if (_phase != CallPhase.incomingRinging) return;
    if (_callId != null) RealtimeService.send({'type': 'call.decline', 'callId': _callId});
    await _cleanup();
  }

  static Future<void> cancelOutgoing() async {
    if (_phase != CallPhase.outgoingRinging) return;
    if (_callId != null) {
      RealtimeService.send({'type': 'call.cancel', 'callId': _callId});
    } else {
      // Le serveur n'a pas encore répondu `ringing` : on annulera dès qu'il
      // nomme l'appel (voir _onCallState), sinon le collègue sonne pour rien.
      _cancelWhenCallIdKnown = true;
    }
    await _cleanup();
  }

  static Future<void> hangUp() async {
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    if (_phase == CallPhase.incomingRinging) return declineCall();
    if (_phase == CallPhase.outgoingRinging) return cancelOutgoing();
    if (_callId != null) RealtimeService.send({'type': 'call.hangup', 'callId': _callId});
    await _cleanup();
  }

  /// Sonnerie non décrochée (délai local ou natif) : appel MANQUÉ. Rien
  /// n'est envoyé — le serveur clôt lui-même avec la raison `timeout`, qui
  /// journalise un appel manqué et non un refus.
  static void _missed(String reason) {
    if (_phase != CallPhase.incomingRinging) return;
    AppLogger.breadcrumb('call_missed:$reason');
    // Délai de l'écran natif : il affiche lui-même « Appel manqué ». Délai
    // local (sonnerie dans l'application) : aucune surface n'a laissé de
    // trace, on la laisse nous-mêmes, comme un téléphone.
    if (reason != 'timeout') _notifyMissed();
    unawaited(_cleanup());
  }

  static void _notifyMissed() {
    unawaited(LocalNotificationsService.showGeneric(
      title: 'Appel manqué',
      body: _peerName ?? 'Un collègue vous a appelé',
      channelId: 'calls',
    ));
  }

  // -----------------------------------------------------------------
  // Réception des messages de signalisation
  // -----------------------------------------------------------------
  static void _onMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    switch (type) {
      case 'call.state':
        _onCallState(message);
      case 'call.incoming':
        _onIncoming(message);
      case 'call.accepted':
        _onAccepted(message);
      case 'call.offer':
        _onRemoteOffer(message); // relais transparent, cas re-négociation
      case 'call.answer':
        _onRemoteAnswer(message);
      case 'call.candidate':
        _onRemoteCandidate(message);
      case 'call.ended':
        _onEnded(message);
      case 'call.peer':
        _onPeer(message);
      case 'error':
        _onError(message);
    }
  }

  /// v17 — la socket vient de (re)passer `ready`. Si un appel est en cours de
  /// notre point de vue, le serveur doit le confirmer : il répond l'état réel
  /// (`call.state`) ou `call.ended{unknown}` si l'appel a été clos pendant la
  /// coupure. Plus jamais d'appel fantôme « en cours » sans fin.
  static void _onSocketReady() {
    if (_callId == null) return;
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    RealtimeService.send({'type': 'call.resume', 'callId': _callId});
    AppLogger.breadcrumb('call_resume_sent');
  }

  static String? _lastErrorReason;
  static void _onError(Map<String, dynamic> message) {
    final reason = message['reason'] as String?;
    if (_phase == CallPhase.idle) {
      // L'invitation annulée en vol a été refusée : plus rien à annuler.
      if (reason == 'peerUnavailable' || reason == 'peerInvalid' || reason == 'callsDisabled'
          || reason == 'alreadyInCall' || reason == 'rateLimited' || reason == 'peerValidationUnavailable') {
        _cancelWhenCallIdKnown = false;
      }
      return; // erreur sans rapport avec un appel en cours (chat, presence...)
    }
    switch (reason) {
      case 'peerUnavailable':
      case 'peerCrossTenant':
      case 'callsDisabled':
      case 'callUnknown':
      case 'callState':
      case 'peerInvalid':
      case 'peerValidationUnavailable':
      case 'alreadyInCall':
        AppLogger.breadcrumb('call_error:$reason');
        _lastErrorReason = reason;
        _cleanup();
      case 'rateLimited':
        // Un rateLimited reçu en pleine conversation concerne le chat, pas
        // l'appel : on ne nettoie que pendant l'établissement.
        if (_phase == CallPhase.outgoingRinging) {
          AppLogger.breadcrumb('call_error:$reason');
          _lastErrorReason = reason;
          _cleanup();
        }
      default:
        break;
    }
  }

  /// Consommé une fois par l'écran pour afficher le bon message (§10
  /// catalogue), puis remis à null.
  static String? consumeLastErrorReason() {
    final reason = _lastErrorReason;
    _lastErrorReason = null;
    return reason;
  }

  static void _onCallState(Map<String, dynamic> message) {
    final state = message['state'] as String?;
    final resumed = message['resumed'] == true;
    if (state == 'busy') {
      _cancelWhenCallIdKnown = false;
      if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
      AppLogger.breadcrumb('call_busy');
      _lastErrorReason = 'busy';
      _cleanup();
      return;
    }
    if (state == 'ringing') {
      if (_phase != CallPhase.outgoingRinging) {
        final callId = message['callId'] as String?;
        if (_cancelWhenCallIdKnown && callId != null) {
          _cancelWhenCallIdKnown = false;
          RealtimeService.send({'type': 'call.cancel', 'callId': callId});
          AppLogger.breadcrumb('call_cancel_after_ringing');
        }
        return;
      }
      // Reprise (socket rouverte pendant notre sonnerie sortante) : le
      // serveur sonne toujours ; on complète seulement ce qui aurait pu se
      // perdre (callId, candidats en attente) sans réarmer le filet.
      _callId ??= message['callId'] as String?;
      _flushLocalCandidates();
      final timeout = (message['timeoutSeconds'] as num?)?.toInt();
      if (!resumed && timeout != null && timeout > 0) {
        _ringTimeoutSeconds = timeout;
        _armRingingSafetyTimer();
      }
      return;
    }
    if (state == 'connected') {
      if (!_isForCurrentCall(message)) return;
      if (resumed && (_phase == CallPhase.idle || _phase == CallPhase.ended || _pc == null)) {
        // Le serveur croit cet appel en cours, nous n'avons plus aucun média
        // (application relancée) : on le clôt proprement, ce qui libère le
        // pair au lieu de le laisser sur un appel mort.
        final callId = message['callId'] as String?;
        if (callId != null) RealtimeService.send({'type': 'call.hangup', 'callId': callId});
        return;
      }
      if (message['peerOnline'] == false) _setPeerReconnecting(true);
      _markConnected();
      return;
    }
    if (state == 'ended') {
      _onEnded(message);
    }
  }

  static void _onIncoming(Map<String, dynamic> message) {
    final callId = message['callId'] as String?;
    if (callId == null) return;
    if (_phase != CallPhase.idle && _phase != CallPhase.ended) {
      if (_callId == callId) {
        // Renvoi du serveur après une reconnexion pendant notre sonnerie :
        // même appel, rien à recréer — on complète seulement l'offre si elle
        // manquait.
        _pendingRemoteSdp ??= message['sdp'] as String?;
        return;
      }
      // Règle 3 : un seul appel actif. Refus EXPLICITE, jamais un silence :
      // sinon l'appelant écoute une sonnerie dans le vide.
      RealtimeService.send({'type': 'call.decline', 'callId': callId});
      AppLogger.breadcrumb('call_incoming_declined_busy');
      return;
    }
    _isCaller = false;
    _callId = callId;
    _nativeCallId = callId;
    _peerId = message['peerId'] as int?;
    _pendingRemoteSdp = message['sdp'] as String?;
    _remoteDescriptionSet = false;
    _lastErrorReason = null;
    final timeout = (message['timeoutSeconds'] as num?)?.toInt();
    if (timeout != null && timeout > 0) _ringTimeoutSeconds = timeout;
    _setPhase(CallPhase.incomingRinging);
    _armRingingSafetyTimer();
    if (_peerId != null && _pendingRemoteSdp != null) {
      _incomingCallController.add(IncomingCallInfo(
          callId: callId, peerId: _peerId!, sdp: _pendingRemoteSdp!));
    }
    AppLogger.breadcrumb('call_incoming');
    // Acceptation déjà donnée sur l'écran natif : rejouée maintenant, une
    // seule fois, et uniquement si elle concerne CET appel.
    if (_pendingAcceptId != null) {
      if (_pendingAcceptId == callId) {
        _forgetPendingAccept();
        unawaited(acceptCall());
        return;
      }
      final stale = _pendingAcceptId!;
      _forgetPendingAccept();
      unawaited(CallUiService.endAll(stale));
    }
    unawaited(_presentIncoming(callId));
  }

  /// Une seule surface de sonnerie, choisie par call_policy.shouldRingInApp.
  /// Le nom du collègue vient du cache local (rapide) ; si l'appel a été
  /// décroché ou terminé pendant cette lecture, rien n'est affiché — c'est
  /// cette course qui relançait la sonnerie en pleine communication.
  static Future<void> _presentIncoming(String callId) async {
    final peerId = _peerId;
    final name = peerId != null ? await PeerNameCache.displayName(peerId) : 'Collègue';
    if (_callId != callId || !_stillRinging) return;
    _peerName = name;
    _emitUi();
    if (shouldRingInApp(android: Platform.isAndroid, foreground: _foreground)) {
      await CallUiService.ringInApp();
      if (_callId != callId || !_stillRinging) {
        await CallUiService.stopInAppRing();
      }
      return;
    }
    await CallUiService.showNativeIncoming(
      callId: callId,
      callerName: name,
      ringTimeoutSeconds: _ringTimeoutSeconds,
    );
    if (_callId != callId || !_stillRinging) {
      // Décroché ou terminé pendant l'affichage : la surface native ne doit
      // pas survivre une seconde à l'appel.
      await CallUiService.dismissIncoming(callId);
    }
  }

  static Future<void> _onAccepted(Map<String, dynamic> message) async {
    final sdp = message['sdp'] as String?;
    if (sdp == null || _pc == null) return;
    if (!_isForCurrentCall(message)) return;
    if (_remoteDescriptionSet) return; // doublon (reprise) : déjà posée
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _remoteDescriptionSet = true;
      AppLogger.breadcrumb('call_remote_answer_set');
      await _flushRemoteCandidates();
      // La réception du SDP answer est en soi la preuve que le pair a
      // décroché ; `_markConnected()` est idempotent.
      _markConnected();
    } catch (error) {
      AppLogger.error('call_set_remote_answer_failed', error);
      _lastErrorReason = 'answerRejected';
      if (_callId != null) RealtimeService.send({'type': 'call.hangup', 'callId': _callId});
      await _cleanup();
    }
  }

  /// §12.6 — offre de RENÉGOCIATION reçue du pair (redémarrage ICE après un
  /// changement de réseau).
  static Future<void> _onRemoteOffer(Map<String, dynamic> message) async {
    final sdp = message['sdp'] as String?;
    if (sdp == null || _pc == null) return;
    if (!_isForCurrentCall(message)) return;
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      final answer = await _pc!.createAnswer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 0});
      await _pc!.setLocalDescription(answer);
      RealtimeService.send({'type': 'call.answer', 'callId': _callId, 'sdp': answer.sdp});
      AppLogger.breadcrumb('call_renegotiation_answered');
    } catch (error) {
      AppLogger.error('call_renegotiation_failed', error);
    }
  }

  static Future<void> _onRemoteAnswer(Map<String, dynamic> message) async {
    final sdp = message['sdp'] as String?;
    if (sdp == null || _pc == null) return;
    if (!_isForCurrentCall(message)) return;
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      AppLogger.breadcrumb('call_renegotiation_completed');
    } catch (error) {
      // Réponse arrivée hors séquence : sans ce filet, l'exception coupait le
      // traitement des messages suivants de la socket.
      AppLogger.error('call_set_remote_answer_failed', error);
    }
  }

  static Future<void> _onRemoteCandidate(Map<String, dynamic> message) async {
    final candidateMap = message['candidate'] as Map<String, dynamic>?;
    if (candidateMap == null) return;
    if (!_isForCurrentCall(message)) return;
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    // Sans description distante, la pile WebRTC REJETTE le candidat : on le
    // garde pour l'appliquer dès qu'elle est posée (voir _flushRemoteCandidates).
    if (_pc == null || !_remoteDescriptionSet) {
      if (_pendingRemoteCandidates.length >= _maxPendingRemoteCandidates) return;
      _pendingRemoteCandidates.add(candidateMap);
      return;
    }
    await _addRemoteCandidate(candidateMap);
  }

  static Future<void> _addRemoteCandidate(Map<String, dynamic> candidateMap) async {
    if (_pc == null) return;
    try {
      await _pc!.addCandidate(RTCIceCandidate(
        candidateMap['candidate'] as String?,
        candidateMap['sdpMid'] as String?,
        candidateMap['sdpMLineIndex'] as int?,
      ));
    } catch (error) {
      AppLogger.breadcrumb('call_add_candidate_failed');
    }
  }

  static Future<void> _flushRemoteCandidates() async {
    if (_pc == null || _pendingRemoteCandidates.isEmpty) return;
    final buffered = List<Map<String, dynamic>>.from(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidateMap in buffered) {
      await _addRemoteCandidate(candidateMap);
    }
    AppLogger.breadcrumb('call_remote_candidates_flushed:${buffered.length}');
  }

  static void _onEnded(Map<String, dynamic> message) {
    final callId = message['callId'] as String?;
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) {
      // Rien à terminer chez nous : on s'assure seulement qu'aucune surface
      // native ne survit (push affiché puis appel annulé avant la socket).
      if (callId != null && callId.isNotEmpty) {
        if (_pendingAcceptId == callId) _forgetPendingAccept();
        unawaited(CallUiService.endAll(callId));
      }
      return;
    }
    if (!_isForCurrentCall(message)) {
      AppLogger.breadcrumb('call_ended_ignored_other_call');
      return;
    }
    final reason = message['reason'] as String?;
    AppLogger.breadcrumb('call_ended:$reason');
    if (reason == 'busy' || reason == 'declined' || reason == 'timeout') {
      if (_phase == CallPhase.outgoingRinging) _lastErrorReason = reason;
    }
    // L'appelant a raccroché avant qu'on décroche, ou le serveur a clos la
    // sonnerie : appel manqué, signalé comme tel (la surface native est
    // fermée sans trace par le nettoyage).
    if (_phase == CallPhase.incomingRinging && !_accepting &&
        (reason == 'cancelled' || reason == 'timeout')) {
      _notifyMissed();
    }
    _cleanup();
  }

  /// v17 — fin d'appel reçue PAR PUSH (`call_ended`) alors que l'application
  /// est vivante : la socket, si elle est ouverte, apporte la même nouvelle
  /// par `call.ended` — le traitement est le même et idempotent.
  static void onCallEndedFromPush({required String callId, required String reason}) {
    if (_callId == callId && _phase != CallPhase.idle && _phase != CallPhase.ended) {
      _onEnded({'type': 'call.ended', 'callId': callId, 'reason': reason});
      return;
    }
    unawaited(CallUiService.endFromPush(
      callId: callId,
      reason: reason,
      callerName: _peerName ?? 'Collègue',
    ));
  }

  /// v17 — état du pair pendant l'appel (`call.peer`). Le serveur conserve
  /// l'appel pendant la reconnexion du pair : l'écran affiche
  /// « Reconnexion… » plutôt qu'un chronomètre qui ment.
  static void _onPeer(Map<String, dynamic> message) {
    if (!_isForCurrentCall(message)) return;
    if (_phase != CallPhase.connected && _phase != CallPhase.outgoingRinging) return;
    final state = message['state'] as String?;
    if (state == 'reconnecting') {
      _setPeerReconnecting(true);
    } else if (state == 'online') {
      _setPeerReconnecting(false);
    }
  }

  static void _setPeerReconnecting(bool value) {
    if (_peerReconnecting == value) return;
    _peerReconnecting = value;
    AppLogger.breadcrumb('call_peer_${value ? 'reconnecting' : 'online'}');
    _emitUi();
  }

  /// Un message de signalisation ne vaut que pour l'appel EN COURS.
  /// Tolérant tant que l'identifiant local est inconnu : côté appelant, le
  /// callId n'arrive qu'avec `call.state{ringing}`.
  static bool _isForCurrentCall(Map<String, dynamic> message) {
    final callId = message['callId'] as String?;
    if (callId == null || callId.isEmpty || _callId == null) return true;
    return callId == _callId;
  }

  // -----------------------------------------------------------------
  // WebRTC — construction, ICE trickle, statistiques
  // -----------------------------------------------------------------
  static Future<RTCPeerConnection> _buildPeerConnection(List<RtcIceServer> iceServers) async {
    final config = {
      'iceServers': iceServers
          .map((s) => {
                'urls': s.urls,
                if (s.username != null) 'username': s.username,
                if (s.credential != null) 'credential': s.credential,
              })
          .toList(),
      'sdpSemantics': 'unified-plan',
    };
    final pc = await createPeerConnection(config);
    pc.onIceCandidate = (candidate) {
      // Règle 2 : trickle ICE — envoyé dès la découverte, jamais attendu.
      if (candidate.candidate == null) return;
      if (_pc != null && !identical(pc, _pc)) return; // PeerConnection d'un appel précédent
      if (_callId == null) {
        _pendingLocalCandidates.add(candidate);
        return;
      }
      _sendLocalCandidate(candidate);
    };
    pc.onConnectionState = (state) {
      if (_pc != null && !identical(pc, _pc)) return;
      _onPeerConnectionState(state);
    };
    return pc;
  }

  /// L'état RÉEL du média fait foi, au même titre que la signalisation :
  /// `call.ended` n'arrive pas toujours (application du pair tuée, batterie
  /// vide, tunnel). La couche WebRTC, elle, le sait en quelques secondes.
  static void _onPeerConnectionState(RTCPeerConnectionState state) {
    AppLogger.breadcrumb('call_pc_state:$state');
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _recoveryTimer?.cancel();
        _recoveryTimer = null;
        if (!_mediaUp) {
          _mediaUp = true;
          _emitUi();
        }
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // Coupure possiblement passagère (changement de cellule) : on tente
        // de recoller avant d'abandonner — jamais un raccrochage au premier
        // hoquet.
        if (_mediaUp) {
          _mediaUp = false;
          _emitUi();
        }
        _beginMediaRecovery();
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        unawaited(_endBrokenCall('mediaLost'));
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        break; // fermeture volontaire : _cleanup() est déjà passé par là.
      default:
        break;
    }
  }

  static void _beginMediaRecovery() {
    if (_phase != CallPhase.connected || _recoveryTimer != null) return;
    AppLogger.breadcrumb('call_media_recovery_started');
    unawaited(restartIceOnNetworkChange());
    _recoveryTimer = Timer(_mediaRecoveryWindow, () {
      _recoveryTimer = null;
      if (_phase != CallPhase.connected) return;
      if (_pc?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        AppLogger.breadcrumb('call_media_recovered');
        return;
      }
      unawaited(_endBrokenCall('mediaLost'));
    });
  }

  /// Fin d'appel décidée par le média, pas par la signalisation. On prévient
  /// le serveur (donc le pair).
  static Future<void> _endBrokenCall(String reason) async {
    if (_phase != CallPhase.connected && _phase != CallPhase.outgoingRinging) return;
    AppLogger.breadcrumb('call_media_broken:$reason');
    _lastErrorReason = reason;
    if (_callId != null) {
      RealtimeService.send({'type': 'call.hangup', 'callId': _callId});
    }
    await _cleanup();
  }

  static void _sendLocalCandidate(RTCIceCandidate candidate) {
    if (_callId == null) return;
    RealtimeService.send({
      'type': 'call.candidate',
      'callId': _callId,
      'candidate': {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      },
    });
  }

  static void _flushLocalCandidates() {
    if (_callId == null) return;
    for (final candidate in List<RTCIceCandidate>.from(_pendingLocalCandidates)) {
      _sendLocalCandidate(candidate);
    }
    _pendingLocalCandidates.clear();
  }

  static Future<MediaStream> _openMicrophone() {
    // Audio seul — le contrat §19 exclut explicitement l'appel vidéo.
    return navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
  }

  /// Règle 6 : bascule réseau pendant CONNECTED → renégocier, ne jamais
  /// raccrocher (network_watcher.dart). No-op hors appel connecté.
  static Future<void> restartIceOnNetworkChange() async {
    if (_phase != CallPhase.connected || _pc == null) return;
    // Un SEUL pair émet l'offre de renégociation (évite le « glare »).
    if (!_isCaller) return;
    try {
      final offer = await _pc!.createOffer({'iceRestart': true});
      await _pc!.setLocalDescription(offer);
      RealtimeService.send({'type': 'call.offer', 'callId': _callId, 'sdp': offer.sdp});
      AppLogger.breadcrumb('call_restart_ice');
    } catch (error) {
      AppLogger.error('call_restart_ice_failed', error);
    }
  }

  /// Règle 7 : statistiques après établissement — inspecte la paire de
  /// candidats sélectionnée.
  static bool _statsReported = false;
  static Future<void> reportCallStats() async {
    if (_pc == null || _callId == null) return;
    if (_statsReported) return;
    _statsReported = true;
    try {
      final stats = await _pc!.getStats();
      bool relayed = false;
      String? selectedPairId;
      for (final report in stats) {
        if (report.type == 'transport' && report.values['selectedCandidatePairId'] != null) {
          selectedPairId = report.values['selectedCandidatePairId'] as String?;
        }
      }
      if (selectedPairId != null) {
        for (final report in stats) {
          if (report.id == selectedPairId && report.type == 'candidate-pair') {
            final localId = report.values['localCandidateId'] as String?;
            for (final r2 in stats) {
              if (r2.id == localId && r2.type == 'local-candidate') {
                relayed = r2.values['candidateType'] == 'relay';
              }
            }
          }
        }
      }
      RealtimeService.send({'type': 'call.stats', 'callId': _callId, 'relayed': relayed});
      AppLogger.breadcrumb('call_stats_reported:$relayed');
    } catch (error) {
      // Best-effort : un échec d'inspection des stats ne doit jamais faire
      // échouer l'appel en cours.
      AppLogger.error('call_stats_failed', error);
    }
  }

  /// Mode audio système : écouteur par défaut, le chauffeur active le
  /// haut-parleur explicitement depuis in_call_screen.dart.
  static void _applyCallAudioMode() {
    try {
      Helper.setSpeakerphoneOn(false);
    } catch (error) {
      AppLogger.error('call_audio_mode_failed', error);
    }
  }

  static void setMuted(bool muted) {
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  static void _armRingingSafetyTimer() {
    _ringingSafetyTimer?.cancel();
    // Règle 4 : filet de sécurité si `call.ended` se perd. La marge de 5 s
    // au-dessus du timeout ANNONCÉ PAR LE SERVEUR garantit que le serveur
    // parle toujours en premier — c'est lui qui fait foi.
    _ringingSafetyTimer = Timer(Duration(seconds: _ringTimeoutSeconds + 5), () {
      AppLogger.breadcrumb('call_ringing_safety_timeout');
      if (_phase == CallPhase.incomingRinging) {
        _missed('safetyTimeout');
      } else if (_phase == CallPhase.outgoingRinging) {
        _lastErrorReason = 'timeout';
        unawaited(cancelOutgoing());
      }
    });
  }

  /// Point d'entrée UNIQUE de la transition vers « en communication ».
  /// Idempotent : appelé par le SDP answer (appelant), par
  /// `call.state{connected}` (les deux pairs) et par `acceptCall()` (appelé).
  static void _markConnected() {
    if (_phase == CallPhase.connected) return;
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    _setPhase(CallPhase.connected);
    _applyCallAudioMode();
    _connectedAt = DateTime.now();
    _ringingSafetyTimer?.cancel();
    _ringingSafetyTimer = null;
    final nativeId = _nativeCallId ?? _callId;
    if (nativeId != null) {
      unawaited(CallUiService.markConnected(callId: nativeId, peerName: _peerName ?? 'Collègue'));
    }
    // Règle 7 : statistiques après établissement, indépendamment de l'UI.
    _statsTimer?.cancel();
    _statsTimer = Timer(const Duration(seconds: 2), () => unawaited(reportCallStats()));
  }

  /// Règle 5 — LE point de passage unique de fin d'appel, quel que soit le
  /// motif : coupe l'audio, ferme la PeerConnection, remet l'état à idle.
  /// Ne doit JAMAIS pouvoir laisser un micro ouvert.
  static Future<void> _cleanup() async {
    _accepting = false;
    _answering = false;
    _ringingSafetyTimer?.cancel();
    _ringingSafetyTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _statsReported = false;
    if (_pendingAcceptId != null && _pendingAcceptId == _callId) _forgetPendingAccept();
    _pendingLocalCandidates.clear();
    _pendingRemoteCandidates.clear();
    _remoteDescriptionSet = false;
    // Surfaces natives + service de premier plan micro : fermés ICI et nulle
    // part ailleurs. Une notification d'appel orpheline qui survit au
    // raccrochage est le défaut le plus visible d'une intégration VoIP.
    unawaited(CallUiService.endAll(_nativeCallId ?? _callId));

    // L'ÉTAT BASCULE D'ABORD, la libération native vient APRÈS : l'écran ne
    // doit jamais attendre trois allers-retours natifs pour se fermer.
    final stream = _localStream;
    final pc = _pc;
    _localStream = null;
    _pc = null;
    _callId = null;
    _nativeCallId = null;
    _peerId = null;
    _peerName = null;
    _pendingRemoteSdp = null;
    _connectedAt = null;
    _isCaller = false;
    _mediaUp = false;
    _peerReconnecting = false;
    _setPhase(CallPhase.ended);
    // Repasse à idle juste après avoir notifié `ended` — laisse une frame à
    // l'écran d'appel pour réagir.
    Future.microtask(() => _setPhase(CallPhase.idle));

    await _releaseMedia(stream, pc);
  }

  /// Libération des ressources natives, découplée de la machine à états.
  static Future<void> _releaseMedia(MediaStream? stream, RTCPeerConnection? pc) async {
    try {
      for (final track in stream?.getTracks() ?? <MediaStreamTrack>[]) {
        await track.stop();
      }
      await stream?.dispose();
    } catch (error) {
      AppLogger.error('call_cleanup_stream_failed', error);
    }
    try {
      await pc?.close();
    } catch (error) {
      AppLogger.error('call_cleanup_pc_failed', error);
    }
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
    _readySub?.cancel();
    _readySub = null;
  }
}
