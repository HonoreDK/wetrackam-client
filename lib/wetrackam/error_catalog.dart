// lib/wetrackam/error_catalog.dart
//
// Lot 3 — Table de traduction EXHAUSTIVE des erreurs, contrat v5 §15
// (catalogue complet v4 + v5). Règle absolue (§3.3 v4, rappelée en tête du
// §15) : l'app affiche un message issu de cette table, jamais un texte
// serveur brut, jamais un code HTTP nu.
//
// Structure : `_httpCatalog` est la table MAÎTRESSE, indexée par `error`
// puis par `reason` (clé composite "error/reason" quand un `reason`
// distingue plusieurs cas sous le même `error`). Les méthodes publiques
// spécifiques à un écran (blockReason, notifyManagerResult...) ajoutent la
// mise en forme contextuelle (interpolation de date, compte à rebours...)
// par-dessus cette même table plutôt que de dupliquer un texte parallèle.
class ErrorCatalog {
  ErrorCatalog._();

  // ===================================================================
  // TABLE MAÎTRESSE — §15.2 du contrat v5 (catalogue complet HTTP)
  // ===================================================================
  //
  // Clé : "<error>" ou "<error>/<reason>" quand la distinction existe.
  // Valeur : message affichable. Une valeur vide ('') signifie
  // explicitement "ne rien afficher" (ex. rtcNotConfigured : masquage
  // silencieux des fonctions, pas un message d'erreur).
  static const Map<String, String> _httpCatalog = {
    // --- 400 : toujours "bug d'app" côté contrat — ne devraient jamais
    // survenir avec une app correcte, mais doivent rester silencieusement
    // sûrs plutôt que de planter ou d'afficher un JSON brut si un cas
    // imprévu se présente (régression serveur, version d'app en retard).
    'invalidToken': 'Ce lien n\'est pas valide.',
    // DELTA-v7.7-QR-APPAIRAGE.md §2 : "Un format inconnu renvoie 400
    // pairingUnrecognized avec un message lisible — jamais un plantage."
    'pairingUnrecognized': 'Lien ou QR code non reconnu. Réessayez ou contactez votre gestionnaire.',
    'missingDeviceUniqueId': 'Erreur technique. Réessayez ou contactez le support.',
    'invalidReason': 'Erreur technique. Réessayez ou contactez le support.',
    'badRequest/mode': 'Erreur technique. Réessayez ou contactez le support.',
    'badRequest/peerRequired': 'Erreur technique. Réessayez ou contactez le support.',
    'badRequest/peerSelf': 'Action impossible sur vous-même.',

    // --- 401 invalidCredentials (driver-auth uniquement — les autres 401
    // passent par `unauthorized(reason)`, indexés par reason et non error)
    'invalidCredentials': 'Code PIN incorrect.',
    'invalidAuthResponse': 'Réponse de connexion invalide. Contactez le support.',
    'tlsIdentityMismatch': 'L’identité du serveur a changé. Recommencez l’appairage.',

    // --- Réponse serveur inexploitable (200 mais corps invalide)
    'malformedResponse': 'Réponse du serveur illisible. Réessayez.',
    'missingToken': 'Réponse du serveur incomplète. Réessayez.',

    // --- Liaison TLS (voir TlsTrustException) ------------------------
    // Ces motifs ne sont PAS des pannes de réseau : le téléphone a bien
    // joint une machine, mais ce n'est pas — ou plus — celle à laquelle
    // il a été appairé. Le geste de réparation est donc le réappairage,
    // jamais « réessayer ».
    'tlsCertificateMismatch':
        'Ce serveur ne correspond pas à celui de votre appairage. '
            'Par sécurité, la connexion a été refusée. Rescannez le QR '
            'fourni par votre gestionnaire.',
    'tlsPinsetUnavailable':
        'Sécurité du serveur non initialisée sur ce téléphone. '
            'Rescannez le QR fourni par votre gestionnaire.',
    'tlsHostMismatch':
        'Adresse de serveur inattendue. Rescannez le QR fourni par votre '
            'gestionnaire.',
    'tlsCertificateInvalid':
        'Le certificat du serveur est illisible. Réessayez, puis '
            'prévenez votre gestionnaire si cela persiste.',
    'tlsHandshakeFailed':
        'Liaison sécurisée impossible avec le serveur. Vérifiez la date '
            'et l\'heure du téléphone, puis réessayez.',

    // --- 403 — communs à plusieurs endpoints
    'notADriverSession': 'Session invalide. Reconnectez-vous.',
    'licenseExpired': 'Votre permis est expiré. Contactez votre gestionnaire.',
    'driverNotActive': 'Votre compte est désactivé. Contactez votre gestionnaire.',
    'deviceNotAssigned': 'Ce véhicule ne vous est plus affecté.',
    // Incident d'isolation multi-tenant — les trois variantes serveur
    // convergent vers le même message utilisateur (§16 : aucune fuite
    // d'information technique sur la nature exacte de l'incident).
    'vehicleOutOfTenant': 'Erreur de configuration. Contactez le support.',
    'crossTenant': 'Erreur de configuration. Contactez le support.',
    'driverNotInTenant': 'Erreur de configuration. Contactez le support.',
    // v5 — module communication (§5, §12)
    'noTenant': 'Erreur de configuration. Contactez votre gestionnaire.',
    'chatDisabled': '', // masquage silencieux — voir isSilentMask()
    'callsDisabled': '', // masquage silencieux — voir isSilentMask()
    'peerUnavailable': 'Ce collègue n\'est plus joignable.',
    'peerCrossTenant': '', // incident isolation — jamais affiché tel quel, purge + rechargement silencieux (§16)
    // Lot 8 — appels (§13, PROMPT-MOBILE-HONORE.md §10). `busy` n'est pas
    // un champ `error` HTTP mais un `call.state.state` — reprise ici pour
    // que l'écran d'appel utilise la même table plutôt qu'un texte à part.
    'busy': 'Occupé. Vous pouvez lui écrire à la place.',


    // --- 404
    'tokenNotFound': 'Lien inconnu. Demandez un nouveau QR à votre gestionnaire.',
    'deviceNotFound': 'Ce véhicule n\'existe plus. Actualisation...',
    'noActiveShift': '', // §9 : retour silencieux à l'accueil, pas d'alarme

    // --- 409
    'tokenAlreadyUsed': 'Ce lien a déjà servi. Demandez-en un nouveau.',
    'deviceBoundToOtherDriver': 'Ce téléphone est déjà utilisé par un autre chauffeur.',
    'noVehicleAssigned': 'Aucun véhicule ne vous est affecté.',
    'vehicleAlreadyInService': 'Ce véhicule est actuellement utilisé par un autre chauffeur.',

    // --- 410
    'tokenExpired': 'Lien expiré. Demandez-en un nouveau.',
    'tokenRevoked': 'Lien annulé par votre gestionnaire.',

    // --- 423
    'locked': 'Compte verrouillé. Réessayez plus tard.',

    // --- 500
    'shiftStartFailed': 'Erreur serveur. Nouvelle tentative...',
    'tokenGenerationFailed': 'Erreur serveur, réessayez.',

    // --- 503
    'mobile_disabled': 'Accès mobile suspendu. Contactez votre gestionnaire.',
    'server_busy': 'Serveur momentanément saturé. Nouvelle tentative...',
    'rtcNotConfigured': '', // masquage silencieux total — voir isSilentMask()
  };

