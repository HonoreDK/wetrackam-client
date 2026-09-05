// lib/wetrackam/state_sync_service.dart
//
// v6 — Synchronisation bilatérale (DELTA-v5-vers-v6-TEMPS-REEL.md).
//
// Deux mécanismes, volontairement redondants (le second est le filet de
// sécurité du premier, §1 du delta) :
//  1. L'epoch (§2, §9.1) : un compteur croissant, lu sur CHAQUE réponse
//     /api/mobile/* (en-tête X-Driver-Epoch) ET sur chaque message
//     `control`. S'il augmente, on recharge /shift/eligibility — rien
//     d'autre à interpréter.
//  2. La table de dispatch des messages `control` (§3, enrichie §9.4) :
//     des actions plus précises que "recharger" pour certains événements
//     (purge token, purge totale...).
//
// Dédoublonnage (§9.2) : `eventId` déjà vu → ignoré ; `seq` ≤ dernier reçu
// → ignoré (message en retard). Un seul événement ne doit JAMAIS produire
// deux transitions d'écran.
import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'app_logger.dart';
import 'call_navigator.dart' show navigatorKey;
import 'discovery_service.dart';
import 'driver_identity_service.dart';
import 'main_navigation_gate.dart';
import 'realtime_service.dart';
import 'shift_service.dart';

class StateSyncService {
  StateSyncService._();

  static int? _lastEpoch;
  static int? get currentEpoch => _lastEpoch;
  static final Set<String> _seenEventIds = {};
  static int? _lastSeq;
  static StreamSubscription<Map<String, dynamic>>? _sub;

  /// Signal générique "l'écran d'accueil doit se recharger" — EligibilityScreen
  /// s'y abonne. Pas de payload : le rechargement relit /shift/eligibility
  /// lui-même, seule source de vérité (cohérent avec le reste du contrat).
  static final _reloadController = StreamController<void>.broadcast();
  static Stream<void> get reloadRequests => _reloadController.stream;

  static void init() {
    _sub ??= RealtimeService.messages.listen(_onRealtimeMessage);
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
    stopFallbackPolling();
  }

  // ==========================================================================
  //  Filet de repli : sondage /state quand la socket est muette
  // ==========================================================================
  //
  // Jusqu'ici la resynchronisation n'avait lieu qu'à trois moments : ouverture
  // de socket (`control.resync`), retour au premier plan, et appel authentifié
  // (en-tête X-Driver-Epoch). Il restait donc un cas réel non couvert :
  // application ouverte, écran allumé, mais socket incapable de se rétablir
  // (zone blanche prolongée, proxy d'entreprise, économiseur de batterie
  // agressif). Le chauffeur pouvait rester des minutes sur un état périmé
  // sans jamais rien toucher.
  //
  // Règles volontairement strictes pour ne pas gaspiller batterie ni data :
  //  - actif UNIQUEMENT au premier plan (piloté par main.dart) ;
  //  - actif UNIQUEMENT tant que la socket n'est pas connectée : dès qu'elle
  //    revient, `control.resync` fait le travail et le sondage se tait ;
  //  - un seul appel en vol à la fois ;
  //  - échec silencieux : /state est déjà un filet, pas une dépendance.

  static Timer? _fallbackTimer;
  static bool _fallbackInFlight = false;

  static const Duration fallbackInterval = Duration(seconds: 60);

  static void startFallbackPolling() {
    if (_fallbackTimer != null) return;
    _fallbackTimer = Timer.periodic(fallbackInterval, (_) => _fallbackTick());
    AppLogger.breadcrumb('state_fallback_polling_started');
  }

  static void stopFallbackPolling() {
    if (_fallbackTimer == null) return;
    _fallbackTimer!.cancel();
    _fallbackTimer = null;
    AppLogger.breadcrumb('state_fallback_polling_stopped');
  }

  static Future<void> _fallbackTick() async {
    if (_fallbackInFlight) return;
    if (!DriverIdentityService.isAuthenticated) return;
    // Socket vivante : le canal temps réel fait déjà foi, on ne double pas.
    if (RealtimeService.state == RealtimeState.connected) return;
    _fallbackInFlight = true;
    try {
      await fetchState();
    } finally {
      _fallbackInFlight = false;
    }
  }

