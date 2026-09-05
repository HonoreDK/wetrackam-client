// lib/wetrackam/network_watcher.dart
//
// v13 — règle 6 du contrat §12 : « bascule réseau pendant CONNECTED →
// restartIce(), jamais un hangup ». Cette règle était écrite dans
// call_service.dart mais n'était câblée nulle part : `restartIceOnNetworkChange()`
// existait, personne ne l'appelait jamais. Un chauffeur qui sortait du Wi-Fi
// de l'entrepôt perdait donc l'audio sans que rien ne tente la renégociation.
//
// Ce service est volontairement minuscule et sans état métier : il observe
// connectivity_plus et rediffuse deux effets, tous deux idempotents :
//   1. CallService.restartIceOnNetworkChange() — no-op hors appel connecté ;
//   2. RealtimeService.ensureConnected() — no-op si la socket est déjà
//      ouverte, mais raccourcit fortement le retour en ligne après un tunnel
//      ou une bascule d'antenne (sinon on attend le backoff exponentiel).
//
// Anti-rebond : Android émet fréquemment plusieurs événements pour une seule
// bascule réelle (perte Wi-Fi, aucun réseau, données mobiles). Sans le délai
// ci-dessous, on déclencherait deux ou trois ICE restarts pour un seul
// changement — chacun coûte un aller-retour de signalisation.
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'app_logger.dart';
import 'call_service.dart';
import 'realtime_service.dart';

class NetworkWatcher {
  NetworkWatcher._();

  static StreamSubscription<List<ConnectivityResult>>? _sub;
  static Timer? _debounce;
  static List<ConnectivityResult> _last = const [];

  static void start() {
    if (_sub != null) return;
    _sub = Connectivity().onConnectivityChanged.listen(_onChanged);
    AppLogger.breadcrumb('network_watcher_start');
  }

  static void stop() {
    _sub?.cancel();
    _sub = null;
    _debounce?.cancel();
    _debounce = null;
  }

  static void _onChanged(List<ConnectivityResult> results) {
    // Une transition « rien → rien » ou strictement identique n'est pas une
    // bascule : ne rien faire évite un ICE restart parasite.
    if (_sameTransport(results, _last)) return;
    final wasOffline = _isOffline(_last);
    _last = results;
    if (_isOffline(results)) {
      // Hors ligne : surtout NE PAS raccrocher — le contrat l'interdit
      // explicitement, et une coupure de quelques secondes dans un tunnel
      // est le cas normal en exploitation. On attend le retour du réseau.
      AppLogger.breadcrumb('network_offline');
      return;
    }
    AppLogger.breadcrumb('network_changed:${results.map((r) => r.name).join(",")}');
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1200), () async {
      // Anomalie corrigée (crash reproduit en test réel, bascules wifi/
      // mobile répétées) : RealtimeService.ensureConnected() peut lever
      // NetworkException (timeout de connexion, ou disconnect() concurrent
      // qui complète l'attente en erreur) — ce callback de Timer n'ayant
      // aucun appelant en amont pour l'intercepter, l'exception remontait
      // non gérée jusqu'au niveau de la Zone Dart ("Unhandled Exception"),
      // visible dans la console à chaque changement de réseau un peu
      // agressif. Un raté de reconnexion ici n'est pas fatal : le backoff
      // exponentiel normal de RealtimeService reprendra la main.
      try {
        // Ordre voulu : la socket d'abord (la signalisation de l'ICE restart
        // passe par elle — un restart envoyé sur une socket fermée serait
        // silencieusement perdu, cf. RealtimeService.send).
        await RealtimeService.ensureConnected();
        await CallService.restartIceOnNetworkChange();
        if (wasOffline) AppLogger.breadcrumb('network_back_online');
      } catch (error) {
        AppLogger.error('network_watcher_reconnect_failed', error);
      }
    });
  }

  static bool _isOffline(List<ConnectivityResult> r) =>
      r.isEmpty || (r.length == 1 && r.first == ConnectivityResult.none);

  static bool _sameTransport(List<ConnectivityResult> a, List<ConnectivityResult> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
