// lib/wetrackam/fleet_screen.dart
//
// Lot 6/7 — écran « Collègues » (contrat v5 §6, PROMPT-MOBILE-HONORE.md §4).
//
// v13 — VRAIE CARTE. La version précédente affichait une simple liste et
// documentait ce choix comme une « simplification assumée » : ce n'en était
// pas une du point de vue de l'exploitation, la carte des collègues est une
// fonctionnalité du contrat, pas un confort. Elle est ici implémentée avec
// flutter_map + tuiles OpenStreetMap :
//   - aucune clé API, aucun compte, aucun quota à surveiller ;
//   - aucune configuration native Android/iOS (contrairement à Google Maps) ;
//   - les coordonnées viennent de `latitude`/`longitude` déjà servis par
//     MobileFleetResource.java — le serveur n'a rien à changer.
//
// Les RÈGLES DE DONNÉES du contrat sont inchangées et intégralement
// respectées : sondage HTTP toutes les 10 s uniquement écran visible ET
// application au premier plan, animation par la socket entre deux sondages,
// point de plus de 3 minutes grisé (`stale`), disparition d'un collègue de
// la carte SANS perte de joignabilité (il reste appelable depuis l'annuaire).
//
// La bascule carte/liste est conservée : en zone sans données, une carte sans
// tuiles est inutilisable alors que la liste, elle, reste lisible.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'api_client.dart';
import 'app_logger.dart';
import 'call_service.dart';
import 'fleet_units.dart';
import 'conversation_screen.dart';
import 'in_call_screen.dart';
import 'peer_name_cache.dart';
import 'realtime_service.dart';
import 'rtc_config_service.dart';
import 'theme.dart';

class FleetScreen extends StatefulWidget {
  const FleetScreen({super.key});

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _peers = [];
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  bool _visible = true;
  bool _mapMode = true;
  bool _followedOnce = false;
  int? _selectedDriverId;
  StreamSubscription<Map<String, dynamic>>? _socketSub;
  final MapController _mapController = MapController();

