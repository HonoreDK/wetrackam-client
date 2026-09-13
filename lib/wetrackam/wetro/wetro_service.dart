import '../api_client.dart';
import 'wetro_models.dart';

/// Client de l'assistant : les deux routes de `WetroDriverResource`.
///
/// Interface étroite pour que le contrôleur reste testable sans réseau
/// (test/wetro_controller_test.dart joue le serveur).
abstract class WetroService {
  /// Disponibilité et sources/actions consultables pour CETTE session.
  Future<WetroState> state();

  /// Pose une question.
  ///
  /// [vocal] : question DICTÉE dont la réponse sera lue (phrases courtes,
  /// sans balisage). [conduite] : le téléphone roule (vitesse au-dessus du
  /// seuil de l'espace) — l'assistant répond en une phrase, sans écran à
  /// regarder. Indications de FORME, jamais de droit.
  Future<WetroAnswer> ask(
    String question, {
    required List<WetroMessage> historique,
    required bool vocal,
    required bool conduite,
  });
}

/// Implémentation réelle, par le même client HTTP que le reste de
/// l'application (jeton chauffeur, époque, épinglage TLS, purge centralisée
/// sur 401). Rien n'est mis en cache : la politique de l'espace est relue
/// par le serveur à chaque appel, et l'application n'en garde aucune copie.
class ApiWetroService implements WetroService {
  const ApiWetroService();

  @override
  Future<WetroState> state() async {
    final body = await WetrackamApiClient.fetchWetroState();
    return WetroState.fromJson(body);
  }

  @override
  Future<WetroAnswer> ask(
    String question, {
    required List<WetroMessage> historique,
    required bool vocal,
    required bool conduite,
  }) async {
    final q = question.trim();
    if (q.isEmpty) {
      throw const ApiException(400, 'badRequest', reason: 'questionRequired');
    }
    final body = await WetrackamApiClient.askWetro(corps(q,
        historique: historique, vocal: vocal, conduite: conduite));
    return WetroAnswer.fromJson(body);
  }

  /// Corps de la requête `ask`, exposé pour les tests : ce que le serveur
  /// reçoit doit être exactement ce que le contrat décrit.
  static Map<String, Object?> corps(
    String question, {
    required List<WetroMessage> historique,
    required bool vocal,
    required bool conduite,
  }) =>
      {
        'question': question.length > wetroMaxQuestion ? question.substring(0, wetroMaxQuestion) : question,
        'history': wetroHistorique(historique),
        'surface': 'mobile',
        'voice': vocal,
        'driving': conduite,
        // Ce que CETTE surface sait exécuter : le serveur n'en propose au
        // modèle que l'intersection avec la politique réelle.
        'actions': [for (final t in WetroActionType.values) wetroActionTypeVers(t)],
      };
}
