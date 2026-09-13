// lib/wetrackam/call_navigator.dart
//
// Lot 8 — un appel entrant peut survenir depuis n'importe quel écran de
// l'app (ou juste après un réveil par push, avant même que l'app soit au
// premier plan). CallService n'a pas de BuildContext ; ce fichier fait le
// pont via une clé de navigation globale (main.dart, MaterialApp.navigatorKey).
//
// v17 — UNE SEULE ROUTE D'APPEL, PILOTÉE PAR LA PHASE.
//
// Avant, chaque écran naviguait pour son compte : l'annuaire poussait l'écran
// d'appel avant même d'appeler, la page d'appel entrant se remplaçait
// elle-même au décrochage, l'écran d'appel en cours dépilait TOUTE la pile au
// raccrochage (`popUntil(isFirst)`), et personne n'ouvrait l'écran d'appel
// quand le décrochage venait de l'écran natif (téléphone verrouillé,
// application tuée) : la page « Appel entrant » restait affichée avec ses
// boutons alors que la communication était établie, ou aucun écran d'appel
// n'apparaissait du tout.
//
// Maintenant : ce répartiteur écoute la phase (CallService.phaseChanges) et
// applique la table de call_policy.nextRouteAction — pousser la page d'appel
// entrant, la remplacer par l'appel en cours, retirer la route d'appel (et
// seulement elle) au retour au repos. Les écrans d'appel n'appellent plus
// jamais Navigator.
import 'package:flutter/material.dart';

import 'app_logger.dart';
import 'call_policy.dart';
import 'call_service.dart';
import 'error_catalog.dart';
import 'in_call_screen.dart';
import 'incoming_call_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class CallNavigator {
  CallNavigator._();

  static bool _listening = false;
  static Route<void>? _route;
  static CallRouteKind? _kind;
  static ScaffoldMessengerState? Function()? _messenger;

  /// [messenger] : pour annoncer la cause d'une fin d'appel (occupé, refusé,
  /// micro indisponible…) une fois la route d'appel retirée.
  static void start({ScaffoldMessengerState? Function()? messenger}) {
    if (_listening) return;
    _listening = true;
    _messenger = messenger;
    CallService.phaseChanges.listen(_onPhase);
  }

  /// La surface d'appel entrant a changé (retour au premier plan pendant la
  /// sonnerie) : on rejoue la décision pour la phase courante.
  static void sync() => _onPhase(CallService.phase);

  static void _onPhase(CallPhase phase) {
    final nav = navigatorKey.currentState;
    if (nav == null) {
      if (phase != CallPhase.idle && phase != CallPhase.ended) {
        AppLogger.error('call_navigator_no_navigator', 'call screen could not be displayed');
      }
      return;
    }
    final action = nextRouteAction(
      phase: phase,
      current: _kind,
      inAppIncomingUi: CallService.isForeground,
    );
    switch (action) {
      case CallRouteAction.pushIncoming:
        _push(nav, CallRouteKind.incoming, const IncomingCallScreen());
      case CallRouteAction.pushInCall:
        _push(nav, CallRouteKind.inCall, const InCallScreen());
      case CallRouteAction.replaceWithInCall:
        final previous = _route;
        _route = null;
        _kind = null;
        _push(nav, CallRouteKind.inCall, const InCallScreen());
        if (previous != null) nav.removeRoute(previous);
      case CallRouteAction.remove:
        final route = _route;
        _route = null;
        _kind = null;
        if (route != null) nav.removeRoute(route);
        _announceEndReason();
      case CallRouteAction.none:
        break;
    }
  }

  static void _push(NavigatorState nav, CallRouteKind kind, Widget screen) {
    final route = MaterialPageRoute<void>(builder: (_) => screen, fullscreenDialog: true);
    _route = route;
    _kind = kind;
    // Si la route disparaît par un autre chemin (redémarrage de l'arbre), on
    // l'oublie pour ne jamais tenter de retirer une route déjà morte.
    route.popped.then((_) {
      if (identical(_route, route)) {
        _route = null;
        _kind = null;
      }
    });
    nav.push(route);
  }

  /// Cause de fin visible par le chauffeur (§10 catalogue). `peerCrossTenant`
  /// reste muet : incident d'isolation, jamais un texte métier.
  static void _announceEndReason() {
    final reason = CallService.consumeLastErrorReason();
    if (reason == null || ErrorCatalog.isSilentMask(reason)) return;
    final messenger = _messenger?.call();
    if (messenger == null) return;
    messenger.showSnackBar(SnackBar(content: Text(ErrorCatalog.http(error: reason))));
  }
}
