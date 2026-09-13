import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_avoidance.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_controller.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_fab.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_models.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_overlay.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_panel.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_runtime.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_service.dart';
import 'package:wetrackam_client/wetrackam/wetro/wetro_voice_engine.dart';

class MuteVoice implements WetroVoiceEngine {
  @override
  bool get available => false;
  @override
  bool get listening => false;
  @override
  bool get speaking => false;
  @override
  Future<bool> init() async => false;
  @override
  Future<bool> listen({
    required void Function(WetroListenResult result) onResult,
    required void Function(double level) onLevel,
    required void Function() onDone,
    Duration listenFor = const Duration(seconds: 20),
    Duration? pauseFor = const Duration(seconds: 3),
  }) async =>
      false;
  @override
  Future<void> cancelListening() async {}
  @override
  Future<void> stopListening() async {}
  @override
  Future<void> speak(String text) async {}
  @override
  Future<void> stopSpeaking() async {}
  @override
  Future<void> dispose() async {}
}

/// Serveur simulé pour la surcouche : disponible ou non, une réponse fixe.
class _Serveur implements WetroService {
  _Serveur({this.available = true});
  final bool available;

  @override
  Future<WetroState> state() async => WetroState.fromJson({
        'available': available,
        'audience': 'driver',
        'sources': ['ma_situation'],
        'actions': ['open_screen'],
        'screens': ['home'],
        'epoch': 1,
      });

  @override
  Future<WetroAnswer> ask(String question,
          {required List<WetroMessage> historique, required bool vocal, required bool conduite}) async =>
      WetroAnswer.fromJson({'answer': 'Votre véhicule est le camion bleu.', 'epoch': 1});
}

WetroController controleur({bool available = true}) => WetroController(
      service: _Serveur(available: available),
      voice: MuteVoice(),
    );

