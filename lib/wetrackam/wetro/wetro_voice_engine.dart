import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Ce qu'une session d'écoute rapporte.
class WetroListenResult {
  const WetroListenResult({required this.text, required this.finalResult});

  final String text;
  final bool finalResult;
}

/// Moteur vocal : reconnaissance (dictée du téléphone) et synthèse, derrière
/// une interface étroite pour que le contrôleur reste testable sans micro.
///
/// Ce que ce moteur assume — et ce qu'il ne promet pas :
///  - la reconnaissance est celle du système (Google sur Android, Siri sur
///    iOS) : elle exige une connexion la plupart du temps, s'arrête seule
///    après un silence, et certains Android émettent un bip à chaque
///    ouverture du micro ;
///  - elle ne fonctionne qu'application AU PREMIER PLAN : en arrière-plan,
///    iOS coupe le micro et Android l'interrompt. Le mode « Wetro » à
///    l'oreille est donc actif tant que l'écran de l'application est
///    visible, sur n'importe lequel de ses écrans ;
///  - synthèse et écoute simultanées (pour pouvoir couper Wetro) sont
///    tentées, jamais garanties : si le système refuse, on écoute après.
abstract class WetroVoiceEngine {
  /// Prépare micro et synthèse. Faux si la dictée n'est pas disponible
  /// (permission refusée, aucun moteur, langue absente).
  Future<bool> init();

  bool get available;
  bool get listening;
  bool get speaking;

  /// Ouvre le micro. [onResult] reçoit les transcriptions partielles puis
  /// finale ; [onLevel] l'intensité sonore (pour l'animation) ; [onDone]
  /// est appelé une seule fois quand la session s'est refermée (fin de
  /// parole, délai, erreur), APRÈS le dernier résultat.
  Future<bool> listen({
    required void Function(WetroListenResult result) onResult,
    required void Function(double level) onLevel,
    required void Function() onDone,
    Duration listenFor = const Duration(seconds: 20),
    Duration? pauseFor = const Duration(seconds: 3),
  });

  /// Referme le micro sans attendre de résultat final.
  Future<void> cancelListening();

  /// Referme le micro en laissant venir le résultat final.
  Future<void> stopListening();

  /// Dit un texte. Se résout à la fin de la lecture, ou à son interruption.
  Future<void> speak(String text);

  /// Interrompt la lecture en cours.
  Future<void> stopSpeaking();

  Future<void> dispose();
}

/// Implémentation réelle sur `speech_to_text` + `flutter_tts`.
class WetroDeviceVoiceEngine implements WetroVoiceEngine {
  WetroDeviceVoiceEngine({SpeechToText? speech, FlutterTts? tts})
      : _speech = speech ?? SpeechToText(),
        _tts = tts ?? FlutterTts();

  static const _locale = 'fr_FR';

  final SpeechToText _speech;
  final FlutterTts _tts;

  bool _available = false;
  bool _speaking = false;
  Completer<void>? _speakDone;
  void Function()? _onDone;
  bool _doneNotified = true;
  bool _awaitingStart = false;
  Timer? _startWatchdog;

  @override
  bool get available => _available;

  @override
  bool get listening => _speech.isListening;

  @override
  bool get speaking => _speaking;

