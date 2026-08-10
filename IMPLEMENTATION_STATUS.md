# IMPLEMENTATION_STATUS

**Projet :** Application iOS de montage musical guidé (nom de travail : MontageMusical)
**Spécification :** `C:\Users\quent\Downloads\specification_application_montage_musical_ios.md` (v1.0, 10 août 2026)
**Dernière mise à jour :** 10 août 2026

---

## État général

| Jalon | État |
|---|---|
| 0 — Bootstrap | ✅ Terminé (build CI vert) |
| 1 — Temps et domaine | ✅ Terminé (tests CI verts) |
| 2 — Projets et persistance | ✅ Terminé (CI verte, run 31382568859) |
| 3 — Import audio | ✅ Terminé (CI verte, run 31385112438) |
| 4 — Moteur musical déterministe | 🔄 En cours |
| 5 — Générateur de scores | ⬜ Non démarré |
| 6 — Interface analyse / choix rythme | ⬜ Non démarré |
| 7 — Timeline d'assemblage | ⬜ Non démarré |
| 8 — PhotoKit | ⬜ Non démarré |
| 9 — Géométrie et preview | ⬜ Non démarré |
| 10 — Export | ⬜ Non démarré |
| 11 — Moteur avancé Core ML | ⬜ Non démarré |
| 12 — Polissage | ⬜ Non démarré |

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
| 9b | `App/Resources/Assets.xcassets/` | Catalogue minimal (AppIcon vide + AccentColor) — requis par `ASSETCATALOG_COMPILER_APPICON_NAME`, évite un échec de validation d'archive |

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

## Distribution et vérification (pipeline ClipFlow)

- `.github/workflows/build-ipa.yml` : à chaque push sur `main`, un runner GitHub macOS (Xcode 26) compile en Release sans signature, empaquette `MontageMusical-unsigned.ipa` et la publie en release GitHub (tag `build-N-rM`). Job `tests` parallèle : tests unitaires sur simulateur (informatif, `continue-on-error`).
- Installation iPhone : Sideloadly sous Windows, signature Apple ID personnelle (validité 7 jours). Voir README.
- Scheme partagé `MontageMusical.xcscheme` requis par `xcodebuild -scheme` sur le runner.
- Dépôt : `github.com/quentinmazzola23-coder/montagemusical-ios` (public, comme clipflow-ios — minutes Actions macOS illimitées).

## Reste à faire (Jalons 0–1)

- ~~Compilation + tests sur Mac~~ → **vérifié** : run Actions 31379440653 (10 août 2026) vert, jobs `build` et `tests` en succès. Première IPA publiée : release `build-1-r1` (commit 33a0bc0). Jalons 0 et 1 terminés — critères d'acceptation §75/§76 satisfaits (compilation sans erreur, tests dont non-dérive passants). Prochain jalon : 2 (projets et persistance).

## À ne pas oublier (jalons suivants)

- **Jalon 2** — contraintes §10.1 non exprimables en simples champs : unicité logique `(projectID, scoreModeRaw, index)` (`#Unique` SwiftData ou validation dans `ProjectStoreActor`), une association max par case, suppression en cascade cases + associations à la suppression définitive d'un projet.
- **Jalon 8** — ajouter `INFOPLIST_KEY_NSPhotoLibraryUsageDescription` (lecture) puis `NSPhotoLibraryAddUsageDescription` (écriture, §40) dans les deux configurations de la cible app du pbxproj, sinon crash à la première demande d'autorisation Photos.
