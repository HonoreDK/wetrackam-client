# Wetro dans l'application chauffeur (v17) — bouton, chat, voix, actions

Le même majordome Wetro que sur le web et l'application manager, pour le
chauffeur : bouton flottant en bas à gauche (évitement temps réel), panneau
de conversation, voix « à la Siri » (mot d'éveil « Wetro » et ses
prononciations, réponses lues, interruptions), actions exécutées par
l'application (appeler un collègue ou un responsable, écrire, ouvrir un
écran, déclencher un SOS confirmé).

Serveur commun (`/api/mobile/wetro/*` → même fournisseur, même quota par
espace client, mêmes règles de dialogue que `WETRO-MOBILE.md` côté manager).

## 1. Ce qui a été ajouté

### Serveur (Traccar)

| Fichier | Rôle |
|---|---|
| `console-superadmin/java/WetroSupport.java` (nouveau) | Ce que les relais gestionnaire et chauffeur PARTAGENT : réglages, **compteur d'usage à verrou unique** (une question chauffeur et une question manager du même espace ne se perdent plus l'une l'autre), historique borné et nettoyé, encadrement des données. `WetroResource` délègue (sans changer ses invariants). |
| `wetrackam-client/java/WetroDriverActions.java` (+ test, 42 cas) | Catalogue **fermé** : `call_driver`, `message_driver`, `call_manager`, `open_conversation`, `open_screen`, `sos`. Chaque type exige que la **politique de l'espace** le permette (appels, chat, annuaire, carte, temps réel configuré). Une personne visée doit figurer dans les listes collectées à l'instant. **Le SOS exige toujours une confirmation.** |
| `wetrackam-client/java/WetroDriverTools.java` | Sources du chauffeur, toutes filtrées par SON tenant : `ma_situation` (service, véhicule, site, politique), `mes_responsables` (gestionnaire principal, co-gestionnaires, responsables **dont la portée couvre ce chauffeur** — `AccessScope.coversDriver` — avec l'identifiant de participant pour l'appel), `collegues` (mêmes règles que l'annuaire mobile : `TENANT` / `ON_DUTY` / `NONE`, sans téléphone), `alerte_sos` (son alerte ouverte). |
| `wetrackam-client/java/WetroDriverResource.java` | `GET /api/mobile/wetro/state`, `POST /api/mobile/wetro/ask`. Session chauffeur (`MobileSessionGuard`), quota arbitré avant l'appel payant (urgence = SOS ouvert), consigne `WetroPrompt.systemeChauffeur` (aucun droit de gestion, sécurité d'abord, mode vocal, mode conduite), action validée contre les listes collectées. `epoch` = état du chauffeur × politique : la conversation repart quand la situation change. |
| `WetroPrompt.systemeChauffeur` (+ 15 cas) | Persona chauffeur : simple, court, jamais un autre espace client ni ce que voient les gestionnaires ; « LE CHAUFFEUR ROULE » = une phrase, pas d'écran. |
| `Dockerfile.traccar-full` | COPY + test isolé de `WetroDriverActions` ; invariants du relais chauffeur (session chauffeur, tenant relu, responsables couvrants, quota partagé, clé jamais renvoyée). |

### Application chauffeur (`lib/wetrackam/wetro/`)

```
wake_word.dart, wetro_dialogue.dart   IDENTIQUES à l'application manager (vérifié par cmp)
wetro_voice_engine.dart               speech_to_text + flutter_tts (même moteur)
wetro_avoidance.dart, wetro_obstacles.dart   évitement (port de fabEvitement.js)
wetro_models.dart                     contrat chauffeur (6 actions, 5 écrans, natures SOS)
wetro_service.dart                    /api/mobile/wetro/* (WetrackamApiClient) — interface + impl.
wetro_controller.dart                 conversation, disponibilité, voix, actions (port fidèle)
wetro_host.dart / wetro_app_host.dart ce que l'app prête : CallService.placeCall,
                                      ChatService.sendText (accusé attendu), DistressService.raiseSos,
                                      navigation (accueil, carte, annuaire, SOS, diagnostics)
wetro_binding.dart                    naît avec la session (PIN / démarrage), meurt à la purge
wetro_runtime.dart, wetro_overlay.dart, wetro_fab.dart, wetro_panel.dart, wetro_wave.dart
```

