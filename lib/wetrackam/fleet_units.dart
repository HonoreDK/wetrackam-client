// lib/wetrackam/fleet_units.dart
//
// v15 — unités de la carte des collègues, isolées ici pour être testables
// sans interface (test/fleet_units_test.dart).
//
// Rappel du piège, corrigé en v13 et verrouillé ici :
//  - le REST /api/mobile/fleet/live expose `speedKmh`, DÉJÀ converti côté
//    serveur (MobileFleetResource : nœuds × 1,852) ;
//  - la socket `fleet.position` relaie `position.getSpeed()` BRUT, donc des
//    NŒUDS (FleetLiveBroadcastHandler.java).
// Recopier la valeur socket dans `speedKmh` sans conversion affichait un
// camion à 90 km/h comme roulant à 49 km/h, sans aucune erreur journalisée.
class FleetUnits {
  FleetUnits._();

  /// Facteur exact nœud → km/h (1 mille marin = 1852 m).
  static const double knotsToKmh = 1.852;

  /// Convertit la vitesse BRUTE de la socket (nœuds) en km/h affichables.
  /// `null` reste `null` : l'absence de vitesse n'est pas zéro.
  static int? kmhFromSocketKnots(num? speedKnots) {
    if (speedKnots == null) return null;
    final value = speedKnots * knotsToKmh;
    if (value.isNaN || value.isInfinite || value < 0) return null;
    return value.round();
  }

  /// Un véhicule est considéré en mouvement dès qu'une vitesse strictement
  /// positive est rapportée par la socket.
  static bool inMotionFromSocketKnots(num? speedKnots) =>
      speedKnots != null && speedKnots > 0;
}
