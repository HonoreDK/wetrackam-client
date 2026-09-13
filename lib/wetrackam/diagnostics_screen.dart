// lib/wetrackam/diagnostics_screen.dart
//
// Outil de diagnostic terrain — pour Honoré, pas pour un chauffeur en
// production. Évite de dépendre d'un accès à la console `flutter run`
// (logcat) pour vérifier l'état de la synchronisation temps réel.
// Atteint via un appui long sur le titre de l'écran d'accueil.
import 'dart:async';

import 'package:flutter/material.dart';

import 'app_logger.dart';
import 'realtime_service.dart';
import 'rtc_config_service.dart';
import 'state_sync_service.dart';
import 'theme.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rtc = RtcConfigService.current;
    final breadcrumbs = AppLogger.recentBreadcrumbs().reversed.take(80).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostic')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('Socket temps réel', [
            _row('État', RealtimeService.state.toString().split('.').last),
          ]),
          _section('Synchronisation d\'état', [
            _row('Dernier epoch connu', StateSyncService.currentEpoch?.toString() ?? '—'),
          ]),
          _section('Configuration RTC', [
            _row('Disponible', rtc.enabled ? 'oui' : 'non'),
            _row('wsUrl', rtc.wsUrl ?? '—'),
            _row('callsEnabled', rtc.policy.callsEnabled.toString()),
            _row('chatEnabled', rtc.policy.chatEnabled.toString()),
          ]),
          const SizedBox(height: 16),
          Text('Traces récentes (les plus récentes en haut)',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...breadcrumbs.map((b) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(b, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              )),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> rows) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...rows,
            ],
          ),
        ),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: WetrackamColors.slate))),
            Flexible(child: Text(value, textAlign: TextAlign.right)),
          ],
        ),
      );
}