  @override
  Future<bool> init() async {
    try {
      _available = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
        finalTimeout: const Duration(milliseconds: 1500),
      );
    } catch (e) {
      debugPrint('[wetro] dictée indisponible : $e');
      _available = false;
    }
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage('fr-FR');
      // 0.5 est la vitesse « normale » d'Android ; iOS lit la même valeur
      // un peu plus vite, ce qui reste naturel pour une réponse courte.
      await _tts.setSpeechRate(Platform.isIOS ? 0.5 : 0.52);
      await _tts.setPitch(1.0);
      if (Platform.isIOS) {
        // Lecture ET micro dans la même session audio : indispensable pour
        // pouvoir couper Wetro à la voix. Sortie sur le haut-parleur, pas
        // sur l'écouteur d'appel.
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playAndRecord,
          [
            IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.duckOthers,
          ],
          IosTextToSpeechAudioMode.voiceChat,
        );
      }
      _tts.setStartHandler(() => _speaking = true);
      _tts.setCompletionHandler(_finSynthese);
      _tts.setCancelHandler(_finSynthese);
      _tts.setErrorHandler((_) => _finSynthese());
    } catch (e) {
      debugPrint('[wetro] synthèse : réglage partiel ($e)');
    }
    return _available;
  }

  void _finSynthese() {
    _speaking = false;
    final c = _speakDone;
    _speakDone = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _onStatus(String status) {
    if (status == SpeechToText.listeningStatus) {
      _awaitingStart = false;
      _startWatchdog?.cancel();
      return;
    }
    // `done` / `notListening` : la session est close. Un seul signal de
    // fin par session, quelle qu'en soit la cause. Les notifications de la
    // session PRÉCÉDENTE (annulée juste avant l'ouverture de celle-ci)
    // arrivent par le même canal, dans l'ordre : tant que la nôtre n'a pas
    // annoncé « listening », une fin ne peut être que la sienne.
    if (status == SpeechToText.doneStatus || status == SpeechToText.notListeningStatus) {
      if (_awaitingStart) return;
      _signaleFin();
    }
  }

  void _onError(SpeechRecognitionError error) {
    debugPrint('[wetro] dictée : ${error.errorMsg} (permanent=${error.permanent})');
    if (error.permanent) _available = false;
    _signaleFin();
  }

  void _signaleFin() {
    if (_doneNotified) return;
    _doneNotified = true;
    _awaitingStart = false;
    _startWatchdog?.cancel();
    final cb = _onDone;
    _onDone = null;
    cb?.call();
  }

  @override
  Future<bool> listen({
    required void Function(WetroListenResult result) onResult,
    required void Function(double level) onLevel,
    required void Function() onDone,
    Duration listenFor = const Duration(seconds: 20),
    Duration? pauseFor = const Duration(seconds: 3),
  }) async {
    if (!_available) return false;
    if (_speech.isListening) {
      await _speech.cancel();
    }
    _onDone = onDone;
    _doneNotified = false;
    _awaitingStart = true;
    _startWatchdog?.cancel();
    // Filet : si « listening » n'arrive jamais (moteur muet), on ne reste
    // pas à attendre une fin qui ne viendra pas.
    _startWatchdog = Timer(const Duration(seconds: 4), () {
      if (_awaitingStart && !_speech.isListening) {
        _awaitingStart = false;
        _signaleFin();
      }
    });
    try {
      await _speech.listen(
        onResult: (SpeechRecognitionResult r) => onResult(
          WetroListenResult(text: r.recognizedWords, finalResult: r.finalResult),
        ),
        onSoundLevelChange: (level) {
          // Android rapporte des décibels (-2..10), iOS une échelle
          // proche (−50..0 puis 0..10 selon versions) : on ramène tout à
          // 0..1 sans prétendre à la précision — c'est pour l'animation.
          final n = ((level + 2) / 12).clamp(0.0, 1.0);
          onLevel(n);
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          autoPunctuation: false,
          enableHapticFeedback: false,
          listenFor: listenFor,
          pauseFor: pauseFor,
          localeId: _locale,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('[wetro] ouverture du micro refusée : $e');
      _signaleFin();
      return false;
    }
  }

  @override
  Future<void> cancelListening() async {
    if (!_speech.isListening) {
      _signaleFin();
      return;
    }
    try {
      await _speech.cancel();
    } catch (_) {
      // rien : le micro était déjà fermé
    }
    _signaleFin();
  }

  @override
  Future<void> stopListening() async {
    if (!_speech.isListening) return;
    try {
      await _speech.stop();
    } catch (_) {
      _signaleFin();
    }
  }

  @override
  Future<void> speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await stopSpeaking();
    final c = Completer<void>();
    _speakDone = c;
    _speaking = true;
    try {
      // `awaitSpeakCompletion(true)` : `speak` ne rend la main qu'à la fin.
      // On double par le completer pour couvrir une annulation.
      await _tts.speak(t);
    } catch (e) {
      debugPrint('[wetro] synthèse en échec : $e');
    } finally {
      _finSynthese();
    }
    if (!c.isCompleted) await c.future;
  }

  @override
  Future<void> stopSpeaking() async {
    if (!_speaking && _speakDone == null) return;
    try {
      await _tts.stop();
    } catch (_) {
      // rien
    }
    _finSynthese();
  }

  @override
  Future<void> dispose() async {
    await stopSpeaking();
    await cancelListening();
  }
}
