/// Moteur d'évitement du bouton flottant Wetro — géométrie PURE.
///
/// Port fidèle de `fabEvitement.js` (console web) : mêmes constantes, mêmes
/// règles, mêmes cas de test, pour que le bouton se comporte à l'identique
/// sur les deux surfaces. Aucune dépendance Flutter hors `dart:ui` (`Rect`,
/// `Size`) : ce fichier se teste sans rendu.
///
/// PRINCIPE
/// --------
/// Le bouton a une position de repos (coin bas-gauche). Quand un élément
/// interactif — bouton, champ, barre, notification — s'y trouve, il cherche
/// la première place LIBRE parmi des candidats ordonnés par anneaux :
/// d'abord monter d'un cran, puis se décaler, puis monter de deux, etc.
/// Il ne se cache jamais : au pire, il prend la place qui gêne le moins.
///
/// HYSTÉRÉSIS
/// ----------
/// Une place tenable est conservée tant qu'une meilleure place n'est pas
/// « franchement » libre (dégagée de `jeu + hysteresis`). Sans cela, un
/// obstacle à la frontière ferait osciller le bouton à chaque image.
library;

import 'dart:ui';

/// Diamètre du bouton flottant (Material).
const double tailleFab = 56;

/// Espace minimal entre le bouton et un obstacle.
const double jeuFab = 12;

/// Distance entre deux candidats successifs.
const double pasFab = 72;

/// Nombre maximal d'anneaux explorés.
const int maxPasFab = 6;

/// Marge supplémentaire exigée pour QUITTER une place tenable.
const double hysteresisFab = 10;

/// En deçà (largeur ou hauteur), un rectangle n'est pas un obstacle.
const double minObstacle = 8;

/// Un élément couvrant au moins cette fraction de l'écran dans les deux
/// dimensions est un fond de page, pas un obstacle.
const double seuilPleinEcran = 0.85;

/// Un candidat : décalage horizontal (vers l'intérieur) et vertical (vers
/// le haut) par rapport au repos, en pixels logiques.
class FabCandidat {
  const FabCandidat(this.dx, this.dy);

  final double dx;
  final double dy;

  static const repos = FabCandidat(0, 0);

  bool memeQue(FabCandidat? autre) =>
      autre != null && autre.dx == dx && autre.dy == dy;

  @override
  bool operator ==(Object other) =>
      other is FabCandidat && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'FabCandidat($dx, $dy)';
}

/// Résultat d'un placement.
class FabPlacement {
  const FabPlacement(this.candidat, {required this.libre});

  final FabCandidat candidat;

  /// Faux si aucune place ne dégage tous les obstacles : le bouton occupe
  /// alors la place de moindre gêne.
  final bool libre;

  double get dx => candidat.dx;
  double get dy => candidat.dy;

  @override
  String toString() => 'FabPlacement($candidat, libre: $libre)';
}

/// Gonfle un rectangle de `jeu` dans les quatre directions.
Rect gonfle(Rect r, double jeu) => Rect.fromLTRB(
      r.left - jeu,
      r.top - jeu,
      r.right + jeu,
      r.bottom + jeu,
    );

/// Aire d'intersection (0 si disjoints).
double aireCommune(Rect a, Rect b) {
  final largeur = (a.right < b.right ? a.right : b.right) -
      (a.left > b.left ? a.left : b.left);
  final hauteur = (a.bottom < b.bottom ? a.bottom : b.bottom) -
      (a.top > b.top ? a.top : b.top);
  return largeur > 0 && hauteur > 0 ? largeur * hauteur : 0;
}

/// Chevauchement strict (un simple contact de bords ne compte pas).
bool chevauche(Rect a, Rect b) =>
    a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

/// Rectangle occupé par le bouton pour un candidat donné.
Rect rectAncre({
  required Size vue,
  required double marge,
  required double margeBas,
  required double taille,
  required double dx,
  required double dy,
  bool gauche = true,
}) {
  final bottom = vue.height - margeBas - dy;
  final left = gauche ? marge + dx : vue.width - marge - dx - taille;
  return Rect.fromLTWH(left, bottom - taille, taille, taille);
}

