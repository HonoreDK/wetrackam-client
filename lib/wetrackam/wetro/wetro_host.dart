/// Ce que l'application chauffeur PRÊTE à Wetro pour exécuter une action.
///
/// L'assistant ne possède aucun service : il demande à l'application — qui
/// détient déjà l'appel (CallService), la messagerie (ChatService), l'alerte
/// (DistressService) et la navigation — de faire ce que le chauffeur aurait
/// fait à la main. Chaque méthode passe par la MÊME voie que le geste
/// manuel, donc par les mêmes gardes : politique relue par le serveur,
/// collègue dans l'annuaire, service temps réel configuré, session valide.
///
/// Les méthodes retournent `false` quand l'action n'a pas pu partir : Wetro
/// le dit alors à voix haute au lieu de faire semblant.
library;

abstract class WetroHost {
  /// Ouvre un écran par son nom (`home`, `fleet`, `directory`, `sos`,
  /// `diagnostics`).
  Future<bool> openScreen(String screen);

  /// Ouvre la discussion avec un collègue.
  Future<bool> openConversation(int driverId, String driverName);

  /// Lance un appel audio vers un collègue (identifiant chauffeur).
  Future<bool> callDriver(int driverId, String driverName);

  /// Lance un appel audio vers un responsable (identifiant de PARTICIPANT
  /// temps réel : 900000000 + identifiant de compte).
  Future<bool> callManager(int participantId, String managerName);

  /// Envoie un message texte à un collègue et attend l'accusé du serveur.
  Future<bool> messageDriver(int driverId, String driverName, String text);

  /// Déclenche une alerte de détresse de la nature donnée (`sos`, `accident`,
  /// `medical`, `security`, `breakdown`), après confirmation du chauffeur.
  Future<bool> raiseSos(String kind);

  /// Vrai pendant un appel (sonnerie comprise) : la voix de Wetro se tait,
  /// le micro est à l'appel.
  bool get inCall;

  /// Vrai quand le véhicule roule au-dessus du seuil de verrouillage de
  /// l'espace : Wetro parle, mais ne propose pas d'écran à regarder.
  bool get driving;
}
