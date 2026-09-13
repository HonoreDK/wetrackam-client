// lib/wetrackam/chat_service.dart
//
// Lot 7 — messagerie (contrat v5 §11, PROMPT-MOBILE-HONORE.md §6). Tout
// passe par le WebSocket, aucun endpoint HTTP pour le texte.
//
// `clientMessageId` est la pièce maîtresse du mode hors ligne (§6) : généré
// côté app, conservé dans la file locale, ENVOYÉ MÊME SI LA SOCKET EST
// FERMÉE (mis en file, rejoué à la reconnexion). Le serveur répond avec le
// même identifiant, ce qui permet de renvoyer un message sans risque de
// doublon si le réseau tombe entre l'envoi et l'accusé.
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_logger.dart';
import 'realtime_service.dart';
import 'rtc_config_service.dart';

class ChatMessage {
  final String? messageId; // null tant que non confirmé par le serveur
  final String clientMessageId;
  final String? conversationId;
  final int peerId;
  final int? senderId;
  final String kind; // 'text' | 'voice'
  final String? body;
  final Map<String, dynamic>? media;
  final int? durationMs;
  final DateTime createdAt;
  String status; // pending | sent | delivered | read | failed

  ChatMessage({
    this.messageId,
    required this.clientMessageId,
    this.conversationId,
    required this.peerId,
    this.senderId,
    required this.kind,
    this.body,
    this.media,
    this.durationMs,
    required this.createdAt,
    required this.status,
  });

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'clientMessageId': clientMessageId,
        'conversationId': conversationId,
        'peerId': peerId,
        'senderId': senderId,
        'kind': kind,
        'body': body,
        'media': media,
        'durationMs': durationMs,
        'createdAt': createdAt.toIso8601String(),
        'status': status,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        messageId: json['messageId'] as String?,
        clientMessageId: json['clientMessageId'] as String,
        conversationId: json['conversationId']?.toString(),
        peerId: json['peerId'] as int,
        senderId: json['senderId'] as int?,
        kind: json['kind'] as String? ?? 'text',
        body: json['body'] as String?,
        media: json['media'] as Map<String, dynamic>?,
        durationMs: json['durationMs'] as int?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        status: json['status'] as String? ?? 'pending',
      );
}

class ChatService {
  ChatService._();

  static const _pendingQueueKey = 'wetrackam_chat_pending_queue';

  static StreamSubscription<Map<String, dynamic>>? _sub;
  static final _seenMessageIds = <String>{}; // §11.6 dédup backlog/history
  static final _incomingController = StreamController<ChatMessage>.broadcast();
  static Stream<ChatMessage> get incoming => _incomingController.stream;

  static final _ackController = StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get acks => _ackController.stream;

  static final Map<int, DateTime> _lastTypingSentByPeer = {};

