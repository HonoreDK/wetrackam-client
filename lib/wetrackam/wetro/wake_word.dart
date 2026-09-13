/// Mot d'éveil « Wetro » — reconnaissance PURE, tolérante aux accents et
/// aux prononciations.
///
/// Un moteur de dictée n'a jamais entendu « Wetro » : il transcrit ce qu'il
/// croit reconnaître — « Wétro », « wêtro », « witro », « vétro », « oué
/// tro », « wet rö »… On ne compare donc pas des lettres, on compare une
/// SILHOUETTE phonétique : une attaque en w/v/ou, une voyelle, un t, un r,
/// une voyelle finale. Tout ce qui a cette silhouette est Wetro ; « métro »,
/// « rétro » ou « pétrole » ne l'ont pas.
///
/// Le texte qui suit le mot d'éveil est la commande (« Wetro, appelle
/// Jean » → « appelle Jean »). Tout ce qui le précède (« hey », « ok »,
/// « dis-moi », ou le début d'une phrase) est ignoré : le mot peut être
/// prononcé n'importe où.
library;

/// Résultat d'une détection.
class WakeWordMatch {
  const WakeWordMatch({required this.commande, required this.mot});

  /// Ce qui suit le mot d'éveil, nettoyé. Vide si rien ne suit.
  final String commande;

  /// Le mot tel qu'il a été transcrit (pour le journal, jamais pour agir).
  final String mot;
}

class WakeWord {
  WakeWord._();

  /// Silhouettes acceptées : w + voyelle(s) + t + r + voyelle(s).
  static final RegExp _silhouette = RegExp(r'^w+V+t+r+V+$');

  static const _accents = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ę': 'e', 'ė': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ō': 'o', 'ø': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
    'ÿ': 'y', 'ç': 'c', 'ñ': 'n',
  };

  /// Minuscules sans accents, ponctuation → espaces.
  static String normalise(String texte) {
    final b = StringBuffer();
    for (final rune in texte.toLowerCase().runes) {
      final c = String.fromCharCode(rune);
      final plain = _accents[c] ?? c;
      final code = plain.codeUnitAt(0);
      final lettre = (code >= 97 && code <= 122) || (code >= 48 && code <= 57);
      b.write(lettre ? plain : ' ');
    }
    return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Silhouette phonétique d'un mot normalisé : w/v/ou/u initial → w,
  /// voyelles → V, t/d → t, r → r ; tout le reste est conservé (et fera
  /// échouer la comparaison, ce qui est voulu).
  static String silhouette(String mot) {
    var m = mot;
    if (m.startsWith('ou')) m = 'w${m.substring(2)}';
    if (m.startsWith('oi')) m = 'w${m.substring(2)}';
    final b = StringBuffer();
    for (var i = 0; i < m.length; i++) {
      final c = m[i];
      String s;
      if (i == 0 && (c == 'w' || c == 'v' || c == 'u')) {
        s = 'w';
      } else if ('aeiouy'.contains(c)) {
        s = 'V';
      } else if (c == 't' || c == 'd') {
        s = 't';
      } else if (c == 'h') {
        continue; // « whetro », « wethro » : le h est muet
      } else {
        s = c;
      }
      b.write(s);
    }
    return b.toString();
  }

  /// Vrai si ce mot (normalisé) sonne comme « Wetro ».
  static bool estWetro(String mot) {
    if (mot.length < 4 || mot.length > 8) return false;
    if (!_silhouette.hasMatch(silhouette(mot))) return false;
    // Wetro finit toujours par un « o » (o, au, eau, ô…) : « vitre »,
    // « vêtre » ont la même silhouette mais un e muet en finale.
    final finale = _finale.firstMatch(mot)?.group(0) ?? '';
    return finale.contains('o') || finale.contains('u');
  }

  static final RegExp _finale = RegExp(r'[aeiouy]+$');

  /// Cherche le mot d'éveil dans une transcription. Retourne `null` s'il n'y
  /// est pas.
  ///
  /// Le mot peut être coupé en deux par le moteur (« wé tro », « wet ro ») :
  /// on essaie aussi la fusion de deux mots consécutifs.
  static WakeWordMatch? detecte(String transcription) {
    // Les mots sont repérés dans le texte ORIGINAL (accents, majuscules,
    // ponctuation intacts) et comparés sous forme normalisée : la commande
    // rendue est celle que la personne a dictée, pas une version aplatie —
    // un message à un chauffeur doit garder ses accents.
    final mots = _mots.allMatches(transcription).toList();
    if (mots.isEmpty) return null;
    final normaux = [for (final m in mots) normalise(m.group(0)!)];
    String commande(int depuis) =>
        depuis < mots.length ? transcription.substring(mots[depuis].start).trim() : '';
    for (var i = 0; i < mots.length; i++) {
      if (estWetro(normaux[i])) {
        return WakeWordMatch(commande: _sansPonctuationEnTete(commande(i + 1)), mot: normaux[i]);
      }
      if (i + 1 < mots.length) {
        final fusion = normaux[i] + normaux[i + 1];
        if (normaux[i].length <= 4 && normaux[i + 1].length <= 4 && estWetro(fusion)) {
          return WakeWordMatch(
            commande: _sansPonctuationEnTete(commande(i + 2)),
            mot: '${normaux[i]} ${normaux[i + 1]}',
          );
        }
      }
    }
    return null;
  }

  /// Suites de lettres ou de chiffres (toutes écritures), sans ponctuation.
  static final RegExp _mots = RegExp(r"[\p{L}\p{N}]+(?:['’][\p{L}]+)?", unicode: true);

  /// « Wetro, appelle Jean » → « appelle Jean » (la virgule reste collée au
  /// mot d'éveil, pas à la commande).
  static String _sansPonctuationEnTete(String s) =>
      s.replaceFirst(RegExp(r"^[\s,;:.!?…'’\-]+"), '').trim();

  /// Vrai si la transcription CONTIENT le mot d'éveil, sans extraire.
  static bool contient(String transcription) => detecte(transcription) != null;
}
