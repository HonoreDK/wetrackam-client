// test/chat_queue_test.dart — file locale du chat (mode hors ligne §6).
//
// Ces tests ne demandent ni serveur ni téléphone : SharedPreferences est
// simulé en mémoire, et la socket est fermée (RealtimeState.idle), donc
// `_trySend` ne part pas. On vérifie exactement ce qui doit survivre à une
// coupure réseau, et ce qui doit disparaître à la déconnexion.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wetrackam_client/wetrackam/chat_service.dart';

const _queueKey = 'wetrackam_chat_pending_queue';

Future<List<Map<String, dynamic>>> _queue() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(_queueKey) ?? const [])
      .map((e) => jsonDecode(e) as Map<String, dynamic>)
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ChatService.purgePendingQueue();
  });

  test('un message envoyé hors réseau est conservé en file', () async {
    final message = await ChatService.sendText(42, 'Je suis au dépôt');
    final queue = await _queue();
    expect(queue, hasLength(1));
    expect(queue.first['clientMessageId'], message.clientMessageId);
    expect(queue.first['peerId'], 42);
    expect(queue.first['status'], 'pending');
    expect(queue.first['kind'], 'text');
  });

  test('chaque envoi porte un identifiant client unique (anti-doublon)', () async {
    final first = await ChatService.sendText(42, 'un');
    final second = await ChatService.sendText(42, 'deux');
    expect(first.clientMessageId, isNot(second.clientMessageId));
    expect(await _queue(), hasLength(2));
  });

  test('une note vocale annoncée suit la même file que le texte', () async {
    await ChatService.sendVoice(peerId: 7, objectKey: 'obj/1.m4a', durationMs: 3200);
    final queue = await _queue();
    expect(queue, hasLength(1));
    expect(queue.first['kind'], 'voice');
    expect(queue.first['media']['objectKey'], 'obj/1.m4a');
    expect(queue.first['durationMs'], 3200);
  });

  test('message vide ou trop long refusé avant la file', () async {
    expect(() => ChatService.sendText(1, ''), throwsArgumentError);
    expect(() => ChatService.sendText(1, 'a' * 2001), throwsArgumentError);
    expect(await _queue(), isEmpty);
  });

  test('déconnexion : la file ne survit pas au changement de chauffeur', () async {
    await ChatService.sendText(42, 'confidentiel');
    expect(await _queue(), hasLength(1));
    await ChatService.purgePendingQueue();
    expect(await _queue(), isEmpty);
  });

  test('sérialisation aller-retour d\'un message', () {
    final now = DateTime.now();
    final message = ChatMessage(
      messageId: 'srv-1',
      clientMessageId: 'cli-1',
      conversationId: 'conv-1',
      peerId: 9,
      senderId: 3,
      kind: 'voice',
      media: const {'objectKey': 'o/1'},
      durationMs: 1500,
      createdAt: now,
      status: 'sent',
    );
    final restored = ChatMessage.fromJson(jsonDecode(jsonEncode(message.toJson())));
    expect(restored.messageId, 'srv-1');
    expect(restored.clientMessageId, 'cli-1');
    expect(restored.peerId, 9);
    expect(restored.kind, 'voice');
    expect(restored.durationMs, 1500);
    expect(restored.status, 'sent');
    expect(restored.createdAt.toIso8601String(), now.toIso8601String());
  });
}
