// lib/wetrackam/call_policy.dart
//
// v17 — les DÉCISIONS pures de la téléphonie, séparées de l'exécution.
//
// Tout ce qui, dans un appel, se décide sans toucher ni au réseau, ni au
// natif, ni à l'arbre de widgets vit ici et se teste cas par cas
// (test/call_policy_test.dart) :
//
//  1. quoi faire d'un événement venu de l'écran d'appel NATIF (répondre,
//     refuser, raccrocher, délai) selon l'appel en cours et sa phase ;
//  2. quelle route d'appel afficher à chaque changement de phase ;
//  3. quelle surface fait sonner un appel entrant (page Flutter + sonnerie
//     applicative au premier plan, écran natif sinon) ;
//  4. la file des signaux d'appel à rejouer quand la socket se rétablit.
//
// POURQUOI CE FICHIER EXISTE. Les pannes corrigées en v17 venaient toutes de
// décisions prises « au passage » dans le code d'exécution : un délai de
// notification traité comme un refus alors que l'appel était décroché ; un
// écran d'appel entrant qui restait affiché après un décrochage natif ; un
// raccrochage perdu parce que la socket se reconnectait. Chacune de ces
// décisions est maintenant une fonction sans effet de bord, avec sa table
// de cas.

/// Phases d'un appel. Définies ici (et non dans call_service.dart) pour que
/// les décisions pures ne dépendent d'aucun code d'exécution.
enum CallPhase { idle, outgoingRinging, incomingRinging, connected, ended }

// ---------------------------------------------------------------------------
//  1. Événements de l'écran d'appel natif
// ---------------------------------------------------------------------------

enum NativeCallEventKind { accept, decline, ended, timeout }

enum NativeCallAction {
  /// L'appel entrant en cours est accepté.
  accept,

  /// Acceptation reçue AVANT la signalisation (push plus rapide que la
  /// socket) : on la mémorise pour la rejouer à `call.incoming`.
  rememberAccept,

  /// L'appel entrant en cours est refusé (call.decline).
  decline,

  /// Sonnerie non décrochée : appel manqué. Rien n'est envoyé au serveur —
  /// son propre minuteur clôt l'appel avec la raison `timeout`, ce qui le
  /// journalise comme MANQUÉ et non comme refusé.
  missed,

  /// L'appel en communication est raccroché depuis une surface native
  /// (CallKit iOS, notification d'appel en cours).
  hangUp,

  /// Une acceptation mémorisée est annulée (refus natif après coup).
  forgetPending,

  /// Rien à changer dans la machine à états : on s'assure seulement que la
  /// surface native est fermée (écran orphelin).
  dismissOnly,

  /// Événement d'un autre appel, ou hors phase : ignoré.
  ignore,
}

/// Décide de l'effet d'un événement natif.
///
/// La règle qui manquait : un événement ne vaut que pour l'appel qu'il nomme
/// ET dans la phase où il a un sens. Le délai (`timeout`) de la notification
/// d'un appel déjà décroché raccrochait la communication au bout de 20 s ;
/// un refus natif tardif faisait de même.
NativeCallAction decideNativeEvent({
  required NativeCallEventKind kind,
  required String eventCallId,
  required CallPhase phase,
  required String? currentCallId,
  required String? pendingAcceptId,
}) {
  final sameCall = currentCallId != null && currentCallId == eventCallId;
  switch (kind) {
    case NativeCallEventKind.accept:
      if (phase == CallPhase.incomingRinging && sameCall) {
        return NativeCallAction.accept;
      }
      if (phase == CallPhase.idle || phase == CallPhase.ended) {
        return NativeCallAction.rememberAccept;
      }
      return NativeCallAction.ignore;
    case NativeCallEventKind.decline:
      if (phase == CallPhase.incomingRinging && sameCall) {
        return NativeCallAction.decline;
      }
      if (pendingAcceptId != null && pendingAcceptId == eventCallId) {
        return NativeCallAction.forgetPending;
      }
      if (phase == CallPhase.idle || phase == CallPhase.ended) {
        return NativeCallAction.dismissOnly;
      }
      return NativeCallAction.ignore;
    case NativeCallEventKind.timeout:
      if (phase == CallPhase.incomingRinging && sameCall) {
        return NativeCallAction.missed;
      }
      if (pendingAcceptId != null && pendingAcceptId == eventCallId) {
        return NativeCallAction.forgetPending;
      }
      return NativeCallAction.ignore;
    case NativeCallEventKind.ended:
      if (phase == CallPhase.connected && sameCall) {
        return NativeCallAction.hangUp;
      }
      if (phase == CallPhase.incomingRinging && sameCall) {
        return NativeCallAction.decline;
      }
      if (phase == CallPhase.idle || phase == CallPhase.ended) {
        return NativeCallAction.dismissOnly;
      }
      return NativeCallAction.ignore;
  }
}

