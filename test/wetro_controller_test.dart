// Wetro côté chauffeur — machine à états de la conversation et de la voix.
//
// Le test joue le serveur (réponses scriptées), le micro et la synthèse
// (FakeVoice) et l'application (FakeHost). Ce qu'il verrouille : les
// actions passent par l'application et jamais par le modèle ; un SOS n'est
// JAMAIS déclenché sans un « oui » explicite ; la conversation repart quand
// la situation du chauffeur change ; la voix se tait pendant un appel ; un
// « stop » coupe Wetro sans devenir une question ; le mode conduite est
// transmis au serveur.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wetrackam_client/wetrackam/api_client.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_controller.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_dialogue.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_host.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_models.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_service.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_voice_engine.dart';

/// Moteur vocal simulé : le test joue le rôle du micro et de la synthèse.
class FakeVoice implements WetroVoiceEngine {
  bool initOk = true;
  bool _listening = false;
  bool _speaking = false;
  final spoken = <String>[];
  int listens = 0;
  int cancels = 0;
  void Function(WetroListenResult)? _onResult;
  void Function()? _onDone;
  Completer<void>? _speakDone;
  bool holdSpeech = false;

  @override
  bool get available => initOk;
  @override
  bool get listening => _listening;
  @override
  bool get speaking => _speaking;

  @override
  Future<bool> init() async => initOk;

  @override
  Future<bool> listen({
    required void Function(WetroListenResult result) onResult,
    required void Function(double level) onLevel,
    required void Function() onDone,
    Duration listenFor = const Duration(seconds: 20),
    Duration? pauseFor = const Duration(seconds: 3),
  }) async {
    if (!initOk) return false;
    listens++;
    _listening = true;
    _onResult = onResult;
    _onDone = onDone;
    return true;
  }

  void hear(String text, {bool finalResult = true}) {
    _onResult?.call(WetroListenResult(text: text, finalResult: finalResult));
  }

  void endListening() {
    if (!_listening) return;
    _listening = false;
    final cb = _onDone;
    _onDone = null;
    cb?.call();
  }

  @override
  Future<void> cancelListening() async {
    cancels++;
    endListening();
  }

  @override
  Future<void> stopListening() async => endListening();

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    _speaking = true;
    if (holdSpeech) {
      _speakDone = Completer<void>();
      await _speakDone!.future;
    }
    _speaking = false;
  }

  void finishSpeaking() {
    final c = _speakDone;
    _speakDone = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> stopSpeaking() async {
    _speaking = false;
    finishSpeaking();
  }

  @override
  Future<void> dispose() async {}
}

/// L'application simulée : on observe ce que Wetro lui demande.
class FakeHost implements WetroHost {
  final calls = <String>[];
  bool ok = true;
  @override
  bool inCall = false;
  @override
  bool driving = false;

  @override
  Future<bool> callDriver(int driverId, String driverName) async {
    calls.add('call:$driverId');
    return ok;
  }

  @override
  Future<bool> callManager(int participantId, String managerName) async {
    calls.add('manager:$participantId');
    return ok;
  }

  @override
  Future<bool> messageDriver(int driverId, String driverName, String text) async {
    calls.add('message:$driverId:$text');
    return ok;
  }

  @override
  Future<bool> openConversation(int driverId, String driverName) async {
    calls.add('conversation:$driverId');
    return ok;
  }

  @override
  Future<bool> openScreen(String screen) async {
    calls.add('screen:$screen');
    return ok;
  }

  @override
  Future<bool> raiseSos(String kind) async {
    calls.add('sos:$kind');
    return ok;
  }
}

/// Serveur simulé : `/state` puis `/ask`, dont la réponse est scriptée.
class FakeServer implements WetroService {
  Map<String, Object?> etat = {
    'available': true,
    'audience': 'driver',
    'sources': ['ma_situation', 'mes_responsables', 'collegues', 'alerte_sos'],
    'actions': ['call_driver', 'message_driver', 'call_manager', 'open_conversation', 'sos', 'open_screen'],
    'screens': ['home', 'fleet', 'directory', 'sos', 'diagnostics'],
    'epoch': 1,
  };
  Map<String, Object?> Function(String question, bool vocal, bool conduite) reponse =
      (_, _, _) => {'answer': 'Votre véhicule est le camion bleu.', 'epoch': 1};
  int asks = 0;
  bool? dernierVocal;
  bool? derniereConduite;
  int status = 200;

  @override
  Future<WetroState> state() async => WetroState.fromJson(Map<String, dynamic>.from(etat));