  /// Motifs qui ne doivent JAMAIS produire de message affiché : soit un
  /// masquage silencieux de fonctionnalité (rtcNotConfigured, chatDisabled,
  /// callsDisabled), soit un retour silencieux à un état neutre
  /// (noActiveShift), soit un incident traité par purge + rechargement
  /// plutôt que par un texte (peerCrossTenant, §16).
  static bool isSilentMask(String error) => _httpCatalog[error] == '';

  /// Point d'entrée générique pour tout endpoint sans mise en forme
  /// contextuelle particulière. `reason` permet de désambiguïser quand un
  /// même `error` recouvre plusieurs cas (essayé en premier sous la forme
  /// composite, puis replié sur `error` seul).
  static String http({required String error, String? reason, int? statusCode}) {
    if (reason != null) {
      final composite = _httpCatalog['$error/$reason'];
      if (composite != null) return composite;
    }
    final direct = _httpCatalog[error];
    if (direct != null) return direct;
    return 'Une erreur est survenue. Réessayez.';
  }

  // ===================================================================
  // Wrappers contextuels — ajoutent une mise en forme (date, compte à
  // rebours) par-dessus la table maîtresse, sans dupliquer son contenu.
  // ===================================================================

  /// §4.3 — Machine à états du jeton de provisionnement.
  static String provisioning(String error) => http(error: error);

