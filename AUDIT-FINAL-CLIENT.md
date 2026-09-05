# Audit final — application chauffeur WeTrackam (v15)

Document unique de clôture de la partie client. Il dit, fonction par
fonction : où c'est codé, à quoi ça répond côté serveur, et comment le
vérifier sur deux téléphones. Ce qui n'a pas pu être prouvé ici est écrit
noir sur blanc à la fin.

## 1. Prise de service

| Point | Où | Contrat serveur |
|---|---|---|
| Écran construit sur un seul appel d'éligibilité | `lib/wetrackam/eligibility_screen.dart` | `GET /api/mobile/shift/eligibility` |
| Véhicule imposé (lecture seule) | idem, mode `ASSIGNED` | `mode` |
| Véhicule imposé + signalement d'indisponibilité | mode `ASSIGNED_WITH_FALLBACK` | `mode` |
| Choix libre dans le parc, sélection obligatoire | mode `FREE_POOL` + `availableVehicles` | `mode` |
| Mode inconnu renvoyé par un serveur plus récent | traité comme véhicule imposé, incident tracé | — |
| Motifs de blocage (permis expiré, aucun véhicule, véhicule déjà en service) | `error_catalog.dart` | `blockReason` |
| Réaffectation programmée annoncée | bandeau dédié | `pendingAssignment` |
| Service déjà en cours au lancement | écran « service en cours », chrono sur l'heure serveur | `shiftActive`, `startedAt` |
| Prise et fin de service idempotentes | `shift_service.dart`, identifiant de requête stable | `POST /shift/start`, `/shift/end` |

Recette : les trois modes, un permis expiré, un double appui rapide sur
« Prendre mon service » (une seule prise côté serveur), une fin de service
puis retour à l'écran du code.

## 2. Appels entre chauffeurs (VoIP)

| Point | Où |
|---|---|
| Signalisation complète (invitation, sonnerie, acceptation, refus, annulation, occupé, fin) | `call_service.dart` |
| Appelant considéré connecté dès la réponse audio du pair | `_markConnected()` (idempotent) |
| Appel entrant écran verrouillé / application fermée | `call_ui_service.dart`, `push_notifications_service.dart` |
| Acceptation depuis l'écran natif avant l'arrivée de la signalisation | intention mémorisée puis rejouée |
| Durée de sonnerie annoncée par le serveur | `timeoutSeconds` / `ringTimeoutSeconds` |
| Micro maintenu en arrière-plan (Android) | service de premier plan micro |
| Bascule Wi-Fi ↔ données pendant l'appel | `network_watcher.dart` → renégociation, pas de raccrochage |
| Fin d'appel : point de passage unique, micro toujours refermé | `_cleanup()` |
| **Correction v15** : candidats de connexion reçus pendant la sonnerie | mémorisés puis appliqués (`_pendingRemoteCandidates`, `_flushRemoteCandidates`) |

La correction v15 est un vrai défaut trouvé pendant cet audit : côté appelé,
la connexion n'existe qu'au décrochage, or les candidats de l'appelant
arrivent pendant la sonnerie. Ils étaient purement jetés. Sur un réseau où
seul le relais fonctionne (deux opérateurs mobiles différents), l'appel
décrochait puis restait muet, sans aucune erreur affichée.

Recette : appel local, appel entre deux opérateurs différents, appel refusé,
appel annulé, ligne occupée, appel reçu téléphone verrouillé, bascule de
réseau en pleine conversation.

## 3. Messages écrits

Fichier : `chat_service.dart`, `conversation_screen.dart`.

- Envoi par la liaison temps réel uniquement, jamais par une autre voie.
- Chaque message porte un identifiant client : un renvoi après coupure ne
  crée jamais de doublon.
- File locale persistante : un message écrit hors réseau part au retour du
  signal, même après redémarrage du téléphone.
- Accusés envoyé / reçu / lu remontés à l'écran.
- Refus définitifs (messagerie coupée, collègue hors périmètre) : message
  marqué en échec et retiré de la file ; seul le dépassement de cadence est
  rejoué.
- Indicateur de saisie limité à un envoi par seconde et par collègue.
- Purge complète au changement de chauffeur.
- Verrou de conduite : au-delà de la vitesse autorisée par l'entreprise, la
  saisie et l'enregistrement sont désactivés.

