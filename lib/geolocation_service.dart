import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:wetrackam_client/location_cache.dart';
import 'package:wetrackam_client/preferences.dart';
import 'package:wakelock_partial_android/wakelock_partial_android.dart';

import 'wetrackam/app_logger.dart';
import 'wetrackam/api_client.dart';
import 'wetrackam/shift_service.dart';

class GeolocationService {
  static Future<void> init() async {
    await bg.BackgroundGeolocation.ready(Preferences.geolocationConfig());
    if (Platform.isAndroid) {
      await bg.BackgroundGeolocation.registerHeadlessTask(headlessTask);
    }
    AppLogger.breadcrumb('geolocation_init');
    bg.BackgroundGeolocation.onEnabledChange(onEnabledChange);
    bg.BackgroundGeolocation.onMotionChange(onMotionChange);
    bg.BackgroundGeolocation.onHeartbeat(onHeartbeat);
    bg.BackgroundGeolocation.onLocation(onLocation, (bg.LocationError error) {
      developer.log('Location error', error: error);
    });
    bg.BackgroundGeolocation.onHttp(_onHttpResponse);
    _schedulePeriodicMaintenance();
  }

  /// Ce que renvoie le plugin sur chaque tentative d'envoi HTTP. Sert
  /// uniquement à l'ACK best-effort (§8.3) — la détection d'un permis
  /// expiré passe désormais par `/eligibility` (`blockReason:
  /// licenseExpired`) et par le `403 licenseExpired` de `/shift/start`,
  /// tous deux gérés côté écrans (eligibility_screen.dart), plus fiables
  /// qu'une inspection du flux OsmAnd brut.
  static void _onHttpResponse(bg.HttpEvent response) {
    if (!response.success) {
      AppLogger.breadcrumb('geolocation_http_error:${response.status}');
      return;
    }
    // §8.3 : ACK purement informatif, uniquement pendant un service actif
    // (hors service, aucun envoi n'a lieu de toute façon — voir onLocation).
    if (ShiftService.isActive) {
      WetrackamApiClient.ack(lastFlushedTs: DateTime.now(), count: 1);
    }
  }

