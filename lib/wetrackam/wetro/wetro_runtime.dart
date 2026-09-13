import 'package:flutter/widgets.dart';

import 'wetro_controller.dart';

/// Point de rencontre entre l'application et la surcouche Wetro.
///
/// La surcouche (bouton + panneau) est montée au-dessus du `Navigator`, par
/// `MaterialApp.builder` : elle existe avant toute connexion et survit à
/// tous les écrans. Le contrôleur, lui, naît avec la session (dans
/// `AppRoot`) et meurt avec elle. Ce registre relie les deux sans qu'aucun
/// n'ait à connaître l'autre : `AppRoot` dépose le contrôleur, la
/// surcouche s'y abonne. Rien d'autre n'y transite.
class WetroRuntime extends ChangeNotifier {
  WetroRuntime._();

  static final WetroRuntime instance = WetroRuntime._();

  WetroController? _controller;
  WetroController? get controller => _controller;

  int _modalDepth = 0;

  /// Vrai quand un dialogue, une feuille ou un menu couvre l'écran : le
  /// bouton s'escamote (il flotterait au-dessus, hors de son contexte).
  bool get modalOpen => _modalDepth > 0;

  /// Compteur de changements de route : la surcouche relance un balayage
  /// des obstacles à chaque navigation.
  int _navigationTick = 0;
  int get navigationTick => _navigationTick;

  void attach(WetroController? controller) {
    if (identical(_controller, controller)) return;
    _controller = controller;
    notifyListeners();
  }

  void _routeChanged(Route<dynamic>? route, int delta) {
    if (route is PopupRoute) {
      _modalDepth = (_modalDepth + delta).clamp(0, 1 << 20);
    }
    _navigationTick++;
    notifyListeners();
  }
}

/// Observateur à déclarer dans `MaterialApp.navigatorObservers`.
class WetroRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      WetroRuntime.instance._routeChanged(route, 1);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      WetroRuntime.instance._routeChanged(route, -1);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      WetroRuntime.instance._routeChanged(route, -1);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    WetroRuntime.instance._routeChanged(oldRoute, -1);
    WetroRuntime.instance._routeChanged(newRoute, 1);
  }
}
