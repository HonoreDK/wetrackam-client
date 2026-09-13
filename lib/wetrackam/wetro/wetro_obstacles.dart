import 'dart:ui' show CheckedState, Rect, SemanticsAction, Size, Tristate;

import 'package:flutter/rendering.dart';

import 'wetro_avoidance.dart';

/// Identifiant sémantique de la surcouche Wetro : ce qui le porte n'est
/// jamais un obstacle pour le bouton (le bouton et son panneau eux-mêmes).
const wetroOverlayIdentifier = 'wetro-overlay';

/// Repérage des obstacles du bouton flottant à partir de l'arbre
/// d'ACCESSIBILITÉ.
///
/// Pourquoi la sémantique et non l'arbre des widgets : un lecteur d'écran
/// a exactement le même besoin que Wetro — savoir ce qui, à l'écran, se
/// touche. Boutons, champs, interrupteurs, curseurs, lignes de liste
/// cliquables y sont annotés, quel que soit le widget qui les dessine, et
/// leurs rectangles sont ceux réellement peints. La console web fait de
/// même avec les rôles ARIA.
///
/// Coût : l'arbre sémantique est maintenu par le moteur tant qu'un
/// `SemanticsHandle` est ouvert (ce que la surcouche fait quand le bouton
/// est visible). Le parcours est borné à la ZONE où le bouton peut aller.
class WetroObstacleScanner {
  WetroObstacleScanner();

  /// Fraction de la largeur au-delà de laquelle une simple ligne
  /// cliquable (sans être un bouton ni un champ) n'est plus un obstacle :
  /// le bouton n'en couvre qu'un coin, elle reste utilisable. Sans cela,
  /// au-dessus d'une liste, le bouton n'aurait nulle part où aller.
  static const double largeurLigne = 0.7;

  /// Rectangles (coordonnées de la vue) des éléments interactifs qui
  /// touchent [zone], filtrés comme la console web.
  List<Rect> scan({required Size vue, required Rect zone}) {
    final out = <Rect>[];
    final racines = <SemanticsNode>[];
    final rootOwner = RendererBinding.instance.rootPipelineOwner;
    final r = rootOwner.semanticsOwner?.rootSemanticsNode;
    if (r != null) racines.add(r);
    rootOwner.visitChildren((child) {
      final n = child.semanticsOwner?.rootSemanticsNode;
      if (n != null) racines.add(n);
    });
    for (final racine in racines) {
      // La racine décrit la vue en pixels PHYSIQUES ; la première
      // descente porte l'échelle d'affichage. On ramène tout en pixels
      // logiques — ceux de notre zone — en partant de l'inverse de cette
      // échelle, lue sur la racine elle-même plutôt que supposée.
      final echelle = vue.width > 0 && racine.rect.width > 0 ? racine.rect.width / vue.width : 1.0;
      final depart = Matrix4.diagonal3Values(1 / echelle, 1 / echelle, 1);
      _visite(racine, depart, vue, zone, out);
    }
    return out;
  }

  void _visite(SemanticsNode node, Matrix4 parent, Size vue, Rect zone, List<Rect> out) {
    if (node.identifier == wetroOverlayIdentifier) return;
    final t = node.transform;
    final matrice = t == null ? parent : (parent.clone()..multiply(t));
    final global = MatrixUtils.transformRect(matrice, node.rect);
    if (!global.overlaps(zone)) return;
    final flags = node.flagsCollection;
    if (flags.isHidden) return;
    if (_interactif(node, flags)) {
      final retenu = obstacleRetenu(global, vue);
      if (retenu != null) {
        final large = retenu.width >= vue.width * largeurLigne;
        final ferme = flags.isButton || flags.isTextField || flags.isSlider;
        if (!large || ferme) out.add(retenu);
      }
      // Un élément interactif peut en contenir d'autres (une carte
      // cliquable avec ses boutons) : on continue.
    }
    node.visitChildren((child) {
      _visite(child, matrice, vue, zone, out);
      return true;
    });
  }

  bool _interactif(SemanticsNode node, SemanticsFlags flags) {
    if (flags.isButton || flags.isTextField || flags.isSlider || flags.isLink) return true;
    if (flags.isToggled != Tristate.none || flags.isChecked != CheckedState.none) return true;
    final data = node.getSemanticsData();
    return data.hasAction(SemanticsAction.tap) ||
        data.hasAction(SemanticsAction.longPress) ||
        data.hasAction(SemanticsAction.increase) ||
        data.hasAction(SemanticsAction.decrease);
  }
}
