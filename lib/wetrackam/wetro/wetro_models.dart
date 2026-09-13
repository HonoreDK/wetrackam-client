/// Modèles de l'assistant Wetro côté CHAUFFEUR — contrat
/// `/api/mobile/wetro/state` et `/api/mobile/wetro/ask` (WetroDriverResource),
/// recopié sans interprétation.
///
/// Même Wetro que sur le web et l'application manager (même serveur, même
/// fournisseur, même quota par espace client), autre interlocuteur : le
/// chauffeur ne détient aucun droit de gestion, et le serveur ne lui livre
/// que ce que l'application lui montre déjà (son service, ses responsables,
/// ses collègues selon la politique de l'espace, son alerte ouverte).
library;

/// Type d'action que le serveur peut proposer (catalogue FERMÉ, recopie de
/// `WetroDriverActions`). Tout type inconnu est ignoré : l'application
/// n'exécute jamais quelque chose qu'elle ne connaît pas.
enum WetroActionType { callDriver, messageDriver, callManager, openConversation, openScreen, sos }

WetroActionType? wetroActionTypeDe(String? brut) => switch (brut) {
      'call_driver' => WetroActionType.callDriver,
      'message_driver' => WetroActionType.messageDriver,
      'call_manager' => WetroActionType.callManager,
      'open_conversation' => WetroActionType.openConversation,
      'open_screen' => WetroActionType.openScreen,
      'sos' => WetroActionType.sos,
      _ => null,
    };

String wetroActionTypeVers(WetroActionType t) => switch (t) {
      WetroActionType.callDriver => 'call_driver',
      WetroActionType.messageDriver => 'message_driver',
      WetroActionType.callManager => 'call_manager',
      WetroActionType.openConversation => 'open_conversation',
      WetroActionType.openScreen => 'open_screen',
      WetroActionType.sos => 'sos',
    };

/// Écrans que `open_screen` peut viser (recopie de `WetroDriverActions.ECRANS`).
const wetroEcrans = {'home', 'fleet', 'directory', 'sos', 'diagnostics'};

/// Natures de détresse (recopie du catalogue fermé de `Distress.KINDS`).
const wetroNaturesSos = {'sos', 'accident', 'medical', 'security', 'breakdown'};

/// Une action VALIDÉE par le serveur (politique relue, personne dans les
/// listes collectées). L'application l'exécute par ses voies habituelles,
/// qui revalident encore : cette classe ne porte aucune autorité.
class WetroAction {
  const WetroAction({
    required this.type,
    this.driverId,
    this.driverName,
    this.managerId,
    this.managerName,
    this.text,
    this.screen,
    this.kind,
    this.needsConfirmation = false,
  });

  final WetroActionType type;
  final int? driverId;
  final String? driverName;

  /// Identifiant de PARTICIPANT temps réel du responsable (900000000 + id).
  final int? managerId;
  final String? managerName;
  final String? text;
  final String? screen;
  final String? kind;

  /// Vrai pour un message dicté (peut avoir été mal entendu) et TOUJOURS
  /// pour un SOS : une alerte mobilise des personnes, jamais sur une
  /// transcription seule. Un appel se raccroche d'un geste.
  final bool needsConfirmation;