// ---------------------------------------------------------------------------
//  2. Route d'appel affichée
// ---------------------------------------------------------------------------

enum CallRouteKind { incoming, inCall }

enum CallRouteAction { none, pushIncoming, pushInCall, replaceWithInCall, remove }

/// Route à afficher pour une phase donnée, connaissant la route d'appel
/// actuellement montée (ou null).
///
/// `inAppIncomingUi` : la page Flutter d'appel entrant est la surface de
/// sonnerie (Android au premier plan). Sinon l'écran natif s'en charge et
/// aucune page n'est poussée pendant la sonnerie — elle le sera à la
/// connexion, ou quand l'application revient au premier plan.
CallRouteAction nextRouteAction({
  required CallPhase phase,
  required CallRouteKind? current,
  required bool inAppIncomingUi,
}) {
  switch (phase) {
    case CallPhase.incomingRinging:
      if (current != null) return CallRouteAction.none;
      return inAppIncomingUi ? CallRouteAction.pushIncoming : CallRouteAction.none;
    case CallPhase.outgoingRinging:
      return current == null ? CallRouteAction.pushInCall : CallRouteAction.none;
    case CallPhase.connected:
      if (current == CallRouteKind.inCall) return CallRouteAction.none;
      if (current == CallRouteKind.incoming) return CallRouteAction.replaceWithInCall;
      return CallRouteAction.pushInCall;
    case CallPhase.ended:
      return CallRouteAction.none; // idle suit immédiatement
    case CallPhase.idle:
      return current == null ? CallRouteAction.none : CallRouteAction.remove;
  }
}

// ---------------------------------------------------------------------------
//  3. Surface de sonnerie
// ---------------------------------------------------------------------------

/// Vrai si l'appel entrant doit sonner DANS l'application (page Flutter +
/// sonnerie applicative) plutôt que par l'écran natif.
///
/// Android au premier plan : la page Flutter, unique surface, sonne via
/// CallRinger. Android en arrière-plan / écran verrouillé : notification
/// plein écran native (seul moyen de réveiller l'écran). iOS : CallKit
/// toujours — c'est l'interface d'appel du système, premier plan compris.
bool shouldRingInApp({required bool android, required bool foreground}) =>
    android && foreground;

// ---------------------------------------------------------------------------
//  4. File des signaux d'appel
// ---------------------------------------------------------------------------

/// Signaux d'appel (`call.*`) à rejouer quand la socket se rétablit.
///
/// Un `call.hangup` envoyé pendant une reconnexion était simplement jeté :
/// le pair restait « en appel » et continuait d'entendre le micro jusqu'à
/// ce que sa pile WebRTC constate la mort du chemin, 15 à 40 s plus tard.
/// Bornée en nombre et en âge : un signal vieux de plus de [ttl] n'a plus de
/// sens (le serveur a de toute façon clos l'appel).
class CallSignalQueue {
  CallSignalQueue({this.maxLength = 30, this.ttl = const Duration(seconds: 25)});

  final int maxLength;
  final Duration ttl;
  final List<_QueuedSignal> _items = [];

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;

  /// Vrai si ce message mérite d'attendre la reconnexion.
  static bool isCallSignal(Map<String, dynamic> message) {
    final type = message['type'];
    return type is String && type.startsWith('call.');
  }

  void enqueue(Map<String, dynamic> message, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final type = message['type'];
    // Un raccrochage/refus/annulation rend caduc tout signal antérieur du
    // même appel : inutile de rejouer des candidats pour un appel fini.
    if (type == 'call.hangup' || type == 'call.decline' || type == 'call.cancel') {
      final callId = message['callId'];
      _items.removeWhere((q) => q.message['callId'] == callId);
    }
    _items.add(_QueuedSignal(message, at));
    while (_items.length > maxLength) {
      _items.removeAt(0);
    }
  }

  /// Retire et renvoie les signaux encore valables, dans l'ordre d'origine.
  List<Map<String, dynamic>> drain({DateTime? now}) {
    final at = now ?? DateTime.now();
    final out = <Map<String, dynamic>>[];
    for (final q in _items) {
      if (at.difference(q.queuedAt) <= ttl) out.add(q.message);
    }
    _items.clear();
    return out;
  }

  void clear() => _items.clear();
}

class _QueuedSignal {
  final Map<String, dynamic> message;
  final DateTime queuedAt;
  const _QueuedSignal(this.message, this.queuedAt);
}
