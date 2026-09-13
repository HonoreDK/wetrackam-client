// test/error_catalog_test.dart — aucun message serveur brut à l'écran.
import 'package:flutter_test/flutter_test.dart';
import 'package:wetrackam_client/wetrackam/error_catalog.dart';

void main() {
  group('ErrorCatalog', () {
    test('un code inconnu ne fuit jamais tel quel vers le chauffeur', () {
      final message = ErrorCatalog.http(error: 'someInternalServerCode');
      expect(message, isNot(contains('someInternalServerCode')));
      expect(message, isNotEmpty);
    });

    test('401 : chaque motif a son écran', () {
      expect(ErrorCatalog.unauthorized('tokenExpired'), contains('PIN'));
      expect(ErrorCatalog.unauthorized('accountSuspended'), contains('suspendu'));
      expect(ErrorCatalog.unauthorized('deviceReplaced'), contains('autre appareil'));
      expect(ErrorCatalog.unauthorized(null), isNotEmpty);
    });

    test('PIN : le compte à rebours vient du serveur, pas de l\'app', () {
      expect(ErrorCatalog.driverAuth('invalidCredentials', retryAfterSeconds: 30),
          contains('30 s'));
      expect(ErrorCatalog.driverAuth('locked', retryAfterSeconds: 120), contains('2 min'));
    });

    test('PIN : les refus TLS ne retombent jamais sur le message générique', () {
      for (final code in <String>[
        'tlsHostMismatch',
        'tlsPinsetUnavailable',
        'tlsCertificateMismatch',
        'tlsCertificateInvalid',
        'tlsIdentityMismatch',
        'invalidAuthResponse',
      ]) {
        expect(ErrorCatalog.http(error: code), isNot('Une erreur est survenue. Réessayez.'));
      }
    });

    test('motifs de blocage de la prise de service', () {
      expect(ErrorCatalog.blockReason('licenseExpired', licenseExpiry: '01/09/2026'),
          contains('01/09/2026'));
      expect(ErrorCatalog.blockReason('motifInconnu'), isNotEmpty);
    });

    test('serveur injoignable ≠ erreur métier', () {
      expect(ErrorCatalog.transverse(status: null), contains('injoignable'));
      expect(ErrorCatalog.transverse(status: 429, scope: 'tenant'), contains('flotte'));
    });

    test('alerte gestionnaire : sans contact configuré, message dédié', () {
      expect(ErrorCatalog.notifyManagerResult(sent: true), contains('prévenu'));
      expect(ErrorCatalog.notifyManagerResult(sent: false, reason: 'noContact'),
          contains('contact'));
    });
  });
}
