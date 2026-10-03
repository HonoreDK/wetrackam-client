# Installer l'app chauffeur sur iPhone sans Mac

Ce dépôt n'a pas été testé sur iOS pendant le stage, faute de Mac
disponible (voir le rapport, chapitre 4). Cette notice documente une
solution de contournement : compiler l'IPA dans le cloud (GitHub Actions,
runner macOS), puis l'installer sur l'iPhone depuis Windows avec Sideloadly
— sans jamais toucher un Mac ni payer de compte Apple Developer (99 $/an).

## 1. Construire l'IPA (GitHub Actions)

1. Sur GitHub, ouvrir l'onglet **Actions** du dépôt.
2. Choisir le workflow **« iOS Build (non signé, pour sideload) »**.
3. Cliquer **Run workflow** (branche `main`).
4. Attendre la fin du job `build_ios` (~10-15 min, runner macOS).
5. Télécharger l'artefact **`wetrackam-ios-unsigned`** (contient
   `WeTrackam.ipa`) depuis la page du run terminé.

Ce déclenchement est volontairement **manuel** (`workflow_dispatch`) : les
runners macOS consomment les minutes GitHub Actions environ 10 fois plus
vite que les runners Linux déjà utilisés par `ci.yml`/`analyze.yml`. Ne
lancer ce workflow que lorsqu'une IPA à jour est réellement nécessaire.

L'IPA produite n'est **pas signée** par Apple (aucun compte Apple Developer
n'est configuré en CI) : c'est normal, Sideloadly s'en charge à l'étape
suivante.

## 2. Installer Sideloadly sur Windows

1. Télécharger Sideloadly : https://sideloadly.io (version Windows).
2. Installer **iTunes** (ou au minimum Apple Mobile Device Support) si ce
   n'est pas déjà fait — Sideloadly en a besoin pour parler à l'iPhone en
   USB.
3. Brancher l'iPhone en USB, le déverrouiller, accepter
   « Faire confiance à cet ordinateur ? ».

## 3. Sideloader l'app

1. Lancer Sideloadly ; l'iPhone doit apparaître dans la liste des
   appareils en haut.
2. Glisser `WeTrackam.ipa` dans la fenêtre Sideloadly.
3. Renseigner un identifiant Apple (un compte gratuit suffit — ce n'est
   **pas** un compte Apple Developer payant). Sideloadly l'utilise
   uniquement pour signer l'app localement, comme le ferait Xcode avec une
   signature personnelle gratuite.
4. Cliquer **Start**. Sideloadly signe l'IPA et l'installe sur l'iPhone.
5. Sur l'iPhone : **Réglages > Général > VPN et gestion d'appareil** →
   faire confiance au profil développeur associé à cet identifiant Apple,
   sinon l'app refuse de s'ouvrir malgré une installation réussie.

## 4. Limite connue : expiration au bout de 7 jours

Une signature par identifiant Apple **gratuit** expire au bout de 7 jours
(contre 1 an avec un compte payant) : passé ce délai, l'app cesse de se
lancer et il faut refaire l'étape 3 (Sideloadly peut re-signer l'IPA déjà
téléchargée, pas besoin de reconstruire l'IPA sauf si le code a changé).
Sideloadly propose une option de rafraîchissement automatique tant que
l'iPhone reste sur le même réseau Wi-Fi que l'ordinateur.

## 5. Ce qui ne fonctionnera pas sur cette installation

- **Notifications push (Firebase)** : aucun `GoogleService-Info.plist`
  n'est configuré côté iOS dans ce dépôt (seul Android l'est, voir
  `firebase.json`). Le workflow CI en crée un **placeholder** juste pour
  que Xcode accepte de compiler (c'est une entrée de build attendue par le
  projet) — ses valeurs ne sont pas réelles. `Firebase.initializeApp()`
  échoue proprement avec ce placeholder (`try`/`catch`, voir
  `push_notifications_service.dart`) : l'app démarre normalement, mais
  sans notifications. Hors périmètre de cette notice.
- **Appel entrant application fermée (PushKit)** : documenté comme limite
  connue depuis la v13 du projet, indépendant de la méthode d'installation.
