// test/fleet_units_test.dart — carte des collègues : unités de vitesse.
import 'package:flutter_test/flutter_test.dart';
import 'package:wetrackam_client/wetrackam/fleet_units.dart';

void main() {
  group('FleetUnits', () {
    test('convertit les nœuds de la socket en km/h', () {
      // 48,6 nœuds ≈ 90 km/h : c'est exactement le cas qui s'affichait à
      // 49 km/h avant le correctif d'unités.
      expect(FleetUnits.kmhFromSocketKnots(48.6), 90);
      expect(FleetUnits.kmhFromSocketKnots(0), 0);
      expect(FleetUnits.kmhFromSocketKnots(100), 185);
    });

    test('absence de vitesse ≠ vitesse nulle', () {
      expect(FleetUnits.kmhFromSocketKnots(null), isNull);
    });

    test('valeurs aberrantes ignorées plutôt qu\'affichées', () {
      expect(FleetUnits.kmhFromSocketKnots(-5), isNull);
      expect(FleetUnits.kmhFromSocketKnots(double.nan), isNull);
      expect(FleetUnits.kmhFromSocketKnots(double.infinity), isNull);
    });

    test('mouvement déduit de la vitesse brute', () {
      expect(FleetUnits.inMotionFromSocketKnots(0.4), isTrue);
      expect(FleetUnits.inMotionFromSocketKnots(0), isFalse);
      expect(FleetUnits.inMotionFromSocketKnots(null), isFalse);
    });
  });
}
