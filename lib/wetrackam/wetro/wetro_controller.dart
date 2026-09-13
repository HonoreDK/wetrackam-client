import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart' show ApiException, SessionInvalidException;
import '../app_logger.dart';
import 'wake_word.dart';
import 'wetro_dialogue.dart';
import 'wetro_host.dart';
import 'wetro_models.dart';
import 'wetro_service.dart';
import 'wetro_voice_engine.dart';

/// L'assistant Wetro côté CHAUFFEUR : conversation, disponibilité, voix et
/// actions. Une seule instance par session authentifiée (WetroRuntime),
/// détruite à la purge de session (la conversation ne survit jamais à la
/// session — rien n'est persisté hors deux réglages vocaux).
///
/// TOUT ce qui touche aux droits vient du serveur : `state()` dit ce que
/// l'assistant peut consulter et proposer ; chaque réponse à `ask` a été
/// filtrée là-bas ; chaque action a été validée là-bas puis l'est encore
/// par l'application au moment de l'exécuter. Ce contrôleur n'ajoute
/// aucune autorité, il orchestre.
///
/// Port fidèle du contrôleur de l'application manager (mêmes phases, même
/// dialogue, mêmes règles d'interruption) : un chauffeur et un gestionnaire
/// parlent au même Wetro.
class WetroController extends ChangeNotifier with WidgetsBindingObserver {
  WetroController({
    required WetroService service,
    required WetroVoiceEngine voice,
    Stream<void>? callSignal,
  })  : _service = service,
        _voice = voice {
    WidgetsBinding.instance.addObserver(this);
    _callSub = callSignal?.listen((_) => _onCallChanged());
  }

  static const _prefWake = 'wetro.wake';
  static const _prefSpeak = 'wetro.speak';

  /// Délai de silence qui clôt une commande dictée.
  static const _pauseCommande = Duration(milliseconds: 2500);

  /// Fenêtre de relance après une réponse : la personne peut enchaîner sans
  /// redire « Wetro ».
  static const _fenetreRelance = Duration(seconds: 7);

  /// Relecture périodique de l'état (politique de l'espace, disponibilité)
  /// tant que l'application est au premier plan — même cadence que le web.
  static const _rafraichissement = Duration(seconds: 60);

  final WetroService _service;
  final WetroVoiceEngine _voice;
  StreamSubscription<void>? _callSub;
  Timer? _rafraichisseur;

  WetroHost? host;

  // --------------------------------------------------------------- état

  WetroState _state = WetroState.indisponible;
  WetroState get state => _state;
  bool _stateLoaded = false;
  bool get stateLoaded => _stateLoaded;

  /// Dernier échec de lecture de `/api/mobile/wetro/state`, pour l'écran de
  /// diagnostic : « pourquoi le bouton n'est pas là » se lit sur le
  /// téléphone, sans logcat. Vide quand la dernière lecture a réussi.
  String _lastStateError = '';
  String get lastStateError => _lastStateError;
  bool get available => _state.available;

  final List<WetroMessage> _messages = [];
  List<WetroMessage> get messages => List.unmodifiable(_messages);

  bool _busy = false;
  bool get busy => _busy;
  String? _error;
  String? get error => _error;
  String? _avis;
  String? get avis => _avis;
  bool _panelOpen = false;
  bool get panelOpen => _panelOpen;

  /// Note affichée quand la portée a changé pendant la conversation.
  String? _note;
  String? get note => _note;

  int? _epoch;
  bool _disposed = false;

  // ---------------------------------------------------------------- voix

  WetroVoicePhase _phase = WetroVoicePhase.idle;
  WetroVoicePhase get phase => _phase;
  bool get voiceActive => _phase != WetroVoicePhase.idle;

  double _level = 0;
  double get level => _level;
  String _partial = '';
  String get partial => _partial;

  bool _voiceReady = false;
  bool get voiceAvailable => _voiceReady;

  bool _wakeEnabled = false;
  bool get wakeEnabled => _wakeEnabled;
  bool _speakEnabled = true;
  bool get speakEnabled => _speakEnabled;

  bool _resumed = true;
  bool _inCall = false;

