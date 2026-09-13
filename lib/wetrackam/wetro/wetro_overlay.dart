import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';

import 'wetro_avoidance.dart';
import 'wetro_controller.dart';
import 'wetro_obstacles.dart';
import 'wetro_runtime.dart';
import 'wetro_fab.dart';
import 'wetro_panel.dart';

/// Surcouche Wetro : bouton flottant en bas à GAUCHE (la droite est le
/// coin des boutons d'action des écrans), panneau de conversation, et
/// moteur d'évitement en temps réel.
///
/// Montée par `MaterialApp.builder`, donc au-dessus du `Navigator` : elle
/// est présente sur TOUS les écrans, sans que chacun ait à la connaître.
/// Elle ne montre rien tant qu'aucune session n'a déposé de contrôleur
/// (`WetroRuntime`) ou que le serveur n'annonce pas l'assistant disponible.
///
/// Elle porte son propre `Overlay` : nous sommes hors de celui du
/// Navigator, et infobulles comme menu de sélection de texte en exigent un.
/// Le sous-arbre est marqué d'un identifiant sémantique pour que le
/// balayage des obstacles l'ignore — sinon le bouton se fuirait lui-même.
class WetroOverlay extends StatefulWidget {
  const WetroOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<WetroOverlay> createState() => _WetroOverlayState();
}

class _WetroOverlayState extends State<WetroOverlay> {
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: Semantics(
            container: true,
            identifier: wetroOverlayIdentifier,
            // `Overlay.wrap` gère lui-même l'entrée unique et son cycle de vie.
            child: Overlay.wrap(clipBehavior: Clip.none, child: const _WetroSurface()),
          ),
        ),
      ],
    );
  }
}

/// La surface vivante : abonnée au registre, au contrôleur et aux
/// métriques, elle place le bouton et le panneau.
///
/// ÉVITEMENT
/// ---------
/// Le bouton ne cache jamais un élément touchable : à intervalle court, et
/// à chaque navigation, la zone où il peut aller est balayée dans l'arbre
/// d'accessibilité (`WetroObstacleScanner`), puis `place()` choisit la
/// première place libre par anneaux, avec hystérésis. Le clavier relève
/// la ligne de base (le bouton monte au-dessus), un dialogue, une feuille
/// ou un menu escamote le bouton.
class _WetroSurface extends StatefulWidget {
  const _WetroSurface();

  @override
  State<_WetroSurface> createState() => _WetroSurfaceState();
}

class _WetroSurfaceState extends State<_WetroSurface> with WidgetsBindingObserver {
  static const _marge = 16.0;
  static const _margeBas = 16.0;
  static const _cadence = Duration(milliseconds: 300);

  final _scanner = WetroObstacleScanner();
  SemanticsHandle? _semantics;
  Timer? _battement;
  WetroController? _controller;
  FabCandidat _actuel = FabCandidat.repos;
  int _tick = -1;
  bool _mecaniqueActive = false;
  Size _vue = Size.zero;
  double _basClavier = 0;
  double _hautSur = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WetroRuntime.instance.addListener(_onRuntime);
    _onRuntime();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WetroRuntime.instance.removeListener(_onRuntime);
    _controller?.removeListener(_rafraichit);
    _battement?.cancel();
    _semantics?.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() => _planifie();

  void _onRuntime() {
    final next = WetroRuntime.instance.controller;
    if (!identical(next, _controller)) {
      _controller?.removeListener(_rafraichit);
      _controller = next;
      _controller?.addListener(_rafraichit);
    }
    if (WetroRuntime.instance.navigationTick != _tick) {
      _tick = WetroRuntime.instance.navigationTick;
      _planifie();
    }
    _rafraichit();
  }

  /// `setState` sûr : le registre et le contrôleur notifient parfois en
  /// pleine construction d'une image (démontage d'un écran, réponse
  /// arrivée pendant une navigation) ; on reporte alors à l'image suivante.
  void _rafraichit() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks || phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  bool get _visible {
    final c = _controller;
    return c != null && c.available && !c.inCall && !WetroRuntime.instance.modalOpen;
  }

  /// Ouvre ou ferme la mécanique (sémantique + battement) selon la
  /// visibilité, pour ne rien coûter quand le bouton n'est pas là.
  void _synchronise(bool visible) {
    if (visible == _mecaniqueActive) return;
    _mecaniqueActive = visible;
    if (visible) {
      _semantics ??= SemanticsBinding.instance.ensureSemantics();
      _battement ??= Timer.periodic(_cadence, (_) => _balaie());
      _planifie();
    } else {
      _battement?.cancel();
      _battement = null;
      _semantics?.dispose();
      _semantics = null;
      _actuel = FabCandidat.repos;
    }
  }

  void _planifie() {
    // Après l'image en cours : la sémantique de la nouvelle route n'existe
    // pas encore pendant la navigation elle-même.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _balaie();
    });
  }

  void _balaie() {
    if (!mounted || !_mecaniqueActive) return;
    final vue = _vue;
    if (vue.isEmpty) return;
    final margeBas = _margeBas + _basClavier;
    final zone = Rect.fromLTRB(
      0,
      vue.height - margeBas - maxPasFab * pasFab - tailleFab - jeuFab,
      _marge + maxPasFab * pasFab + tailleFab + jeuFab,
      vue.height,
    );
    List<Rect> obstacles;
    try {
      obstacles = _scanner.scan(vue: vue, zone: zone);
    } catch (_) {
      // Un arbre sémantique en cours de reconstruction peut lever : on
      // garde la place courante plutôt que de sauter.
      return;
    }
    final placement = place(
      vue: vue,
      obstacles: obstacles,
      marge: _marge,
      margeBas: margeBas,
      actuel: _actuel,
    );
    if (!placement.candidat.memeQue(_actuel)) {
      setState(() => _actuel = placement.candidat);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    _vue = media.size;
    _basClavier = media.viewInsets.bottom + media.padding.bottom;
    _hautSur = media.padding.top;
    final visible = _visible;
    _synchronise(visible);
    final c = _controller;
    if (!visible || c == null) return const SizedBox.shrink();

    // -12 : l'enveloppe du bouton déborde de 12 px pour les anneaux.
    final gauche = _marge + _actuel.dx - 12;
    final bas = _margeBas + _basClavier + _actuel.dy - 12;
    final largeurPanneau = math.min(380.0, _vue.width - 2 * 12);
    final basPanneau = bas + 12 + tailleFab + 8;
    final hauteurDispo = _vue.height - _hautSur - basPanneau - 8;
    final double hauteurPanneau =
        math.min(_vue.height * 0.62, hauteurDispo).clamp(180.0, math.max(180.0, _vue.height)).toDouble();

    return Stack(
      children: [
        if (c.panelOpen)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: 12,
            bottom: basPanneau,
            width: largeurPanneau,
            height: hauteurPanneau,
            child: WetroPanel(controller: c),
          ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          left: gauche,
          bottom: bas,
          child: WetroFab(
            ouvert: c.panelOpen,
            occupe: c.busy,
            phase: c.phase,
            wakeEnabled: c.wakeEnabled,
            onTap: c.togglePanel,
          ),
        ),
      ],
    );
  }
}
