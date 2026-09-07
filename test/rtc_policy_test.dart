// test/rtc_policy_test.dart — politiques tenant reçues du serveur.
//
// Le serveur envoie des énumérations en MAJUSCULES (CommSettings.java).
// Toute régression ici réactive silencieusement une fonction coupée par
// l'exploitant : c'est le test le plus important du fichier.
import 'package:flutter_test/flutter_test.dart';
import 'package:wetrackam_client/wetrackam/rtc_config_service.dart';

void main() {
  group('RtcPolicy.normalizeEnum', () {
    test('accepte les formes serveur en MAJUSCULES', () {
      expect(RtcPolicy.normalizeEnum('ON_DUTY', fallback: 'none'), 'onDuty');
      expect(RtcPolicy.normalizeEnum('NONE', fallback: 'tenant'), 'none');
      expect(RtcPolicy.normalizeEnum('TENANT', fallback: 'none'), 'tenant');
    });

    test('accepte le camelCase et les espaces', () {
      expect(RtcPolicy.normalizeEnum(' onDuty ', fallback: 'none'), 'onDuty');
      expect(RtcPolicy.normalizeEnum('tenant', fallback: 'none'), 'tenant');
    });

    test('valeur inconnue ou absente : repli fermé', () {
      expect(RtcPolicy.normalizeEnum('WHATEVER', fallback: 'none'), 'none');
      expect(RtcPolicy.normalizeEnum(null, fallback: 'none'), 'none');
      expect(RtcPolicy.normalizeEnum('', fallback: 'tenant'), 'tenant');
      expect(RtcPolicy.normalizeEnum(42, fallback: 'none'), 'none');
    });
  });

  group('RtcPolicy.fromJson', () {
    test('carte coupée par le tenant : fleetVisibility none', () {
      final policy = RtcPolicy.fromJson({
        'callsEnabled': true,
        'chatEnabled': true,
        'fleetVisibility': 'NONE',
        'directoryScope': 'ON_DUTY',
        'showPhone': false,
        'speedLockKmh': 20,
        'voiceMaxSeconds': 60,
      });
      expect(policy.fleetVisibility, 'none');
      expect(policy.directoryScope, 'onDuty');
      expect(policy.callsEnabled, isTrue);
      expect(policy.speedLockKmh, 20);
      expect(policy.voiceMaxSeconds, 60);
    });

    test('champs absents : rien n\'est activé par défaut', () {
      final policy = RtcPolicy.fromJson({});
      expect(policy.callsEnabled, isFalse);
      expect(policy.chatEnabled, isFalse);
      expect(policy.fleetVisibility, 'none');
      expect(policy.showPhone, isFalse);
    });
  });

  group('RtcConfig', () {
    test('module masqué : tout est fermé', () {
      expect(RtcConfig.masked.enabled, isFalse);
      expect(RtcConfig.masked.policy.callsEnabled, isFalse);
      expect(RtcConfig.masked.policy.chatEnabled, isFalse);
      expect(RtcConfig.masked.policy.fleetVisibility, 'none');
      expect(RtcConfig.masked.iceServers, isEmpty);
    });

    test('réponse sans bloc policy : repli fermé, pas d\'écran actif', () {
      final config = RtcConfig.fromJson({'enabled': true, 'wsUrl': 'wss://x/rt'});
      expect(config.enabled, isTrue);
      expect(config.policy.chatEnabled, isFalse);
      expect(config.policy.fleetVisibility, 'none');
    });
  });
}
