import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:wetrackam_client/preferences.dart';

class Location {
  final String timestamp;
  final double latitude;
  final double longitude;
  final double heading;
  // Lot 8 : km/h, convertie depuis les m/s du plugin (standard des API de
  // localisation natives) — conversion simple et non ambiguë, à ne pas
  // confondre avec la question des nœuds du protocole OsmAnd (préférences
  // .dart, sans rapport : celle-ci est un problème d'affichage UI local,
  // pas de protocole serveur).
  final double speedKmh;
  const Location({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.heading,
    this.speedKmh = 0,
  });
}

class LocationCache {
  static Location? _last;

  static Location? get() {
    if (_last == null) {
      final timestamp = Preferences.instance.getString(Preferences.lastTimestamp);
      final latitude = Preferences.instance.getDouble(Preferences.lastLatitude);
      final longitude = Preferences.instance.getDouble(Preferences.lastLongitude);
      final heading = Preferences.instance.getDouble(Preferences.lastHeading);
      final speedKmh = Preferences.instance.getDouble(Preferences.lastSpeed) ?? 0;
      if (timestamp != null && latitude != null && longitude != null && heading != null) {
        _last = Location(
          timestamp: timestamp,
          latitude: latitude,
          longitude: longitude,
          heading: heading,
          speedKmh: speedKmh,
        );
      }
    }
    return _last;
  }

  static Future<void> set(bg.Location location) async {
    final last = Location(
      timestamp: location.timestamp,
      latitude: location.coords.latitude,
      longitude: location.coords.longitude,
      heading: location.coords.heading,
      speedKmh: location.coords.speed * 3.6,
    );
    // Anomalie corrigée : ces cinq écritures n'étaient jamais attendues (ni
    // ici, ni par l'appelant dans geolocation_service.dart), malgré la
    // signature `Future<void>` de cette méthode. Si le processus était tué
    // juste après (scénario réaliste en tâche de fond headless), certains
    // champs pouvaient être persistés et d'autres non, sans qu'aucune erreur
    // ne remonte nulle part.
    await Future.wait([
      Preferences.instance.setString(Preferences.lastTimestamp, last.timestamp),
      Preferences.instance.setDouble(Preferences.lastLatitude, last.latitude),
      Preferences.instance.setDouble(Preferences.lastLongitude, last.longitude),
      Preferences.instance.setDouble(Preferences.lastHeading, last.heading),
      Preferences.instance.setDouble(Preferences.lastSpeed, last.speedKmh),
    ]);
    _last = last;
  }
}