/// Candidats ordonnés par anneau, vertical d'abord : (0,0), (0,1), (1,0),
/// (0,2), (1,1), (2,0)… en unités de `pas`. Monter d'abord : un bouton qui
/// s'élève reste « dans son coin » aux yeux de la personne ; un bouton qui
/// glisse vers le centre semble s'être enfui.
List<FabCandidat> candidats({double pas = pasFab, int maxPas = maxPasFab}) {
  final out = <FabCandidat>[];
  for (var anneau = 0; anneau <= maxPas; anneau++) {
    for (var vertical = anneau; vertical >= 0; vertical--) {
      out.add(FabCandidat((anneau - vertical) * pas, vertical * pas));
    }
  }
  return out;
}

int _rang(List<FabCandidat> liste, FabCandidat? c) {
  if (c == null) return 1 << 30;
  final i = liste.indexWhere((x) => x.memeQue(c));
  return i == -1 ? 1 << 30 : i;
}

/// Choisit la place du bouton.
///
/// [obstacles] sont des rectangles en coordonnées de la vue (déjà filtrés :
/// visibles, assez grands, pas plein écran). [actuel] est la place occupée
/// à l'image précédente, pour l'hystérésis.
FabPlacement place({
  required Size vue,
  List<Rect> obstacles = const [],
  bool gauche = true,
  double taille = tailleFab,
  double marge = 24,
  double margeBas = 24,
  double pas = pasFab,
  int maxPas = maxPasFab,
  double jeu = jeuFab,
  double hysteresis = hysteresisFab,
  FabCandidat? actuel,
}) {
  const repos = FabCandidat.repos;
  // Vue absente ou trop petite pour bouger : repos, sans rien casser.
  if (!(vue.width > 0) ||
      !(vue.height > 0) ||
      vue.width < taille + 2 * marge ||
      vue.height < taille + margeBas + marge) {
    return FabPlacement(repos, libre: obstacles.isEmpty);
  }

  final zones = obstacles.map((o) => gonfle(o, jeu)).toList(growable: false);
  final zonesLarges =
      obstacles.map((o) => gonfle(o, jeu + hysteresis)).toList(growable: false);
  final liste = candidats(pas: pas, maxPas: maxPas);

  Rect rectDe(FabCandidat c) => rectAncre(
        vue: vue,
        marge: marge,
        margeBas: margeBas,
        taille: taille,
        dx: c.dx,
        dy: c.dy,
        gauche: gauche,
      );

  // Le repos est toujours jouable (c'est le dernier recours) ; tout autre
  // candidat doit rester entièrement visible, marges comprises.
  bool jouable(FabCandidat c, Rect r) =>
      c.memeQue(repos) ||
      (r.top >= marge &&
          r.left >= marge &&
          r.right <= vue.width - marge &&
          r.bottom <= vue.height);

  FabCandidat? premierLibre;
  FabCandidat? moindreMal;
  double moindreCout = double.infinity;
  for (final c in liste) {
    final r = rectDe(c);
    if (!jouable(c, r)) continue;
    var cout = 0.0;
    for (final z in zones) {
      cout += aireCommune(r, z);
    }
    if (cout == 0 && premierLibre == null) premierLibre = c;
    if (cout < moindreCout) {
      moindreCout = cout;
      moindreMal = c;
    }
  }

  if (actuel != null) {
    final rActuel = rectDe(actuel);
    final tenable =
        jouable(actuel, rActuel) && zones.every((z) => !chevauche(rActuel, z));
    if (tenable) {
      if (premierLibre == null ||
          _rang(liste, premierLibre) >= _rang(liste, actuel)) {
        return FabPlacement(actuel, libre: true);
      }
      final rMieux = rectDe(premierLibre);
      final franchementLibre = zonesLarges.every((z) => !chevauche(rMieux, z));
      return FabPlacement(franchementLibre ? premierLibre : actuel, libre: true);
    }
  }

  if (premierLibre != null) return FabPlacement(premierLibre, libre: true);
  return FabPlacement(moindreMal ?? repos, libre: false);
}

/// Filtre un rectangle brut comme le fait la console web : ignoré s'il est
/// minuscule, hors de la vue, ou s'il couvre presque tout l'écran (fond de
/// page, feuille plein écran). Retourne `null` s'il ne compte pas.
Rect? obstacleRetenu(Rect r, Size vue) {
  if (r.isEmpty || r.width < minObstacle || r.height < minObstacle) return null;
  if (r.right <= 0 || r.bottom <= 0 || r.left >= vue.width || r.top >= vue.height) {
    return null;
  }
  if (r.width >= vue.width * seuilPleinEcran &&
      r.height >= vue.height * seuilPleinEcran) {
    return null;
  }
  return r;
}