Branchements : `main.dart` (`WetroOverlay` dans `MaterialApp.builder`,
`WetroRouteObserver`, hook de purge `WetroBinding.stop`), `pin_auth_screen.dart`
(`WetroBinding.start`), `api_client.dart` (`fetchWetroState`, `askWetro`),
`pubspec.yaml` (`speech_to_text`, `flutter_tts`), `AndroidManifest.xml`
(`<queries>` RecognitionService / TTS), `Info.plist`
(`NSSpeechRecognitionUsageDescription`).

## 2. Les contrats, un par un

| Contrat | Comment il est tenu |
|---|---|
| Isolation inter-tenant | `TenantGuard.tenantOf` sur chaque chauffeur, véhicule, responsable ; session et fiche dans deux espaces = `crossTenant` (403). Le modèle ne reçoit que des blocs de données déjà filtrés, encadrés comme DONNÉES. |
| Isolation inter-site | Les responsables sont ceux qui **couvrent** ce chauffeur (site explicite, sinon site du véhicule). L'annuaire suit la règle produit existante de l'espace (tenant / en service / aucun) — jamais plus que l'écran Annuaire. |
| Multi-rôles (côté chauffeur) | `mes_responsables` distingue *gestionnaire principal*, *co-gestionnaire*, *responsable de site* ; « mon responsable » = le responsable de site s'il existe, sinon le gestionnaire principal. Un responsable n'est « joignable par appel » que s'il détient `comm.call` — et le service temps réel revalide encore (`/api/mobile/push/peer`). |
| Permissions en temps réel | Politique relue **à chaque question** ; `epoch` renvoyé ; `/state` relu à l'ouverture du panneau, toutes les 60 s au premier plan, au retour au premier plan, et sur tout événement `control` de la socket. Conversation effacée quand l'époque change. |
| Synchronisation / temps réel | Actions par les voies temps réel existantes (`call.invite`, `chat.send` avec accusé, `/api/distress` avec idempotence). Wetro ne dit « c'est envoyé » qu'après l'accusé serveur. |
| Automatisation | Appel / ouverture : après la phrase de confirmation. Message : confirmation vocale. **SOS : toujours confirmé** (voix « oui » ou puce), même si le serveur l'oubliait (`wetro_models.dart` force `needsConfirmation`). |
| Communication bilatérale | Réponses lues ; fenêtre de relance de 7 s ; interruption pendant la lecture (écho filtré, « stop » seul = silence, pas une question). |
| Sécurité au volant | Au-dessus de `speedLockKmh` : saisie verrouillée (comme la conversation), bouton « Parler » seul, `driving: true` envoyé → une phrase, pas d'écran. |
| Appels | Pendant un appel (sonnerie comprise), la voix se tait et le bouton s'escamote ; l'éveil reprend après. |
| Rien de persisté | Conversation en mémoire, effacée à la purge ; seuls deux réglages (à l'oreille, lecture). |

## 3. Cas de figure traités (et testés)

`test/wetro_controller_test.dart` (26), `wetro_wake_word_test.dart`,
`wetro_avoidance_test.dart`, `wetro_overlay_test.dart` — 168 tests verts.

- Disponible seulement pour l'audience `driver` (une session web est refusée).
- Indisponible (plateforme, 401, 403) : panneau fermé, voix suspendue, fil effacé sur 401.
- Époque changée pendant une conversation : fil réinitialisé, note affichée.
- Question écrite : `voice=false`, `driving` transmis, rien n'est lu ; l'action est une puce (jamais exécutée seule).
- Action refusée par le serveur : dite, jamais exécutée. Type inconnu : ignoré.
- SOS : puce/voix, « oui » déclenche (phrase « Restez en sécurité »), « non » annule, silence n'envoie rien, deux réponses floues annulent, échec dit honnêtement.
- Voix : mot d'éveil sous ses prononciations (« witro », « wétro »…), « Wetro » seul → « Oui ? », interruption pendant la lecture, écho ignoré, « stop » seul, appel entrant coupe la voix, dictée indisponible → erreur explicite, voix coupée pendant que la question voyage → réponse affichée, ni lue ni exécutée.

## 4. Mon avis et les limites honnêtes

- **Le bon découpage** : le modèle ne fait que *proposer* dans un format fermé ; le serveur *valide* contre ce qu'il vient de collecter pour ce chauffeur ; l'application *exécute* par ses voies habituelles. Aucune des trois couches ne fait confiance à la précédente. C'est ce qui rend l'ensemble blindé sans dépendre du modèle.
- **SOS par la voix** : utile (mains occupées), mais une transcription déformée ne doit jamais mobiliser un dépôt : la confirmation est obligatoire et le « non » l'emporte toujours sur un « oui » qui suit.
- **« Wetro » à l'oreille hors de l'application** : la dictée du téléphone (Google / Siri) ne fonctionne qu'application **au premier plan** ; en arrière-plan iOS coupe le micro et Android l'interrompt. Le mode éveil est donc actif sur tous les écrans de l'application tant qu'elle est visible — pas quand le chauffeur est sur Waze. Un vrai mot d'éveil en arrière-plan exige un moteur embarqué (Porcupine/Vosk) + service de premier plan micro permanent : consommation, autorisation « micro en arrière-plan », validation Play Store. À décider comme un lot à part si le terrain le réclame.
- **Nom des responsables** : Wetro ne donne jamais de téléphone (source sans numéro) — il appelle par le service temps réel, sous la validation du serveur.
- Pas de SDK Android ici : `flutter analyze` (0 issue) et 168 tests verts ; la recette téléphone du §5 reste indispensable (micro, sonnerie, TTS français).

## 5. Recette sur téléphone

0. **D'abord, vérifier que l'application installée est bien celle-ci.** Le
   code vit dans `C:\Wetrackam-f\WeTackam\wetrackam-client-v16-final`
   (`pubspec.yaml` : `17.1.0+171`) ; les dossiers `C:\WeTackam\wetrackam-client-v16-final`
   (16.0.0+160) et `C:\WeTackam\wetrackam-client-v17-final` (17.0.0+170) n'ont
   **pas** Wetro. Sur le téléphone : appui long sur le titre « WeTrackam » →
   Diagnostic → section **Assistant Wetro** → la ligne
   `Build : v17.1.0 (171) — Wetro chauffeur inclus` doit apparaître. Si la
   section n'existe pas, l'APK vient d'un autre dossier. La même section dit
   ensuite pourquoi le bouton serait absent (`Assistant disponible`,
   `Dernière erreur d'état`). Côté serveur, chaque démarrage de session
   laisse une trace `mobile-audit … GET /mobile/wetro/state -> 200` dans
   `tracker-server.log`.
1. Ouvrir l'application, se connecter : bouton Wetro en bas à gauche, il s'écarte des boutons de l'écran et revient à sa place. Le bouton **SOS** reste en bas à droite, intact (épreuve `wetro_overlay_test.dart` : visible et touchable avec ou sans Wetro, panneau ouvert ou non).
2. Taper « Qui est mon responsable ? » → noms et rôles ; « Appelle mon responsable » → puce → appel.
3. Micro : « quel est mon véhicule » → réponse lue ; parler par-dessus : Wetro se tait.
4. Activer l'oreille (interrupteur en haut du panneau — **désactivé par défaut** : le micro ne s'ouvre qu'après un geste, puis le réglage est retenu) : « Wétro, appelle Jean » (aussi « witro », « wêtro ») → appel lancé. Sans l'oreille activée, dire « Wetro » ne fait rien : c'est voulu.
5. « Wetro, j'ai eu un accident » → « Je déclenche une alerte accident… Je confirme ? » → « non » → rien ; refaire → « oui » → alerte visible sur la page Détresse du manager.
6. Rouler (> seuil) : saisie verrouillée, bouton Parler, réponses d'une phrase.
7. Recevoir un appel pendant l'éveil : la voix se tait ; après l'appel, l'éveil reprend.
8. Gestionnaire coupe les appels dans l'espace : à la question suivante, « appelle Jean » est refusé et Wetro le dit.
