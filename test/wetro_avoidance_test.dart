import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_avoidance.dart';

/// Table de cas du moteur d'évitement — miroir de `fabEvitement.test.mjs`
/// (console web) : les deux surfaces doivent placer le bouton pareil.
void main() {
  const vue = Size(390, 844);
  const marge = 16.0;
  const margeBas = 16.0;

  Rect coin({double dx = 0, double dy = 0}) => rectAncre(
        vue: vue,
        marge: marge,
        margeBas: margeBas,
        taille: tailleFab,
        dx: dx,
        dy: dy,
      );

  group('candidats', () {
    test('ordonnés par anneau, vertical d’abord', () {
      final liste = candidats();
      expect(liste.first, FabCandidat.repos);
      expect(liste[1], const FabCandidat(0, pasFab));
      expect(liste[2], const FabCandidat(pasFab, 0));
      expect(liste[3], const FabCandidat(0, 2 * pasFab));
      expect(liste[4], const FabCandidat(pasFab, pasFab));
      expect(liste[5], const FabCandidat(2 * pasFab, 0));
      expect(liste.length, (maxPasFab + 1) * (maxPasFab + 2) ~/ 2);
    });
  });

  group('rectAncre', () {
    test('coin bas-gauche au repos', () {
      final r = coin();
      expect(r.left, marge);
      expect(r.bottom, vue.height - margeBas);
      expect(r.width, tailleFab);
    });
    test('dx pousse vers la droite, dy vers le haut', () {
      final r = coin(dx: 72, dy: 144);
      expect(r.left, marge + 72);
      expect(r.bottom, vue.height - margeBas - 144);
    });
  });

  group('place', () {
    test('sans obstacle : repos, libre', () {
      final p = place(vue: vue, marge: marge, margeBas: margeBas);
      expect(p.candidat, FabCandidat.repos);
      expect(p.libre, isTrue);
    });

    test('un bouton dans le coin : monte d’un cran', () {
      final p = place(vue: vue, marge: marge, margeBas: margeBas, obstacles: [coin()]);
      expect(p.candidat, const FabCandidat(0, pasFab));
      expect(p.libre, isTrue);
    });

    test('une barre pleine largeur en bas : monte au-dessus', () {
      final barre = Rect.fromLTWH(0, vue.height - 80, vue.width, 80);
      final p = place(vue: vue, marge: marge, margeBas: margeBas, obstacles: [barre]);
      expect(p.dy, greaterThanOrEqualTo(pasFab));
      expect(p.dx, 0);
      expect(p.libre, isTrue);
    });

    test('colonne d’obstacles à gauche : se décale vers la droite', () {
      final colonne = Rect.fromLTWH(0, 0, 100, vue.height);
      final p = place(vue: vue, marge: marge, margeBas: margeBas, obstacles: [colonne]);
      expect(p.dx, greaterThan(0));
      expect(p.libre, isTrue);
    });

    test('vue trop petite : repos, sans exception', () {
      final p = place(vue: const Size(60, 60), marge: marge, margeBas: margeBas, obstacles: [coin()]);
      expect(p.candidat, FabCandidat.repos);
      expect(p.libre, isFalse);
    });

    test('tout est bouché : place de moindre gêne, pas libre', () {
      final tout = Rect.fromLTWH(0, 0, vue.width * 0.8, vue.height);
      final p = place(vue: vue, marge: marge, margeBas: margeBas, obstacles: [tout]);
      expect(p.libre, isFalse);
    });

    test('hystérésis : une place tenable est gardée', () {
      // Le bouton est monté de deux crans (un obstacle occupait le bas).
      final repos = coin();
      const actuel = FabCandidat(0, 2 * pasFab);
      // L'obstacle a presque disparu : il reste un liseré juste au-dessus
      // du repos, dans la bande d'hystérésis (dégagé de plus que `jeu`,
      // mais de moins que `jeu + hysteresis`).
      final lisere = Rect.fromLTWH(
        repos.left,
        repos.top - jeuFab - 8,
        repos.width,
        2,
      );
      final p = place(
        vue: vue,
        marge: marge,
        margeBas: margeBas,
        obstacles: [lisere],
        actuel: actuel,
      );
      expect(p.candidat, actuel, reason: 'le repos n’est pas franchement libre : on ne redescend pas');
    });

    test('hystérésis : on redescend quand le repos est franchement libre', () {
      const actuel = FabCandidat(0, pasFab);
      final loin = Rect.fromLTWH(200, 100, 40, 40);
      final p = place(vue: vue, marge: marge, margeBas: margeBas, obstacles: [loin], actuel: actuel);
      expect(p.candidat, FabCandidat.repos);
    });

    test('la place actuelle envahie est quittée', () {
      const actuel = FabCandidat(0, pasFab);
      final p = place(
        vue: vue,
        marge: marge,
        margeBas: margeBas,
        obstacles: [coin(dy: pasFab)],
        actuel: actuel,
      );
      expect(p.candidat, isNot(actuel));
      expect(p.libre, isTrue);
    });
  });

  group('obstacleRetenu', () {
    test('minuscule : ignoré', () {
      expect(obstacleRetenu(const Rect.fromLTWH(10, 10, 4, 4), vue), isNull);
    });
    test('hors vue : ignoré', () {
      expect(obstacleRetenu(const Rect.fromLTWH(-100, 10, 50, 50), vue), isNull);
      expect(obstacleRetenu(Rect.fromLTWH(10, vue.height + 5, 50, 50), vue), isNull);
    });
    test('plein écran : ignoré (fond de page)', () {
      expect(obstacleRetenu(Rect.fromLTWH(0, 0, vue.width, vue.height), vue), isNull);
    });
    test('grand mais pas plein écran : retenu', () {
      expect(obstacleRetenu(Rect.fromLTWH(0, 0, vue.width, 300), vue), isNotNull);
    });
  });
}
