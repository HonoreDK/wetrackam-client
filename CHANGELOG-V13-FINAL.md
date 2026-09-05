# WeTrackam Chauffeur — v13 (finalisation client)

Cette version corrige les causes réelles des symptômes rapportés
(« la VoIP, la messagerie vocale, la carte et le temps réel ne marchent pas »).
Chaque point ci-dessous indique le défaut trouvé, puis le correctif.

## 1. Appels (VoIP)

| Défaut trouvé | Correctif |
|---|---|
| L'appelant restait bloqué sur « sonnerie » : le serveur n'émettait jamais `call.state {connected}`. | `rtc/src/server.js` émet l'état `connected` aux **deux** pairs à l'acceptation ; `call_service.dart` bascule aussi après la SDP answer (`_markConnected()` idempotent). |
| Appel reçu application fermée / écran verrouillé : **jamais** signalé. | Handler FCM d'arrière-plan → écran d'appel natif (CallKit iOS, notification plein écran Android) via `call_ui_service.dart`. Manifeste : `USE_FULL_SCREEN_INTENT`, `showWhenLocked`, `turnScreenOn`. |
| Le push ne contenait ni `callId` ni délai de sonnerie → acceptation non corrélable. | Le serveur génère le `callId` **avant** le push et y joint `callId`, `callerId`, `ringTimeoutSeconds`. |
| Android 14+ coupait le micro dès l'écran verrouillé. | `CallForegroundService.kt` (type `microphone`) + canal `wetrackam/call_fgs` dans `MainActivity.kt`, piloté par Dart. |
| Acceptation depuis l'écran natif avec application tuée : sans effet. | `CallService.resumeExternalAcceptanceAtStartup()` appelé au démarrage (relit `activeCalls()`, reconnecte la socket, envoie `call.accept`). |
| Aucun nom affiché sur l'écran d'appel (le protocole n'en transporte pas). | `peer_name_cache.dart` : cache persistant alimenté par l'annuaire et la carte, lisible depuis l'isolate d'arrière-plan. Purgé à la déconnexion. |
| Changement Wi-Fi ↔ données : l'ICE restart existait mais n'était déclenché par personne. | `network_watcher.dart` (anti-rebond 1,2 s) : reconnexion socket puis ICE restart. |
| Statistiques d'appel envoyées deux fois. | Garde `_statsReported`, remis à zéro au nettoyage. |
| Politiques serveur en MAJUSCULES (`ON_DUTY`) jamais reconnues côté client. | Normalisation dans `rtc_config_service.dart`, repli fail-close. |

## 2. Notes vocales

- Limites lues à la **racine** de la réponse d'intention (`maxBytes`,
  `maxDurationSeconds`, `acceptedMimeTypes`, `maxPerHour`) — l'ancien code
  cherchait un objet `limits` inexistant et retombait sur 2 Mo en dur.
- Erreurs `type:error` corrélées par `requestId` (serveur corrigé pour le
  renvoyer sur **tous** les refus, y compris `media.play.intent`).
- File d'attente persistante (SharedPreferences, 20 entrées, 24 h) : une note
  enregistrée en zone blanche part au retour du réseau, même après fermeture.
- Motifs de refus traduits explicitement dans la conversation.

## 3. Carte des collègues

- Écran refait avec `flutter_map` / OpenStreetMap : vue carte + liste,
  marqueurs, recentrage, actions appel/chat, positions périmées grisées.
- **Bug d'unité corrigé** : la socket relaie `position.getSpeed()` en **nœuds**
  alors que le REST expose déjà des km/h. Un camion à 90 km/h s'affichait à
  49 km/h entre deux sondages. Conversion ×1,852 appliquée.
- Le sondage s'arrête en arrière-plan (batterie et données).

## 4. Sécurité réseau

- Android : plus de confiance aux certificats **utilisateur** (interception
  triviale via proxy) ; cleartext restreint à la boucle locale.
- iOS : `NSAllowsArbitraryLoads` supprimé, `NSAllowsLocalNetworking` conservé
  pour les démos ; modes d'arrière-plan `voip` + `audio` ajoutés.

## 5. Dépendances

`flutter_map ^8.3.1`, `latlong2 ^0.9.1`, `connectivity_plus ^7.3.1`,
`flutter_callkit_incoming ^3.1.5`, et **`http` relevé à ^1.5.0** (exigé par
`flutter_map 8.3.1` : sans cela `flutter pub get` échoue).

## 6. Côté serveur (à redéployer)

Le fichier `rtc/src/server.js` du livrable a été corrigé (callId avant push,
données FCM complètes, `call.state connected`, `requestId` sur tous les refus).
`node --check` passe. **Ces corrections serveur sont indispensables** : sans
elles, le client v13 ne peut pas afficher les appels hors application.

## 7. Ce qui reste à faire par vous (impossible ici)

Ni Flutter, ni Xcode, ni CocoaPods ne sont installés dans cet environnement :
aucune compilation n'a pu être exécutée. Les contrôles réalisés sont statiques
(XML/plist validés, `node --check` serveur, imports et symboles Dart vérifiés).

```bash
# Windows / Git Bash
flutter pub get          # met à jour pubspec.lock (http 1.5.x)
flutter analyze
flutter build apk --release
```

```bash
# macOS, pour iOS
cd ios && pod install && cd ..
flutter build ipa
```

Recette sur appareil réel, dans cet ordre :
1. Appel entrant application **fermée**, écran verrouillé → sonnerie plein écran.
2. Décrocher depuis l'écran natif → audio bidirectionnel.
3. Verrouiller l'écran pendant l'appel → l'interlocuteur entend toujours.
4. Bascule Wi-Fi → 4G pendant l'appel → l'audio reprend (ICE restart).
5. Note vocale en mode avion → partie automatiquement au retour du réseau.
6. Carte collègues : vitesse cohérente avec le tableau de bord web.