  /// v6 §1 / §4 (canal 2, push silencieux de repli) — point d'entrée
  /// PUBLIC pour un message `control` livré par FCM plutôt que par la
  /// socket, appelé depuis push_notifications_service.dart. Repasse par
  /// la MÊME logique de dédoublonnage/dispatch que le canal socket (le
  /// même événement peut légitimement arriver par les deux canaux —
  /// `_seenEventIds` partagé empêche une double transition).
  ///
  /// Normalisation obligatoire : en API FCM v1, TOUTES les valeurs de
  /// `data` sont des chaînes (contrat v5 §8.5.1) — `epoch`/`seq` arrivent
  /// en `String`, alors que le canal socket les livre déjà typés en `int`
  /// (JSON natif). Sans cette conversion, le cast `as int?` utilisé par
  /// le dispatch échouerait au runtime sur un message venu du push.
  static void handleControlMessageFromPush(Map<String, dynamic> raw) {
    _onRealtimeMessage({
      'type': 'control',
      'event': raw['event'],
      'reason': raw['reason'],
      'eventId': raw['eventId'],
      'seq': raw['seq'] is String ? int.tryParse(raw['seq'] as String) : raw['seq'] as int?,
      'epoch': raw['epoch'] is String ? int.tryParse(raw['epoch'] as String) : raw['epoch'] as int?,
    });
  }

  /// À appeler sur toute purge (token ou totale) : l'epoch et les
  /// compteurs de dédoublonnage n'ont plus de sens pour une session qui
  /// n'existe plus — les conserver risquerait d'ignorer à tort un
  /// événement légitime pour la PROCHAINE session (numérotation propre à
  /// chaque chauffeur/appareil, pas de continuité garantie entre deux
  /// sessions différentes sur le même téléphone).
  static void reset() {
    _lastEpoch = null;
    _seenEventIds.clear();
    _lastSeq = null;
  }

  // -----------------------------------------------------------------
  // §9.1 — epoch lu sur CHAQUE réponse /api/mobile/*, pas seulement sur
  // /state ou les messages control. Appelé depuis api_client.dart::_send().
  // -----------------------------------------------------------------
  static void onEpochHeader(String? epochHeader) {
    if (epochHeader == null) return;
    final epoch = int.tryParse(epochHeader);
    if (epoch == null) return;
    _bumpEpochIfNewer(epoch);
  }

  static void _bumpEpochIfNewer(int epoch) {
    if (_lastEpoch != null && epoch <= _lastEpoch!) return; // §J8 : epoch inchangé, aucun rechargement
    _lastEpoch = epoch;
    AppLogger.breadcrumb('state_epoch_bumped:$epoch');
    _reloadController.add(null);
  }

  // -----------------------------------------------------------------
  // Messages `control` sur la socket temps réel (§3, §9.2, §9.4)
  // -----------------------------------------------------------------
  static void _onRealtimeMessage(Map<String, dynamic> message) {
    if (message['type'] != 'control') return;
    final event = message['event'] as String?;
    final reason = message['reason'] as String?;
    final eventId = message['eventId'] as String?;
    final seq = message['seq'] as int?;

    // §9.2 — dédoublonnage sur eventId (le serveur peut réessayer un envoi
    // après une micro-coupure : le doublon est normal, pas une erreur).
    if (eventId != null) {
      if (_seenEventIds.contains(eventId)) {
        AppLogger.breadcrumb('control_duplicate_ignored:$eventId');
        return;
      }
      _seenEventIds.add(eventId);
      if (_seenEventIds.length > 500) _seenEventIds.remove(_seenEventIds.first);
    }
    // §9.2 — un seq inférieur ou égal au dernier reçu est un message en
    // retard, à ignorer. Comparaison indépendante de eventId : un message
    // sans eventId (versions serveur antérieures ?) reste protégé par seq.
    if (seq != null) {
      if (_lastSeq != null && seq <= _lastSeq!) {
        AppLogger.breadcrumb('control_stale_seq_ignored:$seq');
        return;
      }
      _lastSeq = seq;
    }

    // FLUX-JETON-FCM.md §2 : "push.stale ne fait pas bouger l'epoch" —
    // exception explicite, traitée par push_notifications_service.dart
    // (chantier suivant), jamais ici. Le reste des événements bumpe
    // l'epoch normalement s'il progresse.
    if (event != 'push.stale') {
      final epoch = message['epoch'] as int?;
      if (epoch != null) _bumpEpochIfNewer(epoch);
    }

    AppLogger.breadcrumb('control_event:$event/$reason');
    _dispatch(event, reason, message);
  }

