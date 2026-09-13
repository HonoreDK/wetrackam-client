# Appels VoIP — v17 : diagnostic complet et corrections (client, serveur, manager)

Recette sur téléphones réels (rapport d'exploitation) :

> « Même quand on décroche, le téléphone continue de vibrer et sonner » ;
> « la notification de sonnerie reste en haut » ; « l'appel ne fait pas plus
> de 20 s et se raccroche seul » ; « l'autre a raccroché mais mon écran reste
> en cours » ; « j'ai raccroché mais il m'entend encore » ; « deux éléments
> sonnent ».

Tout a été reproduit par lecture du code (client, plugin natif, serveur) et
chaque symptôme a une cause identifiée ci-dessous. Aucun correctif n'a été
posé « au symptôme » : chaque cause est traitée à sa source, avec un test
qui la verrouille.

## 1. Causes racines (ce qui se passait vraiment)

| # | Symptôme | Cause | Où |
|---|---|---|---|
| R1 | Coupe seul après ≈ 20 s, « appel manqué » en prime | La notification native d'appel entrant survivait au décrochage fait sur la page Flutter (seul son *son* était coupé par `setCallConnected`). Elle portait un délai d'expiration égal à la durée de sonnerie ; à l'expiration, le plugin émettait `TIMEOUT`, que l'app traitait comme un **refus** → `hangUp()` de l'appel décroché. | `call_ui_service.dart`, `call_service.dart` |
| R2 | Sonne/vibre encore après décrochage | La notification native était affichée **en plus** de la page Flutter, de façon asynchrone (lecture du nom) : elle pouvait être postée *après* le décrochage ; et `setCallConnected` ne trouvait pas l'appel (pas encore enregistré, ou enregistré dans un autre isolate) → la sonnerie continuait. | idem |
| R3 | « Deux éléments sonnent », notification en haut pendant l'appel | Page Flutter + notification native pour la même sonnerie ; puis jusqu'à trois notifications « appel en cours » (plugin ×2 + service de premier plan). | idem |
| R4 | Événements natifs appliqués au mauvais appel | `Decline`/`Ended`/`Timeout` natifs appliqués à l'appel courant quel que soit son identifiant ou sa phase. | `call_service.dart` |
| R5 | Décroché sur l'écran natif : page « Appel entrant » toujours affichée avec ses boutons ; application tuée : aucun écran d'appel | Les écrans naviguaient chacun pour soi ; personne n'ouvrait l'écran d'appel sur `connected`. | `call_navigator.dart`, écrans |
| R6 | Chronomètre qui démarre avant la sonnerie ; retour à l'écran d'accueil après l'appel | `InCallScreen` comptait depuis son `initState` ; `popUntil(isFirst)` dépilait toute la navigation. | `in_call_screen.dart` |
| R7 | « J'ai raccroché mais il m'entend encore » / « son écran reste en cours » | `RealtimeService.send` **jetait** tout message si la socket n'était pas connectée : un `call.hangup` pendant une reconnexion était perdu. | `realtime_service.dart` |
| R8 | Décroché mais muet, puis coupé | Les candidats ICE de l'appelé **doublaient** la réponse SDP côté serveur (`callAccept` attendait la base avant de relayer), arrivaient chez l'appelant sans description distante, étaient rejetés et perdus ; ICE échouait → `mediaLost`. | `server.js`, `call_service.dart` |
| R9 | Appel fantôme après une coupure | Aucune réconciliation à la reconnexion : le serveur avait clos l'appel, le téléphone restait « en cours ». | client + serveur |
| R10 | Appel coupé par une simple bascule wifi/4G ou une mise en veille | Le serveur terminait l'appel **dès** la fermeture d'une socket (`peerDisconnected`), sans prévenir le côté coupé. | `server.js` |
| R11 | Accepter sur l'écran verrouillé ne faisait rien (application fermée) | À l'ouverture de la socket, le serveur **purgeait** l'appel en cours comme « résiduel » : l'acceptation ne trouvait plus d'appel. | `server.js` |
| R12 | Le téléphone sonnait 30 s pour un appel déjà annulé | Appel reçu par push (application fermée) : aucune information de fin n'était poussée quand l'appelant raccrochait avant le décrochage. | `server.js`, push |

## 2. Corrections

### Client chauffeur (`wetrackam-client-v16-final`)

- **`lib/wetrackam/call_policy.dart`** (nouveau) — décisions pures, testées
  (`test/call_policy_test.dart`, 28 cas) :
  - `decideNativeEvent` : un événement natif ne vaut que pour l'appel qu'il
    nomme, dans la phase où il a un sens. Un `timeout` sur un appel décroché
    est **ignoré** (R1) ; un refus tardif est ignoré (R4) ; l'acceptation
    reçue avant la signalisation est mémorisée **par identifiant**.
  - `nextRouteAction` : une seule route d'appel, pilotée par la phase (R5).
  - `shouldRingInApp` : Android au premier plan = page Flutter + sonnerie
    applicative ; sinon écran natif ; iOS = CallKit (R2, R3).
  - `CallSignalQueue` : signaux `call.*` rejoués à la reconnexion, bornés en
    nombre (30) et en âge (25 s) ; un raccrochage annule les candidats du
    même appel (R7).
- **`call_ui_service.dart`** (réécrit) — une seule surface à la fois :
  `showNativeIncoming` idempotent **entre isolates** (via `activeCalls()`),
  `dismissIncoming` dès le décrochage (ferme sonnerie, vibration,
  notification et son minuteur), `markConnected` (CallKit sur iOS seulement ;
  Android : le service de premier plan est l'unique notification, avec le
  nom du collègue ; `callingNotification` du plugin désactivée), `endAll`,
  `endFromPush`.
- **Android natif** — `CallRinger.kt` (nouveau) : sonnerie + vibration au
  premier plan, respectant le mode sonnerie ; `MainActivity.kt` :
  `ringStart`/`ringStop`, sonnerie coupée à la destruction de l'activité.
- **`call_service.dart`** — sonnerie coupée **avant** l'ouverture du micro
  au décrochage ; candidats distants mis en file jusqu'à la description
  distante (R8) ; `call.resume` à chaque `ready` (R9) ; `call.peer` →
  « Reconnexion… » ; état média réel (`mediaUp`) → « Connexion… » ; appel
  sortant en phase sonnerie **avant** la préparation (R6) ; appel manqué
  signalé (annulation, délai) ; fin d'appel reçue par push (R12) ; fenêtre de
  reprise média 15 s (< grâce serveur 25 s).
- **`realtime_service.dart`** — file de signaux d'appel + `readyEvents`
  (rejeu avant l'annonce du `ready`) ; rouvre la socket si un signal d'appel
  est émis alors qu'elle était fermée en arrière-plan.
- **`call_navigator.dart`** (réécrit) — tient l'unique route d'appel :
  pousse, remplace (`replaceWithInCall` au décrochage natif), retire
  (`removeRoute`, jamais `popUntil`), annonce la cause de fin.
- **Écrans** — `incoming_call_screen.dart` (« Connexion… » dès l'appui),
  `in_call_screen.dart` (chronomètre sur `connectedAt`, statuts vrais), les
  écrans annuaire/flotte n'ouvrent plus l'écran d'appel eux-mêmes.
- **`push_notifications_service.dart`** — type `call_ended` (fermeture de
  l'écran natif + « appel manqué ») ; le push `call` d'arrière-plan passe par
  `showNativeIncoming` (idempotent).
- **`error_catalog.dart`** — phrases pour chaque cause de fin (`declined`,
  `timeout`, `networkUnavailable`, `mediaUnavailable`, …).
- **`main.dart`** — premier plan/arrière-plan transmis à `CallService`
  (bascule de surface), répartiteur relié au `ScaffoldMessenger`.
- Analyse : `flutter analyze` **0 issue** (les deux écrans hérités de
  l'upstream Traccar importaient un paquet inexistant, corrigé).

### Serveur temps réel (`communication/rtc`, v1.7.0)

- **Grâce de socket** (`RTC_CALL_GRACE_MS`, 25 s par défaut) : une socket
  perdue en cours d'appel ne raccroche plus ; le pair reçoit
  `call.peer{reconnecting}` puis `call.peer{online}` ; l'appel se termine
  (`peerDisconnected`) seulement si le participant ne revient pas (R10).
- **Reprise** : à toute nouvelle socket (même si l'ancienne est encore vue
  ouverte — TCP à demi ouvert), l'appel en cours est annoncé : `call.state
  {…, resumed:true}` ou, pour l'appelé encore sonné, **`call.incoming`
  complet avec l'offre** (R11). `call.resume {callId}` répond l'état réel ou
  `call.ended{unknown}` (R9).
- **Signalisation d'abord** : `call.accepted` relayé avant l'écriture en
  base — un candidat ne double plus jamais la réponse (R8) ; une base lente
  ne fait plus échouer l'acceptation.
- **Raccrochage idempotent** : `call.hangup/decline/cancel` sur un appel
  inconnu répond `call.ended{unknown}` (plus une erreur affichée).
- **Push `call_ended`** (data-only) à l'appelé réveillé par push quand
  l'appel se termine sans décrochage (R12) ; remplace l'ancien push
  « Appel manqué » (le téléphone l'affiche lui-même).
- Sonde post-déploiement `tools/signaling-probe.mjs` : 16 contrôles, dont
  les 7 nouveaux (grâce, reprise, relance pendant la sonnerie, ordre
  réponse/candidat, hangup idempotent). Jouée localement : **16/16**.

### Manager mobile (`wetrackam-manager-mobile-v4.6`)

- `call.resume` à chaque `ready`, `call.peer` → « Reconnexion… », appel
  « repris » sans média → raccroché pour libérer le pair, `call.ended
  {unknown}` = fin normale, fenêtre de reprise 15 s. Tests : +6 (177 verts).

## 3. Ce que fait maintenant un appel, pas à pas

1. **Sortant** : l'écran « Appel en cours… » s'ouvre immédiatement ; le
   micro et l'offre se préparent derrière ; `call.state{ringing}` fixe le
   `callId` ; « Connexion… » puis chronomètre dès que le média passe.
2. **Entrant, application ouverte (Android)** : page d'appel entrant +
   sonnerie applicative. Appui « Accepter » → sonnerie coupée
   **immédiatement**, « Connexion… », puis écran d'appel en cours.
3. **Entrant, écran verrouillé / application derrière une autre** :
   notification plein écran native (seule surface). Répondre → l'application
   revient, l'écran d'appel en cours s'ouvre, une seule notification
   « appel en cours ».
4. **Entrant, application fermée** : push → écran natif ; répondre relance
   l'application, la socket s'ouvre, le serveur **renvoie l'invitation**,
   l'acceptation mémorisée est rejouée. L'appelant raccroche avant ? Push
   `call_ended` → l'écran natif se ferme, « appel manqué ».
5. **Coupure réseau pendant l'appel** : « Reconnexion… » des deux côtés ; le
   serveur garde l'appel 25 s, le téléphone tente un redémarrage ICE
   (appelant) pendant 15 s ; si ça revient, le chronomètre reprend ; sinon
   fin propre avec « Connexion perdue avec votre collègue ».
6. **Raccrochage** : immédiat à l'écran ; le signal part, ou attend la
   reconnexion (25 s max) s'il n'y a pas de socket ; le pair est prévenu dans
   tous les cas (signal, ou `call.ended{unknown}` à sa propre reprise, ou
   fin du média).

## 4. Vérification

- `flutter analyze` (client) : 0 issue ; `flutter test` : 58 tests verts
  (+28 `call_policy_test.dart`).
- Manager : `flutter analyze` 10 infos préexistantes ; 177 tests verts.
- Serveur : `node --check` ; sonde de signalisation 16/16 en local (sans
  base, sans FCM : la signalisation ne dépend plus d'eux).
- `verification/verifier_appels_v17.py` (30 invariants, intégré à
  `verifier-livrable.sh`) ; `verifier_recette_smoke.py` mis à jour (1.7.0).

## 5. Limites honnêtes / à valider sur appareil

- Pas de SDK Android ni de Mac ici : le Kotlin (`CallRinger`, `MainActivity`)
  a été relu à la main contre les API du plugin déjà compilées dans ce
  projet ; la recette sur téléphone reste indispensable (voir §6).
- iOS : le chemin CallKit est conservé (`setCallConnected`, `endCall`) ; sans
  PushKit, l'appel entrant application tuée n'est pas couvert sur iOS
  (inchangé, documenté depuis la v13).
- Le plugin `flutter_callkit_incoming` affiche sa propre notification
  « appel manqué » quand SON délai expire (téléphone hors réseau) ; le push
  `call_ended` ne montre pas une seconde notification dans ce cas
  (`endFromPush` vérifie `activeCalls`).

## 6. Recette (deux téléphones + serveur déployé)

1. A appelle B, B ouvert au premier plan : B sonne **une fois** (pas de
   notification en haut), décroche → sonnerie coupée à l'instant, une seule
   notification « appel en cours », conversation > 2 min sans coupure.
2. B raccroche → A voit la fin **immédiatement** ; A ne s'entend plus, B non
   plus. Inverser les rôles.
3. B écran verrouillé : notification plein écran ; répondre depuis l'écran
   verrouillé ; l'application s'ouvre sur l'écran d'appel.
4. B application tuée : idem ; A raccroche avant réponse → l'écran natif de B
   disparaît en < 3 s, « appel manqué ».
5. Pendant l'appel, couper le wifi de B (passage 4G) : « Reconnexion… »
   chez A, retour du son en < 15 s, chronomètre qui continue.
6. Mettre B en mode avion 10 s puis le rétablir : l'appel reprend ; 40 s :
   fin propre des deux côtés avec « Connexion perdue ».
7. `bash communication/scripts/smoke-post-deploy.sh` après déploiement :
   sonde 16/16.
