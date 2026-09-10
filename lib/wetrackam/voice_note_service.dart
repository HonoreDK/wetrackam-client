// lib/wetrackam/voice_note_service.dart
//
// Lot 7 — notes vocales (contrat v5 §11.3, NOTES-VOCALES-STOCKAGE.md,
// PROMPT-MOBILE-HONORE.md §6). Trois temps OBLIGATOIRES, dans cet ordre,
// jamais parallélisés :
//   1. media.upload.intent (WebSocket) → objectKey + uploadUrl
//   2. PUT uploadUrl (HTTP brut, AUCUN en-tête d'authentification — la
//      signature est dans l'URL elle-même)
//   3. chat.send kind:"voice" avec l'objectKey reçu (jamais fabriqué)
//
// Le fichier ne passe JAMAIS par Traccar ni par la socket : seules les
// métadonnées transitent par le WebSocket.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_logger.dart';
import 'chat_service.dart';
import 'realtime_service.dart';
import 'tls_pinning.dart';

class VoiceNoteException implements Exception {
  final String reason; // reprend le vocabulaire du catalogue d'erreurs §11.3
  const VoiceNoteException(this.reason);
}

class VoiceNoteService {
  VoiceNoteService._();

  static StreamSubscription<Map<String, dynamic>>? _sub;
  static final _pendingRequests = <String, Completer<Map<String, dynamic>>>{};
  static final _recorder = AudioRecorder();
  static final _player = AudioPlayer();
  // ARCHITECTURE-VPN-TLS.md §5 : les notes vocales transitent par
  // https://<domaine>/media (MinIO derrière le même proxy TLS) — bug
  // trouvé en audit : http.put()/http.get() globaux créaient un client
  // éphémère et NON épinglé à chaque appel, contournant totalement la
  // protection pour ce flux précis.
  static final http.Client _mediaClient = TlsPinning.pinnedHttpClient();
  static String? _recordingPath;
  static DateTime? _recordingStartedAt;
  static StreamSubscription<RealtimeState>? _stateSub;
  static bool _flushing = false;

  /// Clé SharedPreferences de la file de reprise (même approche que
  /// ChatService : la file doit survivre à la fermeture de l'application,
  /// un chauffeur en zone blanche coupe souvent l'app avant de rouler).
  static const _pendingQueueKey = 'wetrackam_voice_pending_queue';

  /// Dernières limites annoncées par le serveur (media.js §limits, renvoyées
  /// dans `media.upload.intent`). Nulles au premier envoi de la session :
  /// on applique alors le repli conservateur ci-dessous.
  static Map<String, dynamic>? _serverLimits;

  /// Repli UNIQUEMENT tant que le serveur n'a rien annoncé. L'ancien code
  /// codait 2 Mio en dur définitivement : si l'exploitant relevait la limite
  /// serveur, le client continuait de refuser les notes — et s'il la
  /// baissait, le client laissait partir un upload rejeté après coup.
  static const _fallbackMaxBytes = 2 * 1024 * 1024;

  static void init() {
    _sub ??= RealtimeService.messages.listen(_onMessage);
    // Reprise : dès que la socket revient, on rejoue les notes en attente.
    _stateSub ??= RealtimeService.stateChanges.listen((state) {
      if (state == RealtimeState.connected) flushPendingQueue();
    });
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
    _stateSub?.cancel();
    _stateSub = null;
  }

  static void _onMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    final requestId = message['requestId'] as String?;
    if (requestId == null) return;