## 4. Notes vocales

Fichier : `voice_note_service.dart`.

- Dépôt en trois temps (intention, envoi, annonce), limites de taille, de
  durée et de format lues dans la réponse du serveur — aucune valeur inventée.
- File de reprise persistante, 20 notes, péremption à 24 h.
- Refus expliqués en clair (trop longue, trop lourde, format refusé).
- Lecture par lien signé, cache local purgé au changement de chauffeur.

## 5. Carte sociale des collègues

Fichier : `fleet_screen.dart`, `fleet_units.dart`.

- Carte OpenStreetMap et vue liste, marqueurs, recentrage, positions
  périmées grisées.
- Fiche d'un collègue : appeler, écrire, note vocale — selon ce que
  l'entreprise autorise.
- Rafraîchissement arrêté quand l'application passe en arrière-plan.
- Vitesse : le serveur envoie des nœuds sur la liaison temps réel et des
  km/h sur l'autre voie. La conversion est désormais centralisée et testée
  (`FleetUnits`), un camion à 90 km/h ne s'affiche plus à 49.
- Écran entièrement masqué quand l'entreprise coupe la fonction.

## 6. Synchronisation et contraintes

- Liaison temps réel : billet à usage unique demandé juste avant ouverture,
  jamais stocké ; attente du feu vert du serveur avant tout envoi ;
  reconnexion avec temporisation plafonnée.
- Changement d'adresse du serveur pris en compte sans rescan du QR, à
  condition que l'identité du serveur corresponde.
- Cloisonnement : aucune donnée d'une autre entreprise ni d'un autre site ne
  peut être demandée par l'application ; en cas de réponse hors périmètre,
  c'est traité comme un incident, pas comme un message métier.
- Permissions et politiques relues en direct : couper la messagerie, les
  appels ou la carte côté gestionnaire se voit immédiatement sur le
  téléphone, dans le sens fermé par défaut.
- Purge totale sur compte suspendu, archivé, remplacé ou supprimé.
- Sécurité réseau : chiffrement obligatoire avec empreinte du serveur,
  aucune confiance aux certificats installés sur le téléphone.

## 7. Tests automatiques livrés

Dossier `test/`, exécutables sans téléphone ni serveur :

```bash
flutter test
```

- `rtc_policy_test.dart` — politiques de l'entreprise, y compris le repli
  fermé sur valeur inconnue.
- `chat_queue_test.dart` — file hors ligne, absence de doublon, purge.
- `fleet_units_test.dart` — conversion de vitesse de la carte.
- `error_catalog_test.dart` — aucun code technique affiché au chauffeur.

Le contrôle `python3 scripts/verifier-livrable.py` exige la présence de ces
tests et des points de code correspondants.

## 8. Ce qui reste et pourquoi

`scripts/verifier-livrable.py` renvoie aujourd'hui exactement deux manques :

```text
- secret officiel absent: android/app/google-services.json
- secret officiel absent: ios/Runner/GoogleService-Info.plist
```

Ces deux fichiers viennent de la console Firebase du projet et ne peuvent
pas être inventés : sans eux, aucune notification ne peut arriver. Dès
qu'ils sont déposés, le contrôle passe au vert.

Aucune compilation Flutter, aucun test sur appareil, aucune notification
réelle, aucun appel audio réel et aucun essai de relais n'ont pu être
exécutés dans l'environnement de préparation : ni Flutter, ni Xcode n'y sont
installés. Ce qui est garanti ici, c'est la cohérence du code avec le
contrat serveur et les contrôles statiques ; la validation finale se fait
avec la procédure de recette sur deux téléphones.

## 9. Ordre de recette recommandé

1. `flutter pub get`, `flutter analyze`, `flutter test`.
2. `flutter build apk --release`, installation sur deux téléphones.
3. Appairage par QR, code, prise de service dans le mode configuré.
4. Message écrit, puis mode avion, message écrit, retour du réseau.
5. Note vocale hors réseau, retour du réseau.
6. Appel entre les deux téléphones, puis appel téléphone verrouillé, puis
   bascule Wi-Fi → données pendant l'appel.
7. Carte : comparer une vitesse affichée avec le tableau de bord web.
8. Côté gestionnaire : couper la messagerie, puis la carte, et vérifier la
   disparition immédiate sur les téléphones.
