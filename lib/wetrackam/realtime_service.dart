// lib/wetrackam/realtime_service.dart
//
// Lot 6 — service de connexion temps réel (contrat v5 §9-10, PROMPT-MOBILE
// -HONORE.md §3). Singleton : une seule socket pour toute l'app (présence,
// messagerie, signalisation d'appel partagent la même connexion — le
// contrat ne prévoit pas plusieurs sockets simultanées).
//
// Poignée de main manuelle via dart:io HttpClient plutôt que de laisser
// WebSocket.connect() gérer l'upgrade : c'est le seul moyen d'accéder à
// l'en-tête `x-rtc-reason` sur un échec 401 (§9), que l'API haut niveau de
// dart:io ne remonte pas de façon fiable après un upgrade raté.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'app_logger.dart';
import 'api_client.dart';
import 'discovery_service.dart';
import 'driver_identity_service.dart';
import 'state_sync_service.dart';
import 'tls_pinning.dart';

enum RealtimeState { idle, connecting, connected, reconnecting, unavailable }

class RealtimeService {
  RealtimeService._();

  static RealtimeState _state = RealtimeState.idle;
  static WebSocket? _socket;
  static StreamSubscription? _socketSub;
  static StreamSubscription<void>? _rebaseSub;
  static int _reconnectAttempt = 0;
  static Timer? _reconnectTimer;
  static Completer<void>? _readyCompleter;

  /// Chantier B (§8.a) : "sans déconnecter le chauffeur, sans interrompre
  /// le service en cours" — rouvre la socket sur le nouveau rtcWs si elle
  /// était déjà ouverte, sinon ne fait rien (la prochaine ensureConnected()
  /// utilisera de toute façon la nouvelle adresse).
  static void init() {
    _rebaseSub ??= DiscoveryService.onRebase.listen((_) async {
      if (_state == RealtimeState.connected || _state == RealtimeState.connecting) {
        AppLogger.breadcrumb('realtime_rebase_reconnect');
        // Bug évité en vérification : appeler _attemptConnect() directement
        // aurait laissé l'ancienne socket ouverte, orpheline (jamais
        // fermée, son abonnement jamais annulé) — même nettoyage que
        // disconnect(userIntent: false), sans toucher _wantConnected.
        _reconnectTimer?.cancel();
        await _socketSub?.cancel();
        await _socket?.close();
        _socket = null;
        _reconnectAttempt = 0;
        await _attemptConnect();
      }
    });
  }

  /// Intention explicite de connexion (écran carte/annuaire/conversation
  /// ouvert, app au premier plan). Toute reconnexion respecte cette
  /// intention : si l'app passe en arrière-plan, on ne reconnecte pas tout
  /// seul même si le backoff expire.
  static bool _wantConnected = false;

  static final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get messages => _messageController.stream;

  static final _stateController = StreamController<RealtimeState>.broadcast();
  static Stream<RealtimeState> get stateChanges => _stateController.stream;
  static RealtimeState get state => _state;

  static List<String> _capabilities = const [];
  static bool get canChat => _capabilities.contains('chat');
  static bool get canCall => _capabilities.contains('call');

  static void _setState(RealtimeState s) {
    _state = s;
    _stateController.add(s);
  }

  /// À appeler quand un écran ayant besoin du temps réel s'ouvre (carte,
  /// annuaire, conversation) et que l'app est au premier plan.
  static Future<void> ensureConnected() async {
    _wantConnected = true;
    if (_state == RealtimeState.connected) return;
    if (_readyCompleter == null || _readyCompleter!.isCompleted) {
      _readyCompleter = Completer<void>();
    }
    if (_state != RealtimeState.connecting && _state != RealtimeState.reconnecting) {
      _reconnectAttempt = 0;
      unawaited(_attemptConnect());
    }
    try {
      await _readyCompleter!.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const NetworkException();
    }
  }

