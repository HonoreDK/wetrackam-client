import 'package:flutter/material.dart';

import 'wetro_avoidance.dart';
import 'wetro_dialogue.dart';

/// Le bouton flottant Wetro. Ne sait rien de sa position : la surcouche
/// le place ; lui ne fait que se dessiner, respirer quand la voix est
/// active, et signaler d'un point que le micro est ouvert.
class WetroFab extends StatefulWidget {
  const WetroFab({
    super.key,
    required this.ouvert,
    required this.occupe,
    required this.phase,
    required this.wakeEnabled,
    required this.onTap,
  });

  final bool ouvert;
  final bool occupe;
  final WetroVoicePhase phase;
  final bool wakeEnabled;
  final VoidCallback onTap;

  @override
  State<WetroFab> createState() => _WetroFabState();
}

class _WetroFabState extends State<WetroFab> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void initState() {
    super.initState();
    _synchronise();
  }

  @override
  void didUpdateWidget(covariant WetroFab old) {
    super.didUpdateWidget(old);
    if (old.phase != widget.phase) _synchronise();
  }

  void _synchronise() {
    final anime = widget.phase != WetroVoicePhase.idle;
    if (anime && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!anime && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ecoute = widget.phase == WetroVoicePhase.attentive ||
        widget.phase == WetroVoicePhase.confirming ||
        widget.phase == WetroVoicePhase.wake;
    final couleur = switch (widget.phase) {
      WetroVoicePhase.idle => scheme.primary,
      WetroVoicePhase.wake => scheme.primary,
      WetroVoicePhase.attentive || WetroVoicePhase.confirming => scheme.tertiary,
      WetroVoicePhase.thinking => scheme.secondary,
      WetroVoicePhase.speaking => scheme.tertiary,
    };
    return Semantics(
      button: true,
      label: widget.ouvert ? 'Fermer Wetro' : 'Ouvrir Wetro, votre assistant',
      child: SizedBox(
        width: tailleFab + 24,
        height: tailleFab + 24,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Anneaux de respiration pendant l'écoute / la parole.
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                if (!_pulse.isAnimating) return const SizedBox.shrink();
                final v = _pulse.value;
                return Container(
                  width: tailleFab + 24 * v,
                  height: tailleFab + 24 * v,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: couleur.withValues(alpha: (1 - v) * 0.6),
                      width: 2,
                    ),
                  ),
                );
              },
            ),
            Material(
              color: couleur,
              elevation: 6,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onTap,
                child: SizedBox(
                  width: tailleFab,
                  height: tailleFab,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: widget.occupe
                          ? SizedBox(
                              key: const ValueKey('occupe'),
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: scheme.onPrimary,
                              ),
                            )
                          : Icon(
                              key: ValueKey(widget.ouvert ? 'ferme' : (ecoute ? 'ecoute' : 'ouvre')),
                              widget.ouvert
                                  ? Icons.close
                                  : (ecoute ? Icons.mic : Icons.auto_awesome),
                              color: scheme.onPrimary,
                              size: 26,
                            ),
                    ),
                  ),
                ),
              ),
            ),
            // Point discret : « Wetro » à l'oreille est activé.
            if (widget.wakeEnabled && !widget.ouvert)
              Positioned(
                right: 10,
                top: 10,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.phase == WetroVoicePhase.idle ? scheme.outline : scheme.tertiary,
                    border: Border.all(color: scheme.surface, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
