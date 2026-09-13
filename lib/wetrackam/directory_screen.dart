// lib/wetrackam/directory_screen.dart
//
// Lot 6/7 — Annuaire (contrat v5 §7, PROMPT-MOBILE-HONORE.md §5).
// Contrairement à la carte, inclut les chauffeurs hors service.
import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'app_logger.dart';
import 'call_service.dart';
import 'conversation_screen.dart';
import 'in_call_screen.dart';
import 'peer_name_cache.dart';
import 'realtime_service.dart';
import 'rtc_config_service.dart';
import 'theme.dart';

class DirectoryScreen extends StatefulWidget {
  const DirectoryScreen({super.key});

  @override
  State<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends State<DirectoryScreen> {
  List<Map<String, dynamic>> _drivers = [];
  bool _loading = true;
  String? _error;
  final _searchController = TextEditingController();
  Timer? _debounce;
  StreamSubscription<Map<String, dynamic>>? _presenceSub;
  final Set<int> _onlineIds = {};

  @override
  void initState() {
    super.initState();
    // §5 : "Purge l'annuaire en cache à chaque authentification" — cet
    // écran ne persiste jamais sa liste au-delà de son propre cycle de
    // vie (état en mémoire seulement, jamais SharedPreferences), donc
    // rien à purger explicitement — la contrainte est respectée par
    // construction plutôt que par une purge active.
    // Anomalie corrigée (crash reproduit en test réel) : ensureConnected()
    // peut lever NetworkException (timeout, ou disconnect() concurrent) —
    // appelé ici sans await ni gestion, une exception devenait "Unhandled
    // Exception" à chaque bascule réseau un peu agressive.
    unawaited(RealtimeService.ensureConnected().catchError((error) {
      AppLogger.error('directory_realtime_unavailable', error);
    }));
    _presenceSub = RealtimeService.messages.listen(_onRealtimeMessage);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _presenceSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onRealtimeMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == 'presence.state') {
      final online = (message['online'] as List?)?.cast<int>() ?? [];
      setState(() {
        _onlineIds
          ..clear()
          ..addAll(online);
      });
    } else if (type == 'presence') {
      final driverId = message['driverId'] as int?;
      final online = message['online'] == true;
      if (driverId == null) return;
      setState(() {
        if (online) {
          _onlineIds.add(driverId);
        } else {
          _onlineIds.remove(driverId);
        }
      });
    }
  }

  Future<void> _load({String? query}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await WetrackamApiClient.fetchDirectory(query: query);
      final drivers = (data['drivers'] as List? ?? []).cast<Map<String, dynamic>>();
      // v13 : le protocole d'appel ne transporte aucun nom — on mémorise
      // ici ceux de l'annuaire pour l'écran d'appel plein écran natif.
      unawaited(PeerNameCache.rememberAll(drivers, 'name'));
      setState(() {
        _drivers = drivers;
      });
      final ids = drivers.map((d) => d['driverId'] as int).toList();
      if (ids.isNotEmpty) RealtimeService.queryPresence(ids);
    } on TenantDisabledException {
      // §16 : incident d'isolation potentiel ou kill-switch — dans les
      // deux cas, on ne laisse pas une liste obsolète à l'écran.
      setState(() {
        _drivers = [];
        _error = 'Service indisponible.';
      });
    } catch (error) {
      AppLogger.error('directory_load_failed', error);
      setState(() => _error = 'Connexion impossible. Réessayez.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _load(query: value));
  }

  /// Navigation IMMÉDIATE vers InCallScreen (qui affiche "Appel en
  /// cours...") — placeCall() complète ensuite en arrière-plan et fait
  /// évoluer l'écran via CallService.phaseChanges. Règle 3 du contrat (un
  /// seul appel actif) : bouton ignoré si un appel est déjà en cours,
  /// plutôt que de laisser l'utilisateur croire qu'il en démarre un
  /// second qui sera silencieusement rejeté côté service.
  Future<void> _placeCall(int driverId, String name) async {
    if (CallService.phase != CallPhase.idle) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Un appel est déjà en cours.')));
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => const InCallScreen()));
    await CallService.placeCall(peerId: driverId, peerName: name);
  }

  @override
  Widget build(BuildContext context) {
    final chatEnabled = RtcConfigService.current.policy.chatEnabled;
    return Scaffold(
      appBar: AppBar(title: const Text('Annuaire')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: const InputDecoration(
                hintText: 'Rechercher un collègue',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _drivers.isEmpty
                    ? const Center(child: Text('Aucun collègue trouvé.'))
                    : ListView.builder(
                        itemCount: _drivers.length,
                        itemBuilder: (context, index) => _driverTile(_drivers[index], chatEnabled),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _driverTile(Map<String, dynamic> driver, bool chatEnabled) {
    final driverId = driver['driverId'] as int;
    final self = driver['self'] == true;
    final contactable = driver['contactable'] == true && !self;
    final online = _onlineIds.contains(driverId);
    final phoneHidden = driver['phoneHidden'] == true;

    return ListTile(
      leading: Stack(
        children: [
          const CircleAvatar(child: Icon(Icons.person)),
          if (online)
            Positioned(
              right: 0, bottom: 0,
              child: Container(
                width: 12, height: 12,
                decoration: const BoxDecoration(
                    color: WetrackamColors.signalViolet, shape: BoxShape.circle),
              ),
            ),
        ],
      ),
      title: Text(driver['name']?.toString() ?? '—'),
      subtitle: Text([
        if (driver['vehicleName'] != null) driver['vehicleName'],
        driver['inService'] == true ? 'En service' : 'Hors service',
        if (phoneHidden) 'Numéro masqué par l\'entreprise',
      ].join(' · ')),
      // §5 : contactable == false → ni bouton d'appel, ni bouton message,
      // le serveur refuserait de toute façon (peerUnavailable).
      trailing: !contactable
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (RtcConfigService.current.policy.callsEnabled)
                  IconButton(
                    icon: const Icon(Icons.call_outlined),
                    onPressed: () => _placeCall(driverId, driver['name']?.toString() ?? '—'),
                  ),
                if (chatEnabled)
                  IconButton(
                    icon: const Icon(Icons.message_outlined),
                    onPressed: () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => ConversationScreen(
                            peerId: driverId, peerName: driver['name']?.toString() ?? '—'))),
                  ),
              ],
            ),
    );
  }
}
