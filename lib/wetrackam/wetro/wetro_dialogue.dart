/// Règles PURES du dialogue vocal : ce qui est une interruption, ce qui
/// est un « oui », ce qui n'est que l'écho de la voix de Wetro dans le
/// micro, et comment préparer un texte pour qu'il soit dit proprement.
///
/// Séparé du moteur (micro, synthèse) pour être testé cas par cas : c'est
/// ici que se joue la sensation « il m'écoute comme une personne ».
library;

import 'wake_word.dart';

/// Phases du dialogue vocal.
enum WetroVoicePhase {
  /// Micro fermé. Rien n'écoute.
  idle,

  /// Écoute discrète du seul mot d'éveil (« Wetro »).
  wake,

  /// Wetro a été appelé : il écoute une commande.
  attentive,

  /// La question est partie au serveur.
  thinking,

  /// Wetro parle. Le micro reste ouvert pour l'interruption.
  speaking,

  /// Wetro attend un oui / non (envoi d'un message dicté).
  confirming,
}

/// Verdict sur un texte entendu PENDANT que Wetro parle.
enum WetroBargeIn {
  /// Rien à faire (bruit, écho de la synthèse, mot isolé sans sens).
  ignore,

  /// Se taire et écouter : la personne a repris la parole.
  interrupt,
}

/// Réponse à une demande de confirmation.
enum WetroConsent { yes, no, unclear }

class WetroDialogue {
  WetroDialogue._();

  /// Mots qui, seuls ou en tête, coupent la parole de Wetro.
  static const _stops = {
    'stop', 'arrete', 'arretes', 'attends', 'attend', 'tais', 'chut', 'silence',
    'annule', 'annuler', 'laisse', 'pause', 'suffit', 'assez', 'ok', 'merci',
    'non', 'quoi', 'pardon', 'repete', 'repetes',
  };

  static const _oui = {
    'oui', 'ouais', 'ok', 'okay', 'daccord', 'accord', 'confirme', 'confirmer',
    'envoie', 'envoyer', 'envoi', 'vas', 'vasy', 'go', 'exact', 'parfait',
    'bon', 'bien', 'sur', 'affirmatif', 'yes', 'yep', 'valide', 'valider', 'correct',
  };

  static const _non = {
    'non', 'nan', 'annule', 'annuler', 'laisse', 'stop', 'pas', 'jamais',
    'negatif', 'no', 'nope', 'attends', 'faux', 'incorrect', 'refuse', 'oublie',
  };

  /// Décide si un texte entendu pendant la synthèse est une vraie prise de
  /// parole.
  ///
  /// [entendu] : transcription (partielle ou finale). [prononce] : ce que
  /// Wetro est en train de dire. Le micro capte la voix de Wetro sur les
  /// téléphones sans annulation d'écho : si l'essentiel des mots entendus
  /// figure dans la phrase prononcée, c'est l'écho, pas la personne.
  static WetroBargeIn pendantParole(String entendu, String prononce) {
    final mots = WakeWord.normalise(entendu).split(' ').where((m) => m.isNotEmpty).toList();
    if (mots.isEmpty) return WetroBargeIn.ignore;
    if (WakeWord.contient(entendu)) return WetroBargeIn.interrupt;
    if (estEcho(mots, prononce)) return WetroBargeIn.ignore;
    if (_stops.contains(mots.first)) return WetroBargeIn.interrupt;
    // Une phrase d'au moins trois mots qui n'est pas l'écho : la personne
    // parle, on se tait. Deux mots ou moins : trop souvent un bruit ou une
    // bribe de la synthèse déformée.
    return mots.length >= 3 ? WetroBargeIn.interrupt : WetroBargeIn.ignore;
  }

  /// Vrai si les mots entendus sont, pour l'essentiel, ceux prononcés.
  static bool estEcho(List<String> motsEntendus, String prononce) {
    if (motsEntendus.isEmpty) return false;
    final dits = WakeWord.normalise(prononce).split(' ').where((m) => m.length > 1).toSet();
    if (dits.isEmpty) return false;
    var communs = 0;
    var comptes = 0;
    for (final m in motsEntendus) {
      if (m.length <= 1) continue;
      comptes++;
      if (dits.contains(m)) communs++;
    }
    if (comptes == 0) return false;
    return communs / comptes >= 0.6;
  }

  /// Lit un oui / non dans une réponse dictée.
  static WetroConsent consentement(String entendu) {
    final mots = WakeWord.normalise(entendu).split(' ').where((m) => m.isNotEmpty).toList();
    if (mots.isEmpty) return WetroConsent.unclear;
    // « non, envoie » : le premier mot porteur de sens l'emporte, et « non »
    // en tête est toujours un refus — on n'envoie jamais sur un doute.
    for (final m in mots) {
      if (_non.contains(m)) return WetroConsent.no;
      if (_oui.contains(m)) return WetroConsent.yes;
    }
    return WetroConsent.unclear;
  }

  /// Vrai si la phrase n'est faite QUE de mots d'arrêt (« stop », « attends
  /// attends ») : après une interruption, ce n'est pas une commande.
  static bool estArretSeul(String commande) {
    final mots = WakeWord.normalise(commande).split(' ').where((m) => m.isNotEmpty).toList();
    return mots.isNotEmpty && mots.every(_stops.contains);
  }

  /// Vrai si la commande dictée est vide ou n'est qu'un bruit de bouche.
  static bool estVide(String commande) {
    final t = WakeWord.normalise(commande);
    return t.isEmpty || t.length < 2;
  }

  /// Prépare un texte pour la synthèse : retire la mise en forme que le
  /// modèle pourrait avoir laissée malgré la consigne, borne la longueur
  /// (une lecture interminable est une lecture qu'on coupe), et remplace
  /// les symboles que la voix lit mal.
  static String pourLaVoix(String texte, {int maxCaracteres = 600}) {
    var t = texte;
    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    t = t.replaceAll(RegExp(r'[*_`#>|]'), '');
    t = t.replaceAll(RegExp(r'^\s*[-•]\s*', multiLine: true), '');
    t = t.replaceAll(RegExp(r'\[(.*?)\]\((.*?)\)'), r'$1');
    t = t.replaceAll('%', ' pour cent');
    t = t.replaceAll(RegExp(r'\bkm/h\b'), ' kilomètres heure');
    t = t.replaceAll(RegExp(r'\bkm\b'), ' kilomètres');
    t = t.replaceAll(RegExp(r'\bh\b'), ' heures');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length > maxCaracteres) {
      final coupe = t.lastIndexOf(RegExp(r'[.!?]'), maxCaracteres);
      t = coupe > maxCaracteres ~/ 2 ? t.substring(0, coupe + 1) : '${t.substring(0, maxCaracteres)}…';
    }
    return t;
  }
}
