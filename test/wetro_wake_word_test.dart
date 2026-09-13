import 'package:flutter_test/flutter_test.dart';
import 'package:wetrackam_client/wetrackam/wetro/wake_word.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_dialogue.dart';

void main() {
  group('WakeWord.normalise', () {
    test('minuscules, sans accents, ponctuation retirée', () {
      expect(WakeWord.normalise('Wétro, appelle Jean !'), 'wetro appelle jean');
      expect(WakeWord.normalise('  Wêtro…  '), 'wetro');
    });
  });

  group('WakeWord.estWetro — prononciations', () {
    for (final mot in [
      'wetro', 'wétro', 'wètro', 'wêtro', 'wëtro', 'wētro', 'witro', 'wïtro', 'wytro',
      'vetro', 'vétro', 'vitro', 'wettro', 'wetrro', 'ouétro', 'ouetro', 'wetrau', 'wetreau',
      'whetro', 'wétrô', 'wietro', 'wettrau',
    ]) {
      test('« $mot » est Wetro', () {
        expect(WakeWord.estWetro(WakeWord.normalise(mot)), isTrue, reason: mot);
      });
    }
  });

  group('WakeWord.estWetro — faux amis', () {
    for (final mot in [
      'metro', 'métro', 'retro', 'rétro', 'petro', 'pétrole', 'wet', 'we', 'vitre', 'vite',
      'watt', 'ouest', 'vidéo', 'vétérinaire', 'wagon', 'nitro', 'trop', 'tro', 'électro',
    ]) {
      test('« $mot » n’est pas Wetro', () {
        expect(WakeWord.estWetro(WakeWord.normalise(mot)), isFalse, reason: mot);
      });
    }
  });

  group('WakeWord.detecte', () {
    test('mot seul : commande vide', () {
      final m = WakeWord.detecte('Wetro');
      expect(m, isNotNull);
      expect(m!.commande, '');
    });
    test('commande après le mot', () {
      final m = WakeWord.detecte('Wétro, appelle Jean Mballa');
      expect(m!.commande, 'appelle Jean Mballa', reason: 'la commande garde sa forme dictée');
    });
    test('formule d’appel avant le mot', () {
      expect(WakeWord.detecte('hey wetro qui est en service')!.commande, 'qui est en service');
      expect(WakeWord.detecte('ok Wêtro ouvre la carte')!.commande, 'ouvre la carte');
      expect(WakeWord.detecte('dis moi wetro combien de camions')!.commande, 'combien de camions');
      expect(
        WakeWord.detecte('Wétro, écris à Paul : « le camion est prêt »')!.commande,
        'écris à Paul : « le camion est prêt »',
        reason: 'la commande garde accents et ponctuation : un message dicté part tel quel',
      );
    });
    test('mot coupé en deux par le moteur', () {
      expect(WakeWord.detecte('wé tro appelle paul')!.commande, 'appelle paul');
      expect(WakeWord.detecte('wet ro')!.commande, '');
    });
    test('absent : null', () {
      expect(WakeWord.detecte('le métro est en retard'), isNull);
      expect(WakeWord.detecte(''), isNull);
      expect(WakeWord.detecte('   '), isNull);
    });
    test('la fusion ne colle pas deux mots longs', () {
      // « ouvert rond » : fusion "ouvertrond" ne doit pas passer.
      expect(WakeWord.detecte('ouvert rond'), isNull);
    });
  });

  group('WetroDialogue.pendantParole (interruption)', () {
    const dit = 'Trois véhicules sont en ligne, un est hors ligne depuis hier.';
    test('écho de la synthèse : ignoré', () {
      expect(WetroDialogue.pendantParole('trois véhicules sont en ligne', dit), WetroBargeIn.ignore);
      expect(WetroDialogue.pendantParole('hors ligne depuis hier', dit), WetroBargeIn.ignore);
    });
    test('mot d’arrêt en tête : interruption', () {
      expect(WetroDialogue.pendantParole('stop', dit), WetroBargeIn.interrupt);
      expect(WetroDialogue.pendantParole('attends attends', dit), WetroBargeIn.interrupt);
      expect(WetroDialogue.pendantParole('Arrête', dit), WetroBargeIn.interrupt);
    });
    test('le mot d’éveil coupe toujours', () {
      expect(WetroDialogue.pendantParole('wetro', dit), WetroBargeIn.interrupt);
    });
    test('vraie phrase : interruption', () {
      expect(WetroDialogue.pendantParole('appelle plutôt Jean Mballa', dit), WetroBargeIn.interrupt);
    });
    test('bribe de deux mots étrangers : ignorée (bruit)', () {
      expect(WetroDialogue.pendantParole('la porte', dit), WetroBargeIn.ignore);
    });
    test('vide : ignoré', () {
      expect(WetroDialogue.pendantParole('', dit), WetroBargeIn.ignore);
    });
  });

  group('WetroDialogue.estArretSeul', () {
    test('mots d’arrêt seuls', () {
      expect(WetroDialogue.estArretSeul('stop'), isTrue);
      expect(WetroDialogue.estArretSeul('attends attends'), isTrue);
      expect(WetroDialogue.estArretSeul('attends Jean'), isFalse);
      expect(WetroDialogue.estArretSeul(''), isFalse);
    });
  });

  group('WetroDialogue.consentement', () {
    test('oui', () {
      for (final t in ['oui', 'Oui envoie', 'ok', 'd’accord', 'vas-y', 'confirme', 'c’est bon']) {
        expect(WetroDialogue.consentement(t), WetroConsent.yes, reason: t);
      }
    });
    test('non', () {
      for (final t in ['non', 'Non annule', 'annule', 'laisse tomber', 'non envoie pas']) {
        expect(WetroDialogue.consentement(t), WetroConsent.no, reason: t);
      }
    });
    test('un « non » en tête l’emporte sur un « oui » qui suit', () {
      expect(WetroDialogue.consentement('non enfin oui'), WetroConsent.no);
    });
    test('incompréhensible', () {
      expect(WetroDialogue.consentement('le camion bleu'), WetroConsent.unclear);
      expect(WetroDialogue.consentement(''), WetroConsent.unclear);
    });
  });

  group('WetroDialogue.pourLaVoix', () {
    test('retire le balisage et les symboles', () {
      final t = WetroDialogue.pourLaVoix('**Trois** véhicules :\n- A\n- B\n`code` 12 km à 80 km/h, 5 %');
      expect(t, isNot(contains('*')));
      expect(t, isNot(contains('-')));
      expect(t, isNot(contains('`')));
      expect(t, contains('kilomètres'));
      expect(t, contains('pour cent'));
    });
    test('borne la longueur à une phrase entière', () {
      final long = List.filled(60, 'Une phrase de test qui se termine bien.').join(' ');
      final t = WetroDialogue.pourLaVoix(long, maxCaracteres: 200);
      expect(t.length, lessThanOrEqualTo(201));
      expect(t.endsWith('.'), isTrue);
    });
  });
}