  /// `null` si l'objet ne décrit pas une action exécutable.
  static WetroAction? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final type = wetroActionTypeDe(raw['type']?.toString());
    if (type == null) return null;
    final driverId = _entier(raw['driverId']);
    final managerId = _entier(raw['managerId']);
    final nom = _propre(raw['driverName']);
    final nomResp = _propre(raw['managerName']);
    final texte = _propre(raw['text']);
    final ecran = raw['screen']?.toString().trim().toLowerCase();
    final nature = raw['kind']?.toString().trim().toLowerCase();
    switch (type) {
      case WetroActionType.callDriver:
      case WetroActionType.openConversation:
        if (driverId == null || driverId <= 0) return null;
        return WetroAction(type: type, driverId: driverId, driverName: nom);
      case WetroActionType.messageDriver:
        if (driverId == null || driverId <= 0) return null;
        if (texte == null) return null;
        return WetroAction(
          type: type,
          driverId: driverId,
          driverName: nom,
          text: texte,
          needsConfirmation: raw['needsConfirmation'] != false,
        );
      case WetroActionType.callManager:
        if (managerId == null || managerId <= 0) return null;
        return WetroAction(type: type, managerId: managerId, managerName: nomResp);
      case WetroActionType.sos:
        return WetroAction(
          type: type,
          kind: nature != null && wetroNaturesSos.contains(nature) ? nature : 'sos',
          // Quoi qu'en dise le serveur, un SOS proposé par une machine se
          // confirme : la règle est aussi tenue ici.
          needsConfirmation: true,
        );
      case WetroActionType.openScreen:
        if (ecran == null || !wetroEcrans.contains(ecran)) return null;
        return WetroAction(type: type, screen: ecran);
    }
  }

  static int? _entier(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static String? _propre(Object? v) {
    final s = v?.toString().trim();
    return s == null || s.isEmpty ? null : s;
  }

  /// Libellé court pour la puce sous la bulle.
  String get libelle {
    final nom = driverName ?? 'ce collègue';
    return switch (type) {
      WetroActionType.callDriver => 'Appeler $nom',
      WetroActionType.messageDriver => 'Envoyer à $nom',
      WetroActionType.callManager => 'Appeler ${managerName ?? 'mon responsable'}',
      WetroActionType.openConversation => 'Ouvrir la discussion avec $nom',
      WetroActionType.openScreen => 'Ouvrir ${wetroEcranLibelle(screen)}',
      WetroActionType.sos => 'Déclencher l’alerte ${wetroNatureLibelle(kind)}',
    };
  }
}

/// Libellés des écrans, tels que l'assistant et le chauffeur les nomment.
String wetroEcranLibelle(String? ecran) => switch (ecran) {
      'home' => 'mon service',
      'fleet' => 'la carte des collègues',
      'directory' => "l'annuaire",
      'sos' => "l'écran d'alerte",
      'diagnostics' => "l'état de l'application",
      _ => "l'écran",
    };

String wetroNatureLibelle(String? nature) => switch (nature) {
      'accident' => 'accident',
      'medical' => 'médicale',
      'security' => 'sécurité',
      'breakdown' => 'panne',
      _ => 'SOS',
    };

/// Réponse de `/api/mobile/wetro/state`.
class WetroState {
  const WetroState({
    required this.available,
    required this.sources,
    required this.actions,
    required this.screens,
    required this.epoch,
  });

  static const indisponible =
      WetroState(available: false, sources: [], actions: [], screens: [], epoch: 0);

  final bool available;
  final List<String> sources;

  /// Types d'action que le serveur acceptera de CE chauffeur, à cet
  /// instant. La voix n'annonce que ceux-là.
  final List<String> actions;
  final List<String> screens;
  final int epoch;

  bool get peutAppeler => actions.contains('call_driver');
  bool get peutEcrire => actions.contains('message_driver');
  bool get peutAppelerResponsable => actions.contains('call_manager');

  factory WetroState.fromJson(Map<String, dynamic> json) => WetroState(
        available: json['available'] == true && json['audience'] == 'driver',
        sources: _chaines(json['sources']),
        actions: _chaines(json['actions']),
        screens: _chaines(json['screens']),
        epoch: (json['epoch'] as num?)?.toInt() ?? 0,
      );

  static List<String> _chaines(Object? v) =>
      v is List ? v.map((e) => e.toString()).toList(growable: false) : const [];
}

/// Réponse de `/api/mobile/wetro/ask`.
class WetroAnswer {
  const WetroAnswer({
    required this.answer,
    this.action,
    this.actionRefused = false,
    this.notice,
    this.epoch,
  });

  final String answer;
  final WetroAction? action;
  final bool actionRefused;
  final String? notice;
  final int? epoch;

  factory WetroAnswer.fromJson(Map<String, dynamic> json) => WetroAnswer(
        answer: (json['answer'] ?? '').toString(),
        action: WetroAction.fromJson(json['action']),
        actionRefused: json['actionRefused'] == true,
        notice: json['notice']?.toString(),
        epoch: (json['epoch'] as num?)?.toInt(),
      );
}