  static void init() {
    _sub ??= RealtimeService.messages.listen(_onMessage);
    // §6 : rejouer la file locale à chaque (re)connexion réussie.
    RealtimeService.stateChanges.listen((state) {
      if (state == RealtimeState.connected) _flushPendingQueue();
    });
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  // -----------------------------------------------------------------
  // Envoi — texte
  // -----------------------------------------------------------------
  static Future<ChatMessage> sendText(int peerId, String body) async {
    if (body.isEmpty || body.length > 2000) {
      throw ArgumentError('Message vide ou > 2000 caractères (§11.3).');
    }
    final clientMessageId = const Uuid().v4();
    final message = ChatMessage(
      clientMessageId: clientMessageId,
      peerId: peerId,
      kind: 'text',
      body: body,
      createdAt: DateTime.now(),
      status: 'pending',
    );
    await _enqueuePending(message);
    _trySend(message);
    return message;
  }

  /// Met en file l'annonce d'une note déjà déposée dans le stockage objet.
  /// Elle bénéficie ainsi de la même idempotence et du même rejeu sur ACK
  /// que le texte ; un décrochage juste après le PUT ne perd plus la note.
  static Future<ChatMessage> sendVoice({
    required int peerId,
    required String objectKey,
    required int durationMs,
  }) async {
    final message = ChatMessage(
      clientMessageId: const Uuid().v4(),
      peerId: peerId,
      kind: 'voice',
      media: {'objectKey': objectKey},
      durationMs: durationMs,
      createdAt: DateTime.now(),
      status: 'pending',
    );
    await _enqueuePending(message);
    _trySend(message);
    return message;
  }

  static void _trySend(ChatMessage message) {
    if (RealtimeService.state != RealtimeState.connected) return; // restera en file
    RealtimeService.send({
      'type': 'chat.send',
      'peerId': message.peerId,
      'kind': message.kind,
      if (message.body != null) 'body': message.body,
      if (message.media?['objectKey'] != null) 'objectKey': message.media!['objectKey'],
      if (message.durationMs != null) 'durationMs': message.durationMs,
      'clientMessageId': message.clientMessageId,
    });
  }

  /// §6 checklist : file locale PERSISTANTE (survit à un redémarrage de
  /// l'app), pas seulement en mémoire — SharedPreferences suffit ici, le
  /// volume est faible (messages en attente d'accusé, pas tout l'historique).
  static Future<void> _enqueuePending(ChatMessage message) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_pendingQueueKey) ?? [];
    raw.add(jsonEncode(message.toJson()));
    await prefs.setStringList(_pendingQueueKey, raw);
  }

  static Future<void> _removePending(String clientMessageId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_pendingQueueKey) ?? [];
    raw.removeWhere((entry) =>
        (jsonDecode(entry) as Map<String, dynamic>)['clientMessageId'] == clientMessageId);
    await prefs.setStringList(_pendingQueueKey, raw);
  }

  static Future<void> _flushPendingQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_pendingQueueKey) ?? [];
    for (final entry in raw) {
      final message = ChatMessage.fromJson(jsonDecode(entry) as Map<String, dynamic>);
      if (message.status == 'pending') {
        AppLogger.breadcrumb('chat_replay_pending:${message.clientMessageId}');
        _trySend(message);
      }
    }
  }

  /// Purge sur logout — aucun message en attente ne doit survivre à une
  /// déconnexion (§16 isolation, cohérent avec la purge des autres caches).
  static Future<void> purgePendingQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingQueueKey);
    _seenMessageIds.clear();
    _lastTypingSentByPeer.clear();
  }

  // -----------------------------------------------------------------
  // Lecture, saisie
  // -----------------------------------------------------------------
  static void markRead(String conversationId, int peerId) {
    RealtimeService.send({'type': 'chat.read', 'conversationId': conversationId, 'peerId': peerId});
  }

  /// §11.7 : throttle à 1 émission/s — compte dans la limite de 60 msg/min.
  static void sendTyping(int peerId, bool typing) {
    final now = DateTime.now();
    final previous = _lastTypingSentByPeer[peerId];
    if (previous != null && now.difference(previous) < const Duration(seconds: 1)) {
      return;
    }
    _lastTypingSentByPeer[peerId] = now;
    RealtimeService.send({'type': 'chat.typing', 'peerId': peerId, 'typing': typing});
  }

  static void requestConversationList() => RealtimeService.send({'type': 'chat.list'});

  static void requestHistory(String conversationId, {int limit = 50}) {
    RealtimeService.send({
      'type': 'chat.history',
      'conversationId': conversationId,
      'limit': limit > 200 ? 200 : limit, // §11.2 : plafonné serveur, on borne aussi ici
    });
  }

  // -----------------------------------------------------------------
  // Réception
  // -----------------------------------------------------------------
  static void _onMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    switch (type) {
      case 'chat.ack':
        _onAck(message);
      case 'chat.message':
        _onIncoming(message);
      case 'chat.backlog':
        final list = (message['messages'] as List?) ?? [];
        for (final item in list) {
          _onIncoming(item as Map<String, dynamic>, fromBacklog: true);
        }
      case 'chat.messages':
        final list = (message['messages'] as List?) ?? [];
        for (final item in list) {
          _onIncoming(item as Map<String, dynamic>, fromBacklog: true);
        }
      case 'error':
        final reason = message['reason'] as String?;
        if (reason == 'rateLimited') {
          AppLogger.breadcrumb('chat_rate_limited');
          // §9 : la socket reste ouverte. Le refus n'est pas retiré de la
          // file afin qu'il puisse être rejoué après la fenêtre serveur.
        } else {
          final clientMessageId = message['clientMessageId'] as String?;
          if (clientMessageId != null && _isPermanentSendError(reason)) {
            unawaited(_removePending(clientMessageId));
            _ackController.add({
              'clientMessageId': clientMessageId,
              'status': 'failed',
              'reason': reason,
            });
          }
        }
    }
  }

  static bool _isPermanentSendError(String? reason) => const {
        'chatDisabled',
        'emptyMessage',
        'peerInvalid',
        'peerCrossTenant',
        'peerUnavailable',
        'mediaDisabled',
        'mediaMimeUnsupported',
        'mediaTooLong',
        'mediaTooLarge',
        'mediaMissing',
      }.contains(reason);

  static void _onAck(Map<String, dynamic> message) {
    final clientMessageId = message['clientMessageId'] as String?;
    final status = message['status'] as String?;
    if (clientMessageId != null && status == 'sent') {
      // Le serveur a enregistré le message : il n'a plus besoin d'être
      // rejoué à la prochaine reconnexion.
      unawaited(_removePending(clientMessageId));
    }
    _ackController.add(message);
  }

  static void _onIncoming(Map<String, dynamic> message, {bool fromBacklog = false}) {
    final messageId = message['messageId'] as String?;
    // §11.6 : dédup — un message peut apparaître à la fois dans le
    // backlog et dans un chat.history demandé juste après.
    if (messageId != null) {
      if (_seenMessageIds.contains(messageId)) return;
      _seenMessageIds.add(messageId);
    }
    _incomingController.add(ChatMessage(
      messageId: messageId,
      clientMessageId: message['clientMessageId'] as String? ?? '',
      conversationId: message['conversationId']?.toString(),
      peerId: (message['recipientId'] as int?) ??
          (message['senderId'] as int?) ?? 0,
      senderId: message['senderId'] as int?,
      kind: message['kind'] as String? ?? 'text',
      body: message['body'] as String?,
      media: message['media'] as Map<String, dynamic>?,
      durationMs: message['durationMs'] as int?,
      createdAt: message['createdAt'] != null
          ? DateTime.parse(message['createdAt'] as String)
          : DateTime.now(),
      status: fromBacklog ? 'delivered' : 'delivered',
    ));
  }

  /// Note vocale — durée maximale imposée par la politique du tenant
  /// (§4 v5, RtcConfigService.current.policy.voiceMaxSeconds), pas une
  /// valeur inventée côté app.
  static int get voiceMaxSeconds => RtcConfigService.current.policy.voiceMaxSeconds;
}