  /// Purge du buffer offline > 7 jours (contrat §3 : "y ajouter uniquement
  /// une purge des positions > 7 jours pour éviter l'inflation"). Le plugin
  /// n'expose pas de purge par âge native : on interroge périodiquement les
  /// positions persistées et on supprime celles trop anciennes.
  /// ⚠️ Dépend de la disponibilité de `getLocations()` sur la version du
  /// plugin utilisée — à vérifier en test réel (voir QA, cas non couvert
  /// par le contrat).
  static Future<void> purgeOldLocations() async {
    try {
      final locations = await bg.BackgroundGeolocation.locations;
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final raw in locations) {
        final map = raw as Map;
        final timestampStr = map['timestamp'] as String?;
        final uuid = map['uuid'] as String?;
        if (timestampStr == null || uuid == null) continue;
        final timestamp = DateTime.tryParse(timestampStr);
        if (timestamp != null && timestamp.isBefore(cutoff)) {
          await bg.BackgroundGeolocation.destroyLocation(uuid);
        }
      }
      AppLogger.breadcrumb('buffer_purge_7d_done');
    } catch (error) {
      AppLogger.error('buffer_purge_7d_failed', error);
    }
  }

  static void _schedulePeriodicMaintenance() {
    Future<void> tick() async {
      await purgeOldLocations();
      await Future.delayed(const Duration(hours: 6), tick);
    }
    tick();
  }

  /// Anomalie corrigée (audit sécurité/correctness) : avant ce correctif,
  /// rien dans le flux authentifié réel n'appelait jamais
  /// `bg.BackgroundGeolocation.start()` — seuls le code mort de
  /// main_screen.dart et les raccourcis rapides (quick_actions.dart, qui
  /// contournaient en plus toute authentification) le faisaient. Le plugin
  /// ne démarrait donc jamais réellement : `onLocation` ne se déclenchait
  /// jamais, quel que soit l'état du service (§8.1 règle 1 dépend
  /// entièrement de ce déclenchement pour fonctionner). Appelé une seule
  /// fois quand une session authentifiée devient valide (pin_auth_screen.dart
  /// après succès, et main.dart au démarrage avec une session restaurée) —
  /// PAS à chaque prise de service : la capture locale est censée être
  /// continue, seul l'envoi réseau est gated par ShiftService.isActive
  /// (voir onLocation ci-dessous). Symétrique : stop() n'est appelé que sur
  /// purge totale (déliaison, compte archivé...), jamais sur une simple
  /// expiration de session.
  static Future<void> start() async {
    try {
      await bg.BackgroundGeolocation.start();
      AppLogger.breadcrumb('geolocation_plugin_started');
    } catch (error) {
      AppLogger.error('geolocation_plugin_start_failed', error);
    }
  }

  static Future<void> stop() async {
    try {
      await bg.BackgroundGeolocation.stop();
      AppLogger.breadcrumb('geolocation_plugin_stopped');
    } catch (error) {
      AppLogger.error('geolocation_plugin_stop_failed', error);
    }
  }

  /// À appeler après toute prise/fin de service (ShiftService.start/end) :
  /// reconstruit la config du plugin pour que `deviceUniqueId` (ou son
  /// absence) soit reflété sur toute position suivante — voir
  /// Preferences.geolocationConfig() / _locationTemplate().
  static Future<void> refreshDriverIdentity() async {
    try {
      await bg.BackgroundGeolocation.setConfig(Preferences.geolocationConfig());
      AppLogger.breadcrumb('geolocation_config_refreshed_for_shift');
    } catch (error) {
      AppLogger.error('geolocation_config_refresh_failed', error);
    }
  }

  /// §9 — obligation de fin de service : tenter de vider la file avant de
  /// purger l'état local. Best-effort : si le réseau manque, la file reste
  /// intacte et sera rejouée au prochain service (comportement voulu, pas
  /// une erreur — voir geolocation_bridge.dart).
  ///
  /// ⚠️ Limite connue, à vérifier sur appareil réel : si le plugin rend le
  /// template HTTP au moment de l'ENVOI (et non à la capture), une
  /// position capturée sous le véhicule A mais encore en file au moment où
  /// un service B démarre pourrait se voir attribuer `deviceUniqueId` B au
  /// lieu de A. `flushPendingBuffer()` réduit ce risque en vidant la file
  /// avant que `refreshDriverIdentity()` ne change le device courant, mais
  /// ne l'élimine pas en cas d'échec réseau prolongé enjambant deux
  /// services. Le contrat n'impose pas de solution précise à ce cas.
  static Future<void> flushPendingBuffer() async {
    try {
      await bg.BackgroundGeolocation.sync();
      AppLogger.breadcrumb('pending_buffer_flushed_before_shift_end');
    } catch (error) {
      AppLogger.error('flush_buffer_failed', error);
    }
  }

  static Future<void> onEnabledChange(bool enabled) async {
    AppLogger.breadcrumb('geolocation_enabled:$enabled');
    if (Preferences.instance.getBool(Preferences.wakelock) ?? false) {
      if (!enabled) {
        await WakelockPartialAndroid.release();
      }
    }
  }

  static Future<void> onMotionChange(bg.Location location) async {
    AppLogger.breadcrumb('geolocation_motion:${location.isMoving}');
    if (Preferences.instance.getBool(Preferences.wakelock) ?? false) {
      if (location.isMoving) {
        await WakelockPartialAndroid.acquire();
      } else {
        await WakelockPartialAndroid.release();
      }
    }
  }

  static Future<void> onHeartbeat(bg.HeartbeatEvent event) async {
    await bg.BackgroundGeolocation.getCurrentPosition(samples: 1, persist: true, extras: {'heartbeat': true});
  }

  static Future<void> onLocation(bg.Location location) async {
    if (_shouldDelete(location)) {
      try {
        await bg.BackgroundGeolocation.destroyLocation(location.uuid);
      } catch(error) {
        developer.log('Failed to delete location', error: error);
      }
    } else {
      await LocationCache.set(location);
      // §8.1 règle 1 : "Aucun envoi hors service." La position reste
      // persistée nativement (buffer SQLite du plugin, jamais perdue) ;
      // seul l'envoi réseau est différé jusqu'à la prise de service.
      // ShiftService.start() appelle refreshDriverIdentity() qui met à
      // jour le template avec le deviceUniqueId courant AVANT que le
      // prochain sync() ne vide le buffer accumulé.
      if (!ShiftService.isActive) {
        AppLogger.breadcrumb('location_buffered_no_active_shift');
        return;
      }
      try {
        await bg.BackgroundGeolocation.sync();
      } catch (error) {
        developer.log('Failed to send location', error: error);
      }
    }
  }

  static bool _shouldDelete(bg.Location location) {
    if (!location.isMoving) return false;
    if (location.extras?.isNotEmpty == true) return false;

    final lastLocation = LocationCache.get();
    if (lastLocation == null) return false;

    final isHighestAccuracy = Preferences.instance.getString(Preferences.accuracy) == 'highest';
    final duration = DateTime.parse(location.timestamp).difference(DateTime.parse(lastLocation.timestamp)).inSeconds;

    if (!isHighestAccuracy) {
      final fastestInterval = Preferences.instance.getInt(Preferences.fastestInterval);
      if (fastestInterval != null && duration < fastestInterval) return true;
    }

    final distance = _distance(lastLocation, location);

    final distanceFilter = Preferences.instance.getInt(Preferences.distance) ?? 0;
    if (distanceFilter > 0 && distance >= distanceFilter) return false;

    if (distanceFilter == 0 || isHighestAccuracy) {
      final intervalFilter = Preferences.instance.getInt(Preferences.interval) ?? 0;
      if (intervalFilter > 0 && duration >= intervalFilter) return false;
    }

    if (isHighestAccuracy && lastLocation.heading >= 0 && location.coords.heading > 0) {
      final angle = (location.coords.heading - lastLocation.heading).abs();
      final angleFilter = Preferences.instance.getInt(Preferences.angle) ?? 0;
      if (angleFilter > 0 && angle >= angleFilter) return false;
    }

    return true;
  }

  static double _distance(Location from, bg.Location to) {
    const earthRadius = 6371008.8; // meters
    final dLat = _degToRad(to.coords.latitude - from.latitude);
    final dLon = _degToRad(to.coords.longitude - from.longitude);
    final sinLat = sin(dLat / 2);
    final sinLon = sin(dLon / 2);
    final a = sinLat * sinLat + cos(_degToRad(from.latitude)) * cos(_degToRad(to.coords.latitude)) * sinLon * sinLon;
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  static double _degToRad(double degree) => degree * pi / 180.0;
}

@pragma('vm:entry-point')
void headlessTask(bg.HeadlessEvent headlessEvent) async {
  await Preferences.init();
  AppLogger.breadcrumb('geolocation_headless:${headlessEvent.name}');
  switch (headlessEvent.name) {
    case bg.Event.ENABLEDCHANGE:
      await GeolocationService.onEnabledChange(headlessEvent.event);
    case bg.Event.MOTIONCHANGE:
      await GeolocationService.onMotionChange(headlessEvent.event);
    case bg.Event.HEARTBEAT:
      await GeolocationService.onHeartbeat(headlessEvent.event);
    case bg.Event.LOCATION:
      await GeolocationService.onLocation(headlessEvent.event);
  }
}
