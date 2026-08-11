# IMPLEMENTATION_STATUS

**Projet :** Application iOS de montage musical guidé (nom de travail : MontageMusical)
**Spécification :** `C:\Users\quent\Downloads\specification_application_montage_musical_ios.md` (v1.0, 10 août 2026)
**Dernière mise à jour :** 11 août 2026 (revue finale du Jalon 12 — correctifs §39/§60/§61/§62/§64 et état honnête des livrables §87)

---

## État général

| Jalon | État |
|---|---|
| 0 — Bootstrap | ✅ Terminé (build CI vert) |
| 1 — Temps et domaine | ✅ Terminé (tests CI verts) |
| 2 — Projets et persistance | ✅ Terminé (CI verte, run 31382568859) |
| 3 — Import audio | ✅ Terminé (CI verte, run 31385112438) |
| 4 — Moteur musical déterministe | ✅ Terminé (CI verte, run 31392520681) |
| 5 — Générateur de scores | ✅ Terminé (CI verte, run 31398882782) |
| 6 — Interface analyse / choix rythme | ✅ Terminé (CI verte, run 31419878812) |
| 7 — Timeline d'assemblage | ✅ Terminé (CI verte, run 31422818870) |
| 8 — PhotoKit | ✅ Terminé (CI verte, run 31428288550) |
| 9 — Géométrie et preview | ✅ Terminé (CI verte, run 31434117279) |
| 10 — Export | ✅ Terminé (CI verte, run 31439824793) |
| 11 — Moteur avancé Core ML | ⛔ **NON TERMINÉ — délibérément** (§29A : aucun modèle entraîné, donc aucun modèle simulé. Protocole `MusicAnalyzing`, `BeatActivationModel`, fallback déterministe et tests en place ; l'intégration attend un modèle dont la licence et les données d'entraînement sont validées.) — détail : section « Jalon 11 » ci-dessous |
| 12 — Polissage | 🟡 **PARTIEL** (CI verte, run 31444633204) — 5 des 8 livrables §87 sont faits (accessibilité, haptique, animations, erreurs, icône et nom final) ; **3 sont absents** : profilage mémoire/CPU §67 (impossible sans appareil ni Instruments — aucun chiffre relevé), tests UI §73 (aucun XCUITest écrit : il faut un simulateur, donc macOS), localisation (interface française **en dur**, aucun catalogue de chaînes — la V1 est monolingue française §0, choix assumé et non un oubli). Détail et raisons : section « Jalon 12 » ci-dessous. Vérification Mac ⌘B/⌘U toujours requise |

---

## Liste exacte des fichiers — Jalons 0 et 1

### Jalon 0 — Bootstrap

| # | Fichier | Rôle |
|---|---|---|
| 1 | `MontageMusical.xcodeproj/project.pbxproj` | Projet Xcode (objectVersion 77, groupes synchronisés), cibles `MontageMusical` (app iOS 26, SwiftUI, Swift 6) et `MontageMusicalTests`, configs Debug/Release |
| 2 | `App/AppEntry/MontageMusicalApp.swift` | Point d'entrée `@main`, ouvre l'écran d'accueil |
| 3 | `App/AppEntry/AppEnvironment.swift` | Conteneur d'environnement (logger, futurs services) |
| 4 | `App/Core/Logging/AppLogger.swift` | Wrapper OSLog (pas de noms de fichiers personnels en Release) |
| 5 | `App/Features/ProjectList/ProjectListView.swift` | Écran d'accueil : liste vide + gros bouton `+` en zone basse (inerte jusqu'au Jalon 2) |
| 6 | `Tests/Unit/SmokeTests.swift` | Test vide passant |
| 7 | `.gitignore` | Standard Xcode/Swift |
| 8 | `README.md` | Instructions de compilation sur Mac |
| 9 | `IMPLEMENTATION_STATUS.md` | Ce fichier |
| 9b | `App/Resources/Assets.xcassets/` | Catalogue minimal (AppIcon + AccentColor) — requis par `ASSETCATALOG_COMPILER_APPICON_NAME`, évite un échec de validation d'archive. L'`AppIcon` était **vide** jusqu'au Jalon 12, qui y a posé `AppIcon-1024.png` (§87). L'`AccentColor` était vide jusqu'à la **revue finale**, qui y a posé une couleur sobre avec variantes clair/sombre (§39) |

### Jalon 1 — Temps et domaine

| # | Fichier | Rôle |
|---|---|---|
| 10 | `App/Core/Time/MediaTime.swift` | Type temps canonique (ticks Int64, timescale 60 000), arithmétique, `zero`, conversion secondes aux frontières uniquement |
| 11 | `App/Core/Time/MediaTime+CMTime.swift` | Conversion `CMTime` aux frontières AVFoundation, arrondi image-la-plus-proche à règle constante |
| 12 | `App/Core/Time/MediaTimeFormatting.swift` | Affichage `mm:ss,cc` (deux décimales, virgule française) — arrondi d'affichage seulement |
| 13 | `App/Domain/Project/ProjectModels.swift` | `ProjectStatus`, `ProjectRecord`, `ProjectSlotRecord` (SwiftData, §10) |
| 14 | `App/Domain/Project/ProjectGeometry.swift` | `ProjectGeometry`, `ProjectOrientation` (§14) |
| 15 | `App/Domain/MusicAnalysis/MusicAnalysisModels.swift` | Tous les types §12 (résultat, hypothèses, UMS, fonctions, événements, relations, courbes) |
| 16 | `App/Domain/EditScore/EditScoreModels.swift` | Types §13 + §26.3/§28.2 (`PaceMode`, `EditScore*`, `EditAnchor`, `EditSlotDefinition`, gestes, `ScoreConfiguration`) |
| 17 | `App/Domain/Media/MediaModels.swift` | `ClipAssignmentStatus`, `ClipAssignmentRecord` (§13.3), types photothèque (§7) |
| 18 | `App/Domain/Export/ExportModels.swift` | `PreviewScope` (§47), `ProjectSnapshot`, `contiguousReadyPrefix` (§51) |
| 19 | Protocoles §7 rangés par domaine : `MusicAnalysis/MusicAnalyzing.swift`, `EditScore/EditScoreGenerating.swift`, `Media/MediaLibraryBrowsing.swift`, `Media/AudioImporting.swift`, `Export/ProjectExporting.swift`, `Export/PreviewBuilding.swift` | Les 6 protocoles §7 |
| 20 | `Tests/Unit/MediaTimeTests.swift` | §70 Temps : conversions, affichage centième, non-dérive 1 000 cases, durée par différence, 29,97/59,94 |
| 21 | `Tests/Unit/ContiguousPrefixTests.swift` | §70 Préfixe exportable : 6 cas |

---

## Choix techniques retenus

- **pbxproj écrit à la main** (objectVersion 77, `PBXFileSystemSynchronizedRootGroup`) sur le modèle éprouvé de ClipFlow-iOS (déjà compilé avec succès sur Mac).
- **Swift 6** (`SWIFT_VERSION = 6.0`), concurrence stricte.
- **Bundle IDs :** `com.example.montagemusical` / `com.example.montagemusicalTests` (même convention que ClipFlow).
- **Durées jamais persistées** : toujours calculées `end - start`.
- **60 000 ticks/s** : divisible par 24, 25, 30, 50, 60, 30 000/1 001 (NTSC) → frontières 29,97/59,94 exactes en ticks.

## Écarts par rapport à la spécification

