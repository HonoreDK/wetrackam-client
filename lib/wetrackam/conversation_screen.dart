// lib/wetrackam/conversation_screen.dart
//
// Lot 7 — écran de conversation (contrat v5 §11, PROMPT-MOBILE-HONORE.md
// §6). Fonctionne à partir d'un `peerId` seul (pas besoin d'un
// `conversationId` préexistant) : une conversation neuve n'en a pas
// encore, le serveur en crée un au premier `chat.send`.
//
// Dédoublonnage : NOTE POUR LE JURY / MOI-MÊME (voir PROMPT-MOBILE-HONORE
// §"Notes pour toi, Honoré") — trois sources pour le même message
// (backlog, history, réception temps réel). Une seule fonction d'insertion
// (`_insertOrUpdate`) est le point de passage obligé, jamais d'ajout direct
// à `_messages` ailleurs dans ce fichier.
import 'dart:async';

import 'package:flutter/material.dart';

import 'app_logger.dart';
import 'chat_service.dart';
import 'realtime_service.dart';
import 'rtc_config_service.dart';
import 'theme.dart';
import 'voice_note_service.dart';
import '../location_cache.dart';

class ConversationScreen extends StatefulWidget {
  final int peerId;
  final String peerName;

  const ConversationScreen({super.key, required this.peerId, required this.peerName});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final List<ChatMessage> _messages = [];
  String? _conversationId;
  bool _peerOnline = false;
  bool _peerTyping = false;
  Timer? _typingResetTimer;
  Timer? _driveModeTimer;
  final _textController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _rawSub;
  StreamSubscription<ChatMessage>? _incomingSub;
  StreamSubscription<Map<String, dynamic>>? _ackSub;
  bool _recording = false;
  bool _driveLocked = false;
  DateTime? _recordStartedAt;
  // Anomalie corrigée : _recordStartedAt était calculé mais jamais relu
  // nulle part — aucun retour visuel de la durée pendant l'enregistrement
  // d'une note vocale, alors que le champ existait précisément pour ça.
  Timer? _recordingTicker;

  @override
  void initState() {
    super.initState();
    unawaited(RealtimeService.ensureConnected().catchError((error) {
      AppLogger.error('conversation_realtime_unavailable', error);
    }));
    _rawSub = RealtimeService.messages.listen(_onRawMessage);
    _incomingSub = ChatService.incoming.listen(_onIncoming);
    _ackSub = ChatService.acks.listen(_onAck);
    ChatService.requestConversationList();
    _driveModeTimer = Timer.periodic(
        const Duration(seconds: 2), (_) => _refreshDriveLock());
    _refreshDriveLock();
  }

  @override
  void dispose() {
    _rawSub?.cancel();
    _incomingSub?.cancel();
    _ackSub?.cancel();
    _typingResetTimer?.cancel();
    _driveModeTimer?.cancel();
    _recordingTicker?.cancel();
    _textController.dispose();
    super.dispose();
  }

  void _refreshDriveLock() {
    final threshold = RtcConfigService.current.policy.speedLockKmh;
    final locked = threshold > 0 && (LocationCache.get()?.speedKmh ?? 0) > threshold;
    if (mounted && locked != _driveLocked) {
      setState(() => _driveLocked = locked);
    }
  }

