# État final du dossier WeTrackam Client v15

## Construit et raccordé dans le code

- appairage/provisionnement avec contrôle d'identité serveur et pinset Ed25519 ;
- TLS épinglé pour REST, WebSocket et médias, avec plusieurs hôtes et rebase ;
- authentification PIN, prise de service et purge inter-compte ;
- annuaire, présence et carte OpenStreetMap des chauffeurs autorisés ;
- messagerie avec identifiant idempotent, ACK et reprise hors ligne ;
- notes vocales avec intention, URL signée, upload, annonce et cache cloisonné ;
- WebRTC audio, TURN dynamique, trickle ICE sans perte avant le `callId`, reprise
  réseau, appels entrants natifs et nettoyage unique du micro ;
- FCM/APNs, contrôles de jeton et synchronisation bidirectionnelle de contrôle.

L'isolation tenant/site et les permissions sont imposées par le serveur et les
capacités du ticket. Le mobile ne permet pas de choisir ni d'usurper un tenant.

## Blocages externes et preuves manquantes

- `android/app/google-services.json` officiel absent ;
- `ios/Runner/GoogleService-Info.plist` officiel absent ;
- Flutter/Dart et Xcode absents de l'environnement d'audit ;
- aucune recette VPS authentifiée ni essai physique à deux appareils exécuté.

Par conséquent, le code est finalisé statiquement mais la livraison n'est pas
qualifiée « fonctionnelle en production » avant réussite des étapes de
`FIREBASE-ET-RECETTE.md`. Le script `scripts/verifier-livrable.py` échoue
volontairement tant que les deux fichiers Firebase officiels sont absents.