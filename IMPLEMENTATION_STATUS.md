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
| 4 — Moteur musical déterministe | ✅ Terminé (CI verte, run 31392520681) |
| 5 — Générateur de scores | ✅ Terminé (CI verte, run 31398882782) |
| 6 — Interface analyse / choix rythme | ✅ Terminé (CI verte, run 31419878812) |
| 7 — Timeline d'assemblage | ✅ Terminé (CI verte, run 31422818870) |
| 8 — PhotoKit | ✅ Terminé (CI verte, run 31428288550) |
| 9 — Géométrie et preview | ✅ Terminé (CI verte, run 31434117279) |
| 10 — Export | 🔄 En cours |
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
- Matériau `.ultraThinMaterial` au lieu du Liquid Glass natif iOS 26 (§37/§81) — cohérent avec tous les docks existants, migration au Jalon 12.
- §60 : restauration automatique du dernier projet ouvert au lancement à froid non implémentée (la réouverture manuelle retombe au bon écran via le routage par statut) — report Jalon 12.

## Jalon 7 — Timeline d'assemblage (10 août 2026)

**Fichiers** : `App/Features/ProjectTimeline/AssemblyModels.swift` (états de case §13.3/§44/§64 avec forme parlée unique §39, géométrie durée-proportionnelle testable), `SlotCardView.swift` (cartes §35.2 : vide « Plan 8 / 1,20 s / + », remplie miniature+numéro+durée+coche, downloading/unavailable/tooShort/resolving distincts sans seule couleur), `AssemblyMiniTimelineView.swift` (§35.3 : segments proportionnels précalculés, position courante, fenêtre carrousel, limite d'export §51, tap+drag, fluide à 300+ cases §82), `AssemblyView.swift` (écran §35 complet : zone haute avec Plan X sur N + timestamps + durée requise + lecture du passage musical au toucher, carrousel 3 cases à 55 % scroll+tap, dock contextuel §36 avec Export à l'état réel §51, debounce navigation 300 ms §59, case active restaurée §60), `AudioPlayerController.playSegment/stopSegment`, routage `ProjectView`, 2 fichiers de tests logique.

**Écarts documentés (résorption prévue)** :
- §35.1 : aperçu = placeholder 16:9 + lecture du passage **musical** seul — **résorbé** : miniature vidéo au Jalon 8, aperçu vidéo+musique §47.1 au Jalon 9.
- §35.3 : « courbe musicale simplifiée » non dessinée dans la mini-timeline — **résorbé au Jalon 9** : `AssemblyView` extrait 200 bins (`WaveformExtractor`) et les passe en fond à `AssemblyMiniTimelineView`.
- §30 : « Changer de rythme » (action secondaire §65) dans un Menu ellipsis en haut à droite — hors zone pouce, assumé pour une action non essentielle ; réexamen au Jalon 12.
- Pause de fin de passage par observateur 10 Hz : dépassement max ~100 ms (affichage V1) — boundary observer exact envisageable au Jalon 9.
- Dynamic Type : hauteurs de cartes/carrousel fixes — passage à @ScaledMetric au Jalon 12 (§87 accessibilité).

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
