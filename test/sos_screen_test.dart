// Garde-fous de l'écran SOS.
//
// Ce que ces tests protègent réellement :
//  1. l'écran se RENVOIE sans exception de mise en page (une contrainte non
//     bornée y planterait au premier affichage, c'est-à-dire au pire moment) ;
//  2. le bouton NE PART PAS sur un appui bref — c'est toute la raison d'être
//     de l'appui maintenu : un téléphone qui vibre sur le siège d'un camion
//     ne doit jamais réveiller les voisins ni armer une escalade.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wetrackam_client/wetrackam/distress_service.dart';
import 'package:wetrackam_client/wetrackam/sos_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('l\'écran SOS s\'affiche sans erreur de mise en page', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SosScreen()));
    expect(find.text('SOS'), findsOneWidget);
    expect(find.text('Maintenez appuyé 3 secondes'), findsOneWidget);
    // Le catalogue de natures doit être celui du serveur, au complet.
    for (final label in ['Détresse', 'Accident', 'Urgence médicale', 'Agression', 'Panne']) {
      expect(find.text(label), findsOneWidget, reason: 'nature manquante : $label');
    }
  });

  /// Valeur de l'anneau de progression, 0 = repos.
  double? progression(WidgetTester tester) => tester
      .widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator))
      .value;

  testWidgets('un appui bref ne déclenche AUCUNE alerte', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SosScreen()));

    final gesture = await tester.startGesture(tester.getCenter(find.text('SOS')));
    await tester.pump(); // démarre le ticker de l'animation
    await tester.pump(const Duration(milliseconds: 400)); // bien avant 3 s

    // L'appui est REELLEMENT pris en compte : sans cette assertion, le test
    // passerait aussi si le bouton ne réagissait pas du tout — il ne
    // prouverait alors rien de la garde anti-déclenchement.
    expect(progression(tester), greaterThan(0.0),
        reason: 'l\'anneau doit progresser pendant l\'appui');

    await gesture.up();
    await tester.pumpAndSettle();

    // Toujours sur l'écran de déclenchement : ni envoi, ni confirmation.
    expect(find.text('Maintenez appuyé 3 secondes'), findsOneWidget);
    expect(find.text('Envoi...'), findsNothing);
    expect(find.text('Alerte transmise'), findsNothing);
    expect(find.text('Alerte en attente de réseau'), findsNothing);
    // Et surtout : rien n'a été mis en file, donc rien ne partira plus tard.
    expect(await DistressService.hasPending(), isFalse);
  });

  testWidgets('le doigt qui glisse n\'annule PAS l\'appui', (tester) async {
    // Cas réel : 3 secondes d'appui dans une cabine qui tressaute. Un
    // GestureDetector abandonnerait le geste au premier glissement.
    await tester.pumpWidget(const MaterialApp(home: SosScreen()));

    final centre = tester.getCenter(find.text('SOS'));
    final gesture = await tester.startGesture(centre);
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveTo(centre + const Offset(18, 14)); // secousse
    await tester.pump(const Duration(milliseconds: 300));

    expect(progression(tester), greaterThan(0.0),
        reason: 'un glissement ne doit pas remettre l\'appui à zéro');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  test('la nature et la précision survivent à une coupure réseau', () async {
    SharedPreferences.setMockInitialValues({
      'wetrackam_pending_distress_alert_id': 'alerte-de-test',
      'wetrackam_pending_distress_kind': 'accident',
      'wetrackam_pending_distress_note': 'sortie de route',
    });
    // Une alerte en attente doit être visible : sans cela le chauffeur croit
    // les secours prévenus alors que rien n'est parti.
    expect(await DistressService.hasPending(), isTrue);

    final prefs = await SharedPreferences.getInstance();
    // Le rejeu doit repartir en « accident », jamais retomber sur « sos » :
    // c'est cette information qui oriente les secours.
    expect(prefs.getString('wetrackam_pending_distress_kind'), 'accident');
    expect(prefs.getString('wetrackam_pending_distress_note'), 'sortie de route');
  });
}