    // CORRECTIF v13 — le serveur répond aux intentions invalides par
    // `fail(ws, reason, { requestId })`, donc par un message `type:"error"`,
    // JAMAIS par `media.*.intent`. L'ancien code ne regardait que les
    // réponses heureuses : un refus serveur (quota horaire, mime refusé,
    // pair hors tenant) laissait le Completer pendant jusqu'au timeout de
    // 10 s, puis remontait un faux « stockage indisponible ». L'utilisateur
    // voyait une erreur générique 10 s après coup au lieu du vrai motif.
    if (type == 'error') {
      final completer = _pendingRequests.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(
            VoiceNoteException(message['reason'] as String? ?? 'mediaUnavailable'));
      }
      return;
    }

    if (type != 'media.upload.intent' && type != 'media.play.intent') return;
    if (type == 'media.upload.intent') {
      // media.js renvoie `...limits()` À PLAT dans la réponse (maxBytes,
      // maxDurationSeconds, acceptedMimeTypes, maxPerHour…), pas dans un
      // sous-objet `limits` : on lit donc les champs racine.
      _serverLimits = {
        for (final key in const [
          'maxBytes',
          'maxDurationSeconds',
          'uploadTtlSeconds',
          'playbackTtlSeconds',
          'acceptedMimeTypes',
          'maxPerHour',
        ])
          if (message[key] != null) key: message[key],
      };
    }
    final completer = _pendingRequests.remove(requestId);
    if (completer != null && !completer.isCompleted) completer.complete(message);
  }

  static Future<Map<String, dynamic>> _requestResponse(
    Map<String, dynamic> request, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final requestId = request['requestId'] as String;
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[requestId] = completer;
    RealtimeService.send(request);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pendingRequests.remove(requestId);
      throw const VoiceNoteException('mediaStorageUnavailable');
    }
  }

  static int get _maxBytes {
    final value = _serverLimits?['maxBytes'];
    return value is num && value > 0 ? value.toInt() : _fallbackMaxBytes;
  }

  /// Durée maximale effective : la plus CONTRAIGNANTE des deux sources
  /// (politique du tenant côté Traccar, limite technique du service média).
  /// Prendre la plus petite évite un upload qui part puis se fait rejeter.
  static int effectiveMaxSeconds(int policyMaxSeconds) {
    final value = _serverLimits?['maxDurationSeconds'];
    if (value is num && value > 0 && value < policyMaxSeconds) return value.toInt();
    return policyMaxSeconds;
  }

  // -----------------------------------------------------------------
  // Enregistrement
  // -----------------------------------------------------------------
  static Future<bool> hasMicrophonePermission() => _recorder.hasPermission();

  static Future<void> startRecording() async {
    if (!await hasMicrophonePermission()) {
      throw const VoiceNoteException('microphonePermissionDenied');
    }
    final dir = await getTemporaryDirectory();
    _recordingPath = '${dir.path}/voice_${const Uuid().v4()}.m4a';
    _recordingStartedAt = DateTime.now();
    // audio/mp4 (.m4a) — format recommandé Android/iOS par le contrat §11.3.
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1, bitRate: 32000),
      path: _recordingPath!,
    );
  }

  /// Retourne le chemin local du fichier et sa durée, ou `null` si annulé
  /// (durée nulle, appui trop bref).
  static Future<(String path, int durationMs)?> stopRecording() async {
    final path = await _recorder.stop();
    final startedAt = _recordingStartedAt;
    _recordingStartedAt = null;
    if (path == null || startedAt == null) return null;
    final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
    if (durationMs < 500) return null; // appui trop bref, pas un message
    return (path, durationMs);
  }

  static Future<void> cancelRecording() async {
    await _recorder.cancel();
    _recordingStartedAt = null;
  }

  // -----------------------------------------------------------------
  // Envoi (les 3 temps du §11.3)
  // -----------------------------------------------------------------
  static Future<ChatMessage> sendRecording({
    required int peerId,
    required String path,
    required int durationMs,
    required int voiceMaxSeconds,
    bool queueOnFailure = true,
  }) async {
    // §4 v5 : borné par la politique du tenant ET par la limite technique
    // du service média — bloquer AVANT l'envoi, pas après.
    if (durationMs > effectiveMaxSeconds(voiceMaxSeconds) * 1000) {
      throw const VoiceNoteException('mediaTooLong');
    }
    final file = File(path);
    if (!await file.exists()) {
      // Le fichier temporaire a été purgé par le système (nettoyage du
      // cache Android) : inutile de tenter l'envoi ou de le remettre en
      // file, il ne réapparaîtra jamais.
      throw const VoiceNoteException('mediaMissingLocalFile');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxBytes) {
      throw const VoiceNoteException('mediaTooLarge');
    }

    try {
      // Temps 1 — intention d'upload.
      final requestId = const Uuid().v4();
      final intent = await _requestResponse({
        'type': 'media.upload.intent',
        'peerId': peerId,
        'mime': 'audio/mp4',
        'bytes': bytes.length,
        'durationMs': durationMs,
        'requestId': requestId,
      });
      final objectKey = intent['objectKey'] as String;
      final uploadUrl = intent['uploadUrl'] as String;
      final contentType =
          (intent['headers'] as Map?)?['Content-Type'] as String? ?? 'audio/mp4';

      // Re-vérification APRÈS l'intention : c'est seulement là que le
      // serveur annonce ses limites réelles. Si elles sont plus strictes que
      // ce qu'on croyait, on abandonne ici plutôt que de pousser vers le
      // stockage un objet qui sera refusé au chat.send.
      if (bytes.length > _maxBytes) {
        throw const VoiceNoteException('mediaTooLarge');
      }
      final accepted = _serverLimits?['acceptedMimeTypes'];
      if (accepted is List && accepted.isNotEmpty && !accepted.contains(contentType)) {
        throw const VoiceNoteException('mediaMimeRejected');
      }

      // Temps 2 — PUT direct vers le stockage objet. Aucun en-tête
      // d'authentification WeTrackam ici : la signature vit dans l'URL
      // elle-même (§11.3). Ne PAS utiliser WetrackamApiClient (il injecte
      // toujours Bearer + X-Driver-Id, ce qui casserait la signature S3).
      final putResponse = await _mediaClient.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': contentType},
        body: bytes,
      );
      if (putResponse.statusCode < 200 || putResponse.statusCode >= 300) {
        AppLogger.error('voice_upload_put_failed', putResponse.statusCode);
        // Un REFUS du stockage (401/403 : signature invalide, droits, URL
        // expirée) n'est pas une coupure réseau : le rejouer produira
        // exactement le même refus, et annoncer « la note partira au retour
        // du signal » serait un mensonge. On le remonte tel quel — c'est
        // précisément ce qui a masqué le bug de signature /media (l'URL
        // signée incluait le préfixe retiré par le proxy).
        if (putResponse.statusCode == 401 || putResponse.statusCode == 403) {
          throw const VoiceNoteException('mediaStorageRejected');
        }
        throw const VoiceNoteException('mediaStorageUnavailable');
      }

      // Temps 3 — chat.send avec l'objectKey REÇU, jamais fabriqué.
      final message = await ChatService.sendVoice(
        peerId: peerId,
        objectKey: objectKey,
        durationMs: durationMs,
      );
      AppLogger.breadcrumb('voice_note_sent');
      // Succès : le brouillon local n'a plus de raison d'être conservé.
      await _dequeue(path);
      unawaited(file.delete().catchError((_) => file));
      return message;
    } on VoiceNoteException catch (error) {
      // Reprise automatique : SEULEMENT pour les échecs transitoires. Une
      // note refusée sur le fond (trop longue, trop lourde, mime refusé,
      // pair hors tenant, quota horaire) rejouerait indéfiniment le même
      // refus et bloquerait la file derrière elle.
      if (queueOnFailure && _isTransient(error.reason)) {
        await _enqueue(peerId: peerId, path: path, durationMs: durationMs);
      } else {
        await _dequeue(path);
      }
      rethrow;
    } catch (error) {
      AppLogger.error('voice_note_send_failed', error);
      if (queueOnFailure) {
        await _enqueue(peerId: peerId, path: path, durationMs: durationMs);
      }
      throw const VoiceNoteException('mediaStorageUnavailable');
    }
  }

  /// Motifs REJOUABLES uniquement. Tout le reste (mediaDisabled,
  /// mediaMimeUnsupported, mediaTooLong, mediaRateLimited, chatDisabled,
  /// peerInvalid, rateLimited…) est un refus de fond : le rejouer produirait
  /// exactement le même refus et bloquerait la file.
  static bool _isTransient(String reason) =>
      reason == 'mediaStorageUnavailable' ||
      reason == 'notConnected' ||
      reason == 'mediaUnavailable';

  // -----------------------------------------------------------------
  // File de reprise persistante (§6 PROMPT-MOBILE-HONORE)
  // -----------------------------------------------------------------
  static Future<void> _enqueue({
    required int peerId,
    required String path,
    required int durationMs,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_pendingQueueKey) ?? [];
    // Idempotence : une même note ne doit jamais figurer deux fois, sinon
    // un réseau instable la ferait partir en double au retour du signal.
    if (raw.any((entry) => (jsonDecode(entry) as Map)['path'] == path)) return;
    if (raw.length >= 20) raw.removeAt(0); // garde-fou mémoire
    raw.add(jsonEncode({
      'peerId': peerId,
      'path': path,
      'durationMs': durationMs,
      'queuedAt': DateTime.now().toUtc().toIso8601String(),
    }));
    await prefs.setStringList(_pendingQueueKey, raw);
    AppLogger.breadcrumb('voice_note_queued');
  }

  static Future<void> _dequeue(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_pendingQueueKey) ?? [];
    if (raw.isEmpty) return;
    raw.removeWhere((entry) => (jsonDecode(entry) as Map)['path'] == path);
    await prefs.setStringList(_pendingQueueKey, raw);
  }

  /// Rejoue les notes en attente. Appelée à la reconnexion de la socket et
  /// au démarrage. Séquentielle par construction : deux uploads simultanés
  /// sur un lien 2G se pénalisent l'un l'autre et déclenchent des timeouts.
  static Future<void> flushPendingQueue() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = prefs.getStringList(_pendingQueueKey) ?? [];
      for (final entry in List<String>.from(entries)) {
        final data = jsonDecode(entry) as Map<String, dynamic>;
        final path = data['path'] as String;
        // Péremption : une note de plus de 24 h n'a plus de valeur
        // opérationnelle pour une flotte et surprendrait son destinataire.
        final queuedAt = DateTime.tryParse(data['queuedAt'] as String? ?? '');
        if (queuedAt != null &&
            DateTime.now().toUtc().difference(queuedAt) > const Duration(hours: 24)) {
          await _dequeue(path);
          unawaited(File(path).delete().catchError((_) => File(path)));
          continue;
        }
        try {
          await sendRecording(
            peerId: data['peerId'] as int,
            path: path,
            durationMs: data['durationMs'] as int,
            voiceMaxSeconds: ChatService.voiceMaxSeconds,
            queueOnFailure: false, // déjà en file : ne pas la ré-empiler
          );
        } on VoiceNoteException catch (error) {
          if (_isTransient(error.reason)) break; // réseau : on réessaiera
          await _dequeue(path); // refus définitif : on ne bloque pas la file
        }
      }
    } finally {
      _flushing = false;
    }
  }

  /// Nombre de notes vocales en attente d'envoi — affiché par l'écran de
  /// conversation pour que le chauffeur sache que rien n'est perdu.
  static Future<int> pendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_pendingQueueKey) ?? []).length;
  }

  /// Purge de compte : aucune note en attente ni aucun média en cache ne doit
  /// être rejoué ou visible après une déconnexion/changement de chauffeur.
  static Future<void> purgeAll() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingQueueKey) ?? const [];
    for (final entry in pending) {
      try {
        final path = (jsonDecode(entry) as Map<String, dynamic>)['path'] as String?;
        if (path != null) await File(path).delete().catchError((_) => File(path));
      } catch (_) {}
    }
    await prefs.remove(_pendingQueueKey);
    final dir = await getApplicationSupportDirectory();
    final cache = Directory('${dir.path}/wetrackam_voice_cache');
    if (await cache.exists()) await cache.delete(recursive: true);
    _serverLimits = null;
    _pendingRequests.clear();
  }

  // -----------------------------------------------------------------
  // Lecture — cache par messageId, jamais l'URL au-delà de son expiration
  // -----------------------------------------------------------------
  static Future<String> _cachedFilePath(String messageId) async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/wetrackam_voice_cache/$messageId.m4a';
  }

  static Future<void> play(String messageId) async {
    final cachedPath = await _cachedFilePath(messageId);
    final cachedFile = File(cachedPath);
    if (await cachedFile.exists()) {
      await _player.setFilePath(cachedPath);
      await _player.play();
      return;
    }

    final requestId = const Uuid().v4();
    final intent = await _requestResponse({
      'type': 'media.play.intent',
      'messageId': messageId,
      'requestId': requestId,
    });
    final url = intent['url'] as String;

    // §6 : "Mets en cache le fichier téléchargé, indexé par messageId" —
    // jamais l'URL, qui expire en 5 minutes.
    final response = await _mediaClient.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw const VoiceNoteException('mediaUnavailable');
    }
    await cachedFile.parent.create(recursive: true);
    await cachedFile.writeAsBytes(response.bodyBytes);

    await _player.setFilePath(cachedPath);
    await _player.play();
  }

  static Future<void> stopPlayback() => _player.stop();
}