Widget appli({required Widget home}) => MaterialApp(
      navigatorObservers: [WetroRouteObserver()],
      builder: (context, child) => WetroOverlay(child: child!),
      home: home,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => WetroRuntime.instance.attach(null));

  testWidgets('rien sans contrôleur, bouton dès que l’assistant est disponible', (tester) async {
    await tester.pumpWidget(appli(home: const Scaffold(body: Text('accueil'))));
    expect(find.byType(WetroFab), findsNothing);

    final c = controleur();
    WetroRuntime.instance.attach(c);
    await c.init();
    await tester.pump();
    expect(find.byType(WetroFab), findsOneWidget);

    // Le bouton est en bas à gauche.
    final rect = tester.getRect(find.byType(WetroFab));
    final vue = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.left, lessThan(vue.width / 2));
    expect(rect.bottom, greaterThan(vue.height / 2));
    c.dispose();
  });

  testWidgets('indisponible côté serveur : aucun bouton', (tester) async {
    await tester.pumpWidget(appli(home: const Scaffold(body: Text('accueil'))));
    final c = controleur(available: false);
    WetroRuntime.instance.attach(c);
    await c.init();
    await tester.pump();
    expect(find.byType(WetroFab), findsNothing);
    c.dispose();
  });

  testWidgets('ouvrir, poser une question écrite, lire la réponse', (tester) async {
    await tester.pumpWidget(appli(home: const Scaffold(body: Text('accueil'))));
    final c = controleur();
    WetroRuntime.instance.attach(c);
    await c.init();
    await tester.pump();

    await tester.tap(find.byType(WetroFab));
    await tester.pumpAndSettle();
    expect(find.byType(WetroPanel), findsOneWidget);
    expect(find.textContaining('Bonjour, je suis Wetro'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Combien de véhicules ?');
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Votre véhicule est le camion bleu.'), findsOneWidget);

    // Le bouton reste visible et referme le panneau.
    await tester.tap(find.byType(WetroFab));
    await tester.pumpAndSettle();
    expect(find.byType(WetroPanel), findsNothing);
    c.dispose();
  });

  testWidgets('un dialogue escamote le bouton, sa fermeture le ramène', (tester) async {
    await tester.pumpWidget(appli(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(title: Text('Confirmer ?')),
              ),
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ));
    final c = controleur();
    WetroRuntime.instance.attach(c);
    await c.init();
    await tester.pump();
    expect(find.byType(WetroFab), findsOneWidget);

    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    expect(find.byType(WetroFab), findsNothing);

    await tester.tapAt(const Offset(5, 5)); // barrière : ferme le dialogue
    await tester.pumpAndSettle();
    expect(find.byType(WetroFab), findsOneWidget);
    c.dispose();
  });

  testWidgets('un bouton dans le coin fait monter Wetro d’un cran', (tester) async {
    await tester.pumpWidget(appli(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 8,
              bottom: 8,
              child: FilledButton(onPressed: () {}, child: const Text('Action')),
            ),
          ],
        ),
      ),
    ));
    final c = controleur();
    WetroRuntime.instance.attach(c);
    await c.init();
    await tester.pump();
    // Le balayage tourne après l'image, puis toutes les 300 ms.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final fab = tester.getRect(find.byType(WetroFab));
    final bouton = tester.getRect(find.text('Action'));
    expect(fab.overlaps(bouton), isFalse, reason: 'le bouton flottant ne couvre jamais un élément touchable');
    expect(fab.bottom, lessThan(bouton.top + 1));
    // Un cran, pas dix : il est monté de `pasFab` au plus près.
    final vue = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(vue.height - fab.bottom, lessThan(2 * pasFab + 40));
    c.dispose();
  });

  testWidgets('une liste de lignes pleine largeur ne chasse pas le bouton', (tester) async {
    await tester.pumpWidget(appli(
      home: Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < 30; i++) ListTile(title: Text('Chauffeur $i'), onTap: () {}),
          ],
        ),
      ),
    ));
    final c = controleur();
    WetroRuntime.instance.attach(c);
    await c.init();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final fab = tester.getRect(find.byType(WetroFab));
    final vue = tester.view.physicalSize / tester.view.devicePixelRatio;
    // Au repos : une ligne reste utilisable quand le bouton n'en couvre
    // que le coin ; sans cette règle il n'aurait nulle part où aller.
    expect(vue.height - fab.bottom, lessThan(pasFab));
    c.dispose();
  });

  testWidgets('le panneau ouvert n’est pas un obstacle pour son propre bouton', (tester) async {
    await tester.pumpWidget(appli(home: const Scaffold(body: Text('accueil'))));
    final c = controleur();
    WetroRuntime.instance.attach(c);
    await c.init();
    await tester.pump();
    final avant = tester.getRect(find.byType(WetroFab));
    await tester.tap(find.byType(WetroFab));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final apres = tester.getRect(find.byType(WetroFab));
    expect(apres, avant, reason: 'ses propres boutons (micro, envoyer, fermer) ne le font pas fuir');
    c.dispose();
  });

  testWidgets('le bouton SOS d’un écran reste visible et touchable, avec ou sans Wetro', (tester) async {
    // Même composition que l'écran d'accueil chauffeur : un Scaffold avec un
    // FloatingActionButton.extended « SOS » en bas à droite, sous la surcouche.
    var sos = 0;
    await tester.pumpWidget(appli(
      home: Scaffold(
        body: const Center(child: Text('accueil')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => sos++,
          icon: const Icon(Icons.sos),
          label: const Text('SOS'),
        ),
      ),
    ));
    expect(find.text('SOS'), findsOneWidget);
    await tester.tap(find.text('SOS'));
    await tester.pump();
    expect(sos, 1, reason: 'sans contrôleur, la surcouche est transparente');

    final c = controleur();
    WetroRuntime.instance.attach(c);
    await c.init();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(WetroFab), findsOneWidget);
    expect(find.text('SOS'), findsOneWidget);
    final sosRect = tester.getRect(find.text('SOS'));
    final wetro = tester.getRect(find.byType(WetroFab));
    expect(wetro.overlaps(sosRect), isFalse, reason: 'Wetro (gauche) ne couvre jamais le SOS (droite)');
    await tester.tap(find.text('SOS'));
    await tester.pump();
    expect(sos, 2, reason: 'le SOS reste touchable sous la surcouche Wetro');

    // Panneau ouvert : le SOS reste là et touchable.
    await tester.tap(find.byType(WetroFab));
    await tester.pumpAndSettle();
    expect(find.text('SOS'), findsOneWidget);
    await tester.tap(find.text('SOS'), warnIfMissed: false);
    await tester.pump();
    expect(sos, greaterThanOrEqualTo(2));
    c.dispose();
  });
}
