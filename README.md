# MontageMusical

Application iOS de montage musical guidé : elle analyse une musique, génère une partition de montage (ancres et cases), puis guide l'utilisateur pour associer ses rushs vidéo et exporter le montage final.

## Spécification

Le comportement produit est défini exclusivement par la spécification :
`specification_application_montage_musical_ios.md` (voir notamment §5 pile technologique, §6 architecture, §30–§39 UX, §75 Jalon 0).

## Compilation (sur Mac)

1. Ouvrir `MontageMusical.xcodeproj` dans Xcode 26 ou plus récent.
2. Compiler avec `Cmd+B` (cible `MontageMusical`, iOS 26.0 minimum, Swift 6).
3. Lancer les tests avec `Cmd+U` (cible `MontageMusicalTests`).

## Note

Projet généré sous Windows, jamais compilé localement : la première compilation et la vérification des API doivent se faire sur Mac.
