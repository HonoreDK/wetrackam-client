import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'wetro_dialogue.dart';

/// Onde « à la Siri » : trois sinusoïdes translucides qui respirent,
/// s'amplifient avec la voix et changent de caractère selon la phase.
///
/// Rien n'est calculé hors du peintre : le niveau sonore arrive lissé du
/// contrôleur, la phase choisit vitesse et amplitude de base.
class WetroWave extends StatefulWidget {
  const WetroWave({
    super.key,
    required this.phase,
    required this.level,
    this.height = 64,
  });

  final WetroVoicePhase phase;

  /// Intensité sonore 0..1 (déjà lissée).
  final double level;
  final double height;

  @override
  State<WetroWave> createState() => _WetroWaveState();
}

class _WetroWaveState extends State<WetroWave> with SingleTickerProviderStateMixin {
  late final AnimationController _ticker =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  double _niveau = 0;

  @override
  void didUpdateWidget(covariant WetroWave old) {
    super.didUpdateWidget(old);
    // Lissage : le niveau brut saute d'une image à l'autre ; l'onde doit
    // monter vite et redescendre doucement, comme une respiration.
    final cible = widget.level.clamp(0.0, 1.0);
    _niveau = cible > _niveau ? cible : _niveau * 0.85 + cible * 0.15;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _ticker,
        builder: (context, _) => CustomPaint(
          painter: _WavePainter(
            t: _ticker.value,
            phase: widget.phase,
            niveau: _niveau,
            couleurs: [scheme.primary, scheme.tertiary, scheme.secondary],
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.t,
    required this.phase,
    required this.niveau,
    required this.couleurs,
  });

  final double t;
  final WetroVoicePhase phase;
  final double niveau;
  final List<Color> couleurs;

  @override
  void paint(Canvas canvas, Size size) {
    final (base, vitesse, opacite) = switch (phase) {
      WetroVoicePhase.idle => (0.06, 0.6, 0.35),
      WetroVoicePhase.wake => (0.10, 0.8, 0.5),
      WetroVoicePhase.attentive => (0.16, 1.3, 0.9),
      WetroVoicePhase.confirming => (0.16, 1.3, 0.9),
      WetroVoicePhase.thinking => (0.22, 2.6, 0.7),
      WetroVoicePhase.speaking => (0.30, 1.8, 0.9),
    };
    final milieu = size.height / 2;
    // En pensée, l'onde ondule seule ; à l'écoute, elle suit la voix ; en
    // parole, elle pulse au rythme de la synthèse (simulé : la synthèse
    // ne rapporte pas son niveau).
    final pulse = phase == WetroVoicePhase.speaking
        ? 0.5 + 0.5 * math.sin(t * math.pi * 2 * 5).abs()
        : (phase == WetroVoicePhase.thinking ? 0.6 + 0.4 * math.sin(t * math.pi * 2 * 2) : 1.0);
    final amplitude = milieu * (base + 0.7 * niveau) * pulse;

    for (var i = 0; i < couleurs.length; i++) {
      final path = Path()..moveTo(0, milieu);
      final freq = 1.5 + i * 0.7;
      final dephasage = t * math.pi * 2 * vitesse * (1 + i * 0.35) + i * 1.3;
      const pas = 4.0;
      for (var x = 0.0; x <= size.width; x += pas) {
        final u = x / size.width;
        // Enveloppe en cloche : l'onde s'éteint aux bords, comme Siri.
        final enveloppe = math.pow(math.sin(u * math.pi), 1.6).toDouble();
        final y = milieu +
            amplitude * enveloppe * math.sin(u * math.pi * 2 * freq + dephasage) * (i.isEven ? 1 : -1);
        path.lineTo(x, y);
      }
      final peinture = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 - i * 0.4
        ..strokeCap = StrokeCap.round
        ..color = couleurs[i].withValues(alpha: opacite * (1 - i * 0.22));
      canvas.drawPath(path, peinture);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.t != t || old.phase != phase || old.niveau != niveau;
}