  /// Vrai pendant un appel : la surcouche cache le bouton (l'écran d'appel
  /// n'a pas besoin d'un assistant par-dessus) et la voix se tait.
  bool get inCall => _inCall;
  int _session = 0;
  String _spokenText = '';
  WetroAction? _pending;
  WetroAction? get pending => _pending;
  int _unclearCount = 0;
  bool _followUp = false;
  bool _gotFinal = false;

  /// Vrai entre une interruption de la lecture et la commande qui la suit :
  /// le premier mot entendu (« attends », « stop ») n'est pas la commande.
  bool _interrupted = false;
  SharedPreferences? _prefs;

  /// Phrase d'aide sous l'animation vocale.
  String get voiceHint => switch (_phase) {
        WetroVoicePhase.idle => _wakeEnabled ? 'Dites « Wetro » pour m’appeler.' : '',
        WetroVoicePhase.wake => 'J’écoute « Wetro »…',
        WetroVoicePhase.attentive => _partial.isEmpty ? 'Je vous écoute.' : _partial,
        WetroVoicePhase.thinking => 'Je réfléchis…',
        WetroVoicePhase.speaking => 'Parlez pour m’interrompre.',
        WetroVoicePhase.confirming => 'Dites « oui » pour envoyer, « non » pour annuler.',
      };

