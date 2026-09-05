# Firebase et recette obligatoire

## Secrets à fournir avant compilation

- Android : `android/app/google-services.json`, application Firebase
  `org.traccar.client`.
- iOS : `ios/Runner/GoogleService-Info.plist`, bundle Firebase
  `org.traccar.client.TraccarClient`.
- APNs : clé ou certificat APNs associé au même projet Firebase et profil de
  signature avec la capacité Push Notifications.

Ces fichiers ne sont pas interchangeables avec le JSON de compte de service
chargé dans la console super-admin : ce dernier autorise le serveur à envoyer,
alors que les deux fichiers ci-dessus configurent les applications mobiles à
recevoir. Aucun secret factice n'est inclus.

## Commandes de contrôle

```bash
python3 scripts/verifier-livrable.py
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# Sur macOS uniquement
flutter build ios --release --no-codesign
```

## Recette réelle sur deux appareils, deux comptes

1. Appairer puis authentifier deux chauffeurs du même tenant/site autorisé.
2. Vérifier annuaire, présence et positions de carte dans les deux sens.
3. Envoyer texte et note vocale dans les deux sens, couper le réseau pendant
   l'envoi, puis vérifier un seul message après reconnexion et les ACK.
4. Appeler dans les deux sens en Wi-Fi, 4G/5G et après bascule réseau ; vérifier
   sonnerie écran verrouillé/app tuée, audio bidirectionnel et raccrochage.
5. Vérifier qu'un chauffeur d'un autre tenant ou site non autorisé n'apparaît
   pas et ne peut être joint.
6. Déconnecter le compte A, connecter B sur le même téléphone et vérifier
   qu'aucun message, fichier vocal, nom, position ou événement de A ne subsiste.

Un contrôle statique réussi ne prouve ni FCM, ni APNs, ni TURN, ni TLS, ni
l'audio. Conserver les journaux serveur/appareil de chaque scénario.