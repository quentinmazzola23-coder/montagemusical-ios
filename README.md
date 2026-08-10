# MontageMusical

Application iOS de montage musical guidé : elle analyse une musique, génère une partition de montage (ancres et cases), puis guide l'utilisateur pour associer ses rushs vidéo et exporter le montage final.

## Spécification

Le comportement produit est défini exclusivement par la spécification :
`specification_application_montage_musical_ios.md` (voir notamment §5 pile technologique, §6 architecture, §30–§39 UX, §75 Jalon 0).

## Compilation (sur Mac)

1. Ouvrir `MontageMusical.xcodeproj` dans Xcode 26 ou plus récent.
2. Compiler avec `Cmd+B` (cible `MontageMusical`, iOS 26.0 minimum, Swift 6).
3. Lancer les tests avec `Cmd+U` (cible `MontageMusicalTests`).

## Installation sur iPhone (Sideloadly)

Même pipeline que ClipFlow-iOS — aucun Mac requis :

1. Chaque push sur `main` déclenche le workflow GitHub Actions **Build IPA (non signée)** (runner macOS, Xcode 26). Un job `tests` parallèle exécute les tests unitaires sur simulateur (informatif).
2. Le workflow publie `MontageMusical-unsigned.ipa` dans les **Releases** du dépôt (tag `build-N-rM`).
3. Sur le PC Windows : télécharger l'IPA de la dernière release, ouvrir **Sideloadly**, brancher l'iPhone, glisser l'IPA, se connecter avec l'identifiant Apple personnel, installer.
4. Signature gratuite : validité **7 jours**, puis réinstaller de la même façon.
5. Premier lancement : Réglages → Général → VPN et gestion de l'appareil → faire confiance au profil développeur.

## Note

Projet généré sous Windows, jamais compilé localement : la compilation et les tests sont vérifiés par le workflow GitHub Actions (runner macOS) à chaque push.
