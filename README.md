# WeTrackam Client V17 — application chauffeur

Ce dossier autonome est la version de travail à remettre à Honoré. Il contient
l'application Flutter chauffeur et les raccordements au serveur WeTrackam :
appairage QR, authentification PIN, service, géolocalisation, annuaire et carte
des collègues autorisés, présence, messagerie, notes vocales, WebRTC/VoIP,
FCM/APNs et synchronisation de contrôle.

## Avant de compiler

1. Le fichier Firebase Android officiel est fourni. Déposer le fichier iOS
   officiel décrit dans `FIREBASE-ET-RECETTE.md` ; il n'est pas inventé.
2. Exécuter `python3 scripts/verifier-livrable.py`.
3. Exécuter `flutter pub get`, `flutter analyze`, `flutter test` (tests
   automatiques livrés dans `test/`), puis les
   builds Android/iOS depuis une machine équipée des SDK.
4. Réaliser toute la recette sur deux appareils et conserver les preuves.

## État honnête

Les contrats et défauts statiquement identifiés ont été corrigés, notamment le
bootstrap TLS, les hôtes multiples/rebase, l'attente du `ready` WebSocket, les
ACK de chat, les reprises vocales cloisonnées et la file ICE de l'appelant.
Dans cet environnement, Flutter/Dart, le fichier Firebase iOS et les signatures
de production sont absents : aucun APK/IPA, push réel, appel audio, TURN ou test
VPS n'est donc présenté comme validé.

Ce client ne porte aucun rôle manager. Les rôles manager tenant, co-manager et
responsable de site restent appliqués côté serveur/Manager Mobile ; le client
chauffeur ne reçoit que les données que son ticket et son périmètre tenant/site
autorisent.

L'audit de clôture fonction par fonction, avec la procédure de recette,
est dans `AUDIT-FINAL-CLIENT.md`.

## CI/CD (GitHub Actions)

Le workflow `.github/workflows/ci.yml` lance `flutter analyze` + `flutter test`
puis un build `flutter build apk --debug` à chaque push/PR sur `main`.
`android/app/google-services.json` n'est jamais commité (voir `.gitignore`) ;
la CI le reconstruit à partir d'un secret du dépôt GitHub.

Pour configurer ce secret sur le dépôt GitHub :

1. Encoder le fichier en base64 en local :
   ```
   base64 -w0 android/app/google-services.json
   ```
2. Dans le dépôt GitHub : Settings → Secrets and variables → Actions →
   New repository secret.
3. Nom : `GOOGLE_SERVICES_JSON_BASE64`, valeur : le texte obtenu à l'étape 1.

L'APK debug produit est téléchargeable comme artefact du run, dans l'onglet
Actions du dépôt.
"# wetrackam-client"  
# wetrackam-client
# wetrackam-client
