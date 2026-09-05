// lib/wetrackam/call_service.dart
//
// Lot 8 — appels WebRTC (contrat v5 §12-13, PROMPT-MOBILE-HONORE.md §7).
//
// Règles impératives du contrat, toutes appliquées ici :
//  1. iceServers récupérés JUSTE AVANT de créer la RTCPeerConnection
//     (RtcConfigService.refreshIceServersForCall(), jamais le cache du
//     polling général — les identifiants TURN expirent en 120s).
//  2. Trickle ICE obligatoire — chaque candidat envoyé dès sa découverte.
//  3. Un seul appel actif — call.incoming ignoré si déjà en communication.
//  4. Minuteur local de secours à 35s en RINGING (filet si call.ended se perd).
//  5. Sur ENDED quel que soit le motif : audio coupé, PeerConnection
//     fermée, tout nettoyé — jamais de micro qui reste ouvert.
//  6. restartIce() sur bascule réseau pendant CONNECTED, jamais un hangup.
//  7. call.stats{relayed} remonté après établissement.
import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'app_logger.dart';
import 'call_ui_service.dart';
import 'driver_identity_service.dart';
import 'peer_name_cache.dart';
import 'realtime_service.dart';
import 'rtc_config_service.dart';

enum CallPhase { idle, outgoingRinging, incomingRinging, connected, ended }

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
  static String? _pendingRemoteSdp; // offre reçue avant call.incoming traité (rare, défensif)
  static RTCPeerConnection? _pc;
  static MediaStream? _localStream;
  static Timer? _ringingSafetyTimer;
  static StreamSubscription<Map<String, dynamic>>? _sub;
  static DateTime? _connectedAt;
  /// Anomalie corrigée : ce champ était renseigné puis jamais relu nulle
  /// part — in_call_screen.dart maintenait son propre chronomètre
  /// indépendant, toujours réinitialisé à zéro dans initState(). Si cet
  /// écran est (re)construit un peu après l'événement `connected` réel
  /// (transition de navigation, ou ré-affichage après un retour au premier
  /// plan pendant un appel déjà connecté), l'affichage sous-comptait la
  /// durée réelle. Exposé ici pour que l'écran puisse s'initialiser sur la
  /// valeur exacte au lieu d'une hypothèse.
  static DateTime? get connectedAt => _connectedAt;
  /// v13 — durée de sonnerie ANNONCÉE PAR LE SERVEUR (`timeoutSeconds` de
  /// `call.incoming`, `ringTimeoutSeconds` du message `ready`). L'ancienne
  /// constante de 35 s codée en dur devenait fausse dès que l'exploitant
  /// changeait `RTC_RING_TIMEOUT_MS` côté serveur : un timeout serveur à
  /// 60 s faisait raccrocher le mobile 25 s trop tôt, appel « qui coupe
  /// tout seul » sans explication.
  static int _ringTimeoutSeconds = 30;
  /// v13 — appel accepté depuis l'écran natif (téléphone verrouillé,
  /// application tuée) AVANT que `call.incoming` ne soit arrivé sur la
  /// socket : l'intention est mémorisée puis rejouée dès réception.
  static bool _externalAcceptPending = false;
  static Timer? _statsTimer;
  static Timer? _externalAcceptTimer;
  static final List<RTCIceCandidate> _pendingLocalCandidates = [];

  /// v15 — candidats ICE DISTANTS reçus avant l'existence de la
  /// PeerConnection. Côté appelé, `call.candidate` arrive dès que
  /// l'appelant découvre ses candidats, c'est-à-dire pendant la sonnerie,
  /// alors que `_pc` n'est créée qu'à l'acceptation : ces candidats étaient
  /// purement et simplement jetés (`if (_pc == null) return;`). Sur un
  /// réseau où seul le relais TURN fonctionne, le candidat relayé est
  /// souvent le premier émis : l'appel décrochait puis restait muet.
  static final List<Map<String, dynamic>> _pendingRemoteCandidates = [];
  static const _maxPendingRemoteCandidates = 60;


  static final _phaseController = StreamController<CallPhase>.broadcast();
  static Stream<CallPhase> get phaseChanges => _phaseController.stream;
  static CallPhase get phase => _phase;
  static int? get peerId => _peerId;
  static String? get peerName => _peerName;

  /// Écran d'appel entrant à afficher — alimenté par `call.incoming`.
  static final _incomingCallController = StreamController<IncomingCallInfo>.broadcast();
  static Stream<IncomingCallInfo> get incomingCalls => _incomingCallController.stream;

  static void init() {
    _sub ??= RealtimeService.messages.listen(_onMessage);
    // v13 : l'écran d'appel natif (Android full-screen / iOS CallKit) est le
    // SEUL moyen de faire sonner un téléphone en poche. Il ne décide de rien :
    // il remonte l'intention ici, la machine à états reste unique.
    unawaited(CallUiService.init(
      onAccept: _onExternalAccept,
      onDecline: _onExternalDecline,
      onEnd: _onExternalDecline,
    ));
  }

  /// v13 — à appeler UNE FOIS au démarrage : reprend un appel accepté sur
  /// l'écran natif alors que l'application était tuée (le système relance
  /// l'app, il faut retrouver l'appel en cours plutôt que d'ouvrir l'accueil).
  static Future<void> resumeExternalAcceptanceAtStartup() async {
    final acceptedId = await CallUiService.consumeExternalAcceptance();
    if (acceptedId == null) return;
    AppLogger.breadcrumb('call_resume_external_acceptance');
    _externalAcceptPending = true;
    _externalAcceptTimer?.cancel();
    _externalAcceptTimer = Timer(const Duration(seconds: 10), () {
      if (_externalAcceptPending) {
        _externalAcceptPending = false;
        unawaited(CallUiService.hide(acceptedId));
      }
    });
    // La socket est indispensable pour envoyer `call.accept` : sans elle,
    // l'acceptation resterait lettre morte et l'appelant sonnerait dans le
    // vide jusqu'au timeout serveur.
    await RealtimeService.ensureConnected();
    // Si `call.incoming` est déjà arrivé entre-temps, on accepte tout de
    // suite ; sinon `_onIncoming` consommera le drapeau.
    if (_phase == CallPhase.incomingRinging) await acceptCall();
  }

  static void _onExternalAccept(String callId) {
    if (_phase == CallPhase.incomingRinging) {
      unawaited(acceptCall());
      return;
    }
    // L'écran natif a devancé la signalisation (push plus rapide que la
    // socket, cas le plus fréquent application tuée) : on mémorise.
    _externalAcceptPending = true;
    _externalAcceptTimer?.cancel();
    _externalAcceptTimer = Timer(const Duration(seconds: 10), () {
      if (_externalAcceptPending) {
        _externalAcceptPending = false;
        unawaited(CallUiService.hide(callId));
      }
    });
    unawaited(RealtimeService.ensureConnected());
  }

  static void _onExternalDecline(String callId) {
    _externalAcceptPending = false;
    if (_phase == CallPhase.incomingRinging) {
      unawaited(declineCall());
    } else if (_phase == CallPhase.connected) {
      unawaited(hangUp());
    } else {
      // Refus d'un appel jamais parvenu sur la socket : rien à signaler au
      // serveur (il n'a pas de callId côté client), on nettoie l'écran natif.
      unawaited(CallUiService.hide(callId));
    }
  }

  static void _setPhase(CallPhase phase) {
    _phase = phase;
    _phaseController.add(phase);
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
    try {
      await RealtimeService.ensureConnected();
      final iceServers = await RtcConfigService.refreshIceServersForCall(); // règle 1
      _pc = await _buildPeerConnection(iceServers);
      _localStream = await _openMicrophone();
      for (final track in _localStream!.getAudioTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }
      final offer = await _pc!.createOffer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 0});
      await _pc!.setLocalDescription(offer);
      // Garde-fou trouvé en audit de cohérence croisée : entre le début de
      // cette méthode (RealtimeService.ensureConnected, ouverture du
      // micro...) et ce point, une purge de session a pu survenir. Sans
      // cette vérification, l'appel basculerait quand même en "sonnerie"
      // avec micro ouvert et PeerConnection créée, pour un `call.invite`
      // silencieusement perdu (socket déjà fermée par la purge) — fuite
      // de ressources jusqu'au minuteur de secours (35s) au lieu d'un
      // nettoyage immédiat.
      if (!DriverIdentityService.isAuthenticated) {
        AppLogger.breadcrumb('call_place_discarded_session_purged_meanwhile');
        await _cleanup();
        return;
      }
      _setPhase(CallPhase.outgoingRinging);
      RealtimeService.send({'type': 'call.invite', 'peerId': peerId, 'sdp': offer.sdp});
      // Android 14+ : sans service de premier plan de type `microphone`, le
      // système coupe la capture dès que l'application quitte l'écran —
      // l'appel devenait muet si le chauffeur verrouillait son téléphone.
      unawaited(CallUiService.startMicService());
      _armRingingSafetyTimer();
      AppLogger.breadcrumb('call_invite_sent');
    } catch (error) {
      AppLogger.error('call_place_failed', error);
      await _cleanup();
    }
  }

  static Future<void> acceptCall() async {
    final remoteSdp = _pendingRemoteSdp;
    if (_phase != CallPhase.incomingRinging || remoteSdp == null || _callId == null) return;
    try {
      final iceServers = await RtcConfigService.refreshIceServersForCall(); // règle 1
      _pc = await _buildPeerConnection(iceServers);
      _localStream = await _openMicrophone();
      for (final track in _localStream!.getAudioTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }
      await _pc!.setRemoteDescription(RTCSessionDescription(remoteSdp, 'offer'));
      await _flushRemoteCandidates();
      final answer = await _pc!.createAnswer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': 0});
      await _pc!.setLocalDescription(answer);
      // Même garde-fou que placeCall() — voir son commentaire pour le
      // raisonnement complet (audit de cohérence croisée).
      if (!DriverIdentityService.isAuthenticated) {
        AppLogger.breadcrumb('call_accept_discarded_session_purged_meanwhile');
        await _cleanup();
        return;
      }
      RealtimeService.send({'type': 'call.accept', 'callId': _callId, 'sdp': answer.sdp});
      // §13 : le CALLEE passe à connected sur son propre call.accept, sans
      // attendre un message serveur supplémentaire.
      _markConnected();
      AppLogger.breadcrumb('call_accepted');
    } catch (error) {
      AppLogger.error('call_accept_failed', error);
      await _cleanup();
    }
  }

  static Future<void> declineCall() async {
    if (_callId != null) RealtimeService.send({'type': 'call.decline', 'callId': _callId});
    await _cleanup();
  }

  static Future<void> cancelOutgoing() async {
    if (_callId != null) RealtimeService.send({'type': 'call.cancel', 'callId': _callId});
    await _cleanup();
  }

  static Future<void> hangUp() async {
    if (_callId != null) RealtimeService.send({'type': 'call.hangup', 'callId': _callId});
    await _cleanup();
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
      case 'error':
        _onError(message);
    }
  }

  /// Bug trouvé en vérification : sans ce cas, un refus serveur en réponse
  /// à `call.invite` (ex. `peerUnavailable`) n'était jamais traité — la
  /// vue "Appel en cours..." serait restée figée jusqu'au minuteur de
  /// secours à 35s, sans jamais dire au chauffeur ce qui s'est passé.
  static String? _lastErrorReason;
  static void _onError(Map<String, dynamic> message) {
    final reason = message['reason'] as String?;
    if (_phase == CallPhase.idle) return; // erreur sans rapport avec un appel en cours (chat, presence...)
    switch (reason) {
      // Motifs qui condamnent l'appel en cours d'établissement. Correctif
      // v13 : `alreadyInCall`, `callUnknown`, `callState`, `peerInvalid` et
      // `rateLimited` manquaient — le serveur les émet bel et bien
      // (server.js callInvite/callAccept) et l'écran restait figé sur
      // « Appel en cours… » jusqu'au minuteur de secours, sans message.
      case 'peerUnavailable':
      case 'peerCrossTenant':
      case 'callsDisabled':
      case 'callUnknown':
      case 'callState':
      case 'peerInvalid':
      case 'alreadyInCall':
        AppLogger.breadcrumb('call_error:$reason');
        _lastErrorReason = reason;
        _cleanup();
      case 'rateLimited':
        // §9 : la socket reste ouverte, mais l'invitation, elle, a bien été
        // refusée — inutile de laisser sonner un appel qui n'existe pas
        // côté serveur. On ne nettoie QUE pendant l'établissement : un
        // rateLimited reçu en pleine conversation concerne le chat, pas
        // l'appel, et ne doit surtout pas raccrocher.
        if (_phase == CallPhase.outgoingRinging) {
          AppLogger.breadcrumb('call_error:$reason');
          _lastErrorReason = reason;
          _cleanup();
        }
      default:
        break;
    }
  }

  /// Consommé une fois par l'écran appelant pour afficher le bon message
  /// (§10 catalogue), puis remis à null — évite qu'un ancien message
  /// d'erreur ne réapparaisse sur un appel suivant sans rapport.
  static String? consumeLastErrorReason() {
    final reason = _lastErrorReason;
    _lastErrorReason = null;
    return reason;
  }

  static void _onCallState(Map<String, dynamic> message) {
    final state = message['state'] as String?;
    if (state == 'busy') {
      AppLogger.breadcrumb('call_busy');
      _cleanup(); // règle 5 : aucun appel n'a été créé côté serveur, on nettoie notre offre locale
      return;
    }
    if (state == 'ringing') {
      _callId = message['callId'] as String?;
      _flushLocalCandidates();
      final timeout = (message['timeoutSeconds'] as num?)?.toInt();
      if (timeout != null && timeout > 0) {
        _ringTimeoutSeconds = timeout;
        _armRingingSafetyTimer();
      }
      return;
    }
    if (state == 'connected') {
      _markConnected();
      return;
    }
    if (state == 'ended') {
      _onEnded(message);
    }
  }

  static void _onIncoming(Map<String, dynamic> message) {
    if (_phase != CallPhase.idle) {
      // Règle 3 : le serveur envoie déjà `busy` à l'appelant dans ce cas —
      // on ignore silencieusement ici, rien à faire côté appelé.
      AppLogger.breadcrumb('call_incoming_ignored_busy');
      return;
    }
    _callId = message['callId'] as String?;
    _peerId = message['peerId'] as int?;
    _pendingRemoteSdp = message['sdp'] as String?;
    final timeout = (message['timeoutSeconds'] as num?)?.toInt();
    if (timeout != null && timeout > 0) _ringTimeoutSeconds = timeout;
    _setPhase(CallPhase.incomingRinging);
    _armRingingSafetyTimer();
    if (_callId != null && _peerId != null && _pendingRemoteSdp != null) {
      _incomingCallController.add(IncomingCallInfo(
          callId: _callId!, peerId: _peerId!, sdp: _pendingRemoteSdp!));
    }
    // v13 : écran d'appel natif. Indispensable quand l'application n'est pas
    // au premier plan — `incomingCalls` ci-dessus n'a d'effet que si l'arbre
    // de widgets est vivant et visible.
    if (_callId != null) {
      final callId = _callId!;
      final peerId = _peerId;
      unawaited(() async {
        if (peerId != null) _peerName = await PeerNameCache.displayName(peerId);
        await CallUiService.rebind(
          realCallId: callId,
          callerName: _peerName ?? 'Collègue',
          ringTimeoutSeconds: _ringTimeoutSeconds,
        );
      }());
    }
    AppLogger.breadcrumb('call_incoming');
    // Acceptation déjà donnée sur l'écran natif avant l'arrivée de la
    // signalisation : on la rejoue maintenant, une seule fois.
    if (_externalAcceptPending) {
      _externalAcceptPending = false;
      _externalAcceptTimer?.cancel();
      _externalAcceptTimer = null;
      unawaited(acceptCall());
    }
  }

  static Future<void> _onAccepted(Map<String, dynamic> message) async {
    final sdp = message['sdp'] as String?;
    if (sdp == null || _pc == null) return;
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      AppLogger.breadcrumb('call_remote_answer_set');
      await _flushRemoteCandidates();
      // CORRECTIF v13 — le bug numéro un de la VoIP : l'appelant restait
      // bloqué sur « Appel en cours… » alors que l'audio passait déjà. Le
      // serveur n'envoyait `call.state {connected}` qu'à l'APPELÉ (corrigé
      // côté serveur au même moment), et le client attendait ce message.
      // On applique désormais la ceinture ET les bretelles : la réception
      // du SDP answer est en soi la preuve que le pair a décroché, et
      // `_markConnected()` est idempotent — recevoir en plus `call.state`
      // ne produit aucun double effet.
      _markConnected();
    } catch (error) {
      AppLogger.error('call_set_remote_answer_failed', error);
    }
  }

  static Future<void> _onRemoteOffer(Map<String, dynamic> message) async {
    // §12.6 : relais transparent — non utilisé dans le flux d'établissement
    // standard (qui passe par call.invite/call.accept ci-dessus), réservé
    // à une éventuelle re-négociation. Géré défensivement, pas testé
    // faute de scénario connu qui l'exercerait dans ce contrat.
    final sdp = message['sdp'] as String?;
    if (sdp == null || _pc == null) return;
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
  }

  static Future<void> _onRemoteAnswer(Map<String, dynamic> message) async {
    final sdp = message['sdp'] as String?;
    if (sdp == null || _pc == null) return;
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  static Future<void> _onRemoteCandidate(Map<String, dynamic> message) async {
    final candidateMap = message['candidate'] as Map<String, dynamic>?;
    if (candidateMap == null) return;
    if (_pc == null) {
      // Sonnerie en cours : on garde le candidat pour l'appliquer dès que
      // la PeerConnection existe (voir _flushRemoteCandidates).
      if (_phase == CallPhase.idle) return; // aucun appel : rien à mémoriser
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
      // Un candidat en retard sur une PeerConnection déjà fermée n'est pas
      // une erreur à faire remonter — l'appel est probablement déjà terminé.
      AppLogger.breadcrumb('call_add_candidate_failed');
    }
  }

  /// v15 — applique les candidats distants mémorisés pendant la sonnerie,
  /// une fois la PeerConnection créée et la description distante posée.
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
    AppLogger.breadcrumb('call_ended:${message['reason']}');
    _cleanup();
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
      if (_callId == null) {
        _pendingLocalCandidates.add(candidate);
        return;
      }
      _sendLocalCandidate(candidate);
    };
    pc.onConnectionState = (state) {
      AppLogger.breadcrumb('call_pc_state:$state');
    };
    return pc;
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
  /// raccrocher. v13 : désormais RÉELLEMENT câblé — network_watcher.dart
  /// observe connectivity_plus et appelle cette méthode (anti-rebond de
  /// 1,2 s). No-op hors appel connecté, donc sans risque d'effet de bord.
  static Future<void> restartIceOnNetworkChange() async {
    if (_phase != CallPhase.connected || _pc == null) return;
    try {
      final offer = await _pc!.createOffer({'iceRestart': true});
      await _pc!.setLocalDescription(offer);
      RealtimeService.send({'type': 'call.offer', 'callId': _callId, 'sdp': offer.sdp});
      AppLogger.breadcrumb('call_restart_ice');
    } catch (error) {
      AppLogger.error('call_restart_ice_failed', error);
    }
  }

  /// Règle 7 : à appeler une fois après établissement (ex. 2s après
  /// `connected`) — inspecte la paire de candidats sélectionnée.
  static bool _statsReported = false;
  static Future<void> reportCallStats() async {
    if (_pc == null || _callId == null) return;
    // in_call_screen.dart programme lui aussi une remontée à T+2s : sans ce
    // garde-fou, le serveur recevrait deux `call.stats` pour un seul appel
    // (et compterait deux fois les appels relayés dans ses métriques TURN).
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
      // Best-effort documenté par le contrat lui-même ("fortement
      // recommandé", pas obligatoire) — un échec d'inspection des stats
      // ne doit jamais faire échouer l'appel en cours.
      AppLogger.error('call_stats_failed', error);
    }
  }

  /// Contrôle micro depuis l'écran d'appel — la MediaStream reste privée
  /// à ce service, on n'expose que l'action, pas l'objet WebRTC lui-même.
  /// Règle 9 : "Mode audio système sur connected : mode communication,
  /// gestion du proximètre, bouton haut-parleur." flutter_webrtc bascule
  /// en mode communication en interne dès qu'une piste audio est active
  /// sur la PeerConnection ; `setSpeakerphoneOn(false)` force le repli sur
  /// l'écouteur (pas le haut-parleur) par défaut, cohérent avec un appel
  /// vocal classique — le chauffeur active le haut-parleur explicitement
  /// depuis in_call_screen.dart s'il le souhaite.
  /// ⚠️ Gestion fine du proximètre (extinction d'écran collé à l'oreille)
  /// non vérifiable sans compilation ni appareil réel dans cet
  /// environnement — dépend du comportement natif de flutter_webrtc sur
  /// la version exacte du SDK, à confirmer en test.
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
      _cleanup();
    });
  }

  /// v13 — point d'entrée UNIQUE de la transition vers « en communication ».
  /// Idempotent par construction : appelé par le SDP answer (appelant), par
  /// `call.state{connected}` (les deux pairs) et par `acceptCall()` (appelé),
  /// il ne doit produire ses effets qu'une seule fois.
  static void _markConnected() {
    if (_phase == CallPhase.connected) return;
    _setPhase(CallPhase.connected);
    _applyCallAudioMode();
    _connectedAt = DateTime.now();
    _ringingSafetyTimer?.cancel();
    _ringingSafetyTimer = null;
    if (_callId != null) unawaited(CallUiService.setConnected(_callId!));
    // Règle 7 : statistiques après établissement. Câblé ici plutôt que dans
    // l'écran d'appel — un appel accepté depuis l'écran natif n'ouvre pas
    // forcément in_call_screen.dart immédiatement, et la remontée
    // `relayed` (diagnostic TURN) ne doit dépendre d'aucune UI.
    _statsTimer?.cancel();
    _statsTimer = Timer(const Duration(seconds: 2), () => unawaited(reportCallStats()));
  }

  /// Règle 5 — LE point de passage unique de fin d'appel, quel que soit le
  /// motif : coupe l'audio, ferme la PeerConnection, remet l'état à idle.
  /// Ne doit JAMAIS pouvoir laisser un micro ouvert.
  static Future<void> _cleanup() async {
    _ringingSafetyTimer?.cancel();
    _ringingSafetyTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _statsReported = false;
    _externalAcceptPending = false;
    _externalAcceptTimer?.cancel();
    _externalAcceptTimer = null;
    _pendingLocalCandidates.clear();
    _pendingRemoteCandidates.clear();
    // Écran d'appel natif + service de premier plan micro : fermés ICI et
    // nulle part ailleurs. Une notification d'appel orpheline qui survit au
    // raccrochage est le défaut le plus visible d'une intégration VoIP.
    unawaited(CallUiService.hide(_callId));
    try {
      for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        await track.stop();
      }
      await _localStream?.dispose();
    } catch (error) {
      AppLogger.error('call_cleanup_stream_failed', error);
    }
    try {
      await _pc?.close();
    } catch (error) {
      AppLogger.error('call_cleanup_pc_failed', error);
    }
    _localStream = null;
    _pc = null;
    _callId = null;
    _peerId = null;
    _peerName = null;
    _pendingRemoteSdp = null;
    _connectedAt = null;
    _setPhase(CallPhase.ended);
    // Repasse à idle juste après avoir notifié `ended` — laisse une frame
    // à l'écran d'appel pour réagir (fermeture) avant que idle ne masque
    // silencieusement l'état sans qu'aucun écran n'ait eu la transition.
    Future.microtask(() => _setPhase(CallPhase.idle));
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