  /// §3 PROMPT-MOBILE-HONORE : fermer durablement en arrière-plan, le push
  /// prend le relais pour les appels/messages.
  static Future<void> disconnect({bool userIntent = true}) async {
    if (userIntent) _wantConnected = false;
    _reconnectTimer?.cancel();
    await _socketSub?.cancel();
    await _socket?.close();
    _socket = null;
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(const NetworkException());
    }
    _readyCompleter = null;
    _setState(RealtimeState.idle);
  }

  static Future<void> _attemptConnect() async {
    if (!DriverIdentityService.isAuthenticated) return;
    _setState(_reconnectAttempt == 0 ? RealtimeState.connecting : RealtimeState.reconnecting);
    try {
      // §5 : demandé au dernier moment, jamais stocké au-delà de cette
      // fonction — `ticket` ne sort pas de cette portée.
      final ticketResponse = await WetrackamApiClient.requestRtcTicket(mode: 'presence');
      final ticket = ticketResponse['ticket'] as String;
      // Chantier B : endpoints.rtcWs (DiscoveryService) prime désormais
      // sur le wsUrl du ticket — repli conservé pour ne rien casser si la
      // découverte n'a pas encore réussi une seule fois.
      final wsUrl = DiscoveryService.rtcWs ?? ticketResponse['wsUrl'] as String;
      _capabilities = (ticketResponse['capabilities'] as List?)?.cast<String>() ?? const [];

      final socket = await _handshake(wsUrl, ticket);
      _socket = socket;
      _socketSub = socket.listen(_onData, onDone: _onDone, onError: _onError, cancelOnError: false);
      // On attend le message `ready` explicitement plutôt que de considérer
      // la socket connectée dès l'ouverture TCP (§9 : "succès — premier
      // message reçu"). `_onData` bascule l'état en `connected` en le
      // recevant — rien à faire de plus ici.
    } on _HandshakeRejected catch (error) {
      _handleHandshakeRejection(error.reason);
    } on TlsPinningException catch (error) {
      // Le certificat servi n'appartient pas au jeu signé. Se reconnecter
      // en boucle ne peut rien y changer et masquerait l'incident : on
      // s'arrête et on l'annonce, comme pour un incident serveur.
      AppLogger.error('realtime_tls_refused', error.toString());
      _setState(RealtimeState.unavailable);
      _failReadyWaiters();
    } on TlsTrustException catch (error) {
      // Même cause, remontée par la couche API (demande de ticket).
      AppLogger.error('realtime_tls_refused', error.toString());
      _setState(RealtimeState.unavailable);
      _failReadyWaiters();
    } catch (error) {
      AppLogger.error('realtime_connect_failed', error);
      _scheduleReconnect();
    }
  }

  /// Poignée de main manuelle (voir commentaire d'en-tête du fichier).
  /// ARCHITECTURE-VPN-TLS.md §5 / Transport_.txt point 5 : "le canal temps
  /// réel utilise wss://... (même certificat, même épinglage)" — client
  /// épinglé, pas un HttpClient nu.
  static Future<WebSocket> _handshake(String wsUrl, String ticket) async {
    final uri = Uri.parse(wsUrl).replace(queryParameters: {'ticket': ticket});
    final client = TlsPinning.pinnedRawHttpClient();
    try {
      final request = await client.openUrl('GET', uri);
      request.headers
        ..set('Connection', 'Upgrade')
        ..set('Upgrade', 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', _generateWebSocketKey());
      final response = await request.close();
      // Barrière B de l'épinglage, appliquée AVANT de détacher la socket :
      // le client brut ne peut pas la poser lui-même, et sur une chaîne
      // TLS valide `badCertificateCallback` n'est jamais appelé — sans
      // cette ligne, le canal temps réel ne serait pas réellement épinglé.
      TlsPinning.verifyPeerCertificate(response.certificate, uri.host);
      if (response.statusCode != HttpStatus.switchingProtocols) {
        final reason = response.headers.value('x-rtc-reason') ?? 'unknown';
        // Vider le corps pour libérer la connexion proprement.
        await response.drain<void>();
        throw _HandshakeRejected(reason);
      }
      // Anomalie corrigée (lint await_only_futures) : WebSocket.fromUpgradedSocket
      // est synchrone (retourne WebSocket, pas Future<WebSocket>) — seul
      // response.detachSocket() ci-dessous est réellement asynchrone.
      final socket = WebSocket.fromUpgradedSocket(
        await response.detachSocket(),
        serverSide: false,
      );
      return socket;
    } finally {
      client.close(force: true);
    }
  }

  static String _generateWebSocketKey() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return base64.encode(bytes);
  }

  static void _handleHandshakeRejection(String reason) {
    AppLogger.breadcrumb('realtime_handshake_rejected:$reason');
    switch (reason) {
      case 'ticketExpired':
      case 'ticketNotYetValid':
        // §3 : redemander un ticket immédiatement (nouvelle tentative,
        // pas de délai artificiel pour ce cas précis).
        _scheduleReconnect(immediate: true);
      case 'ticketReplayed':
        // §3 PROMPT-MOBILE-HONORE : "Bug de ton code : tu as réutilisé un
        // ticket." Ne devrait jamais arriver avec cette implémentation
        // (chaque tentative redemande son propre ticket) — journalisé
        // comme anomalie plutôt que rejoué en boucle.
        AppLogger.error('realtime_ticket_replayed_bug', reason);
        _setState(RealtimeState.unavailable);
        _failReadyWaiters();
      case 'ticketSignature':
      case 'ticketIncomplete':
      case 'ticketSubject':
        // Incident serveur (secrets désynchronisés, bug serveur) : ne pas
        // boucler indéfiniment sur une cause qui ne se résoudra pas toute
        // seule. Bannière "Communication indisponible", arrêt des tentatives.
        AppLogger.error('realtime_server_incident', reason);
        _setState(RealtimeState.unavailable);
        _failReadyWaiters();
      default:
        _scheduleReconnect();
    }
  }

  static void _failReadyWaiters() {
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(const NetworkException());
    }
  }

  static void _onData(dynamic raw) {
    Map<String, dynamic> message;
    try {
      message = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (error) {
      AppLogger.error('realtime_bad_json_received', error);
      return;
    }
    final type = message['type'] as String?;
    if (type == null) return;

    if (type == 'ready') {
      _reconnectAttempt = 0;
      _setState(RealtimeState.connected);
      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.complete();
      }
      AppLogger.breadcrumb('realtime_ready');
      _capabilities = (message['capabilities'] as List?)?.cast<String>() ?? _capabilities;
      return;
    }
    if (type == 'ping') {
      // §9 : battement de cœur applicatif — répondre au niveau message,
      // distinct du ping/pong au niveau protocole WebSocket (géré par
      // dart:io WebSocket lui-même, aucune action nécessaire ici pour ça).
      send({'type': 'pong'});
      return;
    }
    if (type == 'error') {
      // §9 : "La socket n'est pas fermée sur error. Ne pas déclencher de
      // reconnexion." — on route simplement le message aux écouteurs
      // (chat_service.dart / call_service.dart selon le `reason`).
      AppLogger.breadcrumb('realtime_error_message:${message['reason']}');
      _messageController.add(message);
      return;
    }
    // Type inconnu ou reconnu par un autre service (chat.*, call.*,
    // presence...) : routé aux écouteurs, jamais de plantage sur un type
    // imprévu — le catalogue serveur peut s'enrichir avant une mise à
    // jour de l'app (§3).
    _messageController.add(message);
  }

  static void _onDone() {
    // v6 §3 : "La socket peut être fermée par le serveur avec le code 4001
    // ... c'est volontaire, ne pas reconnecter avant réauthentification."
    // Lu AVANT de vider _socket — l'information n'est plus accessible
    // après (closeCode/closeReason vivent sur l'objet WebSocket lui-même).
    final closeCode = _socket?.closeCode;
    AppLogger.breadcrumb('realtime_socket_closed:code=$closeCode');
    _socket = null;
    // Si la connexion reste désirée, le même appel ensureConnected attend la
    // reconnexion suivante (jusqu'à son timeout) au lieu d'échouer dès une
    // première coupure transitoire.
    if (!_wantConnected) {
      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.completeError(const NetworkException());
      }
      _readyCompleter = null;
    }
    if (closeCode == 4001) {
      // Ne PAS reconnecter tout seul — mais ne pas non plus laisser l'app
      // silencieuse en attendant une action utilisateur fortuite : on
      // force la vérification /state, qui recevra naturellement le 401
      // approprié si la session est bien morte (géré de façon centralisée
      // par api_client.dart, purge + navigation inclus).
      _wantConnected = false;
      _setState(RealtimeState.idle);
      _failReadyWaiters();
      StateSyncService.fetchState();
      return;
    }
    if (_wantConnected) {
      if (_readyCompleter == null || _readyCompleter!.isCompleted) {
        _readyCompleter = Completer<void>();
      }
      _scheduleReconnect();
    } else {
      _setState(RealtimeState.idle);
    }
  }

  static void _onError(Object error) {
    AppLogger.error('realtime_socket_error', error);
    // onDone suit généralement onError sur une socket dart:io ; pas de
    // double planification de reconnexion ici, _onDone s'en charge.
  }

  /// §3 / §9 : backoff exponentiel 1-2-4-8-16s, plafond 30s, dispersion
  /// aléatoire ±20 % pour éviter que toute la flotte ne se reconnecte à la
  /// même seconde après une coupure réseau généralisée.
  static void _scheduleReconnect({bool immediate = false}) {
    if (!_wantConnected) {
      _setState(RealtimeState.idle);
      return;
    }
    _reconnectTimer?.cancel();
    if (immediate) {
      _attemptConnect();
      return;
    }
    _reconnectAttempt++;
    final baseSeconds = min(30, pow(2, _reconnectAttempt - 1).toInt());
    final jitter = (baseSeconds * 0.2 * (Random().nextDouble() * 2 - 1));
    final delay = Duration(milliseconds: ((baseSeconds + jitter) * 1000).round());
    AppLogger.breadcrumb('realtime_reconnect_scheduled:${delay.inSeconds}s');
    _setState(RealtimeState.reconnecting);
    _reconnectTimer = Timer(delay, _attemptConnect);
  }

  /// Envoi générique — utilisé par chat_service.dart et call_service.dart.
  /// Ne fait rien si la socket n'est pas connectée (les appelants gèrent
  /// leur propre file d'attente locale si nécessaire, ex. chat.send hors
  /// ligne — voir chat_service.dart).
  static void send(Map<String, dynamic> message) {
    if (_socket == null || _state != RealtimeState.connected) {
      AppLogger.breadcrumb('realtime_send_dropped_not_connected:${message['type']}');
      return;
    }
    _socket!.add(jsonEncode(message));
  }

  // -----------------------------------------------------------------
  // §10 — présence
  // -----------------------------------------------------------------
  static void queryPresence(List<int> driverIds) {
    if (driverIds.length > 200) {
      throw ArgumentError('200 identifiants maximum par requête (§10).');
    }
    send({'type': 'presence.query', 'driverIds': driverIds});
  }
}

class _HandshakeRejected implements Exception {
  final String reason;
  const _HandshakeRejected(this.reason);
}
