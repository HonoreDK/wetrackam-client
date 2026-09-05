# Rapport de livraison — WeTrackam Client v15

Ce rapport remplace les constats historiques des versions antérieures.

Le dossier contient l'application chauffeur raccordée aux contrats actuels de
provisionnement, TLS, authentification, service, position, contrôle temps réel,
annuaire/carte sociale, chat, voix, VoIP et push.

Les validations statiques disponibles sont pilotées par
`scripts/verifier-livrable.py`. La recette réelle et ses prérequis sont décrits
dans `FIREBASE-ET-RECETTE.md`.

État de qualification : **non qualifié pour production dans cet environnement**.
Les fichiers Firebase mobiles officiels et les SDK Flutter/iOS sont absents ;
aucun build ni essai sur deux appareils n'a été exécuté. Il ne faut pas
interpréter la présence du code comme une preuve de fonctionnement réel.