/// Un tour de conversation, tel qu'affiché et tel que renvoyé au serveur
/// dans `history` (seuls `role` et `content` partent).
class WetroMessage {
  const WetroMessage({
    required this.role,
    required this.content,
    this.action,
    this.actionRefused = false,
    this.actionDone = false,
    this.vocal = false,
  });

  final String role; // 'user' | 'assistant'
  final String content;
  final WetroAction? action;
  final bool actionRefused;

  /// L'action a été exécutée (ou refusée par la personne) : la puce
  /// disparaît, on ne rappelle pas deux fois.
  final bool actionDone;

  /// Tour dicté / lu à voix haute.
  final bool vocal;

  bool get deMoi => role == 'user';

  WetroMessage copyWith({bool? actionDone}) => WetroMessage(
        role: role,
        content: content,
        action: action,
        actionRefused: actionRefused,
        actionDone: actionDone ?? this.actionDone,
        vocal: vocal,
      );
}

/// Recopie de `WetroDriverResource.MAX_ECHANGES` : paires gardées côté serveur.
const wetroMaxEchanges = 6;

/// Recopie de `WetroPrompt.MAX_QUESTION`.
const wetroMaxQuestion = 2000;

/// Recopie de `WetroDriverResource.MAX_MESSAGE`.
const wetroMaxMessage = 4000;

/// Historique borné EXACTEMENT comme le serveur le borne.
List<Map<String, String>> wetroHistorique(List<WetroMessage> messages) {
  final utiles = messages.where((m) => m.content.trim().isNotEmpty).toList();
  final debut = utiles.length > wetroMaxEchanges * 2 ? utiles.length - wetroMaxEchanges * 2 : 0;
  return [
    for (final m in utiles.sublist(debut))
      {
        'role': m.deMoi ? 'user' : 'assistant',
        'content': m.content.length > wetroMaxMessage ? m.content.substring(0, wetroMaxMessage) : m.content,
      },
  ];
}

/// Motifs d'erreur du serveur, en langage humain (chauffeur).
String wetroMotif(String? motif, {String? secours}) => switch (motif) {
      'noSession' || 'notADriverSession' => 'Votre session a expiré. Reconnectez-vous pour retrouver Wetro.',
      'noTenant' || 'crossTenant' => "Votre compte n'est rattaché à aucune entreprise : Wetro n'a rien à consulter.",
      'driverNotFound' => 'Votre fiche chauffeur est introuvable. Prévenez votre responsable.',
      'aiDisabled' => "L'assistant n'est pas activé sur cette plateforme.",
      'questionRequired' => 'Dites ou écrivez votre question.',
      'questionTooLong' => 'Votre question est trop longue. Raccourcissez-la.',
      'quotaExceeded' => "Le quota d'assistance de votre entreprise est atteint pour ce mois-ci.",
      'tooManyRequests' || 'rate_limited' => 'Vous allez un peu vite. Patientez quelques secondes.',
      'unauthorized' || 'providerUnknown' => "L'assistant n'est pas correctement configuré. Prévenez votre responsable.",
      'providerRateLimited' => 'Le service est momentanément saturé. Réessayez dans un instant.',
      'providerError' => "Le service d'assistance a rencontré une erreur. Réessayez.",
      'emptyAnswer' => "Wetro n'a rien trouvé à répondre. Reformulez votre question.",
      'timeout' => 'La réponse a mis trop de temps à venir. Réessayez.',
      'interrupted' => 'La réponse a été interrompue. Réessayez.',
      _ => secours ?? "Wetro n'est pas disponible pour le moment.",
    };

/// Avis accompagnant une réponse (quota), ou `null`.
String? wetroAvis(String? notice) => switch (notice) {
      'quotaReached' => 'Quota mensuel atteint : les réponses continuent, mais prévenez votre responsable.',
      'emergencyOverride' => 'Alerte en cours : cette question passe en priorité, hors quota.',
      _ => null,
    };

/// Libellés des sources annoncées par `/state`.
String wetroSourceLibelle(String s) => switch (s) {
      'ma_situation' => 'mon service',
      'mes_responsables' => 'mes responsables',
      'collegues' => 'mes collègues',
      'alerte_sos' => 'mon alerte',
      _ => s,
    };
