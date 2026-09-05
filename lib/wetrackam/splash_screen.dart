// lib/wetrackam/splash_screen.dart
//
// Splash : fond violet plein, logo pin creux inversé (blanc) centré,
// animation de pulse discrète (prompt §3). Respecte "prefers-reduced-motion"
// via MediaQuery.disableAnimations (aucune dépendance externe ajoutée).
import 'package:flutter/material.dart';

import 'theme.dart';

class WetrackamSplashScreen extends StatefulWidget {
  const WetrackamSplashScreen({super.key});

  @override
  State<WetrackamSplashScreen> createState() => _WetrackamSplashScreenState();
}

class _WetrackamSplashScreenState extends State<WetrackamSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Scaffold(
      backgroundColor: WetrackamColors.purple,
      body: Center(
        child: reduceMotion
            ? _pin()
            : AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final scale = 1.0 + (_controller.value * 0.08);
                  return Transform.scale(scale: scale, child: child);
                },
                child: _pin(),
              ),
      ),
    );
  }

  Widget _pin() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.location_on, size: 96, color: Colors.white),
        const SizedBox(height: 12),
        Text(
          'WeTrackam',
          style: WetrackamTheme.scoreDigits(size: 28, color: Colors.white)
              .copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