1. **`Tests/` à la racine du repo, pas dans `App/`** — l'arbre §6 place `Tests/` sous `App/`, mais les groupes synchronisés Xcode lient un dossier entier à une cible ; séparer évite de compiler les tests dans la cible app.
2. **Compilation et tests non exécutés** — projet généré sous Windows (pas de toolchain Swift/Xcode). Vérification à faire sur Mac : ouvrir `MontageMusical.xcodeproj`, ⌘B puis ⌘U. Même processus que ClipFlow-iOS.
3. **Types de support non définis par la spec** (ex. `TimedValue`, `ContinuousCurves`, `EvidenceContribution`, `ProjectOrientation`) : définis a minima, marqués d'un commentaire `// Non défini par la spécification` dans le code.
4. **Affichage étendu au-delà de §9** : `displayString` gère les heures (`h:mm:ss,cc` au-delà d'une heure) et un signe `-` défensif pour des valeurs transitoires négatives — la spec ne définit que `mm:ss,cc` sur des timestamps absolus positifs. Sans effet sur le parcours produit.
5. **Arborescence §6 partielle** : les dossiers non requis par les Jalons 0–1 (`Core/Errors`, `Core/Extensions`, `Core/DesignSystem`, `Data/*`, `Services/*`, `Features/*` restants, `Resources/Models|Config|Localization`, `Tests/Integration|UI|GoldenAudio`) seront créés par les jalons qui les remplissent — pas de placeholders vides dans les groupes synchronisés.
6. **`nearestFrameBoundary` hors du garde `#if canImport(CoreMedia)`** (même fichier `MediaTime+CMTime.swift`) : ne dépend que des ticks, testable sans CoreMedia.
7. **`init?(cmTime:)` failable** : un `CMTime` non numérique ou débordant `Int64` retourne `nil` au lieu d'un `.zero` fabriqué silencieusement (protège `endTicks > startTicks` §10.1 et « pas de durée nulle » §28.1). Fraction réduite par PGCD + `multipliedReportingOverflow` contre les débordements.

## Revue adversariale (10 août 2026)

Workflow 6 agents (3 générateurs, 3 relecteurs : conformité spec, compilation Swift 6/pbxproj, qualité des tests) : 17 findings, 0 bloqueur, 1 majeur, 16 mineurs. Corrigés dans la foulée : règle d'arrondi unifiée « ,5 supérieur » (`init(seconds:)` aligné sur `roundedDivision`), `roundedDivision` réécrite sans multiplication (zéro débordement possible), `init?(cmTime:)` failable + PGCD, catalogue d'assets créé, assertions tautologiques des tests remplacées par des égalités complètes de structs (`Equatable` ajouté à `ProjectSlot`/`ClipAssignmentSnapshot`), cas `.resolving`/`.tooShort` ajoutés aux tests de préfixe, documentation de suivi corrigée.

## Jalon 2 — Projets et persistance (10 août 2026)

**Fichiers ajoutés/réécrits** : `App/Data/Persistence/ModelContainerFactory.swift`, `App/Data/Persistence/ProjectStore.swift` (@ModelActor §8), `App/Data/ProjectFiles/ProjectFileStore.swift` (arbre §11), `App/Domain/Project/ProjectSummary.swift`, `App/Domain/Project/AutomaticTitle.swift` (titre §10), `App/Features/ProjectList/ProjectListView.swift` (accueil §31 complet), `App/Features/ProjectTimeline/ProjectView.swift` (projet vide §32, dock §36), `App/AppEntry/*` (wiring), `Tests/Unit/AutomaticTitleTests.swift`, `Tests/Unit/ProjectStoreTests.swift`.

**Choix techniques** : cascade §10.1 manuelle (schéma verbatim sans relations SwiftData) + `#Unique<ProjectSlotRecord>` sur `(projectID, scoreModeRaw, index)` ; contraintes §10.1 validées dans `insertSlots` par erreurs typées (`ProjectStoreError`), signature Sendable (`[EditSlotDefinition]`, records construits dans l'acteur) ; ordre fichiers-avant-save partout (jamais d'enregistrement fantôme : createDraft, duplicate avec rollback) ; maintenance au lancement §69A (brouillons vides résiduels, dossiers orphelins, vidage `temp/`) + balayage à l'apparition de l'accueil ; anti double-tap sur `+` ; titre de duplication « … (copie) » (non spécifié, choix V1) ; protection fichiers `completeUntilFirstUserAuthentication` (choix V1).

**Écart/risque connu** : la liste (@Query mainContext) dépend de la propagation inter-contextes SwiftData depuis le contexte de l'acteur — à vérifier sur simulateur/appareil ; repli documenté dans le code (ProjectView re-vérifie auprès du store avant tout retour).

## Jalon 3 — Import audio (10 août 2026)

**Fichiers** : `App/Services/AudioImport/AudioImporter.swift` (+`AudioImportError.swift`), `App/Services/AudioImport/WaveformExtractor.swift`, ajouts `ProjectStore` (`attachAudio`, `audioRelativePath`, reprise post-crash des imports bloqués) et `ProjectFileStore` (`audioFileURL`), `ProjectView` réécrit (3 états : vide/import/musique, fileImporter, waveform, lecture), `WaveformView.swift`, `AudioPlayerController.swift`, `Tests/Unit/AudioImporterTests.swift` (WAV généré en pur Swift), `Tests/Unit/WaveformExtractorTests.swift`.

**Choix techniques** : validation §62 réelle (UTType + taille + DRM + piste **décodable** `load(.isDecodable)` + durée) ; copie atomique temp/ → staging dans audio/ → suppression ancien → renommage (jamais d'état « ancien perdu, nouveau absent ») ; statuts annexe A (`importingAudio` → `analyzing` par `attachAudio`) ; waveform par blocs, canaux natifs entrelacés (AVAssetReaderTrackOutput refuse `AVNumberOfChannelsKey`), recalage VBR, `Task.yield()` par bloc ; aucun faux pourcentage (§33) — libellés « En attente d'analyse » / « Analyse musicale à venir » jusqu'au Jalon 4.

**Limites documentées (V1, à traiter plus tard)** : fichier iCloud Drive non matérialisé → erreur générique (pas de NSFileCoordinator/téléchargement, à améliorer) ; pas d'annulation UI de l'import en cours (§8 — copie généralement courte) ; cas DRM non testé unitairement (aucun fichier protégé synthétisable) ; erreur d'import survenue après avoir quitté l'écran : alerte non visible, projet proprement rendu à `draft` puis balayé.

## Jalon 4 — Moteur musical déterministe niveau A (10 août 2026)

**Fichiers** : `App/Services/MusicAnalysis/` — `PCMDecoder` (streaming AVAssetReaderAudioMixOutput mono 22 050 Hz, §68), `SpectralFeatureExtractor` (STFT vDSP 1024/256 Hann, features §17 normalisées relatives par quantile 0,95), `OnsetDetector` (§18 : détendançage médian, peak picking adaptatif par bande, fusion < 30 ms), `TempoEstimator` (§19.1 : autocorrélation 50–220 BPM, renforcement harmonique + prior log-normal centré 120 BPM, relations half/double conservées, phase par peigne), `BeatTracker` (programmation dynamique type Ellis, mesures 2/3/4 §20, downbeats/bars), `BeatSyncFeatures` (§21/§22 : vecteurs par beat, similarité cosinus au niveau beat — jamais frame×frame, nouveauté par kernels en damier 4/8/16), `StructureBuilder` (arbre UMS §22.3), `CurvesAndEventsBuilder` (courbes §23 E/D/T/N/S/R/V/B, événements §12.4, relations §25 honnêtes, états dramaturgiques heuristiques §24), `AnalysisCache` (empreinte SHA-256 + version moteur + config, checkpoints de phase §79), `DeterministicMusicAnalyzer` (protocole §7, 4 phases §33 publiées, annulable/reprenable), `AudioAnalysisActor` (§8, une analyse par projet). Câblage : analyse réelle au statut `analyzing` dans ProjectView (progression §33 sans pourcentage, Réessayer §63, annulation à la disparition avec checkpoint §8.1) ; succès → `awaitingPaceSelection`. 8 fichiers de tests (audio synthétique déterministe, LCG seedé).

**Écarts niveau A documentés (résorption prévue Jalons 5/11)** :
- §16.3 : seule la branche courte (1024/256) est calculée ; branches moyenne/longue de la config présentes mais non consommées.
- §17 : features partielles — pas de crête/rolloff/flatness/ZCR/contraste/HPSS/**chroma** ; conséquence §22.1 : similarité sur énergie/flux sans timbre ni harmonie (répétitions harmoniques indistinguables). Chroma prévu avec le moteur avancé (Jalon 11) ou l'affinage Jalon 5.
- §20 : mesures candidates limitées à 2/3/4 (5/6/7 non testées).
- §21 : variance par span non conservée (moyenne/max/pente seulement).
- §22 : `repetitionGroupID` toujours nil (pas de regroupement de répétitions).
- §23 : `TimedValue` ne porte que (time, value) — pente/accélération/durée de tendance/distance au max/confiance non persistées ; `V` (présence vocale) constante à 0 (niveau A sans modèle — le générateur §26.2 ne peut pas s'appuyer sur « phrase vocale en cours » avant le Jalon 11).
- §24 : fonctions dramaturgiques réduites à ~6 états heuristiques (confiance ≤ 0,5).
- §11 : pas encore de `features-v1.bin` séparé — les features vivent dans le checkpoint (supprimé au succès) ; à extraire au Jalon 5 pour éviter un redécodage (§69).
- Prior de tempo log-normal (120 BPM, σ 0,5 octave) : choix d'implémentation standard non décrit par la spec, pour départager les familles half/double-time — toutes les hypothèses restent conservées avec leurs relations (§63).

## Jalon 5 — Générateur de partitions (10 août 2026)

**Fichiers** : `App/Services/EditScore/AnchorField.swift` (champ d'ancres §26 : attraction/inhibition, formule d'utilité §26.3 avec les 9 poids de ScoreConfiguration, kinds §13.1, rangs hiérarchiques, fenêtres optimales/tolérées, raisons §29 en français), `GestureDetector.swift` (§27 niveau A : burst-résolution en groupe atomique, impact-maintien, respiration, accent simple), `DeterministicEditScoreGenerator.swift` (§28 : racine début+fin+majeures communes, splits par file de priorité sur splitGain, **imbrication garantie par construction** — une seule séquence d'activations fluid→balanced→percussive avec planchers §28.2, résidu final §28.2, respiration bidirectionnelle après burst), extension `ScoreConfiguration` (seuils de gain, cibles de durée, coûts — défauts documentés), wiring `AudioAnalysisActor` (5ᵉ phase §33 « Création des rythmes » publiée, génération hors acteur annulable, `scores-v1.json` + `scores-meta-v1.json` avec empreinte de config §61), `ProjectStore.saveScores`. Tests : bloc §70 « Partitions » complet + intégration bout-en-bout + tests des poids §26.3.

**Écarts niveau A documentés** :
- §27 : gestes accélération / écho de motif / variation / réinitialisation non générés (4 types sur 8).
- §28.3 étape 6 : pas de passe globale post-sélection distincte — repliée dans overcutPenalty (densité locale), seuils de gain et contraintes de respiration.
- `EditAnchor.finalUtility` persisté exclut le terme overcutPenalty (dépendant de l'état de sélection).
- `saveScores(relativePath:)` : chemin non persisté dans `ProjectRecord` (schéma §10 verbatim sans colonne dédiée) — chemin fixe §11 re-dérivable.
- Projets pré-J5 en `awaitingPaceSelection` sans `scores-v1.json` : pas de régénération silencieuse (§61) — le Jalon 6 proposera la régénération.
- Perf : ré-évaluation complète des candidats après chaque activation — acceptable ≤ ~6 min de musique, optimisation locale notée.

## Jalon 6 — Interface analyse et choix du rythme (10 août 2026)

**Fichiers** : `App/Services/EditScore/ScoreLibrary.swift` (lecture `scores-v1.json` + validité §61 : `ScoresMeta` schéma unique — generatorVersion + empreinte de config + analysisVersion — partagé écriture/lecture/tests), extensions `ProjectStore` (`selectPace` **transaction unique avec rollback**, `revertToPaceSelection`, `clearSlots`, `hasAssignments`, `slotCount`, `insertSlots` gardé par le verrou, `duplicateForPaceChange` — copie SANS cases ni associations remise au choix du rythme §65), `App/Features/PaceSelection/PaceSelectionView.swift` (écran §34 : **trois cartes comparables** — miniature + plans + moy/min/max « 1,20 s » §35.2 —, sélecteur + CTA « Utiliser ce rythme » au dock §36, recalcul §61 explicite), `MiniTimelineView`, `MediaTime.shortDurationString`, routage `ProjectView` (awaitingPaceSelection → sélection ; assembling → placeholder sobre avec « Changer de rythme »), `Tests/Unit/PaceSelectionStoreTests.swift`.

**Choix** : défaut Équilibré (position centrale §34) ; CTA `ViewThatFits` (« Utiliser ce rythme » / « Valider ») ; seules les cases du mode choisi sont persistées (les 3 partitions restent dans `scores-v1.json`) ; après duplication pour changement de rythme, retour à la liste (navigation directe vers la copie : amélioration future).

**Écarts documentés** :
- §34 « feuille inférieure » rendue en plein écran routé par statut (choix V1).
- Matériau `.ultraThinMaterial` au lieu du Liquid Glass natif iOS 26 (§37/§81) — cohérent avec tous les docks existants. **Toujours ouvert après le Jalon 12** (voir « Écarts restants » du Jalon 12) : la migration exige de compiler et de regarder le rendu sur appareil, impossible sous Windows.
- ~~§60 : restauration automatique du dernier projet ouvert au lancement à froid non implémentée~~ — **RÉSORBÉ au Jalon 12** : `ProjectListView` mémorise l'identifiant du dernier projet ouvert et repousse sa `ProjectView` au lancement s'il existe encore. Le stockage est passé de `@AppStorage` à **`@SceneStorage`** à la revue finale (voir « Revue finale » du Jalon 12).

## Jalon 7 — Timeline d'assemblage (10 août 2026)

**Fichiers** : `App/Features/ProjectTimeline/AssemblyModels.swift` (états de case §13.3/§44/§64 avec forme parlée unique §39, géométrie durée-proportionnelle testable), `SlotCardView.swift` (cartes §35.2 : vide « Plan 8 / 1,20 s / + », remplie miniature+numéro+durée+coche, downloading/unavailable/tooShort/resolving distincts sans seule couleur), `AssemblyMiniTimelineView.swift` (§35.3 : segments proportionnels précalculés, position courante, fenêtre carrousel, limite d'export §51, tap+drag, fluide à 300+ cases §82), `AssemblyView.swift` (écran §35 complet : zone haute avec Plan X sur N + timestamps + durée requise + lecture du passage musical au toucher, carrousel 3 cases à 55 % scroll+tap, dock contextuel §36 avec Export à l'état réel §51, debounce navigation 300 ms §59, case active restaurée §60), `AudioPlayerController.playSegment/stopSegment`, routage `ProjectView`, 2 fichiers de tests logique.

**Écarts documentés (résorption prévue)** :
- §35.1 : aperçu = placeholder 16:9 + lecture du passage **musical** seul — **résorbé** : miniature vidéo au Jalon 8, aperçu vidéo+musique §47.1 au Jalon 9.
- §35.3 : « courbe musicale simplifiée » non dessinée dans la mini-timeline — **résorbé au Jalon 9** : `AssemblyView` extrait 200 bins (`WaveformExtractor`) et les passe en fond à `AssemblyMiniTimelineView`.
- §30 : « Changer de rythme » (action secondaire §65) dans un Menu ellipsis en haut à droite — hors zone pouce, assumé pour une action non essentielle. **Réexaminé au Jalon 12 et CONSERVÉ** : §30 vise les contrôles *obligatoires* du parcours principal et §89 interdit qu'une action *essentielle* vive exclusivement en haut ; « Changer de rythme » n'appartient pas au parcours minimal §88 et toutes les actions qui en font partie (remplir, prévisualiser, exporter, revenir) vivent en zone basse.
- Pause de fin de passage par observateur 10 Hz : dépassement max ~100 ms (affichage V1) — boundary observer exact envisageable au Jalon 9.
- ~~Dynamic Type : hauteurs de cartes/carrousel fixes~~ — **RÉSORBÉ au Jalon 12** : `SlotCardView` et `AssemblyView` passent par `@ScaledMetric` sur une base commune, la ligne « numéro • durée • coche » passe en colonne aux tailles d'accessibilité, previews AX3 ajoutées.

## Jalon 8 — PhotoKit (10 août 2026)

**Fichiers** : `App/Services/MediaLibrary/MediaLibraryActor.swift` (acteur §8 : autorisations §40 — `.readWrite` seul niveau lecture PhotoKit —, albums ordonnés §41, assets vidéo §42 avec premier filtre §43, résolution AVAsset réelle avec progression iCloud §44, classement des échecs §64), `MediaLibraryError.swift`, `AssignmentRules.swift` (règles pures §43/§46), `ThumbnailProvider.swift` (`PHCachingImageManager` §42 : préchargement ET arrêt par fenêtre — cache borné, fabriques d'options partagées start/stop), `App/Features/ClipPicker/ClipPickerView.swift` (feuille §40–§46 : autorisation à l'ouverture, refus expliqué + Réglages, accès limité avec rechargement à la fermeture du sélecteur système, grille 3 colonnes avec badges et progression, albums + mémorisation par projet §41, réutilisation confirmée §45, avancement automatique §46, « Montage complet »), extensions `ProjectStore` (begin/complete/fail/remove d'association §13.3/§59, `markAssignmentDownloading` §44, `removeAssignmentIfCurrent` anti-courses, `usedAssetSlotIndexes` §45, `emptySlotIndexes` §46, dernier album §41, reprise §8/§64 des associations en cours dans `performStartupMaintenance`), miniatures réelles des cases (`AssemblyModels.swift`, `SlotCardView.swift`, `AssemblyView.swift` §35.1/§35.2), `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` ajoutée au pbxproj (§40 : les deux descriptions déclarées), `Tests/Unit/MediaAssignmentTests.swift`.

**Choix** : statut `downloading` DYNAMIQUE à la progression (§44) — l'association démarre TOUJOURS en `resolving` (PhotoKit n'expose pas l'état iCloud par asset) ; le PREMIER callback de progression réseau (fraction < 1) bascule la case en `downloading` et fait avancer la feuille — l'utilisateur continue à assigner d'autres cases —, un asset local suit le chemin normal (complete puis avance). Rebouclage §46 documenté (plus de case vide strictement après → première case vide avant ; aucune → « Montage complet »). Dialogue §45 : la case COURANTE est exclue (remplacer une case par sa propre vidéo n'est pas un doublon). `noVideoTrack` → association retirée, case VIDE (§64, même traitement que la validation finale §43). Courses par ASSOCIATION : chaque tâche de résolution complète/échoue par l'identifiant de SA propre association (`removeAssignmentIfCurrent` ne touche jamais une association de remplacement ; `assignmentNotFound` avalée silencieusement — tâche périmée remplacée, ni alerte ni haptique). Reprise après kill (§8/§64) : associations `resolving`/`downloading` basculées `unavailable` au lancement — la case GARDE son association, le dock propose « Remplacer ».

**Écarts documentés** :
- **Badge iCloud §42 sous réserve d'API** : PhotoKit n'expose aucune API publique synchrone « asset non téléchargé localement » — `isCloudAsset` vaut `false` en pratique et le badge (code en place) ne s'affichera que si l'API l'expose un jour ; l'état iCloud RÉEL est découvert à la résolution (§44 : progression + statut `downloading` dynamiques).
- **« Recadrage potentiel » §42 → Jalon 9** : ~~l'indicateur nécessite la géométrie verrouillée du projet (§49), qui n'existe pas encore~~ — **résorbé au Jalon 9** : le badge compare la FORME du rush (`max/min` des pixels encodés) à celle de la géométrie verrouillée, et la cellule montre l'aperçu du crop réel §50. Limite résiduelle documentée au Jalon 9 (orientation absente des métadonnées PhotoKit).
- **Miniatures du carrousel chargées FENÊTRÉES** (case active ± 2, taille de carte en pixels — approximation stable documentée) — jamais tout le projet ; la zone haute réutilise la même image que la carte.

## Jalon 9 — Géométrie et preview (10 août 2026)

**Fichiers** : `App/Services/Preview/GeometryLock.swift` (calculs PURS §49/§50 : dimensions orientées via `preferredTransform`, rapport simplifié par PGCD, `renderSize` à dimensions paires, `cropToFillTransform` centré `scale = max(...)`), `App/Services/Preview/PreviewBuilder.swift` (§48 : `AVMutableComposition` — musique de zéro à la fin de la portée, plages vidéo successives, **aucun audio de rush**, transformations géométriques, `AVPlayerItem`), `App/Services/Preview/PreviewCache.swift` (§48/§69 : clé `projectID + portée + empreinte des cases/associations/géométrie`, LRU borné, `invalidateAll(projectID:)`), `App/Features/Preview/PreviewPlayerView.swift` (feuille §47 : portées `.slot`/`.contiguousPrefix`, dock §36 ligne « Prévisualisation », erreurs françaises §64), extensions `ProjectStore` (`geometry`, `lockGeometry` **no-op définitif**, `projectSnapshot` §51), `App/Features/ClipPicker/ClipPickerView.swift` (verrouillage §49 après la première association prête, badge « recadrage » §42, aperçu du crop réel §50 dans la grille, « Montage complet » → Prévisualiser §46), `App/Features/ProjectTimeline/AssemblyView.swift` (aperçu local §47.1 par toucher sur la zone haute, aperçu principal §47.2 au dock, invalidation §48, courbe musicale §35.3, rattrapage du verrou §49), `App/Services/MediaLibrary/MediaLibraryActor.videoGeometry`. Tests : `GeometryLockTests`, `GeometryLockStoreTests`, `ClipPickerCropLogicTests`, compléments `AssemblyViewLogicTests`.

**Choix** :
- **Zone droite du dock §36 = « Prévisualiser »** dès qu'un préfixe exportable existe (§51), « Export » désactivé sinon. Raison : §88.11 (« prévisualiser le préfixe rempli ») appartient au parcours minimal et §89 interdit de placer une action essentielle **exclusivement en haut** — le menu ellipsis ne pouvait donc pas rester son seul accès ; l'écran d'export n'existant pas avant le Jalon 10, un bouton « Export » actif ne mènerait nulle part. Le dock garde **trois zones** (§36). L'entrée « Prévisualiser » du menu est conservée comme accès redondant. **Au Jalon 10**, le dock retrouvera « Export » en zone droite et l'aperçu principal migrera vers la ligne « Prévisualisation » §36 (ou un accès équivalent en zone basse).
- **Badge « recadrage » §42 : comparaison de FORMES**, pas de rapports orientés. `PHAsset.pixelWidth/pixelHeight` sont les dimensions **encodées** (un rush portrait iPhone est annoncé 1920×1080) alors que la géométrie §14 est orientée : la comparaison naïve marquait « recadrage » **tous** les rushs d'un projet 9:16. Le badge compare désormais `max/min` de chaque côté, avec une tolérance relative de 1 %.
- **Aperçu du crop réel §50 dans la grille** : la miniature **déjà chargée** est rendue dans un cadre au rapport de la géométrie verrouillée, `scaledToFill` + `clipped` (crop-to-fill centré, identique à la composition). Aucun décodage supplémentaire (§42 : jamais de décodage 4K pour la grille) ; cellule carrée conservée tant qu'aucune géométrie n'est verrouillée.
- **Déclencheur d'invalidation §48 bon marché** (§82) : le `.onChange` de `AssemblyView` compare `(nombre d'associations, condensé entier XOR de id + case + statut)` — que des entiers, aucune allocation, indépendant de l'ordre de la `@Query`. L'empreinte textuelle `PreviewCacheKey.fingerprint` (~120 caractères par case, ~35 Ko à 300 cases) reste réservée à la **clé de cache**, calculée une fois par ouverture d'aperçu. `ProjectRecord.updatedAt` **écarté** comme déclencheur : le store le touche à chaque mutation (§59), y compris `setActiveSlot` — une simple navigation dans le carrousel jetterait les compositions que §48 demande de conserver.
- **Rattrapage du verrou §49** : si `videoGeometry` échoue au moment de l'association, aucun chemin ne reposerait la géométrie et les aperçus retomberaient sur un repli différent selon la portée (contraire à §52.1). À l'ouverture d'`AssemblyView`, une géométrie absente + une case prête déclenchent une tentative unique (même méthode que le picker, `lockGeometry` déjà no-op si verrouillée) ; erreur → journal seulement, jamais bloquant.
- **Aperçu d'une case prête sans musique lisible** : le toucher ouvre quand même l'aperçu (§64) — le constructeur lève `missingAudio` et l'écran affiche le message français prévu, au lieu d'un toucher sans effet. Seule la lecture du passage musical reste conditionnée au fichier audio.
- **Duplication et géométrie (§49/§65)** : `duplicateForPaceChange` ne copie **pas** `geometryData` — la copie repart sans cases ni associations, son propre premier rush fixera sa géométrie ; la duplication complète, elle, conserve le verrou avec ses associations.
- **`projectSnapshot` sans rythme choisi** : instantané **sans cases** — aucun montage en cours, donc aucun préfixe exportable (§51). Renvoyer toutes les cases mélangeait les modes (indices en doublon, temps qui se chevauchent).

**Écarts documentés (Jalon 9)** :
- **§52 profil maître → Jalon 10** : `projectSnapshot` fournit déjà la matière (préfixe §51 + géométrie), mais la sélection de résolution/cadence/HDR (§52.2–§52.4) appartient à l'export. La preview rend dans la géométrie verrouillée (§52.1), sans choisir de clip maître. — **résorbé au Jalon 10** : `MasterProfileSelector` + `ProjectExporter.masterProfile(project:)`, source unique du profil pour l'encodage ET pour le résumé §56.
- **Limite du badge « recadrage » §42** : deux cadrages de même forme mais d'orientation opposée (paysage 16:9 dans un projet 9:16) ne portent pas le badge, alors qu'ils seront recadrés. L'orientation réelle exigerait de décoder la vidéo, ce que §42 interdit pour la grille ; le cas est montré **visuellement** par l'aperçu du crop réel de la cellule.
- **« Export » désactivé au dock de prévisualisation** : `PreviewPlayerView` affiche les trois zones §36 (`[Retour] [Lecture/Pause] [Export]`) mais la zone droite est inactive — l'export arrive au Jalon 10 (§85), avec un hint VoiceOver explicite plutôt qu'une promesse non tenue. — **résorbé au Jalon 10** : la zone droite présente `ExportSummaryView` (§56) dès que la portée prévisualisée est exportable et non vide.
- Vérification Mac (⌘B/⌘U) toujours requise : projet généré sous Windows.

## Jalon 10 — Export (10 août 2026)

**Fichiers** : `App/Services/Export/MasterProfile.swift` (§52 PUR : `MasterClipInfo`, classement lexicographique §52.2, cadences normalisées en fractions exactes §52.3 — 29,97/59,94 préservées, plafond 60 —, HDR seulement si TOUS les rushs du préfixe sont HDR §52.4), `App/Services/Export/ProjectExporter.swift` (§51 `ExportPlan` pur + estimation de taille §57, §54 composition — musique originale sur `[0, prefixEnd]`, aucune piste audio de rush, durées RÉELLES vérifiées —, §52.1 rendu dans la géométrie verrouillée, colorimétrie EXPLICITE §52.4, §55 `AVAssetExportSession` avec presets candidats, fichier temporaire unique nettoyé sur tous les chemins, §58 annulation coopérative ; `masterProfile(project:)` expose le profil §52 à l'interface), `App/Services/Export/ExportActor.swift` (§8 : un export actif par projet, résultat de démarrage explicite `started`/`alreadyRunning`/`refused`, progression interrogeable, `lastOutcome`/`lastError`, statut §10 `exporting` → `assembling`/`complete`), `App/Services/Export/PhotoLibrarySaver.swift` (§40 accès `.addOnly` demandé au PREMIER enregistrement, §55 après succès complet, §66 refus → fichier conservé), extensions `ProjectStore` (`setExporting`, `markExportSucceeded`), `App/Features/ExportProgress/ExportSummaryView.swift` (résumé §56 verbatim + logique d'affichage PURE `ExportSummaryLogic`, progression §58 dans le dock, §57 refus avant encodage, §66 issues), routage `ProjectView`, docks `AssemblyView` et `PreviewPlayerView`. Tests : `MasterProfileTests`, `ExportPlanningTests`, `ExportSummaryLogicTests`.

**Choix** :
- **Profil §52 : une seule source.** Le résumé avant export ne calcule plus rien — il lit `ProjectExporter.masterProfile(project:)`, c'est-à-dire exactement ce que l'encodage utilisera. Le calcul parallèle côté vue (résolution PhotoKit rush par rush, rush illisible simplement ignoré) pouvait ANNONCER « HDR » alors que le fichier produit serait SDR. Profil indisponible (un rush du préfixe est illisible) → « Profil technique indisponible » : **jamais un profil partiel**, et l'export reste possible (c'est lui qui tranche). Effet de bord bienvenu : l'écran d'export n'ouvre plus aucun asset PhotoKit et ses previews SwiftUI sont purement locales.
- **Routage des statuts de montage (§10, §58, §88.12)** : `assembling`, `partiallyPreviewable`, `complete` et `exporting` mènent tous à `AssemblyView`. `ExportActor` pose `exporting` pendant l'encodage puis `complete`/`assembling` ensuite : router ces statuts ailleurs faisait disparaître la timeline — et la feuille d'export posée dessus — dès l'appui sur « Exporter ». L'aiguillage de `ProjectView` est désormais **exhaustif** (aucun `default`) : un statut ajouté plus tard forcera une décision.
- **Arrière-plan (§8.1, §58)** : aucune assertion de tâche d'arrière-plan n'est prise pour l'encodage (§8.1 réserve la tâche courte à la finition d'une écriture ou au nettoyage d'un temporaire). Le système ne nous autorise donc pas à « terminer » : pendant l'encodage, l'écran affiche la consigne « Gardez l'application ouverte pendant l'export » et un passage en arrière-plan est traité comme une **interruption** (suivi arrêté, annulation demandée à l'acteur, temporaire supprimé, statut restauré, message « Export interrompu — vous pouvez recommencer »). Jamais un succès : §8.1 interdit d'annoncer un export réussi avant confirmation effective. Si l'annulation n'a pas eu le temps d'être prise en compte, « Recommencer » reçoit `alreadyRunning` et l'écran **reprend le suivi** du run en cours au lieu d'en lancer un second.
- **Démarrage d'export à résultat explicite (§58)** : `startExport` rend `started` / `alreadyRunning` / `refused(erreur)`. L'écran n'entre en phase « export en cours » que sur `started` ou `alreadyRunning` ; un refus est annoncé tel quel. Auparavant, un démarrage refusé laissait lire `lastOutcome` du run **précédent** — donc annoncer un succès qui n'avait pas eu lieu.
- **Enregistrement dans Photos : action utilisateur distincte (§40, §55).** Le CTA reste « Exporter » (§56, verbatim) et s'arrête au fichier produit ; une phase « Montage prêt » propose ensuite `[Fermer] [Partager] [Enregistrer dans Photos]` (trois zones §36). Raison : §40 (« Ne demander l'accès d'écriture qu'au premier enregistrement dans Photos ») veut que la demande système suive un geste explicite, et c'est déjà le contrat documenté de `PhotoLibrarySaver`. L'enchaînement automatique aurait imposé de rebaptiser le CTA (« Exporter et enregistrer dans Photos »), donc de s'écarter du libellé verbatim §56 : la phase intermédiaire est plus honnête à coût égal (un appui de plus, aucune ambiguïté).
- **Logique d'affichage PURE testable** : `ExportSummaryLogic` porte le formatage §56 **et** les messages d'issue (`percentLabel`, `message(for:)`, `storageMessage`, `fileKeptMessage`, `byteCountString`), plus les phases (`ExportPhase`, `FileKeptReason`) et la dérivation `terminalPhase(for:)` partagée par le refus de démarrage et l'issue d'encodage — deux chemins qui ne peuvent donc plus diverger. Aucune vue n'est instanciée par les tests.
- **§57 vérifié deux fois, une seule règle** : l'écran estime et refuse AVANT l'encodage avec `ProjectExporter.requireSufficientStorage` (source unique, marge déjà incluse dans l'estimation — aucune seconde marge côté vue), et l'exportateur refait la vérification avant d'écrire quoi que ce soit. Sans profil §52, la vérification est laissée à l'exportateur plutôt que devinée.

**Écarts documentés (Jalon 10)** :
- **Sortie HDR non prouvée sur matériel (§52.4)** : la composition déclare explicitement sa colorimétrie (Rec.709 en SDR — ce qui **demande** le tone mapping HDR→SDR au lieu de s'en remettre à un comportement implicite —, Rec.2020 + HLG en HDR) et le preset HEVC 10 bits est le seul candidat en HDR (aucun repli 8 bits qui produirait une image fausse en annonçant du HDR). Rien de tout cela n'a été vérifié sur un iPhone HDR réel : projet généré sous Windows, jamais compilé ni exécuté. Point de contrôle explicite à lever sur Mac + appareil ; la variante PQ n'est pas distinguée de HLG par `containsHDRVideo` (limite V1).
- **§55 export via `AVAssetExportSession`** : conforme à la V1 recommandée (« Ne pas démarrer par cette complexité sauf blocage constaté »). Le passthrough est impossible (recadrage + mise à l'échelle + cadence de rendu imposent une ré-encodage unique). Si un profil requis ne peut pas être **garanti** par un preset (débit, 10 bits, cadence fractionnaire exacte), la spécification prévoit une **V2 `AVAssetReader` + `AVAssetWriter`** : elle reste hors périmètre V1 et n'est justifiée que sur blocage constaté sur matériel.
- **Rushs ralentis / timelapse (limite PhotoKit)** : la cadence retenue est la cadence de **lecture** de la piste (§52.3) et elle est plafonnée à 60 i/s (120/240 → 60, 119,88 → 59,94, aucun flux optique). Le facteur de ralenti d'un montage Photos (`PHAssetMediaSubtype.videoHighFrameRate`, réglage de vitesse appliqué côté Photos) n'est pas relu : un rush ralenti est exporté à sa cadence de fichier plafonnée, pas au rendu exact de l'application Photos. Limite V1 assumée et documentée ici.
- **Enregistrement Photos** : variante « phase Montage prêt » retenue (voir Choix). Le fichier vit dans `exports/` (§11) et y reste même après un enregistrement réussi (`shouldMoveFile = false`) : c'est lui que §60 restaure comme « dernier export réussi » — le schéma §10 étant verbatim, aucune colonne ne porte le chemin du dernier export.
- **Interruption en arrière-plan = annulation** : le choix V1 sacrifie un encodage que le système aurait peut-être laissé finir, au profit d'un état déterministe et d'un message honnête. Une assertion de tâche d'arrière-plan (« terminer si le système l'autorise », §58) est le premier candidat d'amélioration au Jalon 12.
- Vérification Mac (⌘B/⌘U) toujours requise : projet généré sous Windows.

## Jalon 11 — Moteur avancé Core ML : NON TERMINÉ (§29A)

**État : délibérément non terminé.** §29A l'interdit explicitement : « L'agent de programmation ne doit pas prétendre avoir créé un modèle intelligent en ajoutant des règles aléatoires ou un fichier Core ML vide. En l'absence de modèle entraîné, il implémente le protocole, le fallback et les tests, puis marque clairement le jalon avancé comme non terminé. » C'est exactement ce qui a été fait.

**Ce qui EXISTE** :
- le protocole de modèle et son registre (`BeatActivationModel`, `CoreMLModelRegistry`) ;
- l'analyseur hybride (`HybridMusicAnalyzer`) branché derrière le MÊME protocole §7 `MusicAnalyzing` que le moteur déterministe ;
- le **fallback déterministe systématique** : sans modèle chargé, l'analyse est celle du Jalon 4, à l'identique — l'application fonctionne de bout en bout ;
- les tests de repli (`Tests/Unit/HybridAnalyzerFallbackTests.swift`) ;
- le dossier `ml/` (pipeline d'entraînement hors cible iOS, §29A).

**Ce qui MANQUE — et qui fait que le jalon n'est pas terminé** :
- **aucun modèle n'est embarqué** : pas de `.mlpackage` dans `App/Resources/Models/`, aucun poids, aucune version de modèle déclarée (§61) ;
- donc aucun des livrables §86 qui en dépendent : beats/downbeats appris, meilleur décodeur, segmentation sémantique, fonctions dramaturgiques apprises, calibration de confiance.

**Ce qu'il faudra faire pour le terminer** (ordre de §29A « Export » et acceptation §86) :
1. choisir un modèle **dont la licence est validée** pour un usage embarqué (et un corpus d'entraînement dont la provenance et les droits sont documentés — manifeste §29A) ; entraîner ou distiller dans `ml/` (BeatDownbeatModel, puis MusicEmbeddingModel et FunctionalStateModel) ;
2. évaluer sur le **corpus de référence §72** (tests audio de référence : morceaux annotés, tolérances de placement de beat/downbeat, non-régression des frontières de phrase) ;
3. convertir en `.mlpackage`, vérifier les opérations Core ML supportées, comparer Float32/Float16/quantifié sur précision, taille, latence, mémoire et énergie ; générer une **model card** ;
4. embarquer une version **explicitement identifiée** (§61 : version du modèle persistée avec l'analyse) et conserver le fallback déterministe ;
5. mener la **comparaison A/B §86** avec le moteur déterministe sur le corpus §72 et n'activer le moteur avancé que si l'amélioration est **mesurable** (critère d'acceptation §86), poids et performance acceptables (§67).

Tant que 1 à 5 ne sont pas faits, la V1 livrée est **niveau A** (§15 : moteur déterministe compilable), ce que §15 prévoit explicitement.

## Jalon 12 — Polissage (11 août 2026) — 🟡 PARTIEL

**État honnête : 5 livrables §87 sur 8.** §87 en liste huit — accessibilité, haptique, animations, erreurs, profilage mémoire/CPU, tests UI, localisation, icône et nom final. Le travail réalisé couvre **cinq** d'entre eux ; les **trois** autres ne sont pas faits et ne peuvent pas l'être depuis ce poste :

| Livrable §87 | État | Raison |
|---|---|---|
| Accessibilité (§39) | ✅ fait | Dynamic Type (`@ScaledMetric`, dispositions adaptatives), cibles ≥ 44 pt, libellés VoiceOver, jamais la seule couleur — **non vérifié sur appareil** (ni VoiceOver réel, ni Accessibility Inspector) |
| Haptique (§38) | ✅ fait | Association réussie / asset invalide (photothèque) + issue d'export — **non ressenti** : aucun appareil |
| Animations (§38) | ✅ fait | Aucune animation décorative + garde `reduceMotionSafe()` |
| Erreurs (§62–§66) | ✅ fait | Messages revus écran par écran, chacun nommant le geste possible |
| Icône et nom final (§87) | ✅ fait | `AppIcon-1024.png` + `CFBundleDisplayName = Montage` — **rendu jamais vu** sur un écran d'accueil |
| **Profilage mémoire/CPU (§67)** | ⛔ **absent** | Instruments n'existe pas sous Windows et le projet n'a jamais été lancé : **aucun chiffre** n'a été relevé (ni pic mémoire d'analyse §68, ni fluidité de timeline §67). Les garde-fous de conception sont en place, ce qui n'est pas une mesure |
| **Tests UI (§73)** | ⛔ **absent** | Aucun `XCUITest` écrit. Ils exigent un simulateur, donc une toolchain macOS. Les logiques d'écran sont couvertes par des tests **unitaires purs** (`AssemblyViewLogicTests`, `ExportSummaryLogicTests`, `ClipPickerCropLogicTests`, `ProjectRestoreDecisionTests`) — utile, mais ce n'est pas un test d'interface |
| **Localisation** | ⛔ **absent** | L'interface est écrite **en français en dur**, sans `String Catalog` ni `Localizable.strings`. `SWIFT_EMIT_LOC_STRINGS = YES` rend l'extraction possible plus tard. La V1 est **monolingue française** par choix (§0 : document et produit en français) — c'est une décision assumée, pas un oubli, mais le livrable §87 « localisation » n'est pas rempli pour autant |

Périmètre effectivement traité : accessibilité, haptique, animations, erreurs, icône et nom final. Aucune fonctionnalité ajoutée — les écarts documentés J6/J7 sont résorbés et les finitions réalisables posées.

**Fichiers modifiés/ajoutés** :

| Fichier | Objet |
|---|---|
| `App/Core/DesignSystem/ReduceMotion.swift` *(nouveau)* | `reduceMotionSafe()` — garde §38 « respecter Réduire les animations » |
| `App/Features/ProjectTimeline/SlotCardView.swift` | Dynamic Type §39 (`@ScaledMetric`), disposition adaptative, preview AX3 |
| `App/Features/ProjectTimeline/AssemblyView.swift` | Dynamic Type §39 (carrousel + mini-timeline), garde §38, messages d'erreur §65 distincts, preview AX3 |
| `App/Features/ProjectList/ProjectListView.swift` | Réouverture du dernier projet §60, alerte d'échec §62/§64, garde §38 |
| `App/Features/ProjectTimeline/ProjectView.swift` | Messages §62/§63 (audio introuvable, analyse échouée), garde §38 |
| `App/Features/ExportProgress/ExportSummaryView.swift` | Haptique d'issue §38, message de profil §52 et de lecture impossible, garde §38 |
| `App/Features/Preview/PreviewPlayerView.swift` | Messages d'erreur §64 nommant le geste possible, garde §38 |
| `App/Features/PaceSelection/PaceSelectionView.swift`, `App/Features/ClipPicker/ClipPickerView.swift` | Garde §38 |
| `App/Resources/Assets.xcassets/AppIcon.appiconset/` | `AppIcon-1024.png` + `Contents.json` (§87 icône) |
| `MontageMusical.xcodeproj/project.pbxproj` | `INFOPLIST_KEY_CFBundleDisplayName = Montage` dans les DEUX configs de la cible app (§87 nom final) |

**Choix** :

- **Dynamic Type (§39/§87) — `@ScaledMetric` sur une base COMMUNE.** `SlotCardView.baseMinHeight` (132) et `baseThumbnailHeight` (56) sont désormais des constantes publiées par la carte ; la carte les met à l'échelle (`relativeTo: .subheadline`) et `AssemblyView` réutilise la **même** base pour la hauteur du carrousel — carte et fenêtre grandissent ensemble, une carte ne peut plus déborder de son conteneur. La carte utilise `minHeight` (et non `height`) : elle peut dépasser sa hauteur de référence si le texte l'exige. La **largeur** reste proportionnelle au conteneur (55 %, §35.2 « largeur tactile stable ») : elle ne dépend pas de la taille de texte, exactement comme demandé. Aux tailles d'accessibilité (`dynamicTypeSize.isAccessibilitySize`), la ligne « numéro • durée • coche » d'une case remplie passe en **colonne** au lieu d'être comprimée. La mini-timeline §35.3 suit la même logique avec un **plancher à 44 pt** (§39 : c'est aussi une zone de tap et de glissé, elle ne doit pas rétrécir aux petites tailles de texte). Les miniatures demandées à PhotoKit suivent la hauteur mise à l'échelle. Deux previews « accessibilité 3 » ajoutées (`SlotCardView`, `AssemblyView`) pour le contrôle visuel sur Mac.
- **Réouverture du dernier projet (§60) — la forme la plus simple qui tienne.** L'identifiant du dernier projet ouvert vit dans l'état de restauration de la **scène** (`@SceneStorage("lastOpenedProjectID")` — `@AppStorage` à l'origine, corrigé à la revue finale), pas en base : c'est un état d'**interface**, et le schéma §10 reste verbatim (aucune colonne ajoutée). Il est écrit et effacé au **même** endroit — le `.onChange(of: path)` de `ProjectListView`, qui voit tous les push (création `+`, appui sur une carte, restauration) et tous les pop. Au lancement, une seule tentative : l'existence est vérifiée auprès du `ProjectStore` (source de vérité — la `@Query` du contexte principal peut être en retard au premier affichage), et la `ProjectView` est repoussée dans le `NavigationStack`. Trois refus explicites, tous silencieux et sans écran vide : projet **supprimé** entre-temps → retour à la liste, identifiant oublié ; **brouillon sans contenu** → jamais restauré (§31 le supprime de toute façon au retour à l'accueil, et le restaurer créerait une course avec le balayage §69A) ; lecture impossible → journal + identifiant oublié. La restauration passe **avant** le balayage des brouillons vides, qui épargne le projet ouvert. Le reste de l'état §60 (case active, position de timeline, dernier album, progression d'analyse, associations, géométrie, dernier export réussi) était déjà persisté §59 et relu par les écrans : rouvrir le projet suffit.
- **Réduire les animations (§38) — une garde, pas une suppression.** Le projet n'a **aucune** animation décorative (choix constant depuis le Jalon 2) : il n'y avait rien à désactiver. `reduceMotionSafe()` met `transaction.animation = nil` (+ `disablesAnimations`) quand `\.accessibilityReduceMotion` est actif, sur le CONTENU des écrans qui changent de phase (`ProjectListView`, `ProjectView`, `AssemblyView`, `PaceSelectionView`, `ClipPickerView`, `PreviewPlayerView`, `ExportSummaryView`) — les seuls endroits où une animation implicite héritée pourrait apparaître. Elle n'est **pas** posée sur le `NavigationStack` : les transitions de navigation appartiennent au système, qui applique déjà le réglage. Chaque vue porte une ligne de commentaire rappelant que l'absence d'animation est un choix §38.
- **Haptique (§38) — complétée côté export, nulle part ailleurs.** §38 demande un retour léger à l'association réussie et un retour d'erreur pour un asset invalide : `ClipPickerView` les portait déjà (`PickerHaptics`). L'export — le geste le plus long du parcours — ne disait rien au doigt : `ExportSummaryView` déclenche désormais, sur un `.onChange(of: phase)` unique, un impact **léger** aux phases `ready` (fichier écrit §55) et `succeeded` (ajouté à Photos), une notification d'**erreur** aux phases `insufficientStorage` (§57), `failed` (§66, y compris l'interruption en arrière-plan §8.1) et `fileKept` (§66). Une **annulation** demandée par l'utilisateur (§58) ne déclenche rien : ce n'est ni un succès ni une panne. Même vocabulaire UIKit que la photothèque, aucune dépendance. L'haptique reste active sous « Réduire les animations » : ce n'est pas une animation.
- **Erreurs (§87, §62/§64) — cinq messages corrigés, aucun réécrit sans raison.** (1) `ProjectView` « Fichier audio introuvable » → dit désormais quoi faire (créer un nouveau projet et réimporter — le remplacement de musique §65 n'existe pas en V1) ; (2) `ProjectView` « L'analyse a échoué » → explique que « Réessayer » repart du checkpoint, rien n'est perdu (§63) ; (3) `AssemblyView` : un message unique servait au changement de rythme **et** à la duplication — il en décrivait donc une pour l'autre ; deux messages distincts, chacun rappelant que le montage est intact ; (4) `ExportSummaryView` « Profil technique indisponible » → ajoute que l'export reste possible (la ligne ressemblait à un blocage) ; (5) « Le projet n'a pas pu être lu. Réessayez. » (export et aperçu) → « Réessayez » ne désignait aucun bouton sur ces deux écrans : le message nomme le geste qui existe (fermer puis rouvrir). Enfin, `ProjectListView` **n'affichait rien du tout** quand une création, un renommage, une duplication ou une suppression échouait (journal seul) : l'utilisateur voyait un bouton sans effet — une alerte « Action impossible » explique désormais chaque cas et la suite à donner. Les messages déjà clairs (import §62, photothèque §40–§46, issues d'export §57/§66, aperçu §64) n'ont pas été touchés.
- **Icône (§87)** : `AppIcon-1024.png` — 1024 × 1024, PNG écrit à la main (chunks IHDR/IDAT/IEND, zlib), **RGB 8 bits sans canal alpha** (iOS refuse une icône transparente), fond `#14151A` uni, trois barres verticales blanches en capsule (largeur 120, écart 76, hauteurs 420/660/520, centrées) évoquant une timeline musicale — aucun texte, aucune marque tierce. Généré par un script Python déterministe (mêmes octets à chaque exécution, SHA-256 `a500728a…`) ; validité vérifiée par relecture indépendante du fichier : signature PNG, CRC de chaque chunk, IHDR `1024×1024` profondeur 8 type couleur 2, longueur des pixels décodés = `hauteur × (1 + largeur × 3)`. `Contents.json` mis à jour (`idiom universal`, `platform ios`, `size 1024x1024`, `filename`).
- **Nom affiché (§87)** : `INFOPLIST_KEY_CFBundleDisplayName = Montage` posé dans les **deux** configurations (Debug et Release) de la cible app. Raison : l'interface est 100 % française et l'écran d'accueil iOS tronque au-delà de ~12 caractères — « MontageMusical » (14) comme « Montage Musical » (15) s'y afficheraient coupés. « Montage » tient, reste sobre et français. Le nom de **cible**, le `PRODUCT_NAME`, le scheme, le bundle ID et l'artefact CI (`MontageMusical-unsigned.ipa`) sont inchangés : rien dans la chaîne de build ne dépend du nom affiché.

### Revue finale (11 août 2026) — correctifs

Relecture complète du code livré au Jalon 12, sans ajout de fonctionnalité.

| Fichier | Correctif |
|---|---|
| `App/Features/ExportProgress/ExportSummaryView.swift` | **§60 — dernier export réussi enfin RESTAURÉ côté vue** ; **§39 — docks empilés aux tailles d'accessibilité** ; **§8.1/§38 — plus d'haptique d'erreur sur une interruption d'arrière-plan** |
| `App/Features/PaceSelection/PaceSelectionView.swift` | **§39 — plancher de largeur 44 pt** sur les segments du sélecteur + sélecteur sur sa propre ligne aux tailles d'accessibilité |
| `App/Features/ProjectList/ProjectListView.swift` | **§60 — `@SceneStorage`** au lieu de `@AppStorage` ; **§62/§64 — alerte d'échec de suppression** portée par le `NavigationStack` ; décision de réouverture extraite en **fonction pure** |
| `App/Services/EditScore/ScoreLibrary.swift`, `App/Services/MusicAnalysis/AudioAnalysisActor.swift` | **§61 — `coreMLModelVersion` tracé** dans `scores-meta-v1.json` |
| `App/Resources/Assets.xcassets/AccentColor.colorset/` | Couleur d'accent renseignée (clair/sombre) — le colorset était vide |
| `Tests/Unit/ProjectRestoreDecisionTests.swift` *(nouveau)*, `Tests/Unit/PaceSelectionStoreTests.swift` | Règle §60 de réouverture (5 cas) ; validité §61 avec version de modèle |

**Choix de la revue finale** :

- **§60 — le « dernier export réussi » était persisté mais jamais relu.** `ProjectFileStore.lastExportURL` (le fichier d'`exports/` §11) et `ExportActor.lastOutcome` (qui le reconstruit après relance, `isRestored = true`) existaient depuis le Jalon 10 ; **`ExportSummaryView` ne les interrogeait pas**. Après relance, l'écran repartait donc sur le résumé §56 comme si rien n'avait jamais été exporté, et le fichier conservé devenait inatteignable — ni partage §66, ni enregistrement dans Photos §40/§55. `load()` interroge désormais `lastOutcome` **en l'absence d'export en cours** (un export qui tourne a sa propre issue à venir : afficher celle d'avant la ferait passer pour la sienne, §8.1) et **après** `lastError`, qui décrit un événement plus récent. Un résultat **restauré** est visuellement DISTINCT d'un export qui vient d'aboutir : icône `clock.arrow.circlepath`, titre « Montage déjà exporté », message qui dit que l'export date d'une session précédente, et **aucune haptique de réussite** — §8.1 interdit d'annoncer un succès qui n'a pas eu lieu maintenant. Ses `duration`/`slotCount` valent zéro (le fichier est la seule trace §10/§11) et ne sont donc **jamais** affichés comme des mesures. **Décision associée** : la phase restaurée ajoute une rangée secondaire « Exporter à nouveau » au-dessus des trois zones §36 `[Fermer] [Partager] [Enregistrer dans Photos]`. Sans elle l'écran devenait un **cul-de-sac** — `lastOutcome` retrouvant toujours le fichier, le CTA « Exporter » §56 n'aurait plus jamais réapparu et aucun nouvel export n'aurait été possible. La rangée du bas conserve les trois zones importantes §36 ; celle du haut est délibérément discrète (même forme que la rangée « Annuler » de la phase d'encodage) et n'existe **pas** après un export qui vient de se terminer.
- **§39 — cibles tactiles : la largeur manquait.** Les segments du sélecteur de rythme (`PaceSelectionView`) n'avaient qu'un plancher de **hauteur** (`minHeight: 52`) ; leur largeur était le tiers de ce que « Projets » et « Utiliser ce rythme » laissaient libre, donc potentiellement **sous 44 pt** aux grandes tailles de texte. Deux correctifs : `minWidth: 44` explicite sur chaque segment, et — aux tailles d'accessibilité — sélecteur sur **sa propre ligne, au-dessus** de `[Projets] [Valider]`. Le dock reste entier en zone basse (§30) et les trois zones §36 restent présentes, réparties sur deux lignes ; le sélecteur passe **au-dessus** pour que la validation reste le contrôle le plus proche du pouce. Les autres docks du même fichier ont été vérifiés (`staleDock` : deux zones dont une extensible — jamais serrée ; `projectsOnlyDock` : une seule) et portent désormais eux aussi un plancher `minWidth: 44` écrit dans le code plutôt que déduit d'un calcul de place. Une preview AX3 est ajoutée pour le contrôle visuel sur Mac.
- **§39 — docks d'export aux tailles d'accessibilité.** Les rangées de deux ou trois capsules comprimaient leurs libellés (`lineLimit(1)` + `minimumScaleFactor(0.8)`) : « Enregistrer dans Photos » devenait illisible à AX3+. `dockLayout` (un `AnyLayout`) bascule ces rangées en **VStack** dès `dynamicTypeSize.isAccessibilitySize`, la compression est retirée et les boutons secondaires prennent toute la largeur. Même règle que `SlotCardView`/`AssemblyView`.
- **§8.1/§38 — l'haptique d'erreur mentait.** `playHaptic(for:)` jouait `ExportHaptics.error()` sur toute phase `failed`, or cette phase est **aussi** produite par un passage en arrière-plan pendant l'encodage — une interruption normale, provoquée par l'utilisateur lui-même. Un drapeau d'origine (`didInterruptForBackground`, même rôle que `didRequestCancel`) fait sauter l'haptique dans ce cas ; le message §8.1, lui, reste affiché. Deux phases terminales se lisent donc à leur **origine** et non à leur seul cas d'énumération : `failed` (panne vs arrière-plan) et `ready` (export qui vient d'aboutir vs fichier restauré §60).
- **§60/§39 — `@SceneStorage` plutôt que `@AppStorage`.** `@AppStorage` écrit dans `UserDefaults`, **partagé par toutes les scènes** : sur iPad multi-fenêtres, la même restauration se serait appliquée à chaque fenêtre et deux fenêtres ouvertes sur deux projets se seraient écrasées mutuellement, alors que §60 restaure l'état d'**une** session de travail. `@SceneStorage` range la valeur dans l'état de restauration de la scène. Même type (`String`), même code appelant, aucune migration : au pire, un premier lancement après mise à jour n'a rien à restaurer.
- **§62/§64 — l'alerte d'échec de suppression pouvait être avalée.** Elle était demandée dans le **même cycle** que la fermeture du `confirmationDialog`, et portée par la **même** vue : la présentation qui se termine pouvait annuler celle qui commence, et l'échec redevenait silencieux — exactement ce que §62/§64 interdisent. L'alerte est désormais attachée au `NavigationStack` (vue différente du contenu qui porte le dialogue), sans temporisation ni « tour de boucle » artificiel.
- **§60 — décision de réouverture extraite en fonction PURE.** `ProjectRestore.decision(storedIdentifier:summary:)` rend `open(UUID)` / `forget` / `none` ; la vue ne fait plus que l'appliquer. Cinq situations testées sans écran ni base (`ProjectRestoreDecisionTests`) : identifiant vide (→ `none`, aucune écriture inutile), identifiant illisible, projet absent, **brouillon sans contenu** (§31 : jamais restauré), cas nominal — plus deux garde-fous (résumé d'un autre projet, casse de l'UUID).
- **§61 — version du modèle Core ML tracée.** `ScoresMeta` porte un champ optionnel `coreMLModelVersion`, renseigné à l'écriture depuis `CoreMLModelRegistry.beatActivationModelVersion()` — **`nil` aujourd'hui**, puisque aucun modèle n'est embarqué (§29A/§86). C'est précisément la trace exigée : la méta dit que ces partitions viennent du moteur déterministe seul, sans qu'aucune version soit inventée. Le décodage est **tolérant** (`decodeIfPresent` explicite, pas seulement la synthèse) : les métas déjà écrites restent valides et ne déclenchent aucune régénération. À l'encodage, une version `nil` n'écrit **aucune clé** — les fichiers existants gardent la même forme. Le champ **ne participe pas** au verdict de validité §61 : comparer `nil` à `nil` ne trancherait rien, et le jour où un modèle sera livré, décider s'il périme les partitions existantes devra être un choix explicite (§61 : « ne pas modifier automatiquement un projet terminé »). Deux tests figent ce comportement.
- **Couleur d'accent — renseignée plutôt que supprimée.** Le colorset `AccentColor` était **vide** (avertissement de catalogue). Deux issues : le supprimer, ou lui donner une couleur. **Choix : lui donner une couleur**, parce que le catalogue est déjà référencé par la cible et que la teinte système par défaut (bleu iOS) n'a aucun rapport avec l'identité de l'icône ; un accent explicite évite aussi qu'un futur `Color.accentColor` hérite d'une valeur non décidée. Teinte sobre et cohérente avec l'icône (fond sombre, barres blanches) : **bleu ardoise désaturé** — clair `sRGB(0.204, 0.396, 0.573)` (#3465 92), sombre `sRGB(0.498, 0.663, 0.808)`, les deux variantes déclarées par `appearances: luminosity` pour rester lisibles en mode clair **et** sombre (§39 « fonctionnement en mode sombre et clair », « contrastes suffisants »). Aucune référence à supprimer : le pbxproj ne déclare pas `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` et aucun code Swift ne nomme `AccentColor` — la couleur sert de teinte par défaut du catalogue. **À vérifier sur Mac** : contraste réel des contrôles teintés dans les deux apparences.

**Écarts restants après le Jalon 12** :
- **Liquid Glass natif §37/§81 non adopté** : tous les docks, boutons et feuilles utilisent `.ultraThinMaterial`. Le matériau natif iOS 26 change le rendu de chaque surface translucide de l'application ; l'adopter à l'aveugle, sans jamais avoir vu l'écran, produirait un rendu invérifiable. À faire sur Mac, écran par écran.
- **Tests UI §73 absents** — livrable §87 **non rempli** : aucun `XCUITest` ; ils exigent un simulateur, donc une toolchain macOS. Les logiques d'écran restent couvertes par des tests **unitaires purs** (`AssemblyViewLogicTests`, `ExportSummaryLogicTests`, `ClipPickerCropLogicTests`, `ProjectRestoreDecisionTests`…), ce qui ne remplace pas un parcours réellement joué.
- **Profilage mémoire/CPU §67 non mesuré** — livrable §87 **non rempli** : Instruments n'existe pas sous Windows et l'application n'a jamais été lancée. Les garde-fous de conception sont en place (décodage par blocs §68, miniatures fenêtrées, caches bornés, condensés entiers §82) mais **aucun chiffre** n'a été relevé : les objectifs §67 sont donc invérifiés, pas atteints.
- **Localisation absente** — livrable §87 **non rempli** : l'interface est écrite en français **en dur**, sans `String Catalog` ni `Localizable.strings`. `SWIFT_EMIT_LOC_STRINGS = YES` est activé : l'extraction reste possible le jour où une seconde langue sera voulue. La V1 est monolingue française **par choix** (§0) — décision assumée, mais le livrable reste non rempli.
- **Tâche d'arrière-plan pour l'export (§58)** : toujours pas d'assertion de tâche d'arrière-plan — un passage en arrière-plan pendant l'encodage reste traité comme une interruption honnête (décision Jalon 10 inchangée).
- **Vérification Mac (⌘B/⌘U) requise** : le projet n'a jamais été compilé (généré sous Windows). Les previews « accessibilité 3 » ajoutées sont le premier contrôle à faire, avec l'icône, la couleur d'accent et le nom sur l'écran d'accueil.

## Checklist de livraison (annexe B) — ce qui est vérifié, et par qui

L'annexe B de la spécification liste quinze points à contrôler avant chaque livraison. Deux colonnes, parce que « vérifié » ne veut pas dire la même chose selon la ligne : la **CI** (runner macOS GitHub, Xcode 26) compile en Release et exécute les tests unitaires sur simulateur — elle ne touche jamais un iPhone, ne voit aucun rendu, ne mesure aucune performance réelle.

| Point (annexe B) | Vérifié par | État |
|---|---|---|
| Le projet compile sans warning critique | **CI** (`build`, Release non signé) | ✅ vert au Jalon 11 ; **à rejouer** après la revue finale |
| Tous les tests passent | **CI** (`tests`, simulateur — job `continue-on-error`, donc à LIRE, pas seulement à voir vert) | ✅ au dernier run ; **à rejouer** |
| Aucun timestamp métier stocké en `Double` arrondi | **CI** (tests `MediaTimeTests`, non-dérive 1 000 cases) | ✅ |
| L'analyse reste locale | Revue de code (aucune dépendance réseau dans la cible) | ✅ |
| Les tâches longues sont annulables | **CI** (tests d'annulation analyse/export) + revue | ✅ |
| La timeline reste fluide | **Appareil réel — NON VÉRIFIÉ** | ⛔ aucun profilage §67 |
| Les boutons principaux sont atteignables au pouce | Revue de code (§30 : tout est en `safeAreaInset` bas) — **rendu jamais vu** | 🟡 |
| Les clips trop courts sont refusés | **CI** (`MediaAssignmentTests`, §43/§64) | ✅ |
| Le premier rush verrouille la géométrie | **CI** (`GeometryLockTests`, `GeometryLockStoreTests`) | ✅ |
| L'export s'arrête au premier trou | **CI** (`ContiguousPrefixTests`, `ExportPlanningTests`) | ✅ |
| L'export n'invente pas un profil absent | **CI** (`MasterProfileTests`) | ✅ |
| Les fichiers temporaires sont nettoyés | **CI** (tests d'export/annulation) + revue | ✅ |
| Le projet est restaurable après fermeture | **CI** partiellement (`ProjectStoreTests`, `ProjectRestoreDecisionTests` — la *décision* §60 est pure et testée) ; le parcours complet (relance à froid, réouverture, dernier export retrouvé) **exige un appareil** | 🟡 |
| VoiceOver et Dynamic Type restent utilisables | **Appareil réel — NON VÉRIFIÉ** : libellés et dispositions adaptatives écrits et relus, previews AX3 fournies, mais ni VoiceOver ni Accessibility Inspector n'ont été exécutés | 🟡 |
| Les écarts à la spécification sont documentés | Ce fichier | ✅ |

**Ce que la CI ne dira jamais** : rendu visuel (matériaux §37, icône, couleur d'accent, contrastes), retour haptique, fluidité et mémoire (§67/§68), comportement PhotoKit réel (autorisations §40, iCloud §44), export sur matériel réel (§55), et tout parcours d'interface (§73, aucun XCUITest). Ces lignes restent **ouvertes** jusqu'à un passage sur Mac + iPhone.

## Distribution et vérification (pipeline ClipFlow)

- `.github/workflows/build-ipa.yml` : à chaque push sur `main`, un runner GitHub macOS (Xcode 26) compile en Release sans signature, empaquette `MontageMusical-unsigned.ipa` et la publie en release GitHub (tag `build-N-rM`). Job `tests` parallèle : tests unitaires sur simulateur (informatif, `continue-on-error`).
- Installation iPhone : Sideloadly sous Windows, signature Apple ID personnelle (validité 7 jours). Voir README.
- Scheme partagé `MontageMusical.xcscheme` requis par `xcodebuild -scheme` sur le runner.
- Dépôt : `github.com/quentinmazzola23-coder/montagemusical-ios` (public, comme clipflow-ios — minutes Actions macOS illimitées).

## Reste à faire (Jalons 0–1)

- ~~Compilation + tests sur Mac~~ → **vérifié** : run Actions 31379440653 (10 août 2026) vert, jobs `build` et `tests` en succès. Première IPA publiée : release `build-1-r1` (commit 33a0bc0). Jalons 0 et 1 terminés — critères d'acceptation §75/§76 satisfaits (compilation sans erreur, tests dont non-dérive passants). Prochain jalon : 2 (projets et persistance).

## À ne pas oublier (jalons suivants)

- **Jalon 2** — contraintes §10.1 non exprimables en simples champs : unicité logique `(projectID, scoreModeRaw, index)` (`#Unique` SwiftData ou validation dans `ProjectStoreActor`), une association max par case, suppression en cascade cases + associations à la suppression définitive d'un projet.
- **Jalon 8** — ✅ fait au Jalon 8 : `INFOPLIST_KEY_NSPhotoLibraryUsageDescription` (lecture) ET `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` (écriture, §40) sont déclarées dans les deux configurations de la cible app du pbxproj.