  /// §5 / §20.5 — Authentification PIN. `retryAfterSeconds` vient de
  /// `Retry-After` / `retryAfterMs` (la valeur la plus élevée des deux,
  /// §20.3) — jamais recalculé ici, seulement mis en forme.
  static String driverAuth(String error, {int? retryAfterSeconds}) {
    if (error == 'invalidCredentials' && retryAfterSeconds != null && retryAfterSeconds > 0) {
      return 'Code PIN incorrect. Réessayez dans ${_formatDuration(retryAfterSeconds)}.';
    }
    if (error == 'locked' && retryAfterSeconds != null && retryAfterSeconds > 0) {
      return 'Compte verrouillé. Réessayez dans ${_formatDuration(retryAfterSeconds)}.';
    }
    return http(error: error);
  }

  /// Refus de liaison TLS (voir TlsTrustException). Volontairement séparé
  /// de `transverse()` : ce n'est ni un code HTTP, ni une panne réseau, et
  /// le geste attendu du chauffeur n'est pas le même.
  static String tls(String code) => http(error: code);

  /// Vrai si ce refus TLS ne se réglera pas en réessayant : le téléphone
  /// doit être réappairé. L'écran peut alors proposer le scan du QR au
  /// lieu d'un bouton « Réessayer » qui échouerait indéfiniment.
  static bool tlsNeedsRepairing(String code) =>
      code == 'tlsCertificateMismatch' ||
      code == 'tlsPinsetUnavailable' ||
      code == 'tlsHostMismatch';

  /// §15.1 — Les 401, indexés par `reason` (jamais par un message serveur,
  /// et jamais par `error` puisque `error` vaut toujours `"unauthorized"`
  /// pour ce code — c'est `reason` qui porte l'information utile).
  static String unauthorized(String? reason) => switch (reason) {
        'tokenExpired' => 'Votre session a expiré, saisissez votre code PIN.',
        'accountSuspended' => 'Votre compte est suspendu. Contactez votre gestionnaire.',
        'accountArchived' => 'Votre compte n\'est plus actif.',
        'deviceReplaced' => 'Votre compte est utilisé sur un autre appareil.',
        'assignmentRemoved' => 'Votre affectation a changé.',
        _ => 'Votre session a expiré, saisissez votre code PIN.', // repli le plus doux, §15.1
      };

  /// §7 — Prise de service.
  static String shiftStart(String error) => http(error: error);

  /// §9 — Fin de service.
  static String shiftEnd(String error) => http(error: error);

  /// §6.4 — Motifs de blocage à l'écran d'accueil (`blockReason`, un champ
  /// d'`/eligibility`, pas un code d'erreur HTTP — table séparée mais
  /// délibérément alignée en formulation sur `licenseExpired`/
  /// `noVehicleAssigned`/`vehicleAlreadyInService` de la table maîtresse).
  static String blockReason(String reason, {String? licenseExpiry}) => switch (reason) {
        'licenseExpired' => licenseExpiry != null
            ? 'Votre permis a expiré le $licenseExpiry. Contactez votre gestionnaire.'
            : http(error: 'licenseExpired'),
        'noVehicleAssigned' => http(error: 'noVehicleAssigned'),
        'vehicleAlreadyInService' => http(error: 'vehicleAlreadyInService'),
        _ => 'Impossible de démarrer votre service pour le moment.',
      };

  /// §10 — Réponse de `/notify-manager` (business response 200, pas une
  /// erreur HTTP — `sent: false` est un état normal, pas un échec).
  static String notifyManagerResult({required bool sent, String? reason, int? retryAfterSeconds}) {
    if (sent) return 'Votre gestionnaire a été prévenu.';
    if (retryAfterSeconds != null && retryAfterSeconds > 0) {
      return 'Alerte déjà envoyée. Nouvelle alerte possible dans ${_formatDuration(retryAfterSeconds)}.';
    }
    if (reason == 'noContact') {
      return 'Aucun contact n\'est configuré. Appelez votre gestionnaire.';
    }
    return 'Impossible d\'envoyer l\'alerte pour le moment.';
  }

  /// Codes HTTP transverses sans `error` métier précis à mapper (429
  /// générique, timeout réseau) — pour tout le reste, préférer `http()`.
  static String transverse({required int? status, String? error, String? scope}) {
    if (status == 429 && error != 'invalidCredentials') {
      return scope == 'tenant'
          ? 'Trop de requêtes pour votre flotte. Nouvelle tentative dans un instant.'
          : 'Trop de requêtes. Nouvelle tentative dans un instant.';
    }
    if (error != null && _httpCatalog.containsKey(error)) return http(error: error);
    if (status == null) return 'Serveur injoignable. Vérifiez le réseau.';
    return 'Une erreur est survenue. Réessayez.';
  }

  static String _formatDuration(int seconds) {
    if (seconds >= 60) {
      final minutes = (seconds / 60).ceil();
      return '$minutes min';
    }
    return '$seconds s';
  }
}
