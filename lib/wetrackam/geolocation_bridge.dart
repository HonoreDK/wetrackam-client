// lib/wetrackam/geolocation_bridge.dart
//
// Pont minimal vers geolocation_service.dart (fichier upstream). Garde les
// autres fichiers de lib/wetrackam/ isolés du code Traccar Client d'origine.
//
// ⚠️ v4 change de politique par rapport à v1 : le contrat v1 exigeait
// d'ABANDONNER le buffer non envoyé au changement de chauffeur (§16.2 v1).
// Le contrat v4 §9 exige l'INVERSE : "vider la file hors-ligne avant de
// purger l'état local ; si le réseau manque, CONSERVER la file et la
// rejouer au prochain service". `discardPendingBuffer` a donc été retiré
// et remplacé par `flushPendingBuffer`.
import '../geolocation_service.dart';

class GeolocationBridge {
  GeolocationBridge._();

  /// À appeler une seule fois quand une session authentifiée devient valide
  /// — jamais à chaque prise de service (voir geolocation_service.dart::start
  /// pour le raisonnement complet : capture locale continue, envoi seul
  /// gated par le service).
  static Future<void> start() => GeolocationService.start();

  /// À appeler uniquement sur purge TOTALE (déliaison, compte archivé,
  /// dérive tenant...), jamais sur une simple expiration de session.
  static Future<void> stop() => GeolocationService.stop();

  /// À appeler après toute prise/fin de service pour que `deviceUniqueId`
  /// soit reflété (ou retiré) du flux de positions envoyées, et pour que
  /// le gating "aucun envoi hors service" (§8.1 règle 1) soit à jour.
  static Future<void> refreshDriverIdentity() => GeolocationService.refreshDriverIdentity();

  /// §9 — tentative best-effort de vidage de la file avant fin de service.
  /// Ne lève jamais d'exception : un échec réseau laisse la file intacte,
  /// à rejouer au prochain service (comportement voulu, pas une erreur).
  static Future<void> flushPendingBuffer() => GeolocationService.flushPendingBuffer();
}