  // ============================================================ cycle de vie

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _wakeEnabled = _prefs?.getBool(_prefWake) ?? false;
      _speakEnabled = _prefs?.getBool(_prefSpeak) ?? true;
    } catch (_) {
      // réglages non lisibles : valeurs par défaut
    }
    await refreshState();
    _armeRafraichissement();
    if (_wakeEnabled) await _ensureWake();
  }

  void _armeRafraichissement() {
    _rafraichisseur?.cancel();
    _rafraichisseur = Timer.periodic(_rafraichissement, (_) {
      if (!_disposed && _resumed) unawaited(refreshState());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _callSub?.cancel();
    _rafraichisseur?.cancel();
    _session++;
    unawaited(_voice.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` n'est PAS l'arrière-plan : c'est aussi la boîte de
    // permission du micro, le centre de contrôle, un appel entrant. Couper
    // le micro à ce moment-là annulerait la demande de permission qu'on
    // vient de lancer. Seuls `paused`/`hidden`/`detached` suspendent.
    switch (state) {
      case AppLifecycleState.resumed:
        if (_resumed) return;
        _resumed = true;
        // Retour au premier plan : la politique a pu changer pendant
        // l'absence (appels coupés, annuaire réduit) — on relit.
        unawaited(refreshState());
        unawaited(_ensureWake());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (!_resumed) return;
        _resumed = false;
        // Arrière-plan : le système coupe le micro de toute façon ; on
        // ferme proprement pour ne pas croire écouter alors que rien
        // n'entre.
        unawaited(_suspendVoice());
      case AppLifecycleState.inactive:
        return;
    }
  }

  /// L'état du chauffeur a changé côté serveur (affectation, statut, site —
  /// `control` reçu par la socket ou par /state) : on relit l'assistant, il
  /// repartira d'une conversation neuve si l'époque a bougé.
  void onDriverStateChanged() {
    if (!_disposed) unawaited(refreshState());
  }

  void _onCallChanged() {
    final now = host?.inCall ?? false;
    if (now == _inCall) return;
    _inCall = now;
    notifyListeners();
    if (now) {
      unawaited(_suspendVoice());
    } else {
      unawaited(_ensureWake());
    }
  }

  // ================================================================== état

  bool _refreshing = false;

  Future<void> refreshState() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final next = await _service.state();
      if (_disposed) return;
      _lastStateError = '';
      final previous = _epoch;
      _epoch = next.epoch;
      _state = next;
      _stateLoaded = true;
      if (previous != null && previous != next.epoch && _messages.isNotEmpty) {
        // Même règle que le web : une conversation entamée sous une autre
        // situation (autre véhicule, appels coupés…) ne continue pas — le
        // contexte envoyé au modèle en porterait la trace.
        _messages.clear();
        _note = 'Votre situation a changé : nouvelle conversation.';
      }
      if (!next.available) {
        _panelOpen = false;
        await _suspendVoice();
      }
    } on SessionInvalidException {
      // La purge de session est centralisée (api_client) : ici on s'efface.
      if (_disposed) return;
      _stateLoaded = true;
      _lastStateError = 'session invalide';
      _state = WetroState.indisponible;
      _panelOpen = false;
      _messages.clear();
      await _suspendVoice();
    } on ApiException catch (e) {
      if (_disposed) return;
      _stateLoaded = true;
      _lastStateError = 'HTTP ${e.statusCode} ${e.error}${e.reason == null ? '' : ' (${e.reason})'}';
      // Un 503 aiDisabled est un état normal (assistant non activé) ; une
      // erreur réseau passagère ne doit pas faire disparaître le bouton
      // d'un assistant qui était là : on garde le dernier état connu.
      if (e.statusCode == 503 || e.statusCode == 403 || e.statusCode == 404) {
        _state = WetroState.indisponible;
        _panelOpen = false;
        await _suspendVoice();
      }
      AppLogger.breadcrumb('wetro_state_failed:${e.error}');
    } catch (error) {
      if (_disposed) return;
      _stateLoaded = true;
      _lastStateError = error.toString();
      AppLogger.error('wetro_state_failed', error);
    } finally {
      _refreshing = false;
    }
    if (!_disposed) notifyListeners();
  }

  void openPanel() {
    if (!_state.available) return;
    _panelOpen = true;
    _error = null;
    notifyListeners();
    // La politique est relue à l'ouverture : ce que le panneau annonce
    // (sources, appels possibles) est celui de l'instant.
    unawaited(refreshState());
  }

  void closePanel() {
    _panelOpen = false;
    notifyListeners();
  }

  void togglePanel() => _panelOpen ? closePanel() : openPanel();

  // ============================================================ conversation

  /// Amorces proposées tant que la conversation est vide, dérivées des
  /// sources RÉELLEMENT consultables — jamais une question qui finirait
  /// en refus.
  List<String> get suggestions {
    final s = _state.sources;
    return [
      if (s.contains('ma_situation')) 'Quel est mon véhicule aujourd’hui ?',
      if (s.contains('collegues')) 'Qui est en service maintenant ?',
      if (s.contains('mes_responsables')) 'Qui est mon responsable ?',
      if (_state.peutAppelerResponsable) 'Appelle mon responsable',
      if (_state.peutAppeler) 'Appelle un collègue en service',
      'Comment lancer une alerte SOS ?',
    ];
  }

  Future<void> send(String question, {bool vocal = false}) async {
    final q = question.trim();
    if (_disposed) return;
    if (q.isEmpty || _busy || !_state.available) {
      if (!_state.available) _error = wetroMotif('aiDisabled');
      if (vocal) {
        // Commande dictée qui ne peut pas partir : on ne reste pas « en
        // réflexion » ; retour au calme (et à l'éveil s'il est activé).
        _setPhase(WetroVoicePhase.idle);
        notifyListeners();
        await _ensureWake();
        return;
      }
      notifyListeners();
      return;
    }
    _error = null;
    _avis = null;
    _note = null;
    final anterieur = List<WetroMessage>.from(_messages);
    _messages.add(WetroMessage(role: 'user', content: q, vocal: vocal));
    _busy = true;
    if (vocal) _phase = WetroVoicePhase.thinking;
    notifyListeners();
    // Si la personne coupe la voix (« Stop », appel entrant, arrière-plan)
    // pendant que la question voyage, la réponse s'affiche mais ne se lit
    // pas et ne déclenche rien toute seule.
    final jeton = _session;

    WetroAnswer? reponse;
    String? erreur;
    try {
      reponse = await _service.ask(q,
          historique: anterieur, vocal: vocal, conduite: host?.driving ?? false);
    } on ApiException catch (e) {
      erreur = wetroMotif(e.reason ?? e.error);
      if (e.statusCode == 401) {
        _state = WetroState.indisponible;
        _panelOpen = false;
      }
    } catch (error) {
      AppLogger.error('wetro_ask_failed', error);
      erreur = wetroMotif(null);
    }
    if (_disposed) return;
    _busy = false;
    final vocalEncore = vocal && jeton == _session;
    if (vocal && !vocalEncore && _phase == WetroVoicePhase.thinking) {
      _setPhase(WetroVoicePhase.idle);
    }

    if (reponse == null) {
      _error = erreur;
      notifyListeners();
      if (vocalEncore) {
        await _speakThen('Désolé, je n’ai pas pu répondre. ${erreur ?? ''}', relance: false);
      }
      return;
    }

    final epoch = reponse.epoch;
    if (epoch != null) _epoch = epoch;
    _avis = wetroAvis(reponse.notice);
    final action = reponse.action;
    _messages.add(WetroMessage(
      role: 'assistant',
      content: reponse.answer,
      action: action,
      actionRefused: reponse.actionRefused,
      vocal: vocal,
    ));
    notifyListeners();

    if (!vocalEncore) {
      // Question écrite (ou voix coupée entre-temps) : rien n'est lu, et
      // une action se déclenche d'un geste (la puce), jamais seule.
      return;
    }

    if (action == null) {
      await _speakThen(reponse.actionRefused
          ? '${reponse.answer} Mais cette action n’est pas permise dans votre entreprise.'
          : reponse.answer);
      return;
    }

    if (action.needsConfirmation) {
      _pending = action;
      _unclearCount = 0;
      final question = action.type == WetroActionType.sos
          ? '${reponse.answer} Vos responsables seront alertés. Je confirme ?'
          : '${reponse.answer} Je confirme ?';
      await _speakThen(question, confirmation: true);
      return;
    }

    // Appel, fiche, écran : on dit la phrase de confirmation, puis on agit.
    await _speakThen(reponse.answer, relance: false);
    if (_disposed) return;
    await runAction(action);
  }

  /// Exécute une action validée par le serveur, par les voies de
  /// l'application. Retourne vrai si elle est partie.
  Future<bool> runAction(WetroAction action) async {
    final h = host;
    if (h == null) {
      _noteAssistant('Cette action n’est pas disponible sur cet écran.');
      return false;
    }
    _marqueActionFaite(action);
    bool ok;
    try {
      ok = switch (action.type) {
        WetroActionType.openScreen => await h.openScreen(action.screen ?? ''),
        WetroActionType.openConversation =>
          await h.openConversation(action.driverId ?? 0, action.driverName ?? 'ce collègue'),
        WetroActionType.callDriver =>
          await h.callDriver(action.driverId ?? 0, action.driverName ?? 'le collègue'),
        WetroActionType.callManager =>
          await h.callManager(action.managerId ?? 0, action.managerName ?? 'le responsable'),
        WetroActionType.messageDriver => await h.messageDriver(
            action.driverId ?? 0, action.driverName ?? 'le collègue', action.text ?? ''),
        WetroActionType.sos => await h.raiseSos(action.kind ?? 'sos'),
      };
    } catch (e) {
      AppLogger.error('wetro_action_failed:${action.type.name}', e);
      ok = false;
    }
    if (_disposed) return ok;
    switch (action.type) {
      case WetroActionType.openScreen:
      case WetroActionType.openConversation:
      case WetroActionType.callDriver:
      case WetroActionType.callManager:
        if (ok) {
          _panelOpen = false;
        } else {
          _noteAssistant(action.type == WetroActionType.callDriver ||
                  action.type == WetroActionType.callManager
              ? 'Je n’ai pas pu lancer l’appel : service indisponible ou appels coupés.'
              : 'Je n’ai pas pu ouvrir cet écran.');
        }
      case WetroActionType.messageDriver:
        _noteAssistant(ok
            ? 'Message envoyé à ${action.driverName ?? 'ce collègue'}.'
            : 'Le message n’est pas parti : connexion ou messagerie coupée. Réessayez depuis l’annuaire.');
      case WetroActionType.sos:
        if (ok) _panelOpen = false;
        _noteAssistant(ok
            ? 'Alerte envoyée. Vos responsables sont prévenus.'
            : 'L’alerte n’est pas partie : réessayez depuis l’écran SOS.');
    }
    notifyListeners();
    return ok;
  }

  /// La personne a refusé l'action proposée (puce ou voix).
  void declineAction(WetroAction action) {
    _marqueActionFaite(action);
    notifyListeners();
  }

  void _marqueActionFaite(WetroAction action) {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (identical(m.action, action)) {
        _messages[i] = m.copyWith(actionDone: true);
        return;
      }
    }
  }

  void _noteAssistant(String texte) {
    _messages.add(WetroMessage(role: 'assistant', content: texte));
    notifyListeners();
  }

  void clearConversation() {
    _messages.clear();
    _note = null;
    _error = null;
    _avis = null;
    notifyListeners();
  }

  // ================================================================== voix

  Future<bool> _ensureVoice() async {
    if (_voiceReady) return true;
    // Chaque appui retente l'initialisation : la permission micro a pu être
    // accordée depuis le dernier refus.
    _voiceReady = await _voice.init();
    notifyListeners();
    return _voiceReady;
  }

  Future<void> setWakeEnabled(bool on) async {
    _wakeEnabled = on;
    try {
      await _prefs?.setBool(_prefWake, on);
    } catch (_) {
      // réglage non persisté : sans gravité
    }
    notifyListeners();
    if (on) {
      if (!await _ensureVoice()) {
        _wakeEnabled = false;
        _error = 'La dictée n’est pas disponible sur ce téléphone (permission micro ou moteur absent).';
        notifyListeners();
        return;
      }
      await _ensureWake();
    } else if (_phase == WetroVoicePhase.wake) {
      await _suspendVoice();
    }
  }

  Future<void> setSpeakEnabled(bool on) async {
    _speakEnabled = on;
    try {
      await _prefs?.setBool(_prefSpeak, on);
    } catch (_) {
      // rien
    }
    if (!on) await _voice.stopSpeaking();
    notifyListeners();
  }

  /// Appui sur le micro : Wetro écoute une commande tout de suite.
  Future<void> startVoice() async {
    if (_busy) return;
    if (!await _ensureVoice()) {
      _error = 'La dictée n’est pas disponible sur ce téléphone (permission micro ou moteur absent).';
      notifyListeners();
      return;
    }
    await _voice.stopSpeaking();
    _pending = null;
    await _listen(WetroVoicePhase.attentive);
  }

  /// Appui sur « stop » : micro fermé, Wetro se tait. Le mode « Wetro » à
  /// l'oreille reprend de lui-même s'il est activé.
  Future<void> stopVoice({bool keepWake = true}) async {
    _session++;
    _pending = null;
    await _voice.stopSpeaking();
    await _voice.cancelListening();
    _setPhase(WetroVoicePhase.idle);
    if (keepWake) await _ensureWake();
  }

  Future<void> _suspendVoice() async {
    _session++;
    _pending = null;
    await _voice.stopSpeaking();
    await _voice.cancelListening();
    _setPhase(WetroVoicePhase.idle);
  }

  Future<void> _ensureWake() async {
    if (_disposed || !_wakeEnabled || !_resumed || _inCall) return;
    if (!_state.available) return;
    if (_phase != WetroVoicePhase.idle) return;
    if (!await _ensureVoice()) return;
    await _listen(WetroVoicePhase.wake);
  }

  void _setPhase(WetroVoicePhase p) {
    if (_phase == p) return;
    _phase = p;
    if (p == WetroVoicePhase.idle || p == WetroVoicePhase.wake) {
      _partial = '';
      _level = 0;
    }
    notifyListeners();
  }

  /// Ouvre une session d'écoute pour une phase donnée. Chaque session porte
  /// un numéro : les retours d'une session périmée sont ignorés.
  Future<void> _listen(WetroVoicePhase mode, {bool followUp = false}) async {
    if (_disposed) return;
    final id = ++_session;
    _followUp = followUp;
    _gotFinal = false;
    _interrupted = false;
    _partial = '';
    _setPhase(mode);
    final wake = mode == WetroVoicePhase.wake;
    final ok = await _voice.listen(
      listenFor: wake
          ? const Duration(seconds: 55)
          : (followUp ? _fenetreRelance : const Duration(seconds: 20)),
      pauseFor: wake ? null : (followUp ? const Duration(seconds: 2) : _pauseCommande),
      onLevel: (l) {
        if (id != _session) return;
        _level = l;
        notifyListeners();
      },
      onResult: (r) {
        if (id != _session) return;
        unawaited(_onResult(id, r));
      },
      onDone: () {
        if (id != _session) return;
        unawaited(_onListenDone(id));
      },
    );
    if (!ok && id == _session) {
      // Micro refusé : on n'insiste pas en boucle. En mode éveil, on
      // réessaie plus tard ; sinon on rend la main.
      _setPhase(WetroVoicePhase.idle);
      if (wake) {
        Timer(const Duration(seconds: 15), () => unawaited(_ensureWake()));
      } else {
        await _ensureWake();
      }
    }
  }

  Future<void> _onResult(int id, WetroListenResult r) async {
    if (id != _session || _disposed) return;
    final texte = r.text.trim();
    switch (_phase) {
      case WetroVoicePhase.wake:
        final m = WakeWord.detecte(texte);
        if (m == null) return; // pas pour nous : on ne montre même pas le texte
        _partial = m.commande;
        if (!r.finalResult) {
          _setPhase(WetroVoicePhase.attentive);
          notifyListeners();
          return;
        }
        _gotFinal = true;
        await _commande(m.commande);
      case WetroVoicePhase.attentive:
        final m = WakeWord.detecte(texte);
        final commande = m == null ? texte : m.commande;
        _partial = commande;
        notifyListeners();
        if (!r.finalResult) return;
        _gotFinal = true;
        final apresInterruption = _interrupted;
        _interrupted = false;
        await _commande(commande, apresInterruption: apresInterruption);
      case WetroVoicePhase.speaking:
        // Micro ouvert pendant la lecture : n'est une interruption que ce
        // qui n'est pas l'écho de Wetro lui-même.
        final verdict = WetroDialogue.pendantParole(texte, _spokenText);
        if (verdict == WetroBargeIn.ignore) return;
        // Phase et drapeau AVANT de couper la synthèse : la suite de
        // `_speakThen` (qui attend la fin de la lecture) doit voir que la
        // parole a été reprise et laisser cette session mener.
        _interrupted = true;
        _setPhase(WetroVoicePhase.attentive);
        await _voice.stopSpeaking();
        if (id != _session) return;
        final m = WakeWord.detecte(texte);
        _partial = m == null ? texte : m.commande;
        notifyListeners();
        if (r.finalResult) {
          _gotFinal = true;
          _interrupted = false;
          await _commande(_partial, apresInterruption: true);
        }
      case WetroVoicePhase.confirming:
        if (!r.finalResult) {
          _partial = texte;
          notifyListeners();
          return;
        }
        _gotFinal = true;
        await _consentement(texte);
      case WetroVoicePhase.idle:
      case WetroVoicePhase.thinking:
        return;
    }
  }

  Future<void> _onListenDone(int id) async {
    if (id != _session || _disposed) return;
    switch (_phase) {
      case WetroVoicePhase.wake:
        // Le système a refermé le micro (délai, silence) : on le rouvre,
        // c'est le principe de l'éveil. Petite pause pour ne pas marteler.
        _setPhase(WetroVoicePhase.idle);
        Timer(const Duration(milliseconds: 350), () => unawaited(_ensureWake()));
      case WetroVoicePhase.attentive:
        if (_gotFinal) return; // la commande est déjà partie
        if (_followUp || _partial.trim().isEmpty) {
          // Fenêtre de relance écoulée, ou rien d'intelligible : retour au
          // calme, sans commentaire.
          _setPhase(WetroVoicePhase.idle);
          await _ensureWake();
        } else {
          // Le moteur a rendu une transcription partielle sans finale
          // (coupure réseau…) : on l'utilise plutôt que de la perdre.
          final apresInterruption = _interrupted;
          _interrupted = false;
          await _commande(_partial, apresInterruption: apresInterruption);
        }
      case WetroVoicePhase.confirming:
        if (_gotFinal) return;
        await _annulePending('Je n’ai pas entendu de réponse : j’annule l’envoi.');
      case WetroVoicePhase.speaking:
        // L'écoute d'interruption s'est fermée : la lecture continue.
        return;
      case WetroVoicePhase.idle:
      case WetroVoicePhase.thinking:
        return;
    }
  }

  Future<void> _commande(String commande, {bool apresInterruption = false}) async {
    if (WetroDialogue.estVide(commande) ||
        (apresInterruption && WetroDialogue.estArretSeul(commande))) {
      if (apresInterruption) {
        // « Stop » seul : Wetro se tait et écoute la suite.
        await _listen(WetroVoicePhase.attentive, followUp: true);
        return;
      }
      // « Wetro » seul : on se signale et on écoute.
      await _speakThen('Oui ?', relance: true, court: true);
      return;
    }
    if (apresInterruption) {
      // La personne a coupé Wetro d'un mot, puis a parlé : le premier mot
      // n'est pas la commande.
      final mots = commande.split(' ');
      if (mots.length > 1 &&
          WetroDialogue.pendantParole(mots.first, '') == WetroBargeIn.interrupt) {
        commande = mots.sublist(1).join(' ');
      }
    }
    await _closeMic();
    _setPhase(WetroVoicePhase.thinking);
    await send(commande, vocal: true);
  }

  /// Ferme le micro en périmant la session : ses derniers retours (fin de
  /// session, résultat tardif) sont ignorés au lieu de relancer une écoute
  /// pendant qu'une question part au serveur.
  Future<void> _closeMic() async {
    _session++;
    await _voice.cancelListening();
  }

  Future<void> _consentement(String texte) async {
    final action = _pending;
    if (action == null) {
      await _listen(WetroVoicePhase.attentive, followUp: true);
      return;
    }
    switch (WetroDialogue.consentement(texte)) {
      case WetroConsent.yes:
        _pending = null;
        await _closeMic();
        _setPhase(WetroVoicePhase.thinking);
        final ok = await runAction(action);
        final phrase = switch (action.type) {
          WetroActionType.sos => ok
              ? 'Alerte envoyée. Vos responsables sont prévenus. Restez en sécurité.'
              : 'L’alerte n’est pas partie. Ouvrez l’écran SOS.',
          _ => ok ? 'C’est envoyé.' : 'Le message n’est pas parti.',
        };
        await _speakThen(phrase, relance: false);
      case WetroConsent.no:
        await _annulePending('D’accord, j’annule.');
      case WetroConsent.unclear:
        _unclearCount++;
        if (_unclearCount >= 2) {
          await _annulePending('Je n’ai pas compris : j’annule l’envoi.');
        } else {
          await _speakThen('Dites oui pour envoyer, ou non pour annuler.', confirmation: true);
        }
    }
  }

  Future<void> _annulePending(String phrase) async {
    final action = _pending;
    _pending = null;
    if (action != null) declineAction(action);
    await _speakThen(phrase, relance: false);
  }

  /// Dit une phrase (si la lecture est activée), micro ouvert pendant la
  /// lecture pour l'interruption, puis enchaîne : fenêtre de relance,
  /// attente de confirmation, ou retour au calme.
  Future<void> _speakThen(
    String texte, {
    bool relance = true,
    bool confirmation = false,
    bool court = false,
  }) async {
    if (_disposed) return;
    if (_speakEnabled && _voiceReady) {
      final aDire = court ? texte : WetroDialogue.pourLaVoix(texte);
      _spokenText = aDire;
      final id = ++_session;
      _followUp = false;
      _gotFinal = false;
      _setPhase(WetroVoicePhase.speaking);
      _partial = '';
      // Micro ouvert AVANT de parler : c'est ce qui permet de couper Wetro.
      // Si le système refuse (session audio exclusive), la lecture a lieu
      // quand même ; on écoutera après. Cette session survit à
      // l'interruption : c'est elle qui capte la phrase de la personne.
      unawaited(_voice.listen(
        listenFor: const Duration(seconds: 40),
        pauseFor: null,
        onLevel: (l) {
          if (id != _session || _phase == WetroVoicePhase.speaking) return;
          _level = l;
          notifyListeners();
        },
        onResult: (r) {
          if (id != _session) return;
          unawaited(_onResult(id, r));
        },
        onDone: () {
          if (id != _session) return;
          unawaited(_onListenDone(id));
        },
      ));
      await _voice.speak(aDire);
      // Interrompue : la phase n'est plus « speaking » et la session
      // d'écoute, toujours vivante, mène la suite.
      if (_disposed || id != _session || _interrupted || _phase != WetroVoicePhase.speaking) return;
      await _closeMic();
    }
    if (_disposed) return;
    if (confirmation && _pending != null) {
      if (_voiceReady) {
        await _listen(WetroVoicePhase.confirming);
      } else {
        // Pas de micro : la puce fait office de confirmation.
        _setPhase(WetroVoicePhase.idle);
      }
      return;
    }
    if (relance && _voiceReady) {
      await _listen(WetroVoicePhase.attentive, followUp: true);
      return;
    }
    _setPhase(WetroVoicePhase.idle);
    await _ensureWake();
  }
}