  /// Douala — repli tant qu'aucune position n'est connue. Jamais (0,0) :
  /// un point au large du golfe de Guinée donne l'impression d'un bug.
  static const _fallbackCenter = LatLng(4.0511, 9.7679);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    RealtimeService.ensureConnected();
    // v6 §7 : le sondage HTTP PEUPLE la carte, la socket l'ANIME.
    _socketSub = RealtimeService.messages.listen(_onFleetPosition);
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _socketSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // §6 checklist : « Application en arrière-plan → requêtes carte arrêtées. »
    if (state == AppLifecycleState.resumed) {
      _visible = true;
      _startPolling();
    } else {
      _visible = false;
      _pollTimer?.cancel();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_visible) _load();
    });
  }

  Future<void> _placeCall(int driverId, String name) async {
    if (CallService.phase != CallPhase.idle) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Un appel est déjà en cours.')));
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => const InCallScreen()));
    await CallService.placeCall(peerId: driverId, peerName: name);
  }

  /// v6 §7 : anime les points déjà peuplés par le sondage HTTP. Ignore un
  /// `driverId` inconnu : le REST reste la seule source qui « peuple ».
  ///
  /// v13 : applique aussi latitude/longitude — la version précédente ne
  /// reprenait que la vitesse, ce qui était sans effet visible en liste mais
  /// aurait figé les marqueurs de la carte entre deux sondages de 10 s.
  void _onFleetPosition(Map<String, dynamic> message) {
    if (message['type'] != 'fleet.position') return;
    final driverId = message['driverId'] as int?;
    if (driverId == null || !mounted) return;
    final index = _peers.indexWhere((p) => p['driverId'] == driverId);
    if (index == -1) return;
    // CORRECTIF v13 — UNITÉS. Le REST expose `speedKmh` (déjà converti par
    // MobileFleetResource : nœuds × 1,852). La socket, elle, relaie
    // `position.getSpeed()` BRUT, c'est-à-dire des NŒUDS
    // (FleetLiveBroadcastHandler.java). L'ancien code recopiait cette valeur
    // dans `speedKmh` sans conversion : entre deux sondages HTTP, un camion à
    // 90 km/h s'affichait à 49 km/h. Bug silencieux, jamais journalisé.
    final speedKnots = message['speed'] as num?;
    final speedKmh = FleetUnits.kmhFromSocketKnots(speedKnots);
    final lat = (message['latitude'] as num?)?.toDouble();
    final lon = (message['longitude'] as num?)?.toDouble();
    setState(() {
      _peers[index] = {
        ..._peers[index],
        if (speedKmh != null) 'speedKmh': speedKmh,
        if (speedKnots != null) 'motion': FleetUnits.inMotionFromSocketKnots(speedKnots),
        if (lat != null) 'latitude': lat,
        if (lon != null) 'longitude': lon,
        'stale': false, // position fraîche reçue à l'instant par la socket
      };
    });
  }

  Future<void> _load() async {
    try {
      final data = await WetrackamApiClient.fetchFleetLive();
      final peers = (data['peers'] as List? ?? []).cast<Map<String, dynamic>>();
      // v13 : mémorise les noms pour l'écran d'appel natif (le protocole
      // d'appel ne transporte aucun nom — voir peer_name_cache.dart).
      unawaited(PeerNameCache.rememberAll(peers, 'driverName'));
      if (mounted) {
        setState(() {
          _peers = peers;
          _loading = false;
          _error = null;
        });
        _centerOnFirstLoad();
      }
    } on TenantDisabledException {
      if (mounted) setState(() { _loading = false; _error = 'Service indisponible.'; });
    } catch (error) {
      AppLogger.error('fleet_load_failed', error);
      if (mounted) setState(() { _loading = false; _error = 'Connexion impossible.'; });
    }
  }

  // -----------------------------------------------------------------
  // Géométrie
  // -----------------------------------------------------------------
  static LatLng? _positionOf(Map<String, dynamic> peer) {
    final lat = (peer['latitude'] as num?)?.toDouble();
    final lon = (peer['longitude'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    // Coordonnées hors bornes ou (0,0) exact : un capteur qui n'a pas encore
    // de fix renvoie souvent l'un ou l'autre — ne jamais les afficher, sinon
    // la carte se recentre sur l'Atlantique et « perd » la flotte réelle.
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    if (lat == 0 && lon == 0) return null;
    return LatLng(lat, lon);
  }

  List<Map<String, dynamic>> get _located =>
      _peers.where((p) => _positionOf(p) != null).toList();

  void _centerOnFirstLoad() {
    if (_followedOnce || !_mapMode) return;
    final located = _located;
    if (located.isEmpty) return;
    _followedOnce = true;
    // Un seul recentrage automatique, au premier chargement : recentrer à
    // chaque sondage de 10 s empêcherait le chauffeur de déplacer la carte.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitAll());
  }

  void _fitAll() {
    final points = _located.map(_positionOf).whereType<LatLng>().toList();
    if (points.isEmpty) return;
    if (points.length == 1) {
      _mapController.move(points.first, 14);
      return;
    }
    try {
      _mapController.fitCamera(CameraFit.coordinates(
        coordinates: points,
        padding: const EdgeInsets.all(56),
        maxZoom: 15,
      ));
    } catch (error) {
      // fitCamera lève si la carte n'est pas encore montée (bascule
      // liste → carte pendant un sondage) — sans conséquence.
      AppLogger.breadcrumb('fleet_fit_skipped');
    }
  }

  // -----------------------------------------------------------------
  // Rendu
  // -----------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final visibility = RtcConfigService.current.policy.fleetVisibility;
    if (visibility == 'none') {
      // Filet de sécurité : l'onglet est normalement déjà masqué en amont
      // (eligibility_screen.dart).
      return const Scaffold(body: Center(child: Text('Fonction non disponible.')));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Collègues en service'),
        actions: [
          IconButton(
            tooltip: _mapMode ? 'Afficher la liste' : 'Afficher la carte',
            icon: Icon(_mapMode ? Icons.view_list_outlined : Icons.map_outlined),
            onPressed: () => setState(() {
              _mapMode = !_mapMode;
              _selectedDriverId = null;
            }),
          ),
          if (_mapMode)
            IconButton(
              tooltip: 'Recentrer',
              icon: const Icon(Icons.center_focus_strong_outlined),
              onPressed: _fitAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : _mapMode
                  ? _mapView()
                  : _listView(),
    );
  }

  Widget _errorView() => ListView(children: [
        const SizedBox(height: 80),
        Center(child: Text(_error!)),
        const SizedBox(height: 16),
        Center(child: OutlinedButton(onPressed: _load, child: const Text('Réessayer'))),
      ]);

  Widget _listView() {
    return RefreshIndicator(
      onRefresh: _load,
      child: _peers.isEmpty
          ? ListView(children: const [
              SizedBox(height: 80),
              Center(child: Text('Aucun collègue en service actuellement.')),
            ])
          : ListView.builder(
              itemCount: _peers.length,
              itemBuilder: (context, index) => _peerTile(_peers[index]),
            ),
    );
  }

  Widget _mapView() {
    final located = _located;
    final center = located.isEmpty
        ? _fallbackCenter
        : _positionOf(located.first) ?? _fallbackCenter;
    final selected = _selectedDriverId == null
        ? null
        : _peers.cast<Map<String, dynamic>?>().firstWhere(
              (p) => p?['driverId'] == _selectedDriverId,
              orElse: () => null,
            );
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 13,
            minZoom: 3,
            maxZoom: 18,
            onTap: (_, _) => setState(() => _selectedDriverId = null),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              // Exigé par la politique d'usage des tuiles OSM : un agent
              // identifiable. Omettre ce champ expose à un blocage du réseau
              // de tuiles côté OSM, donc à une carte grise en production.
              userAgentPackageName: 'cm.wetrackam.driver',
              maxNativeZoom: 19,
            ),
            MarkerLayer(markers: [for (final peer in located) _marker(peer)]),
          ],
        ),
        if (located.isEmpty)
          const Positioned(
            left: 16,
            right: 16,
            top: 16,
            child: _MapBanner('Aucune position disponible pour le moment.'),
          )
        else if (located.length < _peers.length)
          Positioned(
            left: 16,
            right: 16,
            top: 16,
            child: _MapBanner(
                '${_peers.length - located.length} collègue(s) sans position — visibles dans la liste.'),
          ),
        if (selected != null)
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Card(
              elevation: 6,
              child: _peerTile(selected),
            ),
          ),
        // Attribution OSM — obligation légale d'utilisation des tuiles.
        Positioned(
          right: 4,
          bottom: 2,
          child: Container(
            color: Colors.white70,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: const Text('© OpenStreetMap', style: TextStyle(fontSize: 9)),
          ),
        ),
      ],
    );
  }

  Marker _marker(Map<String, dynamic> peer) {
    final point = _positionOf(peer)!;
    final stale = peer['stale'] == true;
    final self = peer['self'] == true;
    final moving = peer['motion'] == true;
    final driverId = peer['driverId'] as int;
    final color = self
        ? WetrackamColors.signalViolet
        : (stale ? Colors.grey : WetrackamColors.purple);
    return Marker(
      point: point,
      width: 44,
      height: 44,
      child: GestureDetector(
        onTap: () => setState(() => _selectedDriverId = driverId),
        child: Opacity(
          opacity: stale ? 0.55 : 1.0, // §6 : position de plus de 3 min grisée
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: _selectedDriverId == driverId ? Colors.white : Colors.white70,
                width: _selectedDriverId == driverId ? 3 : 2,
              ),
            ),
            child: Icon(
              moving ? Icons.local_shipping : Icons.local_shipping_outlined,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }

  Widget _peerTile(Map<String, dynamic> peer) {
    final stale = peer['stale'] == true;
    final moving = peer['motion'] == true;
    final self = peer['self'] == true;
    final driverId = peer['driverId'] as int;

    final chatEnabled = RtcConfigService.current.policy.chatEnabled;
    final callsEnabled = RtcConfigService.current.policy.callsEnabled;

    return Opacity(
      opacity: stale ? 0.5 : 1.0,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: self ? WetrackamColors.signalViolet : WetrackamColors.purple,
          child: Icon(moving ? Icons.local_shipping : Icons.local_shipping_outlined,
              color: Colors.white),
        ),
        title: Text('${peer['driverName'] ?? '—'}${self ? ' (vous)' : ''}'),
        subtitle: Text([
          peer['vehicleName'] ?? '',
          if (peer['speedKmh'] != null) '${peer['speedKmh']} km/h',
          stale ? 'Position ancienne' : null,
          _positionOf(peer) == null ? 'Sans position' : null,
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · ')),
        onTap: _positionOf(peer) == null
            ? null
            : () {
                setState(() {
                  _mapMode = true;
                  _selectedDriverId = driverId;
                });
                _mapController.move(_positionOf(peer)!, 15);
              },
        trailing: self
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (callsEnabled)
                    IconButton(
                      icon: const Icon(Icons.call_outlined),
                      onPressed: () =>
                          _placeCall(driverId, peer['driverName']?.toString() ?? '—'),
                    ),
                  if (chatEnabled)
                    IconButton(
                      icon: const Icon(Icons.message_outlined),
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ConversationScreen(
                                  peerId: driverId,
                                  peerName: peer['driverName']?.toString() ?? '—'))),
                    ),
                ],
              ),
      ),
    );
  }
}

class _MapBanner extends StatelessWidget {
  const _MapBanner(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          textAlign: TextAlign.center),
    );
  }
}