  @override
  Future<WetroAnswer> ask(String question,
      {required List<WetroMessage> historique, required bool vocal, required bool conduite}) async {
    asks++;
    dernierVocal = vocal;
    derniereConduite = conduite;
    if (status != 200) {
      throw ApiException(status, 'tooManyRequests', reason: 'quotaExceeded');
    }
    return WetroAnswer.fromJson(Map<String, dynamic>.from(reponse(question, vocal, conduite)));
  }
}

Future<void> pump([int ms = 10]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeServer server;
  late FakeVoice voice;
  late FakeHost host;
  late WetroController c;
  late StreamController<void> appels;

  Future<void> monte({bool wake = false}) async {
    SharedPreferences.setMockInitialValues({'wetro.wake': wake, 'wetro.speak': true});
    server = FakeServer();
    voice = FakeVoice();
    host = FakeHost();
    appels = StreamController<void>.broadcast();
    c = WetroController(service: server, voice: voice, callSignal: appels.stream);
    c.host = host;
    await c.init();
    await pump();
  }

  tearDown(() async {
    c.dispose();
    await appels.close();
  });

  group('état', () {
    test('disponible pour l’audience chauffeur, suggestions dérivées des sources', () async {
      await monte();
      expect(c.available, isTrue);
      expect(c.suggestions, contains('Qui est mon responsable ?'));
      expect(c.suggestions, contains('Appelle mon responsable'));
      expect(c.suggestions, contains('Comment lancer une alerte SOS ?'));
    });

    test('l’audience « tenant » (session web) n’est pas la nôtre : indisponible', () async {
      await monte();
      server.etat = {...server.etat, 'audience': 'tenant'};
      await c.refreshState();
      expect(c.available, isFalse);
    });

    test('indisponible : panneau fermé, voix suspendue', () async {
      await monte(wake: true);
      expect(c.phase, WetroVoicePhase.wake);
      server.etat = {'available': false, 'audience': 'driver', 'epoch': 1};
      await c.refreshState();
      expect(c.available, isFalse);
      expect(c.panelOpen, isFalse);
      expect(c.phase, WetroVoicePhase.idle);
    });

    test('changement de situation (époque) pendant une conversation : fil réinitialisé', () async {
      await monte();
      await c.send('bonjour');
      expect(c.messages.length, 2);
      server.etat = {...server.etat, 'epoch': 2};
      await c.refreshState();
      expect(c.messages, isEmpty);
      expect(c.note, contains('situation'));
    });

    test('session invalide : Wetro s’efface, conversation effacée', () async {
      await monte();
      await c.send('bonjour');
      server.etat = {};
      // Le serveur répond 401 : la purge est centralisée, Wetro s'efface.
      final s = server;
      c.dispose();
      c = WetroController(service: _Rejette(s), voice: voice, callSignal: appels.stream);
      c.host = host;
      await c.init();
      expect(c.available, isFalse);
      expect(c.messages, isEmpty);
    });
  });

  group('question écrite', () {
    test('envoie voice=false et le mode conduite, affiche la réponse, ne lit rien', () async {
      await monte();
      host.driving = true;
      await c.send('Quel est mon véhicule ?');
      expect(server.dernierVocal, false);
      expect(server.derniereConduite, true);
      expect(c.messages.last.content, 'Votre véhicule est le camion bleu.');
      expect(voice.spoken, isEmpty);
    });

    test('action proposée : puce, exécution au geste seulement', () async {
      await monte();
      server.reponse = (_, _, _) => {
            'answer': "J'appelle Jean.",
            'action': {'type': 'call_driver', 'driverId': 12, 'driverName': 'Jean'},
          };
      await c.send('appelle Jean');
      final action = c.messages.last.action;
      expect(action, isNotNull);
      expect(host.calls, isEmpty);
      await c.runAction(action!);
      expect(host.calls, ['call:12']);
      expect(c.panelOpen, isFalse);
    });

    test('appel du responsable : identifiant de participant transmis tel quel', () async {
      await monte();
      server.reponse = (_, _, _) => {
            'answer': "J'appelle Alice Fotso.",
            'action': {'type': 'call_manager', 'managerId': 900000042, 'managerName': 'Alice Fotso'},
          };
      await c.send('appelle mon responsable');
      await c.runAction(c.messages.last.action!);
      expect(host.calls, ['manager:900000042']);
    });

    test('action refusée par le serveur : dite, jamais exécutée', () async {
      await monte();
      server.reponse = (_, _, _) => {'answer': "J'appelle Paul.", 'actionRefused': true};
      await c.send('appelle Paul');
      expect(c.messages.last.action, isNull);
      expect(c.messages.last.actionRefused, isTrue);
      expect(host.calls, isEmpty);
    });

    test('type d’action inconnu : ignoré', () async {
      await monte();
      server.reponse = (_, _, _) => {
            'answer': 'Je termine votre service.',
            'action': {'type': 'end_shift'},
          };
      await c.send('termine mon service');
      expect(c.messages.last.action, isNull);
    });

    test('erreur serveur (quota) : message humain, pas de lecture', () async {
      await monte();
      server.status = 429;
      await c.send('bonjour');
      expect(c.error, contains('quota'));
      expect(c.messages.length, 1);
    });
  });

  group('SOS : jamais sans confirmation', () {
    Map<String, Object?> sos(String _, bool _, bool _) => {
          'answer': 'Je déclenche une alerte accident pour vous.',
          'action': {'type': 'sos', 'kind': 'accident', 'needsConfirmation': true},
        };

    test('puce : le SOS n’est pas déclenché par la réponse elle-même', () async {
      await monte();
      server.reponse = sos;
      await c.send('j’ai eu un accident');
      expect(c.messages.last.action!.needsConfirmation, isTrue);
      expect(host.calls, isEmpty);
      await c.runAction(c.messages.last.action!);
      expect(host.calls, ['sos:accident']);
      expect(c.messages.last.content, contains('Alerte envoyée'));
    });

    test('même si le serveur oubliait la confirmation, l’application l’exige', () async {
      await monte();
      server.reponse = (_, _, _) => {
            'answer': 'Alerte.',
            'action': {'type': 'sos', 'kind': 'sos', 'needsConfirmation': false},
          };
      await c.send('sos');
      expect(c.messages.last.action!.needsConfirmation, isTrue);
    });

    test('voix : « oui » déclenche, phrase de sécurité lue', () async {
      await monte();
      server.reponse = sos;
      await c.startVoice();
      voice.hear('j’ai eu un accident');
      await pump(50);
      expect(c.phase, WetroVoicePhase.confirming);
      expect(voice.spoken.last, contains('Je confirme ?'));
      expect(host.calls, isEmpty);
      voice.hear('oui');
      await pump(50);
      expect(host.calls, ['sos:accident']);
      expect(voice.spoken.last, contains('Restez en sécurité'));
    });

    test('voix : « non » annule, rien ne part', () async {
      await monte();
      server.reponse = sos;
      await c.startVoice();
      voice.hear('sos');
      await pump(50);
      voice.hear('non');
      await pump(50);
      expect(host.calls, isEmpty);
      expect(voice.spoken.last, contains('annule'));
    });

    test('voix : silence, rien ne part', () async {
      await monte();
      server.reponse = sos;
      await c.startVoice();
      voice.hear('sos');
      await pump(50);
      voice.endListening();
      await pump(50);
      expect(host.calls, isEmpty);
    });

    test('voix : deux réponses incompréhensibles, annulé', () async {
      await monte();
      server.reponse = sos;
      await c.startVoice();
      voice.hear('sos');
      await pump(50);
      voice.hear('le camion bleu');
      await pump(50);
      expect(c.phase, WetroVoicePhase.confirming);
      voice.hear('euh');
      await pump(50);
      expect(host.calls, isEmpty);
      expect(c.phase, WetroVoicePhase.idle);
    });

    test('l’alerte qui ne part pas est dite honnêtement', () async {
      await monte();
      server.reponse = sos;
      host.ok = false;
      await c.send('sos');
      await c.runAction(c.messages.last.action!);
      expect(c.messages.last.content, contains('n’est pas partie'));
    });
  });

  group('voix', () {
    test('commande dictée : envoyée avec voice=true, réponse lue, relance', () async {
      await monte();
      await c.startVoice();
      expect(c.phase, WetroVoicePhase.attentive);
      voice.hear('quel est mon', finalResult: false);
      expect(c.partial, 'quel est mon');
      voice.hear('quel est mon véhicule');
      await pump(50);
      expect(server.dernierVocal, true);
      expect(voice.spoken, ['Votre véhicule est le camion bleu.']);
      expect(c.phase, WetroVoicePhase.attentive, reason: 'fenêtre de relance');
    });

    test('mot d’éveil : « Wetro, appelle Jean » sous ses prononciations', () async {
      await monte(wake: true);
      server.reponse = (_, _, _) => {
            'answer': "J'appelle Jean.",
            'action': {'type': 'call_driver', 'driverId': 12, 'driverName': 'Jean'},
          };
      expect(c.phase, WetroVoicePhase.wake);
      voice.hear('le camion bleu');
      expect(c.phase, WetroVoicePhase.wake, reason: 'sans le mot d’éveil, rien ne bouge');
      voice.hear('witro appelle jean');
      await pump(50);
      expect(server.asks, 1);
      expect(host.calls, ['call:12']);
    });

    test('« Wetro » seul : « Oui ? » puis écoute', () async {
      await monte(wake: true);
      voice.hear('wétro');
      await pump(50);
      expect(voice.spoken, ['Oui ?']);
      expect(c.phase, WetroVoicePhase.attentive);
      expect(server.asks, 0);
    });

    test('interruption pendant la lecture : Wetro se tait, la suite est la commande', () async {
      await monte();
      voice.holdSpeech = true;
      await c.startVoice();
      voice.hear('quel est mon véhicule');
      await pump(50);
      expect(c.phase, WetroVoicePhase.speaking);
      voice.hear('votre véhicule est le camion', finalResult: false);
      expect(c.phase, WetroVoicePhase.speaking, reason: 'écho ignoré');
      voice.hear('attends appelle plutôt jean', finalResult: false);
      await pump(50);
      expect(c.phase, WetroVoicePhase.attentive);
      voice.hear('attends appelle plutôt jean');
      await pump(50);
      expect(server.asks, 2);
    });

    test('« stop » seul pendant la lecture : Wetro se tait, sans question', () async {
      await monte();
      voice.holdSpeech = true;
      await c.startVoice();
      voice.hear('quel est mon véhicule');
      await pump(50);
      voice.hear('stop');
      await pump(50);
      expect(c.phase, WetroVoicePhase.attentive);
      expect(server.asks, 1);
    });

    test('appel entrant : la voix se tait ; fin d’appel : l’éveil reprend', () async {
      await monte(wake: true);
      expect(c.phase, WetroVoicePhase.wake);
      host.inCall = true;
      appels.add(null);
      await pump();
      expect(c.inCall, isTrue);
      expect(c.phase, WetroVoicePhase.idle);
      host.inCall = false;
      appels.add(null);
      await pump();
      expect(c.phase, WetroVoicePhase.wake);
    });

    test('dictée indisponible : éveil refusé, erreur explicite', () async {
      await monte();
      voice.initOk = false;
      await c.setWakeEnabled(true);
      expect(c.wakeEnabled, isFalse);
      expect(c.error, contains('dictée'));
    });

    test('voix coupée pendant que la question voyage : réponse affichée, ni lue ni exécutée', () async {
      await monte();
      final libere = Completer<Map<String, Object?>>();
      server.reponse = (_, _, _) => throw UnimplementedError();
      final s = server;
      c.dispose();
      c = WetroController(service: _Lent(s, libere.future), voice: voice, callSignal: appels.stream);
      c.host = host;
      await c.init();
      await c.startVoice();
      voice.hear('appelle jean');
      await pump(20);
      expect(c.phase, WetroVoicePhase.thinking);
      await c.stopVoice(keepWake: false);
      libere.complete({
        'answer': "J'appelle Jean.",
        'action': {'type': 'call_driver', 'driverId': 12, 'driverName': 'Jean'},
      });
      await pump(50);
      expect(voice.spoken, isEmpty);
      expect(host.calls, isEmpty);
      expect(c.messages.last.action, isNotNull, reason: 'la puce reste disponible au geste');
    });
  });
}

/// Serveur qui rejette toute session (401) : Wetro doit s'effacer.
class _Rejette implements WetroService {
  _Rejette(this.inner);
  final FakeServer inner;
  @override
  Future<WetroState> state() async => throw const SessionInvalidException('tokenExpired');
  @override
  Future<WetroAnswer> ask(String question,
          {required List<WetroMessage> historique, required bool vocal, required bool conduite}) =>
      inner.ask(question, historique: historique, vocal: vocal, conduite: conduite);
}

/// Serveur dont la réponse à `ask` n'arrive que quand le test la libère.
class _Lent implements WetroService {
  _Lent(this.inner, this.reponse);
  final FakeServer inner;
  final Future<Map<String, Object?>> reponse;
  @override
  Future<WetroState> state() => inner.state();
  @override
  Future<WetroAnswer> ask(String question,
      {required List<WetroMessage> historique, required bool vocal, required bool conduite}) async {
    final r = await reponse;
    return WetroAnswer.fromJson(Map<String, dynamic>.from(r));
  }
}