  static void _dispatch(String? event, String? reason, Map<String, dynamic> message) {
    switch (event) {
      case 'assignment.changed':
      case 'mode.changed':
        _reloadController.add(null);
      case 'assignment.removed':
        // §3 : "recharger /shift/eligibility, revenir à l'accueil" —
        // EligibilityScreen EST l'écran d'accueil dans cette architecture
        // (pas d'écran séparé à fermer par-dessus) : un rechargement suffit,
        // il réaffichera naturellement l'état "pas de véhicule affecté".
        _reloadController.add(null);
      case 'session.revoked':
      case 'pin.rotated':
        // §13.1 (v5) déjà en place : purge token seul → écran PIN, garde
        // le provisionnement. Exactement le comportement demandé ici.
        //
        // Anomalie corrigée : la purge seule ne suffisait pas — contrairement
        // à eligibility_screen.dart::_startShift (on SessionInvalidException),
        // rien ici ne renaviguait vers l'écran PIN. MainNavigationGate est un
        // StatelessWidget qui ne se reconstruit QUE quand on le pousse
        // explicitement (voir son propre commentaire d'en-tête) : sans cet
        // appel, le chauffeur restait bloqué sur un écran d'éligibilité figé,
        // tout futur appel authentifié échouant en StateError interne
        // ("Appel authentifié sans session") jamais rattrapé par les écrans.
        DriverIdentityService.purgeTokenOnly().then((_) => _navigateToRoot());
      case 'shift.closed':
        // Arrêter l'envoi de positions localement AVANT de recharger —
        // sinon une position pourrait partir entre la clôture serveur et
        // le rechargement de l'écran.
        ShiftService.forceLocalStop();
        _reloadController.add(null);
      case 'device.unbound':
        // Anomalie corrigée : même bug que session.revoked/pin.rotated
        // ci-dessus — purgeAll() efface tout mais rien ne renaviguait vers
        // l'écran de scan QR, laissant le chauffeur bloqué sur un écran figé.
        DriverIdentityService.purgeAll().then((_) => _navigateToRoot());
      case 'lifecycle.changed':
        if (reason == 'driverDeleted') {
          DriverIdentityService.purgeAll().then((_) => _navigateToRoot());
        } else {
          // suspended / archived / active (§9.4) : pas une purge en soi —
          // c'est le PROCHAIN appel authentifié qui recevra le 401
          // approprié (accountSuspended/accountArchived) si nécessaire,
          // déjà géré par api_client.dart. Ici, on se contente de
          // rafraîchir l'écran d'accueil pour refléter l'état à jour.
          _reloadController.add(null);
        }
      case 'settings.changed':
        ShiftService.refreshConfigNow();
      case 'control.resync':
        // §9.3 : toute ouverture de socket exige un GET /state — couvre
        // les décisions prises pendant que la socket était fermée.
        fetchState();
      case 'server.rebased':
        // Chantier B (§8.a) : ne bumpe pas l'epoch, ne recharge PAS
        // l'écran d'accueil — c'est une bascule d'adresse réseau, pas un
        // changement d'état métier. DiscoveryService valide serverId lui-
        // même avant d'adopter quoi que ce soit.
        DiscoveryService.handleRebasedEvent(message);
      case 'push.stale':
        // Explicitement PAS traité ici (chantier FCM v6.1 suivant) — voir
        // commentaire au-dessus sur l'epoch. Ne recharge jamais l'écran
        // d'accueil pour ce motif (FLUX-JETON-FCM.md §4 "ce qu'il ne faut
        // pas faire").
        break;
      default:
        // Catalogue fermé (§3) : tout événement inconnu est ignoré sans
        // erreur visible — le serveur peut s'enrichir avant une mise à
        // jour de l'app.
        AppLogger.breadcrumb('control_unknown_event_ignored:$event');
    }
  }

  /// Ramène l'app à MainNavigationGate, qui redirige lui-même vers le bon
  /// écran (scan QR si plus provisionné, PIN si provisionné sans session) —
  /// nécessaire après toute purge déclenchée depuis un message `control`,
  /// puisque MainNavigationGate est un StatelessWidget qui ne se reconstruit
  /// que s'il est explicitement repoussé (voir son commentaire d'en-tête).
  static void _navigateToRoot() {
    final nav = navigatorKey.currentState;
    if (nav == null) {
      AppLogger.error('state_sync_no_navigator', 'purge occurred but could not navigate back to root');
      return;
    }
    nav.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MainNavigationGate()),
      (route) => false,
    );
  }

  // -----------------------------------------------------------------
  // §5 — GET /api/mobile/state, filet de sécurité sans socket
  // -----------------------------------------------------------------
  static Future<void> fetchState() async {
    if (!DriverIdentityService.isAuthenticated) return;
    try {
      final data = await WetrackamApiClient.fetchState();
      final epoch = data['epoch'] as int?;
      if (epoch != null) _bumpEpochIfNewer(epoch);
      AppLogger.breadcrumb('state_fetched:epoch=$epoch');
    } catch (error) {
      // Best-effort : un échec de /state ne doit jamais bloquer le reste
      // de l'app — c'est déjà lui-même un filet de sécurité, pas une
      // dépendance critique du démarrage.
      AppLogger.error('state_fetch_failed', error);
    }
  }
}
