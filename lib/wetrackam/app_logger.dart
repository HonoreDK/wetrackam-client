// lib/wetrackam/app_logger.dart
//
// Remplace les appels FirebaseCrashlytics.instance.log(...) retirés du
// code upstream. Aucun envoi réseau : conforme à la règle "pas de service
// de crash externe non déclaré" (prompt §2, anti-pattern §14).
//
// ⚠️ Ne jamais passer de PII à `breadcrumb()` : driverUniqueId, token,
// managerId, coordonnées GPS, plaque, nom du chauffeur, n° de téléphone.
// Passer uniquement des libellés d'événement (ex. 'tracking_toggle_start').
//
// Bug de diagnostic trouvé en analysant un vrai retour de log terrain :
// `developer.log()` seul ne s'affiche pas de façon fiable dans la console
// `flutter run` sans un débogueur/DevTools attaché — un log entier fourni
// pour investiguer un problème de synchronisation ne contenait AUCUNE des
// traces attendues, alors qu'elles auraient dû apparaître dès le
// démarrage. `print()` est ajouté en complément : il s'affiche TOUJOURS
// dans la console `flutter run`, quel que soit l'état du débogueur.
import 'dart:collection';
import 'dart:developer' as developer;

class AppLogger {
  AppLogger._();

  static final Queue<String> _ring = ListQueue<String>();
  static const int _maxEntries = 500; // borne mémoire, pas de fichier persistant

  /// Miette de contexte fonctionnelle (ex. 'geolocation_init'). Ne jamais
  /// y inclure de donnée personnelle — voir avertissement en tête de fichier.
  static void breadcrumb(String label) {
    final entry = '${DateTime.now().toIso8601String()} $label';
    _ring.add(entry);
    while (_ring.length > _maxEntries) {
      _ring.removeFirst();
    }
    developer.log(label, name: 'wetrackam');
    // Anomalie corrigée : ce commentaire ignore/avoid_print était scindé sur
    // deux lignes, la directive `ignore:` ne se trouvant donc pas
    // immédiatement au-dessus du print() ci-dessous — l'analyseur ne
    // l'associait plus, d'où l'avertissement qui persistait malgré tout.
    // Justification : garantit la visibilité en console flutter run, voir
    // avertissement en tête de fichier.
    // ignore: avoid_print
    print('[wetrackam] $label');
  }

  static void error(String label, Object error, [StackTrace? stackTrace]) {
    developer.log(label, name: 'wetrackam', error: error, stackTrace: stackTrace);
    // ignore: avoid_print
    print('[wetrackam] ERROR $label: $error');
  }

  /// Pour un futur écran de diagnostic interne (jamais transmis à un tiers).
  static List<String> recentBreadcrumbs() => List.unmodifiable(_ring);
}
