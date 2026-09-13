import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'package:rate_my_app/rate_my_app.dart';
import 'package:wetrackam_client/geolocation_service.dart';
import 'package:wetrackam_client/password_service.dart';
import 'package:wetrackam_client/quick_actions.dart';

import 'l10n/app_localizations.dart';
import 'preferences.dart';
import 'configuration_service.dart';
import 'wetrackam/theme.dart';
import 'wetrackam/app_logger.dart';
import 'wetrackam/call_navigator.dart';
import 'wetrackam/call_service.dart';
import 'wetrackam/chat_service.dart';
import 'wetrackam/network_watcher.dart';
import 'wetrackam/peer_name_cache.dart';
import 'wetrackam/driver_identity_service.dart';
import 'wetrackam/geolocation_bridge.dart';
import 'wetrackam/local_notifications_service.dart';
import 'wetrackam/main_navigation_gate.dart';
import 'wetrackam/push_notifications_service.dart';
import 'wetrackam/realtime_service.dart';
import 'wetrackam/rtc_config_service.dart';
import 'wetrackam/shift_service.dart';
import 'wetrackam/state_sync_service.dart';
import 'wetrackam/tls_pinning.dart';
import 'wetrackam/splash_screen.dart';
import 'wetrackam/voice_note_service.dart';

final messengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lot 4 (contrat v5 §7.5/§8) : Firebase réintroduit, spécifiquement pour
  // FCM v1. Le contrat v4 exigeait son retrait (anti-pattern) ; le v5 le
  // réintroduit explicitement pour le push — évolution documentée, pas une
  // régression. AppLogger reste la seule source de breadcrumbs (pas de
  // retour à Crashlytics).
  await Preferences.init();
  await Preferences.migrate();
  await PasswordService.migrate();
  await DriverIdentityService.restoreFromStorage();
  // EPINGLAGE-TLS.md §4-5 : "à chaque démarrage/reconnexion" — no-op
  // interne si TlsPinning n'est pas encore amorcé (pas encore appairé).
  if (TlsPinning.isBootstrapped) unawaited(TlsPinning.refreshPinsIfPossible());
  // v4 §13.1 : si le token devient invalide (401 quelconque) pendant un
  // service actif, on ne peut plus appeler /shift/end proprement — on
  // arrête le tracking localement plutôt que de continuer à émettre des
  // positions pour une session qui n'est plus valide.
  DriverIdentityService.registerTokenPurgeHook(ShiftService.forceLocalStop);
  // Lot 4 : révocation du jeton FCM — uniquement sur purge TOTALE
  // (registerFullPurgeHook), pas sur une simple expiration de session
  // (tokenExpired) où le chauffeur va juste ressaisir son PIN : le
  // déconnecter du push dans ce cas lui ferait perdre appels/messages
  // pour rien pendant l'attente. Fires avant l'effacement du stockage
  // (encore une session valide pour authentifier le DELETE) — voir
  // RAPPORT_LIVRAISON_V4 pour la lacune notée : pas de bouton
  // "déconnexion volontaire" distinct actuellement dans l'app, cette
  // révocation couvre donc les cas de purge totale existants
  // (accountArchived, deviceReplaced, dérive tenant, réinitialisation).
  DriverIdentityService.registerFullPurgeHook(PushNotificationsService.revokeCurrentToken);
  // Anomalie corrigée : symétrique du démarrage sur authentification
  // réussie (pin_auth_screen.dart) — seule une purge TOTALE (déliaison,
  // compte archivé, dérive tenant) doit arrêter la capture locale ; une
  // simple expiration de session (tokenExpired) ne le fait pas, la capture
  // continue étant censée survivre à un simple retour à l'écran PIN.
  DriverIdentityService.registerFullPurgeHook(GeolocationBridge.stop);
  // Lot 5 : arrêt du polling /rtc/config sur TOUTE purge (token ou totale)
  // — contrairement au push, un module "disponible" affiché avec une
  // session invalide serait trompeur, même en attente de ressaisie du PIN.
  DriverIdentityService.registerTokenPurgeHook(() async => RtcConfigService.stop());
  // Lot 8 : un appel en cours ne doit jamais survivre à une session
  // invalidée — raccroche proprement (coupe le micro, ferme la
  // PeerConnection). ⚠️ DOIT s'exécuter AVANT RealtimeService.disconnect()
  // ci-dessous : bug trouvé en audit de cohérence croisée — hangUp()
  // envoie `call.hangup` via RealtimeService.send(), qui abandonne
  // silencieusement tout message si la socket est déjà fermée
  // (RealtimeState != connected). Avec l'ordre inversé constaté
  // précédemment, le micro se coupait bien localement mais le collègue en
  // ligne n'était jamais notifié — appel fantôme côté pair jusqu'à un
  // timeout serveur. L'ordre d'enregistrement des hooks EST l'ordre
  // d'exécution (voir driver_identity_service.dart::purgeTokenOnly/All) :
  // ce commentaire et cet ordre ne doivent plus être dissociés.
  DriverIdentityService.registerTokenPurgeHook(() async => CallService.hangUp());
  // Lot 6 : fermer la socket temps réel sur toute purge — une session
  // invalide ne doit plus recevoir de présence/messages/appels. Doit venir
  // APRÈS CallService.hangUp() (voir commentaire ci-dessus).
  DriverIdentityService.registerTokenPurgeHook(
      () => RealtimeService.disconnect(userIntent: true));
  // Lot 7 : aucun message en attente ne doit survivre à une déconnexion.
  DriverIdentityService.registerTokenPurgeHook(ChatService.purgePendingQueue);
  DriverIdentityService.registerTokenPurgeHook(VoiceNoteService.purgeAll);
  // v6 : epoch et dédoublonnage eventId/seq n'ont plus de sens pour une
  // session qui n'existe plus — les conserver risquerait d'ignorer à tort
  // un événement légitime de la PROCHAINE session.
  DriverIdentityService.registerTokenPurgeHook(() async => StateSyncService.reset());
  // v13 : le cache des noms de collègues est une donnée du tenant — il est
  // purgé exactement comme la file de messages et l'état de synchro.
  DriverIdentityService.registerTokenPurgeHook(PeerNameCache.purge);
  ChatService.init();
  VoiceNoteService.init();
  CallService.init();
  CallNavigator.start();
  // v13 : bascule Wi-Fi <-> données mobiles. Sans cet observateur, l'ICE
  // restart existait dans CallService mais n'était déclenché par personne :
  // un appel survivait rarement à un changement de réseau.
  NetworkWatcher.start();
  StateSyncService.init();
  // Démarrage à froid = premier plan : on arme le filet tout de suite plutôt
  // que d'attendre un premier cycle pause/reprise qui peut ne jamais venir.
  StateSyncService.startFallbackPolling();
  RealtimeService.init(); // Chantier B : abonnement à DiscoveryService.onRebase
  await GeolocationService.init();
  await LocalNotificationsService.init();
  await LocalNotificationsService.requestPermissions();
  await PushNotificationsService.init();
  // Couvre le cas d'un relance de l'app avec une session déjà valide
  // (restaurée depuis le stockage sécurisé) : dans ce cas, l'écran PIN
  // n'est jamais affiché, donc son propre appel à registerAfterAuth() ne
  // se déclencherait jamais. Sans effet si non authentifié (no-op interne).
  unawaited(PushNotificationsService.registerAfterAuth());
  // v13 : l'utilisateur a pu ACCEPTER un appel sur l'écran natif alors que
  // l'application était tuée — c'est ce démarrage-ci qui doit alors envoyer
  // `call.accept` et ouvrir l'audio, sinon il décroche dans le vide.
  unawaited(CallService.resumeExternalAcceptanceAtStartup());
  // v13 : notes vocales restées en file (zone blanche, app fermée avant le
  // retour du réseau) — nouvelle tentative dès le démarrage.
  unawaited(VoiceNoteService.flushPendingQueue());
  if (DriverIdentityService.isAuthenticated) {
    // Anomalie corrigée : couvre le redémarrage de l'app avec une session
    // déjà valide restaurée depuis le stockage sécurisé — dans ce cas
    // pin_auth_screen.dart n'est jamais affiché, donc son propre appel à
    // GeolocationBridge.start() ne se déclencherait jamais.
    unawaited(GeolocationBridge.start());
    unawaited(RtcConfigService.start());
    // v6 §5 : filet de sécurité au tout premier chargement, même sans
    // passer par l'écran PIN (session déjà valide au démarrage).
    unawaited(StateSyncService.fetchState());
  }
  AppLogger.breadcrumb('app_start');
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with WidgetsBindingObserver {
  RateMyApp rateMyApp = RateMyApp(minDays: 0, minLaunches: 0);
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initLinks();
    _bootstrap();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await rateMyApp.init();
      if (mounted && rateMyApp.shouldOpenDialog) {
        try {
          await rateMyApp.showRateDialog(context);
        } catch (error) {
          developer.log('Failed to show rate dialog', error: error);
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Gap trouvé en audit de cohérence croisée : le commentaire d'en-tête de
  /// realtime_service.dart affirmait "fermer durablement en arrière-plan,
  /// le push prend le relais" (§3 PROMPT-MOBILE-HONORE) — mais ce
  /// comportement n'était câblé NULLE PART. La socket, une fois ouverte
  /// par un écran (carte/annuaire/conversation), restait connectée
  /// indéfiniment en arrière-plan, y compris app fermée à l'écran.
  ///
  /// Exception délibérée : ne JAMAIS fermer la socket si un appel est en
  /// cours ou sonne — l'audio WebRTC continue en P2P/TURN une fois établi,
  /// mais toute signalisation ultérieure (raccrochage propre, ICE restart,
  /// candidats tardifs) a besoin de cette même socket. Un appel actif doit
  /// survivre à une mise en arrière-plan (comportement standard de
  /// téléphonie), ce que cette exception garantit.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      if (CallService.phase == CallPhase.idle) {
        RealtimeService.disconnect(userIntent: false);
      }
      // Le sondage de repli est un filet de PREMIER PLAN uniquement : en
      // arrière-plan on coupe tout, l'état sera relu au retour (ci-dessous).
      StateSyncService.stopFallbackPolling();
    }
    // v6 §5 : "à faire au retour au premier plan" — canal INDÉPENDANT du
    // control.resync (§9.3), qui ne se déclenche que si la socket est déjà
    // ouverte. Comme la règle ci-dessus ferme délibérément la socket en
    // arrière-plan par défaut (sauf appel en cours), un simple retour au
    // premier plan sans écran de communication ouvert ne rouvrirait jamais
    // la socket tout seul — /state reste le seul filet de sécurité dans
    // ce cas précis.
    if (state == AppLifecycleState.resumed) {
      StateSyncService.fetchState();
      // Armement du filet : tant que l'application reste au premier plan
      // avec une socket incapable de se rétablir, /state est relu toutes
      // les 60 s. Le sondage se met en veille de lui-même dès que la
      // socket repasse à `connected` (control.resync prend le relais).
      StateSyncService.startFallbackPolling();
      // v6.1 §3.5 : filet de sécurité — si aucune confirmation d'enregistrement
      // du jeton push depuis plus de 24h, vérifier et réenregistrer si besoin.
      // No-op interne si le dernier contrôle date de moins de 24h.
      PushNotificationsService.checkStalenessOnResume();
    }
  }

  /// Court affichage du splash le temps que la session (déjà restaurée de
  /// façon synchrone dans main()) soit reflétée à l'écran.
  Future<void> _bootstrap() async {
    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) setState(() => _booting = false);
  }

  Future<void> _initLinks() async {
    final appLinks = AppLinks();
    final uri = await appLinks.getInitialLink();
    if (uri != null) {
      await ConfigurationService.applyUri(uri);
    }
    appLinks.uriLinkStream.listen((uri) async {
      // ⚠️ Isolation multi-tenant (contrat §16.1 / M4) : ConfigurationService
      // n'accepte que les clés de réglage upstream (id, url, accuracy...).
      // `driverUniqueId` n'y figure JAMAIS et ne doit jamais y être ajouté —
      // l'identification chauffeur ne provient que d'un aller-retour serveur
      // validé par DriverIdentificationScreen.
      await ConfigurationService.applyUri(uri);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey, // Lot 8 : requis par call_navigator.dart
      scaffoldMessengerKey: messengerKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: WetrackamTheme.light(),
      darkTheme: WetrackamTheme.dark(),
      home: _booting
          ? const WetrackamSplashScreen()
          : Stack(
              children: const [
                QuickActionsInitializer(),
                MainNavigationGate(),
              ],
            ),
    );
  }
}