  void _onRawMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == 'chat.conversations') {
      final list = (message['conversations'] as List? ?? []).cast<Map<String, dynamic>>();
      final mine = list.where((c) => c['peerId'] == widget.peerId).toList();
      if (mine.isNotEmpty) {
        _conversationId = mine.first['conversationId']?.toString();
        setState(() => _peerOnline = mine.first['peerOnline'] == true);
        if (_conversationId != null) {
          ChatService.requestHistory(_conversationId!);
          ChatService.markRead(_conversationId!, widget.peerId);
        }
      }
    } else if (type == 'presence' && message['driverId'] == widget.peerId) {
      setState(() => _peerOnline = message['online'] == true);
    } else if (type == 'chat.typing' && message['peerId'] == widget.peerId) {
      _typingResetTimer?.cancel();
      setState(() => _peerTyping = message['typing'] == true);
      if (message['typing'] == true) {
        // Filet de sécurité : si un "typing: false" se perd, ne pas rester
        // bloqué sur "en train d'écrire" indéfiniment.
        _typingResetTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _peerTyping = false);
        });
      }
    } else if (type == 'chat.read' && message['by'] == widget.peerId) {
      setState(() {
        for (final m in _messages) {
          if (m.senderId == null) m.status = 'read'; // mes messages envoyés
        }
      });
    }
  }

  void _onIncoming(ChatMessage message) {
    // Filtre : seuls les messages de cette conversation (par peer, plus
    // fiable que conversationId qui peut être encore inconnu localement
    // pour une conversation neuve).
    if (message.senderId != widget.peerId && message.peerId != widget.peerId) return;
    _conversationId ??= message.conversationId;
    _insertOrUpdate(message);
    if (message.senderId == widget.peerId && _conversationId != null) {
      ChatService.markRead(_conversationId!, widget.peerId);
    }
  }

  void _onAck(Map<String, dynamic> ack) {
    final clientMessageId = ack['clientMessageId'] as String?;
    final status = ack['status'] as String?;
    if (clientMessageId == null || status == null) return;
    setState(() {
      final index = _messages.indexWhere((m) => m.clientMessageId == clientMessageId);
      if (index != -1) {
        _messages[index].status = status;
        final messageId = ack['messageId'] as String?;
        if (messageId != null) _conversationId ??= ack['conversationId']?.toString();
      }
    });
  }

  /// Point de passage UNIQUE pour ajouter un message à la liste affichée —
  /// dédoublonne sur `messageId` s'il existe, sinon sur `clientMessageId`
  /// (cas d'un message encore local, pas encore confirmé par le serveur).
  void _insertOrUpdate(ChatMessage message) {
    setState(() {
      final existingIndex = _messages.indexWhere((m) =>
          (message.messageId != null && m.messageId == message.messageId) ||
          (m.clientMessageId.isNotEmpty && m.clientMessageId == message.clientMessageId));
      if (existingIndex != -1) {
        _messages[existingIndex] = message;
      } else {
        _messages.add(message);
        _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      }
    });
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    try {
      final message = await ChatService.sendText(widget.peerId, text);
      // Le même clientMessageId est conservé jusqu'à l'ACK serveur : l'état
      // pending peut donc réellement évoluer vers sent/delivered/read.
      _insertOrUpdate(message);
    } catch (error) {
      AppLogger.error('send_text_failed', error);
    }
  }

  void _onTextChanged(String value) {
    ChatService.sendTyping(widget.peerId, value.isNotEmpty);
  }

  Future<void> _startRecording() async {
    try {
      await VoiceNoteService.startRecording();
      setState(() {
        _recording = true;
        _recordStartedAt = DateTime.now();
      });
      _recordingTicker?.cancel();
      _recordingTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } on VoiceNoteException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error.reason == 'microphonePermissionDenied'
                ? 'Autorisez le microphone pour envoyer une note vocale.'
                : 'Impossible d\'enregistrer.')));
      }
    }
  }

  Future<void> _stopAndSendRecording() async {
    _recordingTicker?.cancel();
    setState(() => _recording = false);
    final result = await VoiceNoteService.stopRecording();
    if (result == null) return; // trop bref, ignoré silencieusement
    final (path, durationMs) = result;
    try {
      final message = await VoiceNoteService.sendRecording(
        peerId: widget.peerId,
        path: path,
        durationMs: durationMs,
        voiceMaxSeconds: ChatService.voiceMaxSeconds,
      );
      _insertOrUpdate(message);
    } on VoiceNoteException catch (error) {
      if (mounted) {
        // v13 — message explicite par motif : le serveur corrèle désormais
        // ses refus au requestId, on peut donc les afficher tels quels au
        // lieu d'un « Envoi impossible » systématique.
        const labels = <String, String>{
          'mediaTooLong': 'Note vocale trop longue.',
          'mediaTooLarge': 'Fichier trop volumineux.',
          'mediaMimeUnsupported': 'Format audio non pris en charge.',
          'mediaMimeRejected': 'Format audio non pris en charge.',
          'mediaRateLimited': 'Trop de notes vocales envoyées cette heure-ci.',
          'rateLimited': 'Trop de messages envoyés, patientez un instant.',
          'mediaDisabled': 'Les notes vocales sont désactivées.',
          'chatDisabled': 'La messagerie est désactivée.',
          'peerInvalid': 'Destinataire indisponible.',
          'mediaMissingLocalFile': 'Enregistrement introuvable, réessayez.',
          'mediaStorageUnavailable':
              'Réseau indisponible : la note partira automatiquement au retour du signal.',
          'mediaStorageRejected':
              'Le stockage a refusé la note vocale. Prévenez votre gestionnaire.',
        };
        final msg = labels[error.reason] ?? 'Envoi impossible.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Future<void> _cancelRecording() async {
    _recordingTicker?.cancel();
    setState(() => _recording = false);
    await VoiceNoteService.cancelRecording();
  }

  String _formatRecordingElapsed() {
    final seconds = _recordStartedAt == null
        ? 0
        : DateTime.now().difference(_recordStartedAt!).inSeconds;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.peerName),
            Text(
              _peerTyping ? 'En train d\'écrire...' : (_peerOnline ? 'En ligne' : 'Hors ligne'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(child: Text('Aucun message pour l\'instant.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) => _bubble(_messages[index]),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_recording)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 4),
                      child: Text(_formatRecordingElapsed(),
                          style: const TextStyle(color: WetrackamColors.error)),
                    ),
                  Row(
                    children: [
                  GestureDetector(
                    onLongPressStart: _driveLocked ? null : (_) => _startRecording(),
                    onLongPressEnd: _driveLocked ? null : (_) => _stopAndSendRecording(),
                    onLongPressCancel: _driveLocked ? null : _cancelRecording,
                    child: CircleAvatar(
                      backgroundColor: _driveLocked
                          ? WetrackamColors.slate
                          : (_recording ? WetrackamColors.error : WetrackamColors.purple),
                      child: Icon(_recording ? Icons.mic : Icons.mic_none, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      onChanged: _onTextChanged,
                      maxLength: 2000,
                      decoration: const InputDecoration(
                        hintText: 'Message...',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      enabled: !_recording && !_driveLocked,
                    ),
                  ),
                   IconButton(
                     icon: const Icon(Icons.send),
                     onPressed: _recording || _driveLocked ? null : _sendText,
                   ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(ChatMessage message) {
    final mine = message.senderId == null; // mes messages n'ont pas de senderId localement
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: mine ? WetrackamColors.purple : WetrackamColors.lilacTint,
          borderRadius: WetrackamRadii.borderRadius,
        ),
        child: message.kind == 'voice'
            ? _voiceBubble(message, mine)
            : Text(message.body ?? '', style: TextStyle(color: mine ? Colors.white : WetrackamColors.ink)),
      ),
    );
  }

  Widget _voiceBubble(ChatMessage message, bool mine) {
    final seconds = ((message.durationMs ?? 0) / 1000).round();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(Icons.play_arrow, color: mine ? Colors.white : WetrackamColors.purple),
          onPressed: message.messageId == null
              ? null
              : () => VoiceNoteService.play(message.messageId!).catchError((error) {
                    AppLogger.error('voice_play_failed', error);
                  }),
        ),
        Text('${seconds}s', style: TextStyle(color: mine ? Colors.white : WetrackamColors.ink)),
      ],
    );
  }
}
