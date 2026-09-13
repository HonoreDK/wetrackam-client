# Synchronisation bidirectionnelle WeTrackam Web ↔ WeTrackam Client

Version v15. Ce document décrit les mécanismes implémentés, par quel canal, et
comment les recetter. Il ne constitue pas une preuve de recette réelle.

## 1. Les trois canaux (par ordre de priorité)

| Canal | Déclencheur | Latence | Rôle |
|---|---|---|---|
| Socket temps réel (`control`) | Publication serveur `RtcControlPublisher` | < 1 s | Canal principal |
| Push FCM silencieux | Même publication, si la socket est fermée | quelques secondes | Application en arrière-plan |
| Epoch `X-Driver-Epoch` + `GET /state` | Tout appel authentifié, reconnexion, retour au premier plan, sondage 60 s | au plus 60 s | Filet, jamais désarmé |

Le filet ne dépend d'aucun événement : même si une publication est perdue, l'epoch
en base finit par être lu et provoque le rechargement. Les événements ne servent
qu'à rendre la réaction immédiate.

Dédoublonnage : chaque message porte `eventId` (idempotence) et `seq` (ordre).
Le même événement arrivé par socket ET par push n'est traité qu'une fois.

## 2. Table action → événement → effet mobile

| # | Action (web ou manager mobile) | Événement publié | Effet immédiat sur le téléphone |
|---|---|---|---|
| 1 | Création d'un chauffeur | — (rien à notifier) | s/o |
| 2 | Définition / réinitialisation du PIN | `pin.rotated` **(ajouté v14)** | Rechargement ; la session en cours reste valide |
| 3 | Provisionnement / QR | `session.revoked` si re-provisionnement | Retour à l'écran d'appairage |
| 4 | Affectation d'un véhicule | `assignment.changed` | L'écran d'accueil affiche le véhicule, la prise de service s'ouvre |
| 5 | Retrait d'affectation | `assignment.removed` | Prise de service refermée, éligibilité relue |
| 6 | Modification d'un véhicule affecté (documents) | `assignment.changed` motif `vehicle:documents` **(ajouté v14)** | Fiche véhicule rafraîchie côté chauffeur |
| 7 | Suspension (web) | `lifecycle.changed` + `session.revoked` | Session coupée, écran de blocage |
| 8 | Suspension (app manager) | idem **(ajouté v14)** | Identique au chemin web |
| 9 | Réactivation (app manager) | `lifecycle.changed` motif `active` **(ajouté v14)** | Le chauffeur redevient opérationnel sans relancer l'application |
| 10 | Archivage | `lifecycle.changed` + fermeture de socket | Session invalidée |
| 11 | Suppression | `lifecycle.changed` motif `driverDeleted` | Purge locale complète |
| 12 | Clôture de service (web) | `shift.closed` | Arrêt local de l'émission de positions, puis rechargement |
| 13 | Clôture de service (app manager) | `shift.closed` motif `managerMobile` **(ajouté v14)** | Identique au chemin web |
| 14 | Changement de mode de flotte | `mode.changed` | Écran d'accueil reconstruit dans le nouveau mode |
| 15 | Réglages tenant (chat, appels, notes vocales) | `settings.changed` | Capacités et limites relues |
| 16 | Déliaison d'appareil | `device.unbound` | Retour à l'appairage |
| 17 | Jeton push obsolète | `push.stale` | Réenregistrement ; **n'incrémente pas l'epoch** (sinon toute la flotte rechargerait) |

## 3. Sens mobile → web

- Positions et états de service : flux Traccar habituel, puis `TenantEventBus`.
- Actions manager depuis le mobile : passent par les mêmes ressources que le web et
  publient donc sur `TenantEventBus` (`driverId`, `driverName`, motif, epoch), ce qui
  rafraîchit la console sans attendre son sondage.
- Indisponibilité signalée par le chauffeur, notes vocales, messages : événements
  temps réel dédiés déjà en place.

## 4. Isolation multi-tenant

Règle unique : **le tenant d'un événement est toujours résolu depuis le chauffeur
ciblé**, jamais depuis l'appelant ni depuis le véhicule. `RtcControlPublisher.publish`
charge le chauffeur, lit son `tenantId`, et n'émet que sur ce canal. Une action d'un
manager du tenant A sur une fiche du tenant B est refusée en amont
(`assertSameTenant` / `TenantGuard`) et ne produit donc aucun événement.

Recette d'isolation : ouvrir une socket authentifiée pour un chauffeur du tenant B,
effectuer les 17 actions ci-dessus sur un chauffeur du tenant A, vérifier qu'aucun
message n'arrive sur la socket B.

## 5. Recette à deux téléphones

1. Téléphone 1 = chauffeur, téléphone 2 = manager, plus la console web ouverte.
2. Pour chaque ligne du tableau : déclencher l'action, chronométrer l'apparition de
   l'effet sur le téléphone 1 (cible < 2 s socket ouverte).
3. Répéter les lignes 4, 7, 9 et 13 **en mode avion** côté téléphone 1 : rétablir le
   réseau, l'effet doit apparaître en moins de 60 s (filet epoch/sondage).
4. Répéter la ligne 9 **application tuée** : rouvrir, l'effet doit être déjà appliqué
   (lecture d'epoch au premier appel authentifié).

## 6. Limites connues

- Le sondage de repli est volontairement inactif en arrière-plan : là, c'est le push
  FCM qui prend le relais. Un téléphone en arrière-plan sans push (fabricant qui tue
  l'application, absence de Google Play Services) se resynchronise au retour à l'écran.
- Aucune compilation Java/Flutter ni recette sur deux appareils n'a pu être
  exécutée dans cet environnement. Suivre `FIREBASE-ET-RECETTE.md` ; la
  validation finale exige la compilation et les tests réels, pas leur seule
  description dans ce document.
