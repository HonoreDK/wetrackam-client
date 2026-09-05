// lib/wetrackam/eligibility_screen.dart
//
// §6 — "C'est le seul appel qui construit l'écran d'accueil." Appelé à
// l'ouverture, au retour au premier plan, après 202/409, après expiration
// de ttlSeconds, et au pull-to-refresh (tous couverts ci-dessous).
//
// §6.3 : le `mode` ne doit JAMAIS être codé en dur autrement que par ce
// switch — un mode inconnu est traité comme ASSIGNED (§6.3, "comportement
// le plus sûr").
import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'app_logger.dart';
import 'directory_screen.dart';
import 'disabled_tenant_screen.dart';
import 'diagnostics_screen.dart';
import 'driver_identity_service.dart';
import 'error_catalog.dart';
import 'fleet_screen.dart';
import 'main_navigation_gate.dart';
import 'pin_auth_screen.dart';
import 'push_notifications_service.dart';
import 'realtime_service.dart';
import 'rtc_config_service.dart';
import 'shift_service.dart';
import 'state_sync_service.dart';
import 'theme.dart';

class EligibilityScreen extends StatefulWidget {
  const EligibilityScreen({super.key});

  @override
  State<EligibilityScreen> createState() => _EligibilityScreenState();
}

class _EligibilityScreenState extends State<EligibilityScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  Timer? _ttlTimer;
  Timer? _chronoTimer; // checklist B10 : chrono en direct pendant le service
  String? _selectedFreePoolDevice;
  bool _actionInProgress = false;

  StreamSubscription<void>? _reloadSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Bug trouvé en test réel (retour terrain) : la socket temps réel
    // n'était ouverte QUE par les écrans Annuaire/Collègues/Conversation
    // (voir directory_screen.dart, fleet_screen.dart, conversation_screen
    // .dart) — jamais par l'écran d'accueil. Or c'est justement ICI que le
    // message control `assignment.changed` doit arriver en direct quand un
    // manager affecte un véhicule : un chauffeur qui reste simplement sur
    // cet écran, sans jamais ouvrir le chat/la carte, n'avait donc AUCUN
    // canal temps réel ouvert pour le recevoir. Le sondage TTL et le
    // rafraîchissement au retour au premier plan masquaient partiellement
    // le problème (l'affectation finissait par apparaître, mais jamais
    // "en direct" comme prévu par la synchronisation v6).
    RealtimeService.ensureConnected();
    // v6 : rechargement automatique sur epoch/événement control, sans
    // action du chauffeur — c'est tout le principe de la synchronisation
    // bilatérale ("le téléphone n'a plus à deviner ce qui a changé").
    _reloadSub = StateSyncService.reloadRequests.listen((_) {
      if (mounted) _load();
    });
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ttlTimer?.cancel();
    _chronoTimer?.cancel();
    _reloadSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // §6 : "au retour au premier plan".
    if (state == AppLifecycleState.resumed) _load();
  }

  /// Horodatage de la dernière lecture RÉUSSIE de /shift/eligibility.
  /// Sert de garde de fraîcheur avant la prise de service (voir _startShift).
  DateTime? _loadedAt;

  /// Au-delà de ce délai, l'écran affiché n'est plus considéré comme une base
  /// fiable pour DÉMARRER un service. 30 s : assez large pour ne pas ajouter
  /// un appel à chaque appui, assez court pour fermer la fenêtre "le manager
  /// vient de me suspendre / de me retirer le véhicule".
  static const Duration _freshnessWindow = Duration(seconds: 30);

  Future<void> _load() async {
    setState(() {
      _loading = _data == null; // pas de spinner plein écran sur un refresh silencieux
      _error = null;
    });
    try {
      final data = await WetrackamApiClient.fetchEligibility();
      _loadedAt = DateTime.now();
      _ttlTimer?.cancel();
      final ttl = (data['ttlSeconds'] as num?)?.toInt() ?? 43200;
      // §6 : "après expiration de ttlSeconds" — re-fetch automatique.
      _ttlTimer = Timer(Duration(seconds: ttl), _load);
      if (mounted) {
        setState(() {
          _data = data;
          _loading = false;
        });
      }
    } on TenantDisabledException {
      if (mounted) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const DisabledTenantScreen()));
      }
    } on SessionInvalidException catch (error) {
      // La purge (token seul ou tout) a déjà été appliquée par api_client.
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const PinAuthScreen()),
        );
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorCatalog.unauthorized(error.reason)),
          duration: const Duration(seconds: 5),
        ));
      }
    } on NetworkException {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _data == null
              ? 'Connexion impossible. Vérifiez le réseau.'
              : null; // on garde le dernier écran valide si on l'a déjà (§ ttl = cache)
        });
      }
    } catch (error) {
      AppLogger.error('eligibility_load_failed', error);
      if (mounted) setState(() => _loading = false);
    }
  }

  // §6.3 : POST /shift/start avec le bon body selon le mode.
  Future<void> _startShift() async {
    setState(() => _actionInProgress = true);
    // GARDE DE FRAÎCHEUR — l'affichage peut dater (TTL jusqu'à 12 h, socket
    // coupée, événement `control` perdu). Démarrer un service sur un écran
    // périmé, c'est démarrer alors qu'on vient d'être suspendu ou que le
    // véhicule a été réaffecté. On relit donc l'éligibilité juste avant, et
    // on renonce si elle n'autorise plus le démarrage. Le serveur reste
    // l'arbitre final (il refusera de toute façon), mais l'utilisateur voit
    // ici un écran cohérent au lieu d'une erreur brute.
    if (_loadedAt == null ||
        DateTime.now().difference(_loadedAt!) > _freshnessWindow) {
      await _load();
      if (!mounted) return;
      if (_data == null || _data!['eligible'] != true) {
        setState(() => _actionInProgress = false);
        return; // _load() a déjà mis à jour l'écran avec la raison réelle
      }
    }
    final mode = _data!['mode'] as String? ?? 'ASSIGNED';
    try {
      final deviceUniqueId = mode == 'FREE_POOL' ? _selectedFreePoolDevice : null;
      if (mode == 'FREE_POOL' && deviceUniqueId == null) {
        setState(() => _actionInProgress = false);
        return; // bouton normalement désactivé dans ce cas, garde-fou
      }
      await ShiftService.start(deviceUniqueId: deviceUniqueId);
      AppLogger.breadcrumb('shift_started');
      await _load();
    } on TenantDisabledException {
      // Lot 3 : bug trouvé — ce cas tombait avant dans `on ApiException`
      // (TenantDisabledException en hérite) et affichait un message
      // générique au lieu de rediriger vers l'écran kill-switch.
      if (mounted) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const DisabledTenantScreen()));
      }
    } on SessionInvalidException catch (error) {
      // Lot 3 : même bug — une session invalidée pendant la prise de
      // service affichait "Impossible de prendre le service" au lieu de
      // renvoyer à l'écran PIN avec le bon message.
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainNavigationGate()),
          (route) => false,
        );
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ErrorCatalog.unauthorized(error.reason))));
      }
    } on NetworkException {
      // Lot 3 : bug trouvé — cette clause était placée APRÈS `on
      // ApiException`, qui l'interceptait avant elle (NetworkException en
      // hérite) : elle n'était jamais atteinte, le message "Connexion
      // impossible" ne s'affichait donc jamais réellement.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ErrorCatalog.transverse(status: null))));
      }
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ErrorCatalog.shiftStart(error.error))));
        if (error.error == 'deviceNotFound' ||
            error.error == 'noVehicleAssigned' ||
            error.error == 'vehicleAlreadyInService') {
          await _load(); // rafraîchir comme demandé par le contrat
        }
      }
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<void> _endShift() async {
    setState(() => _actionInProgress = true);
    try {
      final response = await ShiftService.end();
      AppLogger.breadcrumb('shift_ended');
      // Checklist C7 — bug trouvé en vérification : `tokenRevoked` était
      // renvoyé par le serveur mais jamais traité nulle part dans l'app.
      // Sans ce bloc, le chauffeur restait sur l'écran d'accueil avec un
      // token en réalité déjà révoqué côté serveur — la prochaine action
      // aurait échoué en 401 de façon confuse plutôt que de le ramener
      // proprement à l'écran PIN tout de suite.
      if (response['tokenRevoked'] == true) {
        await DriverIdentityService.purgeTokenOnly();
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const MainNavigationGate()),
            (route) => false,
          );
        }
        return;
      }
      await _load();
    } on TenantDisabledException {
      if (mounted) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const DisabledTenantScreen()));
      }
    } on SessionInvalidException catch (error) {
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainNavigationGate()),
          (route) => false,
        );
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ErrorCatalog.unauthorized(error.reason))));
      }
    } on ApiException catch (error) {
      // Lot 3 : bug trouvé — le catalogue shiftEnd() existait mais n'était
      // jamais appelé ; un message générique s'affichait pour tous les cas
      // (y compris noActiveShift, censé rester silencieux, §9).
      final message = ErrorCatalog.shiftEnd(error.error);
      if (mounted && message.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
      await _load(); // noActiveShift notamment : l'état a bougé, se resynchroniser
    } catch (error) {
      AppLogger.error('shift_end_failed', error);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ErrorCatalog.transverse(status: null))));
      }
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<void> _notifyManager(String reason) async {
    try {
      final result = await WetrackamApiClient.notifyManager(reason);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorCatalog.notifyManagerResult(
            sent: result['sent'] == true,
            reason: result['reason'] as String?,
            retryAfterSeconds: (result['retryAfterSeconds'] as num?)?.toInt(),
          )),
        ));
      }
    } on TenantDisabledException {
      if (mounted) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const DisabledTenantScreen()));
      }
    } on SessionInvalidException catch (error) {
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainNavigationGate()),
          (route) => false,
        );
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ErrorCatalog.unauthorized(error.reason))));
      }
    } catch (error) {
      // Lot 3 : auparavant totalement silencieux (juste un log) — le
      // chauffeur appuyait sur le bouton sans jamais savoir si ça avait
      // fonctionné ou non.
      AppLogger.error('notify_manager_failed', error);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ErrorCatalog.transverse(status: null))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
          child: const Text('WeTrackam'),
        ),
        actions: [
          if (RtcConfigService.isAvailable) _communicationMenu(),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Se déconnecter',
            onPressed: () => _disconnect(context),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _networkErrorView()
              : RefreshIndicator(onRefresh: _load, child: _content()),
    );
  }

  /// DELTA-v5-vers-v6 §6 (`POST /api/mobile/unbind`) : déliaison volontaire
  /// depuis l'app. Purge locale uniquement après confirmation serveur
  /// (200) — sur échec réseau, on ne purge pas, on laisse réessayer.
  Future<void> _disconnect(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Se déconnecter'),
        content: const Text(
            'Ce téléphone sera délié de votre compte. Toutes les données locales seront effacées.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirmer')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await WetrackamApiClient.unbind();
      await PushNotificationsService.onUnbind();
      await DriverIdentityService.purgeAll();
      if (context.mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainNavigationGate()),
          (route) => false,
        );
      }
    } catch (error) {
      AppLogger.error('disconnect_failed', error);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Déconnexion impossible. Vérifiez le réseau et réessayez.')));
      }
    }
  }

  Widget _communicationMenu() {
    final policy = RtcConfigService.current.policy;
    final items = <PopupMenuEntry<String>>[];
    if (policy.fleetVisibility != 'none') {
      items.add(const PopupMenuItem(value: 'fleet', child: Text('Collègues en service')));
    }
    if (policy.chatEnabled) {
      items.add(const PopupMenuItem(value: 'directory', child: Text('Annuaire')));
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      icon: const Icon(Icons.people_outline),
      itemBuilder: (_) => items,
      onSelected: (value) {
        if (value == 'fleet') {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const FleetScreen()));
        } else if (value == 'directory') {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const DirectoryScreen()));
        }
      },
    );
  }

  Widget _networkErrorView() => ListView(children: [
        const SizedBox(height: 80),
        const Icon(Icons.wifi_off, size: 48, color: WetrackamColors.slate),
        const SizedBox(height: 12),
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Center(child: FilledButton(onPressed: _load, child: const Text('Réessayer'))),
      ]);

  Widget _content() {
    final data = _data!;
    final shiftActive = data['shiftActive'] == true;
    if (shiftActive) return _shiftActiveView(data);
    // Bug évité en vérification : sans cet arrêt explicite, le chrono
    // démarré dans _shiftActiveView() continuerait de tourner (setState
    // chaque seconde) même après la fin du service, puisque cette
    // méthode ne serait alors plus jamais appelée pour le stopper elle-même.
    _chronoTimer?.cancel();
    _chronoTimer = null;
    return _shiftInactiveView(data);
  }

  // -----------------------------------------------------------------
  // Service en cours (§6.4, cas particulier)
  // -----------------------------------------------------------------
  Widget _shiftActiveView(Map<String, dynamic> data) {
    final activeShift = data['activeShift'] as Map<String, dynamic>?;
    final startedAt = data['startedAt'] != null ? DateTime.tryParse(data['startedAt']) : null;
    // Checklist B10 : "chrono basé sur serverTime" — startedAt vient de
    // /shift/eligibility (heure serveur), et Timer.periodic ne fait que
    // rafraîchir l'affichage local de la différence entre maintenant et
    // ce point de référence serveur, sans jamais recalculer depuis
    // l'horloge du téléphone seule (bug trouvé en vérification checklist :
    // l'ancien code affichait uniquement l'heure de début, statique,
    // jamais une durée qui avance).
    if (startedAt != null && _chronoTimer == null) {
      _chronoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (startedAt == null) {
      _chronoTimer?.cancel();
      _chronoTimer = null;
    }
    final elapsed = startedAt != null ? DateTime.now().difference(startedAt) : null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: WetrackamColors.purple,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              const Icon(Icons.local_shipping, color: Colors.white, size: 40),
              const SizedBox(height: 12),
              Text(activeShift?['deviceName']?.toString() ?? 'Véhicule',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center),
              if (elapsed != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_formatElapsed(elapsed),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                ),
              if (startedAt != null)
                Text('Depuis ${_formatTime(startedAt)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ]),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.tonal(
          onPressed: _actionInProgress ? null : _endShift,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: _actionInProgress
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Terminer mon service'),
        ),
      ],
    );
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _formatElapsed(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h}h ${m.toString().padLeft(2, '0')}min';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // -----------------------------------------------------------------
  // Pas de service actif — variante selon `mode` et `blockReason`
  // -----------------------------------------------------------------
  Widget _shiftInactiveView(Map<String, dynamic> data) {
    final rawMode = data['mode'] as String?;
    // Checklist B6 : "Mode inconnu renvoyé par le serveur : traité comme
    // ASSIGNED, incident journalisé." Le repli sur ASSIGNED était déjà
    // correct (rawMode ?? 'ASSIGNED' + tout ce qui n'est pas
    // explicitement 'FREE_POOL' tombe dans le rendu de type ASSIGNED plus
    // bas) — seule la journalisation manquait, trouvée en vérification
    // checklist.
    const knownModes = {'ASSIGNED', 'ASSIGNED_WITH_FALLBACK', 'FREE_POOL'};
    if (rawMode != null && !knownModes.contains(rawMode)) {
      AppLogger.error('eligibility_unknown_mode', rawMode);
    }
    final mode = rawMode ?? 'ASSIGNED';
    final eligible = data['eligible'] == true;
    final blockReason = data['blockReason'] as String?;
    final pendingAssignment = data['pendingAssignment'] == true;
    final notificationsConfigured = data['notificationsConfigured'] == true;
    final reportedUnavailable = data['reportedUnavailable'] == true;
    final driverName = data['driverName'] as String?;

    // Lot 1 — vocabulaire de /shift/notify-manager ≠ vocabulaire de
    // blockReason (confirmé par DriverShiftScreen.jsx, Bloc 6) :
    //   blockReason 'noVehicleAssigned'      -> reason 'noVehicle'
    //   blockReason 'vehicleAlreadyInService' -> reason 'vehicleUnavailable'
    // Envoyer blockReason tel quel casserait silencieusement l'appel côté
    // serveur si 'noVehicleAssigned' n'est pas une valeur de reason valide.
    String? notifyReasonFor(String? reason) => switch (reason) {
          'noVehicleAssigned' => 'noVehicle',
          'vehicleAlreadyInService' => 'vehicleUnavailable',
          _ => null, // pas de bouton pour les autres motifs (ex. licenseExpired)
        };
    final blockNotifyReason = notifyReasonFor(blockReason);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (driverName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('Bonjour $driverName',
                style: Theme.of(context).textTheme.headlineMedium),
          ),
        if (pendingAssignment)
          Card(
            color: WetrackamColors.warning.withValues(alpha: 0.15),
            child: ListTile(
              leading: const Icon(Icons.info_outline, color: WetrackamColors.warning),
              title: const Text('Un changement de véhicule est prévu'),
              subtitle: Text(data['pendingAssignmentDeviceName'] != null
                  ? 'Prochain véhicule : ${data['pendingAssignmentDeviceName']}'
                  : 'Il s\'appliquera à la fin de votre prochain service.'),
            ),
          ),
        const SizedBox(height: 8),
        if (mode == 'FREE_POOL')
          _freePoolCard(data)
        else
          _assignedVehicleCard(data, mode),
        if (blockReason != null) ...[
          const SizedBox(height: 16),
          Card(
            color: WetrackamColors.error.withValues(alpha: 0.1),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  ErrorCatalog.blockReason(blockReason,
                      licenseExpiry: data['licenseExpiry'] as String?),
                  style: const TextStyle(color: WetrackamColors.error),
                ),
                if (blockNotifyReason != null && notificationsConfigured)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextButton(
                      onPressed: () => _notifyManager(blockNotifyReason),
                      child: const Text('Prévenir mon manager'),
                    ),
                  ),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: (!eligible || _actionInProgress || (mode == 'FREE_POOL' && _selectedFreePoolDevice == null))
              ? null
              : _startShift,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: _actionInProgress
              ? const SizedBox(height: 20, width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Prendre mon service'),
        ),
        // Lot 1 — garde-fou reportedUnavailable (DriverShiftScreen.jsx) :
        // une fois signalé, le bouton disparaît pour éviter le spam manager.
        if (mode == 'ASSIGNED_WITH_FALLBACK' && eligible && !reportedUnavailable)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton(
              onPressed: () => _notifyManager('vehicleUnavailable'),
              child: const Text('Ce véhicule est indisponible'),
            ),
          ),
      ],
    );
  }

  Widget _assignedVehicleCard(Map<String, dynamic> data, String mode) {
    final vehicle = data['assignedVehicle'] as Map<String, dynamic>?;
    if (vehicle == null) return const SizedBox.shrink();
    return Card(
      child: ListTile(
        leading: const Icon(Icons.local_shipping_outlined, color: WetrackamColors.purple),
        title: Text(vehicle['deviceName']?.toString() ?? 'Véhicule'),
        subtitle: Text('Statut : ${vehicle['status'] ?? '—'}'),
      ),
    );
  }

  Widget _freePoolCard(Map<String, dynamic> data) {
    final vehicles = (data['availableVehicles'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (vehicles.isEmpty) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.local_shipping_outlined, color: WetrackamColors.slate),
          title: Text('Aucun véhicule disponible actuellement'),
        ),
      );
    }
    // Anomalie corrigée (lint deprecated_member_use) : `groupValue`/
    // `onChanged` directement sur RadioListTile sont dépréciés depuis
    // Flutter 3.32 au profit d'un ancêtre RadioGroup unique qui gère l'état
    // partagé pour tous les Radio de la liste.
    return Card(
      child: RadioGroup<String>(
        groupValue: _selectedFreePoolDevice,
        onChanged: (value) => setState(() => _selectedFreePoolDevice = value),
        child: Column(
          children: vehicles.map((v) {
            final id = v['deviceUniqueId'] as String?;
            return RadioListTile<String>(
              value: id ?? '',
              title: Text(v['deviceName']?.toString() ?? 'Véhicule'),
            );
          }).toList(),
        ),
      ),
    );
  }
}
