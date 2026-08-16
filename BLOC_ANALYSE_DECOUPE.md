# Bloc « Analyse musicale et découpe » — recueil complet

> Jalons **4** (moteur musical déterministe), **5** (générateur de partitions / découpe), **6** (interface analyse + choix du rythme) et **11** (moteur avancé Core ML, délibérément non terminé).
> Spécification de référence : `specification_application_montage_musical_ios.md` v1.0 (10 août 2026), sections §7 à §30, §33-§34, §61-§63, §68-§72, §74, §79-§81, §86, §29A, Annexe A.
> Document établi le 15 août 2026 par relecture intégrale des **29** fichiers Swift du bloc (recensés au §1) + 15 fichiers de tests + la spécification.

> **Révision du 15 août 2026 (build-27, commit `5f00cc2`).** Ce document décrit désormais le moteur **de build-27**, et non la V1 d'origine. Le commit `5f00cc2` « Correctifs de la critique : tempo, onsets, buildup, ancres, échelles, filets » (**28 fichiers** — 14 sources, 12 fichiers de tests, 2 documents —, **4 166 lignes ajoutées / 277 supprimées**, chiffres relevés sur `git show --stat 5f00cc2`) a modifié en profondeur l'estimation de tempo, la fusion d'onsets, la fenêtre de buildup, le champ d'ancres, les échelles structurelles et le versionnage. `engineVersion` 2 → **3**, `generatorVersion` 1 → **2**, apparition d'`analysisSchemaVersion` = 1. Les sections §3.4, §3.5, §3.7, §3.9, §3.10, §4.5, §4.6, §4.8, §4.12, §6, §7, §8 ont été reprises valeur par valeur sur le code du worktree.
>
> **Origine des validations numériques.** Les chiffres cités dans les commentaires du moteur (balayage de 62 tempos de 60 à 210 BPM, densité d'onsets d'un roulement, `energyRise` sur la fixture « montée + gap + impact ») proviennent d'un **report de l'algorithme en Python**, pas d'une exécution Swift. En revanche, la suite de tests unitaires a bien tourné depuis : le job `tests` de la CI, étape « Tests unitaires (simulateur) », est en succès sur le run **31894912740**. Ce job reste déclaré `continue-on-error: true` dans `build-ipa.yml` — il est informatif pour la production de l'IPA, mais son résultat est réel et il est vert.

---

## 1. Périmètre — les fichiers du bloc

### Analyse musicale (Jalon 4)

| Fichier | Rôle |
|---|---|
| `App/Domain/MusicAnalysis/MusicAnalysisModels.swift` | Types purs du résultat d'analyse (aucune logique) |
| `App/Domain/MusicAnalysis/MusicAnalyzing.swift` | Protocole §7, `AnalysisConfiguration`, `AnalysisPhase`, `AnalysisProgress` |
| `App/Services/AudioImport/AudioImporter.swift` | Validation AVFoundation + copie atomique |
| `App/Services/AudioImport/AudioImportError.swift` | 5 cas d'erreur §62, messages français |
| `App/Services/AudioImport/WaveformExtractor.swift` | Forme d'onde d'affichage (200 bins) |
| `App/Services/MusicAnalysis/PCMDecoder.swift` | Décodage PCM streaming mono 22 050 Hz |
| `App/Services/MusicAnalysis/SpectralFeatureExtractor.swift` | STFT vDSP, features §17 |
| `App/Services/MusicAnalysis/FeatureTimeline.swift` | Conteneur de features + conversion frame → ticks |
| `App/Services/MusicAnalysis/OnsetDetector.swift` | Onsets §18 + enveloppe globale |
| `App/Services/MusicAnalysis/TempoEstimator.swift` | Tempo §19.1 |
| `App/Services/MusicAnalysis/BeatTracker.swift` | Beats, mesure, downbeats §19.1/§20 |
| `App/Services/MusicAnalysis/BeatSyncFeatures.swift` | §21/§22 : spans, similarité, nouveauté |
| `App/Services/MusicAnalysis/StructureBuilder.swift` | Arbre d'UMS §22.3 |
| `App/Services/MusicAnalysis/CurvesAndEventsBuilder.swift` | Courbes §23, événements §12.4, relations §25, fonctions §24 |
| `App/Services/MusicAnalysis/AnalysisCache.swift` | Cache §69 + checkpoints de phase |
| `App/Services/MusicAnalysis/DeterministicMusicAnalyzer.swift` | Orchestrateur, `engineVersion = 3`, `analysisSchemaVersion = 1` |
| `App/Services/MusicAnalysis/AudioAnalysisActor.swift` | Acteur §8, une analyse par projet |
| `App/Services/MusicAnalysis/HybridMusicAnalyzer.swift` | Niveau B — délègue toujours au déterministe |
| `App/Services/MusicAnalysis/BeatActivationModel.swift` | Protocole §19.2 (verbatim) |
| `App/Services/MusicAnalysis/CoreMLModelRegistry.swift` | Registre — renvoie `nil` partout aujourd'hui |

### Découpe / partitions (Jalon 5)

| Fichier | Rôle |
|---|---|
| `App/Domain/EditScore/EditScoreModels.swift` | `PaceMode`, `EditScoreFamily`, `EditScore`, `EditAnchor`, `EditSlotDefinition`, `EditGesture` |
| `App/Domain/EditScore/EditScoreGenerating.swift` | Protocole §7 + `ScoreConfiguration` (**toutes** les constantes de découpe) |
| `App/Services/EditScore/AnchorField.swift` | Champ d'ancres §26 : pose, évaluation, déduplication |
| `App/Services/EditScore/GestureDetector.swift` | Gestes §27 (4 types sur 8) |
| `App/Services/EditScore/DeterministicEditScoreGenerator.swift` | §28 : racine, raffinement glouton, finalisation |
| `App/Services/EditScore/ScoreLibrary.swift` | Lecture + péremption §61 des partitions persistées |

### Interface (Jalon 6)

| Fichier | Rôle |
|---|---|
| `App/Features/ProjectTimeline/ProjectView.swift` | Progression d'analyse §33, waveform, réessai |
| `App/Features/PaceSelection/PaceSelectionView.swift` | Choix du rythme §34 + `MiniTimelineView` |

### Persistance — le point d'arrivée

| Fichier | Rôle |
|---|---|
| `App/Data/Persistence/ProjectStore.swift` | `selectPace`, `insertSlotRecords` (validation §10.1), `revertToPaceSelection`, `saveAnalysisResult`, `saveScores` |

Aucun `actor` dans le périmètre de la découpe : tout est `struct`/`enum` `Sendable`, la génération est synchrone et sans état partagé. Le seul acteur impliqué est `AudioAnalysisActor`.

---

## 2. La chaîne complète, de bout en bout

```
fichier externe (Fichiers / iCloud)
  └─ AudioImporter          validation AVFoundation + copie atomique → audio/original.<ext>
      └─ ProjectView         statut .analyzing
          └─ AudioAnalysisActor.startAnalysisIfNeeded      (§8 : une analyse par projet)
              └─ DeterministicMusicAnalyzer.analyze
                   ├─ AnalysisCache          empreinte SHA-256 + engineVersion + schemaVersion + config → retour immédiat si à jour
                   ├─ PCMDecoder             mono Float32 22 050 Hz, par blocs
                   ├─ SpectralFeatureExtractor  STFT vDSP 1024/256 Hann → FeatureTimeline @ 86,1328125 fps
                   ├─ OnsetDetector          détendançage médian → peak picking adaptatif → fusion PAR CLUSTER (3 frames)
                   ├─ TempoEstimator         ACF → filtre de relation entière → moyenne pondérée → pénalité sous-harmonique → prior σ 0,9 → phase
                   ├─ BeatTracker            DP type Ellis (λ=4) → beats ; mesure 2/3/4 → downbeats → bars
                   ├─ BeatSyncFeatureExtractor  spans → vecteurs 17-D (variance) → similarité cosinus → damier 4/8/16/64 temps
                   ├─ StructureBuilder       globalArc → section → phrase → bar → beat
                   └─ CurvesAndEventsBuilder 8 courbes, événements, relations, états fonctionnels
              ├─ AnalysisCache.save  +  ProjectStore.saveAnalysisResult
              ├─ phase 5 « Création des rythmes » publiée par l'ACTEUR
              └─ DeterministicEditScoreGenerator.generateScores        (hors acteur, Task.detached)
                   ├─ AnchorFieldBuilder     8 sources → fusion des co-localisés → évaluation §26.3 → dédup. 2 passes (2ᵉ = rétrogradation)
                   ├─ GestureDetector        burstResolution / impactHold / breathing / simpleAccent
                   ├─ buildRoot              début + fin + ancres majeures (plancher FLUIDE)
                   ├─ refine × 3             fluid → balanced → percussive, séquence d'activations UNIQUE
                   └─ finalizeScore × 3      résidu final, filtrage des gestes, fabrication des cases
              └─ analysis/scores-v1.json + analysis/scores-meta-v1.json  +  ProjectStore.saveScores
                  └─ statut awaitingPaceSelection
                      └─ PaceSelectionView   3 cartes comparables
                          └─ ProjectStore.selectPace
                              └─ ProjectSlotRecord en base SwiftData   ← LES CASES FINALES
```

Hors chaîne : `WaveformExtractor` (200 bins) est recalculé par un décodage complet à **chaque** apparition de `ProjectView` et d'`AssemblyView`, sans aucun cache.

---

## 3. Analyse musicale — étage par étage

### 3.1 Import audio (§62)

Types acceptés : UTType `.mpeg4Audio`, `.mp3`, `.wav`, `.aiff` + `public.aac-audio` ; extensions `m4a, aac, mp3, wav, wave, aiff, aif, aifc`.

Chaîne de validation, dans l'ordre :
1. `startAccessingSecurityScopedResource` avec `defer` de libération
2. contrôle d'extension → `unsupportedType`
3. taille > 0 → `emptyOrCorruptFile`
4. `asset.load(.hasProtectedContent)` → `protectedContent` ; `loadTracks(.audio)` + `isDecodable` → `noDecodableAudioTrack` ; `asset.load(.duration)` en `MediaTime` avec `ticks > 0`
5. **copie atomique** : `temp/import-<UUID>.<ext>` → `audio/staged-<UUID>.<ext>` → purge de l'ancien `audio/` → `audio/original.<ext>`. Toute erreur nettoie temp **et** staged puis lève `copyInterrupted`.

### 3.2 Décodage PCM

`AVAssetReaderAudioMixOutput` et **non** `AVAssetReaderTrackOutput` : seul le mix output accepte `AVSampleRateKey` et `AVNumberOfChannelsKey`. Sortie : `kAudioFormatLinearPCM`, 22 050 Hz, **1 canal**, Float32 little-endian entrelacé. `Task.checkCancellation()` + `Task.yield()` avant chaque bloc.

### 3.3 Caractéristiques spectrales (§16.3, §17)

Une **seule** branche est calculée : `shortBranch` = FFT **1 024** / hop **256** à 22 050 Hz → cadence **86,1328125 frames/s**.

- Setup `vDSP_DFT_zrop_CreateSetup(nil, 1024, .FORWARD)`, fenêtre `vDSP_hann_window(vDSP_HANN_DENORM)`
- Frames **centrées** : bourrage de `fftSize/2 = 512` zéros en tête et en queue
- Buffer glissant compacté au-delà de `1<<16 = 65 536` échantillons lus
- Spectre de puissance sur bins 0…512 (empaquetage zrop : DC dans `outputReal[0]`, Nyquist dans `outputImag[0]`)
- Spectre logarithmique `log(power + 1e-9)`
- Flux spectral = somme des différences redressées demi-onde entre spectres **log** consécutifs (global + par bande), première frame = 0
- Centroïde en **Hz absolus**, DC exclu (bins 1…512), garde `total > 1e-12`

**5 bandes LINÉAIRES** (aucun banc Mel dans le projet) : bornes basses `[20, 120, 500, 2000, 8000]` Hz, dernière bande jusqu'à Nyquist = 11 025 Hz.

Normalisation relative au morceau : division par le **quantile 0,95**, repli sur le maximum si le quantile ≤ 1e-9. Appliquée à `rms`, `bandEnergies`, `spectralFlux`, `bandFlux` ; le centroïde reste en Hz.

`FeatureTimeline.duration` est dérivée du nombre d'échantillons PCM **réellement consommés**, pas du nombre de frames. `FeatureTimeline.mediaTime(forFrame:frameRate:)` est la **seule** conversion frame → ticks du moteur : `ticks = round(frame / frameRate × 60 000)`.

### 3.4 Onsets (§18)

Constantes : `bandWeights = [1.25, 1, 1, 1, 0.75]` · `mergeWindowSeconds = 0.030` · `peakThresholdFactor k = 1.5` · `bandFloorRatio = 0.05` · `globalFloorRatio = 0.02`.

1. Par bande : moyenne glissante de rayon 1 sur `bandFlux`, puis retrait de tendance par **médiane glissante** de rayon `max(2, round(0.5 × frameRate))` ≈ 43 frames (≈ 1 s), redressement `max(0, lissé − tendance)`
2. Enveloppe globale = somme pondérée des 5 bandes détendancées ; retour anticipé si `max ≤ 1e-9`
3. Peak picking adaptatif par bande : seuil = `moyenne locale + 1.5 × écart local` sur rayon `max(2, round(0.175 × frameRate))` ≈ 15 frames, + plancher de bande, + maximum local sur ±2 frames (égalité → frame la plus précoce)
4. **Fusion PAR CLUSTER** (et non plus en chaîne) : `mergeGap = max(1, Int((0.030 × frameRate).rounded()))` — **arrondi et non troncature**, donc **3 frames = 34,8 ms** à 86,1328125 fps (la troncature donnait 2 frames = 23,2 ms, une constante qui mentait de 23 % sur les 30 ms déclarés). L'écart est mesuré au **premier** membre du cluster (`candidate.frame - clusterStartFrame <= mergeGap`) et non au précédent : la largeur d'un cluster est bornée par `mergeGap` par construction. Survivant = la frame de **valeur d'enveloppe globale maximale** du cluster ; égalité → la frame la plus précoce (les candidats sont triés par frame croissante). `mergedFrames` reste strictement croissant.
   > La fusion en chaîne réassignait la référence à chaque itération : une suite de candidats espacés chacun de ≤ `mergeGap` collapsait **intégralement**, sans borne de longueur. Un roulement en 1/32 à 150 BPM (une note toutes les 4,3 frames, étalement inter-bandes de 2 à 3 frames) rendait 1 à 3 onsets ; `onsetDensity` **chutait** pendant le roulement au lieu d'y culminer et la source d'ancres « Attaque marquée » disparaissait exactement là où le montage doit s'accélérer. Report Python cité en commentaire (3 bandes décalées de 0/+1/+2 frames, une note toutes les 4 frames sur 2 s) : chaîne → 1 onset, cluster → 39 onsets. Couvert par `OnsetDetectorTests.testDenseRollIsNotCollapsedByOnsetMerging`.
5. `OnsetEvent` : rejet si `valeur < 0.02 × max` ; `strength = valeur / maxEnveloppe` ; `dominantBand` = bande au flux détendancé maximal ; `confidence = clamp01(1 − moyenneLocale / valeur)`

### 3.5 Tempo (§19.1) — refondu par `5f00cc2`

Constantes de plage : `minBPM = 50` · `maxBPM = 220` · `maxHypotheses = 6` · `maxRawPeaks = 8` · `duplicateTolerance = 0.02` · `doubleTimeRatioTolerance = 0.08`.
Constantes d'arbitrage d'octave : `priorCenterBPM = 120.0` · `priorSigmaOctaves = 0.9` · `integerRelationTolerance = 0.04` · `anchorStrengthRatio = 0.5` · `subharmonicPeakTolerance = 0.05` · `subharmonicDominanceRatio = 0.9` · `subharmonicPenalty = 1.0`.

1. Détendançage de l'enveloppe par soustraction de la moyenne mobile sur ≈ 1 s ; abandon si `énergie/frameCount ≤ 1e-12`
2. **Autocorrélation normalisée** (pas de tempogramme par banc de filtres) : `acf[lag] = (Σ x[i]·x[i+lag] / (N−lag)) / meanSquare`, `acf[0] = 1`. Calcul étendu jusqu'à `min(2×lagMaxIdeal+2, frameCount−1)`. ACF fractionnaire par interpolation **linéaire**
3. Pics : `acf[lag] > acf[lag−1]`, `acf[lag] >= acf[lag+1]`, `acf[lag] > 0.2 × maxACF` ; raffinement du lag par interpolation **parabolique** ; les **8** meilleurs (force décroissante, puis lag croissant) sont gardés
4. **Filtre de relation ENTIÈRE** (correctif 3) — le correctif qui supprime l'alias 2/3 :
   - **Ancre** = le **plus COURT** des pics atteignant `anchorStrengthRatio × rangeMax` = **0,5 × max d'ACF de la plage**, et **non** le plus fort. Mesuré : sur 174 BPM + contretemps, le pic le plus fort est à 3·L (lag 89, acf 0,977) et non à L (lag 30, acf 0,936) ; ancré sur 3·L, le filtre rejetterait le half-time légitime (59/89 = 1,508) et conserverait l'alias 2/3 (45/89 = 1,978 ≈ 2) — l'inverse du but. Tout niveau métrique étant un multiple entier de la pulsation la plus rapide, l'ancrage sur le plus court lag fort ne peut jamais éliminer le vrai tempo.
   - `isIntegerRelated(lag, anchor)` : `ratio = max/min`, `nearest = ratio.rounded()`, retenu si `|ratio − nearest| ≤ 0.04 × nearest` — tolérance **relative à l'entier visé** (un multiple d'ordre *k* cumule *k* fois l'erreur de lag). Un ratio 1,5 est à 33 % de l'entier le plus proche : écarté sans ambiguïté.
   - **Repli §63** : le filtre n'est appliqué que si `peaks.count >= 2` **et** qu'une ancre existe, et le résultat n'est retenu que s'il laisse **≥ 2** candidats. Sinon la liste **non filtrée** est conservée.
5. **Score = MOYENNE PONDÉRÉE** (correctif 1), et non plus une somme :
   ```
   score = ( 1 × max(0, acf(L)) + 0.5 × max(0, acf(2L)) ) / (1 + 0.5)
   ```
   Le terme `2L` — et son poids 0,5 au dénominateur — n'est ajouté **que si** `acf(2L)` tombe dans la plage réellement calculée. Le score vit donc dans [0 ; ~1] et reste comparable d'un candidat à l'autre quel que soit le nombre de termes disponibles. `acf(L)` est lu par interpolation fractionnaire, avec repli sur la valeur brute du pic.
6. **Pénalité sous-harmonique CONDITIONNELLE** (correctif 2) — le terme `+ 0.25 × acf(L/2)` a changé de **signe** :
   ```
   si  ∃ pic à ±5 % de L/2  ET  pic.base ≥ 0.9 × max(acf(L), 1e-6)
       score /= (1 + 1.0)          // c.-à-d. score divisé par 2
   ```
   Une ACF forte à la demi-période signifie que le signal pulse deux fois par période candidate : c'est une preuve **contre** le candidat, qui était comptée **pour** lui. La pénalité est conditionnelle et non proportionnelle : avec des hats à 0,6 du kick, `acf(L/2)/acf(L) ≈ 0,88` sur le **vrai** tempo, alors que ce rapport vaut ≈ 1,0 sur un candidat deux fois trop lent. Deux seuils, donc : `subharmonicPeakTolerance = 0,05` (existence d'un vrai pic à la demi-période) et `subharmonicDominanceRatio = 0,9` (dominance). Comme les pics ne sont cherchés que dans [50 ; 220] BPM, un candidat à *B* BPM ne peut être pénalisé que si `2·B ≤ 220` : la pénalité ne peut **jamais** rétrograder un tempo rapide qui porte des subdivisions. Étant un simple diviseur, elle ne peut pas annuler un score : une hypothèse est rétrogradée, jamais perdue.
7. Garde de plage : `bpm ≥ 50 × 0.98` et `bpm ≤ 220 × 1.02`, `score > 0`
8. **Prior log-normal type Ellis** (correctif 4), appliqué avant normalisation :
   ```
   priorWeight = exp(−0.5 × (log2(bpm/120) / 0.9)²)     // centre 120 BPM, σ = 0,9 OCTAVE
   score *= priorWeight
   ```
   Le centre reste **volontairement** à 120 et n'est pas recentré sur le corpus visé : un prior symétrique en log ne lève l'ambiguïté d'octave que sur `[c/√2 ; c·√2]` = [84,9 ; 169,7] BPM ; recentrer sur 150 déplacerait la fenêtre sur [106 ; 212] et ferait basculer en double-time toute musique sous 106 BPM. C'est le **score** qui doit discriminer au-delà de 169,7 BPM.
   Valeurs du prior documentées dans le code (centre 120, σ 0,9) : **75 → 0,7529 · 120 → 1,0000 · 150 → 0,9380 · 174 → 0,8375 · 200 → 0,7152**.
   Rapport `prior(B)/prior(B/2)`, c'est-à-dire ce que le score doit compenser pour que *B* batte son half-time : **140 → 1,409 · 150 → 1,246 · 160 → 1,111 · 170 → 0,997 · 174 → 0,956 · 180 → 0,900 · 190 → 0,818**. Le prior reste favorable au vrai tempo jusqu'à 170 BPM ; de 170 à 190 il devient défavorable d'au plus 1,223, et la pénalité sous-harmonique (facteur 2) couvre ce déficit avec une marge de 1,64× à 190 BPM et 1,49× à 200 BPM. L'élargissement de σ 0,5 → 0,9 ne répare **pas** l'octave à lui seul (il rapproche même le point de bascule de 165,3 à 155,6 BPM à score inchangé) : il divise le rapport score exigé de 2,580 à 1,340 à 200 BPM et de 1,405 à 1,111 à 180 BPM.
9. Déduplication : écart relatif > 2 % avec tous les gardés, plafond 6 hypothèses ; tri déterministe score décroissant puis BPM croissant
10. **Phase par peigne d'impulsions** : pour chaque décalage entier de 0 à `round(period)−1`, somme de l'enveloppe **brute** aux positions `phase + k×periodFrames` (avance fractionnaire, index par `round`) ; le décalage de somme maximale gagne
11. Relations half/double : appariement des paires dont `|bpmRapide/bpmLent − 2| ≤ 0.16`, par écart croissant au ratio 2, chaque extrémité appariée au plus une fois
12. `probability = score / Σ scores` (somme exactement 1)

Sortie : `tempoCurve` **constante** à une seule valeur (niveau A), `meterNumerator/Denominator = nil` (laissés au `BeatTracker`).

> **Ce que ces quatre correctifs réparent.** L'ancien score `acf(L) + 0,5·acf(2L) + 0,25·acf(L/2)` accordait au half-time un bonus **structurel** : sur une pulsation régulière tous les multiples entiers de la période ont sensiblement la même ACF *a*, le vrai tempo marquait 1,5·*a* (`acf(L/2) ≈ 0` sur un signal pulsé) et son half-time 1,75·*a* — car pour lui le terme `L/2` retombe sur le vrai tempo et vaut *a*. Le facteur 1,1667 restant n'était compensé que par le prior, et seulement jusqu'à **165,3 BPM** : au-delà, l'estimateur rendait la moitié du tempo (174 → 87, 180 → 90, 200 → 100) ; avec une couche de contretemps il rendait même une grille **non métrique** à 2/3 du tempo (174 → 116, 180 → 120), soit une pulsation sur trois.
>
> Le prior log-normal, la moyenne pondérée, la pénalité sous-harmonique et le filtre de relation entière restent un **choix d'implémentation non décrit par la spec**. Ils modifient l'ordre des hypothèses, donc celle que retient l'analyseur (`hypotheses.first`). Toutes les hypothèses restent conservées avec leurs relations (§63).
>
> **Non corrigé** : `DeterministicMusicAnalyzer` consomme toujours `hypotheses.first` sans jamais exploiter les relations half/double pourtant calculées.

### 3.6 Beats, mesure, downbeats (§19.1.5, §20)

Constantes : `lambda = 4.0` · `meterCandidates = [2, 3, 4]` · `fallbackMeter = 4`.

**Programmation dynamique type Ellis** :
```
score[t] = env[t] + max(0, max_{τ ∈ [t−windowHigh, t−windowLow]} ( score[τ] − λ · (log((t−τ)/period))² ))
```
avec `period = envelopeRate × 60 / tempoBPM`, `windowLow = max(1, floor(period/2))`, `windowHigh = max(windowLow+1, ceil(2×period))`. Démarrage libre. Backtrack depuis la meilleure frame de la **dernière période** du morceau.

Confiance = cohérence des intervalles = `clamp01(1 − écart-type/moyenne)`, exige ≥ 3 beats sinon 0. Elle est recopiée **à l'identique** dans chaque `BeatEvent` (pas de confiance locale par beat).

**Mesure** : pour chaque m ∈ {2,3,4} et chaque décalage 0…m−1, score d'alignement = moyenne de `(bassNormalisée[beat] + forceOnset[beat])` sur les downbeats candidats, normalisée par le **nombre** de candidats. La basse est lue sur la bande 0 (20–120 Hz) au **maximum sur ±2 frames** autour de la frame convertie (jitter de ±1 frame du beat suivi). `downbeatConfidence = clamp01((meilleur − second) / meilleur)`.

**Barres** : downbeats aux indices `bestOffset + k×bestMeter`, un `BarEvent` entre downbeats consécutifs, index croissant depuis 0. Il faut ≥ 2 downbeats. `meterDenominator = 4` **figé**.

**Confiance d'un `BarEvent`** (changé par `5f00cc2`) : `downbeatConfidence` n'est **plus** recopiée telle quelle. C'est une marge inter-hypothèses de **métrique**, structurellement bornée (≈ 0,08 sur un 4/4 dont le temps 1 porte un accent de +20 %, exactement 0 sur un 4-on-the-floor uniforme) ; propagée comme confiance de **position**, elle faisait de chaque début de mesure l'ancre la plus faible du niveau beat (§4.5). La confiance de barre est désormais :
```
barConfidence = clamp01( coherence + (1 − coherence) × downbeatConfidence )
```
`coherence` étant la cohérence des intervalles de la grille. Elle vaut **exactement** `coherence` quand rien ne distingue les temps (aucune certitude inventée, §63), n'est **jamais** inférieure à la confiance du beat co-localisé, et tend vers 1 quand la mesure s'impose. `TrackedRhythm.downbeatConfidence` reste rendue telle quelle : son seul consommateur légitime est `confidenceBreakdown.rhythm`.

Cas dégénéré (enveloppe vide/plate, BPM ≤ 0) : aucun beat, aucune barre, mesure 4, confiance 0.

### 3.7 Similarité et nouveauté (§21, §22) — refondu par `5f00cc2`

Constantes : `fallbackStepTicks = 30 000` (0,5 s) · `minimumBeatsForGrid = 4` · `kernelHalfWidths = [2, 4, 8, 32]` (kernels de **4, 8, 16 et 64 temps**) · `sectionKernelHalfWidth = 32` · `minimumSectionSeparationSpans = 32` · `minimumRawNoveltyResponse = 0.8` · `maxSimilaritySpans = 2 000` (plafond ≈ 16 Mo).

- Grille = beats réels si ≥ 4 beats, sinon grille uniforme tous les 30 000 ticks avec `isBeatAligned = false`
- **Vecteur 17-D** par span : pour chacune des 5 bandes → moyenne, maximum, **VARIANCE de population** (division par *n*), + moyenne du rms + moyenne du flux. La **pente** (moyenne de la 2ᵉ moitié − moyenne de la 1ʳᵉ moitié) a été **remplacée** par la variance, comme §21 le demandait : un span de 0,4 s ne contient que ≈ 34 frames et le jitter de ±1 frame du beat suivi déplaçait la pente d'environ 0,3 × la moyenne du span — soit l'ordre du signal lui-même. Ces 5 dimensions sur 17 (≈ 29 % de la norme du vecteur), z-scorées au même poids que le RMS, n'étaient que du bruit : plancher de nouveauté remonté, donc frontières réelles écrasées à la normalisation. La variance est **invariante au décalage temporel** de la fenêtre et distingue exactement ce qu'on veut distinguer (span « tenu », variance ≈ 0 ; span « percuté », variance forte). Son échelle absolue (≈ 1e-3) est sans importance : `standardized` z-score chaque dimension avant la similarité.
- Scalaires par span : energy, bass, flux, centroid, `onsetDensity` (onsets/seconde), chacun normalisé par quantile 0,95 borné 0…1 (repli sur le maximum si le quantile ≤ 1e-9)
- Si `spanCount > 2000` : sous-échantillonnage par stride avec agrégation par **moyenne** avant toute matrice ; nouveauté ré-étendue en palier constant par groupe, `spanIndex` des frontières remappé par `× gridStride`
- Vecteurs standardisés dimension par dimension (z-score, plancher 1e-6), **matrice de similarité cosinus** symétrique, diagonale à 1
- **Nouveauté par kernel en damier** le long de la diagonale, pour chaque h ∈ {2, 4, 8, **32**} :
  ```
  N[i] = ( Σ_{u,v<h} S[i−1−u][i−1−v] + S[i+u][i+v] − S[i−1−u][i+v] − S[i+u][i−1−v] ) / terms
  avec  curve[i] = terms >= max(h²/2, 1) ? max(N[i], 0) : 0        // convention de Foote
  ```
  **Annulation de l'artefact de bord** : la réponse est rendue **nulle** tant que le nombre de quadruples valides est insuffisant. `terms` valant exactement `min(h, i, count−i)²`, exiger `h²/2` revient à exiger `min(i, count−i) ≥ 0,71 × h`, c'est-à-dire à annuler la réponse sur les ≈ *h* premiers et derniers spans. Sans ce garde, à `index = 1` un **seul** terme survivait au garde de bornes quelle que soit la demi-largeur : sa valeur `2 − 2·S[0][1]` est bornée par 4,0 alors qu'une vraie frontière moyennée sur 1 024 termes plafonne vers 2,8–3,6 ; sur un morceau à fade-in, `novelty[1]` fixait à lui seul le maximum de normalisation et déflatait toute la courbe d'environ 1,43×, les frontières réelles à ≈ 0,42 passant sous le seuil 0,3.
  Conséquence assumée : sur un morceau plus court que ≈ 2 × 0,71 × 32 ≈ **46 spans**, le kernel de section est identiquement nul → aucune frontière de section, le morceau forme **une** section (`StructureBuilder` gère déjà ce cas).
  La courbe combinée normalise chaque kernel par son propre maximum, moyenne les **4**, renormalise. Les réponses **brutes** (`perKernelRaw`, échelle commune) servent à la dominance et au seuil absolu.
- **Frontières** : maximum local sur ±2 spans → kernel dominant = réponse **brute** maximale (`>` strict, donc à égalité parfaite la plus **petite** échelle l'emporte — une égalité ne doit jamais promouvoir une phrase en section) → **seuil ABSOLU** `dominantResponse >= 0.8` → seuil adaptatif `valeur >= max(0.3, moyenneLocale(±8 spans) × 1.2)` → `confidence = min(0.3 + 0.6 × strength, 0.9)`, **jamais 1,0 au niveau A**.
  - `isSectionScope = (dominantHalfWidth >= 32)`, c'est-à-dire **réservé au kernel de 64 temps = 16 mesures en 4/4**. L'ancien `kernelSize >= 16` faisait passer une alternance A/B de 4 mesures pour une section : à 150 BPM, 16 temps = 6,4 s, soit exactement une phrase — le damier entrait en résonance avec un drop alterné et étiquetait « nouvelle section » toutes les 6,4 s. Une vraie section EDM fait 16 à 32 mesures, soit 25 à 50 s.
  - **Séparation minimale de section portée de 8 à 32 spans** (= 8 mesures en 4/4, la moitié de la plus petite section plausible) : à 8 spans le moteur pouvait produire des « sections » de 3,2 s. La plus forte des deux survit.
  - **Le seuil absolu `minimumRawNoveltyResponse = 0.8` est ce qui rend possible ZÉRO frontière.** Les deux autres seuils sont relatifs (`novelty` est normalisée par son propre maximum, deux fois) et ne pouvaient donc **structurellement** pas rendre zéro frontière : sur 90 s prélevées dans un drop — l'usage visé — ils promouvaient les pics de bruit en frontières de section, donc en ancres majeures de rang 0 imposées aux trois modes. Justification du 0,8 par la plage théorique du damier sur vecteurs standardisés : chaque terme vit dans [−4, +4] ; deux blocs internement identiques et mutuellement orthogonaux donnent **2,0** (frontière idéale), du matériau réel **1,0–1,4**, une boucle homogène **0** plus quelques centièmes de bruit. 0,8 est à 40 % de la frontière idéale.

> **Coût du kernel long**, vérifié dans le code : h² = 1 024 quadruples de 4 lectures par span, soit ≈ 4 M lectures pour 1 000 spans et ≈ 8 M au plafond de 2 000. À comparer à la matrice de similarité elle-même (≈ 34 M multiplications-additions) et à l'autocorrélation du tempo (≈ 50 M). Négligeable.

### 3.8 Arbre d'UMS (§22.3)

Hiérarchie réellement construite : `globalArc` → `section` → `phrase` → `bar` → `beat`. **`microEvent` n'est jamais instancié.**

- Racine `globalArc` 0…duration, forces 1, confiance 0,9
- Sections aux frontières `isSectionScope` internes ; sans frontière, le morceau forme une section unique ; `confidence = min(entrée, sortie)`
- Phrases aux frontières de petite portée ; **à défaut, groupement fixe de 4 mesures** (force 0,3, confiance 0,4) ; à défaut encore, la section entière
- Mesures : `boundaryStrengthIn/Out = 0.25` **fixe**
- Beats : `boundaryStrengthIn = clamp01(beat.strength) × 0.5`
- **`repetitionGroupID` reste `nil` partout**

Descripteurs agrégés par unité : energy / rhythmicDensity / novelty / bassPresence = moyennes ; `tension = min(0.6 × montée d'énergie + 0.4 × montée de centroïde, 1)` ; `stability = clamp01(1 − 4 × variance du flux)` ; `regularity` = moyenne des confiances des beats ; **`vocalPresence = 0` constant**.

### 3.9 Courbes, événements, relations, fonctions (§23, §12.4, §25, §24)

Seuils : `impactEnergy = 0.65` · `impactRise = 0.35` · `impactFloorWindow = 8 spans` · `silenceRMS = 0.03` · `silenceMinimumSeconds = 0.8` · `buildUpTension = 0.4` · `buildUpEnergyRise = 0.15`.
Fenêtre de montée §25 (ajoutée par `5f00cc2`) : `buildUpWindowBars = 8` · `buildUpWindowFallbackSpans = 8` · `buildUpWindowMaximumSpans = 64` · `buildUpMinimumSpans = 4`.

> `impactFloorWindow = 8` est justifié numériquement : sur 3 spans, la montée d'un crescendo graduel plafonne à 0,26–0,33 (< 0,35) et l'impact n'était jamais détecté ; sur 8 spans elle atteint 0,45–0,66 sans créer d'impact parasite sur click track. Elle est désormais **volontairement découplée** de la fenêtre de `genuineRise` : les deux mesurent des choses différentes. Ici, « l'impact domine-t-il son plancher **local** ? », seuil calibré contre le creux minimal d'un click track sur 8 spans (≈ 0,21) ; élargir à 32 spans ferait franchir 0,35 par simple respiration du signal et **inventerait** des impacts sur une boucle sans drop (§0.7/§63). `genuineRise` répond à « une montée précède-t-elle réellement cet impact ? », figure qui dure 8 à 16 mesures.

**Événements produits** : `.onset` (un par onset) · `.accent` (force > `max(80ᵉ centile, 0.6)`) · `.downbeat` (salience du beat apparié à ±3 000 ticks = ±50 ms, sinon 0,5) · `.sectionBoundary` / `.phraseBoundary` · `.impact` · `.silence`.

**Impacts** : maximum local d'énergie ≥ 0,65, montée ≥ 0,35 par rapport au **minimum des 8 spans précédents**, séparation minimale de 2 spans. `salience = min(0.5×valeur + 0.5×montée, 1)`, `confidence = min(0.3 + 0.4×montée, 0.7)`. Temps **raffiné à la frame de dérivée RMS maximale** dans le span, fenêtre élargie de 0,15 s vers l'arrière.

**Relations** : `contains` (section → phrases au même instant à ±1 beat) et `prepares` (buildUp → impact), **uniquement si `genuineRise` est validé**. Le buildUp émis est `geometry = .interval`, `start = spanStart(windowStart)`, `end = impact.start` **au tick exact**, `confidence = 0.45`, `salience = min(0.5 × meanTension + 0.5 × energyRise, 1)`. Sans montée : aucun buildUp, aucune relation — règle « ne jamais inventer de drop ».

**`genuineRise`, refondu par `5f00cc2`** — fenêtre en **mesures** et montée mesurée jusqu'au **sommet** :

1. **Largeur de fenêtre** calculée **une fois** pour tout le morceau par `buildUpWindowSpans(bars:beatSync:)` :
   ```
   spansPerBar = médiane HAUTE du nombre de spans démarrant dans chaque BarEvent
                 (balayage à deux curseurs, O(mesures + spans) ; nil si la grille
                  n'est pas alignée sur la pulsation ou si aucune mesure n'existe)
   windowSpans = spansPerBar != nil ? min(8 × spansPerBar, 64) : 8
   ```
   Soit 32 spans en 4/4 (≈ 12,8 s à 150 BPM), plafonnés à 64 temps = 16 mesures. Le repli §63 à **8 spans** reprend exactement la valeur historique en temps : on ne fabrique pas une mesure qu'on n'a pas mesurée.
2. `windowStart = max(spanIndex − windowSpans, 0)`, `windowEnd = spanIndex` (exclusif) ; abandon si `windowEnd − windowStart < 4`
3. **Sommet** : `peakIndex` = argmax de `energy` sur `[windowStart, windowEnd)`, égalité → le span le plus **précoce**
4. `energyRise = energy[peakIndex] − energy[windowStart]` ; abandon si `< 0.15`
5. La partie ascendante doit être une **figure** et non un sursaut isolé : abandon si `peakIndex − windowStart + 1 < 4`
6. `meanTension` = moyenne de `tension` sur **`[windowStart, peakIndex]`** — la montée elle-même, pas la fenêtre entière ; abandon si `< 0.4`

> **Pourquoi le sommet et non la dernière valeur.** L'ancien calcul `energy[windowEnd − 1] − energy[windowStart]` mesurait jusqu'au span précédant **immédiatement** l'impact, c'est-à-dire, dans la figure canonique du genre (riser → 1 à 2 temps de **silence** → drop), jusqu'au silence. La différence est **négative** (−0,68 mesuré sur la fixture « montée + gap 1 s + impact »), le garde ≥ 0,15 échouait, et l'impact était détecté sans que le `.buildUp` le soit jamais : ni relation `.prepares`, ni `burstResolution`, ni densification pendant la montée. Le maximum sur la fenêtre est insensible au gap : **+0,30** (fenêtre de repli 8 spans) à **+0,90** (fenêtre de 8 mesures) sur la même fixture. La tension souffrait du même mal en plus doux — `smoothedPositiveSlope` écrête à 0 toute décroissance, donc les spans du gap rentraient des zéros dans la moyenne : 0,61 sur la fenêtre entière contre **0,81** sur la partie ascendante. Couvert par `BuildupPipelineTests.testRiserThenSilenceGapThenImpactStillProducesBuildUpAndPrepares`.

**Fonctions dramaturgiques**, par span, dans l'ordre : `impact` → `transition` (novelty ≥ 0,6) → `accumulation` (tension ≥ 0,45 et Δénergie ≥ 0) → `sustain` (energy ≥ 0,6 et |Δ| ≤ 0,08) → `release` (Δ ≤ −0,15) → `exposition`. Lissage absorbant les runs < 2 spans. Confiance **fixe** 0,4 (0,3 pour une section plus courte qu'un span).

### 3.10 Orchestration, cache, reprise

`engineVersion = 3` · **`analysisSchemaVersion = 1`** (nouveau) · `minimumOnsetsForTempo = 4` · `noHypothesisID` = UUID nul déterministe.

**Deux versions, deux rôles** — c'est le découplage introduit par `5f00cc2` :

| Constante | Ce qu'elle décrit | Ce qu'elle périme |
|---|---|---|
| `engineVersion = 3` | Version d'**algorithme** : le même audio ne produit plus le même résultat | Le **cache** `AnalysisCache` et les checkpoints de phase — et **rien d'autre** |
| `analysisSchemaVersion = 1` | Version de **forme** du `MusicAnalysisResult` ; c'est elle qui est écrite dans `result.version` | La **lisibilité** d'un blob persisté et la validité des **partitions** (§4.12) |

Les deux étaient confondues : `AnalysisCache` exigeait `result.version == engineVersion` et `ScoreLibrary` exigeait `meta.analysisVersion == engineVersion`. Toute évolution du moteur — y compris une simple correction de bug — périmait **simultanément** le cache d'analyse et les partitions de tous les projets de tous les utilisateurs, ce qui faisait tomber la promesse §69 exactement dans le cas fréquent.

`engineVersion` v2 → **v3** est justifiée dans le code par quatre changements de comportement, chacun suffisant à lui seul : **tempo** (moyenne pondérée + filtre de relation entière), **onsets** (fusion par cluster), **buildup** (`energyRise` au maximum de la fenêtre), **structure** (kernels longs + seuil absolu de nouveauté).

`analysisSchemaVersion` vaut **1 et n'a jamais été incrémentée** : le schéma §12 n'a pas bougé depuis la première version (le fichier s'appelle `analysis-v1.json`). À incrémenter uniquement si un champ change de nom, de type ou de sens.

**Migration, sans réécriture en place.** `CacheMeta` porte désormais un champ `schemaVersion` **obligatoire et non optionnel** : aucune méta écrite avant ce découplage ne le porte, leur décodage échoue donc, leur cache est ignoré et le résultat est simplement recalculé. Aucun résultat n'est jamais relu sous un schéma qu'il ne respecte pas. Symétriquement, les `scores-meta-v1.json` existants portent `analysisVersion = 2` (une ancienne version de **moteur**) : ils sont déclarés périmés **une dernière fois** par ce changement de sémantique, et l'écran du choix du rythme affiche « Les rythmes doivent être recalculés » avec un bouton — le recalcul reste une action de l'utilisateur (§61).

Ordre exact d'`analyze` :
1. Empreinte audio **SHA-256** (blocs de 1 Mio) + `configurationFingerprint` (`sr22050-s1024.256-m2048.512-l4096.1024-whann`)
2. Cache à jour → **retour immédiat, aucune progression publiée**
3. Chargement du checkpoint, invalidé si `engineVersion` diffère
4. Phase 1 « Préparation audio » → checkpoint. **Le fichier de checkpoint est du JSON** (`AnalysisCache.makeEncoder()` est un `JSONEncoder` à clés triées, `AnalysisCache.swift:211-214`) ; seul le blob `featureTimelineData` qu'il transporte est un plist binaire (`DeterministicMusicAnalyzer.swift:434, 453`), donc encodé en **base64** dans ce JSON
5. **Garde morceau très court** : `rms.count < 8` ou `duration ≤ 0` → `minimalResult` (racine globalArc seule, `ConfidenceBreakdown(overall: 0.1, rhythm: 0, structure: 0.1, functions: 0)`)
6. Phase 2 « Pulsation et tempo » : onsets **toujours** recalculés, hypothèses de tempo **seulement si `onsets.count >= 4`**
7. Phase 3 « Phrases et structure »
8. Phase 4 « Montées et impacts »
9. `MusicAnalysisResult` → `AnalysisCache.save` → effacement du checkpoint

> **Pourquoi `minimumOnsetsForTempo = 4`** (bug corrigé, `engineVersion` 1 → 2) : sur « silence + impact isolé », le détendançage creusait un piédestal négatif dont l'autocorrélation produisait un pic parasite ≈ 0,02, donnant une hypothèse fantôme ≈ 109 BPM de probabilité 1, des beats fantômes, et une grille démarrant **sur** l'impact.

`confidenceBreakdown` :
```
rhythm    = clamp01( probabilité(hypothèse retenue) × (0.5 + 0.5 × downbeatConfidence) )
structure = moyenne des confiances des frontières, sinon 0,3 (arbre > 1 unité) ou 0,2
functions = moyenne des confiances des états, 0 si aucun
overall   = clamp01( 0.4×rhythm + 0.4×structure + 0.2×functions )
```

`try Task.checkCancellation()` entre **chaque** phase. Annulation → statut inchangé (`analyzing`), reprise à la réouverture. Le cache exige la **conjonction** : empreinte audio ET `meta.engineVersion` ET `meta.schemaVersion` ET empreinte de config ET `result.version == schemaVersion`. Le **checkpoint** de phase, lui, reste invalidé par le seul `engineVersion` (`checkpoint?.engineVersion != Self.engineVersion → checkpoint = nil`). `save` écrit le **résultat d'abord**, la méta ensuite (une méta sans résultat validerait un cache vide), les deux atomiquement, JSON à clés triées.

`AudioAnalysisActor` : garde de réentrance (`startingProjects`), lit la durée réelle via `AVURLAsset` (**jamais inventée**), publie lui-même la phase 5, impose une progression **monotone** (les `Task` du callback n'ont aucun ordre FIFO garanti). Trois changements de `5f00cc2` :
- `analyzer` et `scoreGenerator` sont désormais **injectables** (`any MusicAnalyzing & Sendable`, `any EditScoreGenerating & Sendable`)
- **la reprise ne bloque plus sur une tâche annulée** : `await existing.value` suivi d'un appel récursif est remplacé par une **demande de redémarrage non bloquante** (`restartRequests.insert(projectID)`), rejouée à la fin de la tâche en cours (`Task { await self.startAnalysisIfNeeded(projectID:) }`)
- **l'annulation atteint la génération détachée** : le `Task.detached` est enveloppé dans `withTaskCancellationHandler { try await generation.value } onCancel: { generation.cancel() }`, et `DeterministicEditScoreGenerator.refine` teste `try Task.checkCancellation()` en tête de chaque tour de boucle. La génération n'est donc plus un cœur brûlé jusqu'au bout.
- la méta de partitions reçoit `analysisEngineVersion: DeterministicMusicAnalyzer.engineVersion` (tracée, non discriminante — §4.12)

---

## 4. Découpe — du champ d'ancres aux cases

### 4.1 `ScoreConfiguration` — toutes les constantes

Les **9 poids §26.3** valent tous **1.0** : `rhythmicStrength`, `structuralStrength`, `novelty`, `contrast`, `resolutionValue`, `expectedFutureValue`, `inhibition`, `uncertaintyPenalty`, `overcutPenalty`.

| Paramètre | Valeur | Origine |
|---|---|---|
| `overcutDensityWindow` | 90 000 ticks = **1,5 s** | hors spec |
| `overcutDensityScale` | **0.1** | hors spec |
| `minimumSlotDurationFluid` | 45 000 ticks = **0,75 s** | **§28.2** |
| `minimumSlotDurationBalanced` | 24 000 ticks = **0,40 s** | **§28.2** |
| `minimumSlotDurationPercussive` | 15 000 ticks = **0,25 s** | **§28.2** |
| `addedCutCost` | **0.5** | hors spec |
| `splitGainThreshold` fluid / balanced / percussive | **0.30 / 0.12 / 0.05** | hors spec |
| `targetSlotDuration` fluid / balanced / percussive | **2,5 s / 1,2 s / 0,6 s** | hors spec |

Un `assert` impose la **monotonie** `fluid ≥ balanced ≥ percussive` : sans elle, l'imbrication §70 par séquence d'activations unique casserait. *(C'est un `assert`, donc retiré en Release.)*

Toute modification d'une de ces constantes change l'empreinte SHA-256 de `ScoreConfiguration` et **périme automatiquement** les partitions déjà écrites.

### 4.2 Grille de référence

`AnchorFieldSupport.medianBeatIntervalTicks` : intervalle de beat **médian** calculé sur les écarts strictement positifs entre beats triés. Repli **30 000 ticks (0,5 s = 120 BPM)** si moins de 2 beats (§63, morceau ambiant). Cette valeur `beatTicks` règle **toutes** les fenêtres du champ d'ancres et du détecteur de gestes.

### 4.3 Les 8 sources de candidats

Seuils : `mergeTicks = 3 600` (60 ms) · `minimumOptimalHalfTicks = 3 600` · `anticipationTicks = 90 000` (1,5 s) · `postImpactTicks = 60 000` (1 s) · `resolutionSearchTicks = 150 000` (2,5 s) · `strongOnsetSalience = 0.75` · `conditionalConfidence = 0.5`.

| # | Source | Pondération | Raison affichée | Rang |
|---|---|---|---|---|
| 1 | Début du morceau | structural 1.0, confiance 1.0, **protégé** | « Début du morceau » | 0 |
| 2 | Fin du morceau | structural 1.0, confiance 1.0, **protégé** | « Fin du morceau » | 0 |
| 3 | Bords de section | structural = `clamp01(boundaryStrength)` | « Nouvelle section » | 0 |
| 4 | Bords de phrase | structural = **0.6 ×** `clamp01(boundaryStrength)` | « Frontière de phrase » | 1 |
| 5 | Downbeat | rhythmic = force du beat à ±3 000 ticks, sinon **0.7** | « Downbeat fort » (≥ 0.6) / « Downbeat » | 2 |
| 6 | Beat | rhythmic = `clamp01(beat.strength)` | « Beat fort » (≥ 0.8) / « Beat » | 3 |
| 7a | Impact | rhythmic = `clamp01(salience)` | « Impact probable » | 2 |
| 7b | Accent | rhythmic = **0.5 ×** `clamp01(salience)` | « Accent fort » | 4 |
| 7c | Onset ≥ 0.75 | rhythmic = **0.4 ×** `clamp01(salience)` | « Attaque marquée » | 4 |
| 8a | Événement `.release` | resolution = `clamp01(max(salience, 0.5))` | « Résolution après impact » | 3 |
| 8b | État `.release` | resolution = **0.8**, **si** suit un impact de < 2,5 s | « Résolution après impact » | 3 |

Kind de base : trackEdge/section/phrase → `.structural` ; downbeat/beat/impact → `.exact` ; strongOnset → `.soft` ; resolution → `.resolution`. Fenêtre étroite pour downbeat/beat/impact uniquement.

### 4.4 Évaluation d'une ancre (§26.3)

Pour un candidat au tick `t` :

```
N            = clamp01( novelty(t) )
contrast     = clamp01( | energy(min(t+beatTicks, durée)) − energy(max(t−beatTicks, 0)) | )
futureValue  = max sur les impacts dans (t, t+90 000] de ( 1 − Δ/90 000 )        // rampe linéaire

heldNote        = max(0, (S − 0.6)/0.4) × max(0, (0.3 − N)/0.3)   avec S = clamp01(stability(t))
postImpactHold  = max sur impacts avec 0 < t − impact ≤ 60 000 de ( 1 − |2p − 1| ),  p = Δ/60 000
                  // TRIANGLE culminant à 0,5 s après l'impact
noChange        = max(0, (0.1 − N)/0.1) × 0.5
inhibitionComponent = heldNote + postImpactHold + noChange

attraction   = w_rhythmic·rhythmic + w_structural·structural + w_novelty·N
             + w_contrast·contrast + w_resolution·resolution + w_expectedFuture·futureValue
inhibition   = w_inhibition × inhibitionComponent
uncertainty  = w_uncertaintyPenalty × (1 − clamp01(confidence))

finalUtility = attraction − inhibition − uncertainty
```

> **Le terme `− overcutPenalty` de §26.3 n'est PAS dans la valeur persistée** : il dépend de l'état de sélection et n'est appliqué qu'au moment du choix des splits.

Kind final : base par source ; si `.exact` ou `.soft` **et** qu'un impact tombe dans `(t, t + beatTicks]` → `.anticipatory` ; si `confidence < 0.5` et candidat non protégé → `.conditional` (écrase tout). **`.grouped` n'est jamais assigné.**

Raisons §29 (français) : raisons de la source + « Nouveauté élevée » (N ≥ 0.5) + « Contraste élevé » (≥ 0.5) + « Anticipation d'un impact » + toujours en dernier « Confiance 0,91 » (formaté à la main, sans locale).

Fenêtres §13.1 : `optimalHalf = max(beatTicks/2, 3 600)` en fenêtre étroite, `max(beatTicks, 3 600)` sinon ; `toleratedHalf = 2 × optimalHalf` ; les 4 bornes clampées à `[0, durée]`.

### 4.5 Fusion des co-localisés + déduplication — refondu par `5f00cc2`

Le champ d'ancres est désormais **non destructif** et **indépendant du mode** : seule la sélection est spécifique au mode.

**Passe 0 — fusion des candidats CO-LOCALISÉS, AVANT évaluation** (`coalesceColocated`). Seuil `coLocationTicks = 348` ticks = **5,8 ms = une demi-frame d'analyse**. Justification du seuil : tout ce que le moteur observe est quantifié au hop de la STFT (256 échantillons à 22 050 Hz = 11,61 ms = 696,6 ticks) via l'unique `FeatureTimeline.mediaTime(forFrame:)` ; deux observations **distinctes** sont donc séparées d'au moins une frame entière, et un écart inférieur à une demi-frame ne peut provenir que de deux descriptions du même instant. Cas canonique : `bar.start` **est** littéralement `beats[k].time`, écart exactement 0. Le seuil reste 10× sous `mergeTicks` (60 ms), pour que la passe 1 garde son rôle d'arbitrage entre deux instants réellement distincts.

- Tri en **ordre total strict** : (centerTicks, `hierarchyRank`, `mergeOrder`, index de production). `mergeOrder` est un ordre explicite des 8 sources — `trackEdge 0 · section 1 · phrase 2 · impact 3 · downbeat 4 · beat 5 · resolution 6 · strongOnset 7` — où **`impact` passe devant `downbeat`** à rang 2 (un impact est daté et raffiné à la frame de dérivée RMS maximale, plus spécifique qu'un début de mesure déduit de la grille).
- Groupement **par rapport au premier membre** du groupe : largeur bornée par `coLocationTicks`, aucune agglomération en chaîne. Deux protégés (début et fin du morceau) ne fusionnent jamais entre eux.
- **Fusion composante par composante** : `rhythmic`, `structural`, `resolution` et `confidence` prennent le **maximum** du groupe ; `isProtected` est un OU ; les raisons sont cumulées sans doublon. Le **représentant** (protégé > rang le plus petit > `mergeOrder` > instant le plus précoce) fixe `centerTicks` et `source`, donc `baseKind`, le rang et la largeur de fenêtre §13.1.
- En sortie, tous les centres sont **deux à deux distincts**.

> **Ce que cette passe répare.** La déduplication classait par `hierarchyRank` **avant** `finalUtility`. Au tick exact d'un downbeat, l'ancre de barre (rang 2) et l'ancre de beat (rang 3) sont à distance **0**, et la barre gagnait par son seul rang. Or les deux portent la même attraction, mais des confiances très différentes : la barre portait `downbeatConfidence`, une marge inter-hypothèses de métrique bornée à ~0,03–0,10, quand le beat porte la cohérence des intervalles (> 0,9). Avec `uncertaintyPenalty = 1`, la pénalité valait ≈ 0,92 sur le downbeat contre ≈ 0,1 sur le beat : `finalUtility(downbeat)` tombait ≈ 0,8 **sous** celle du beat, et c'est pourtant le downbeat qui survivait. Chaque début de mesure devenait l'ancre la plus faible du niveau beat et le générateur évitait de couper sur le « 1 ». **Règle posée** : une frontière de mesure ne peut jamais valoir moins que le beat qu'elle remplace ; l'utilité fusionnée est ≥ celle de chaque membre pris isolément. Le correctif jumeau côté analyse est `barConfidence` (§3.6). Couvert par `ScoreConfigurationWeightsTests.testColocatedDownbeatIsNeverWeakerThanTheBeatItReplaces` et `…testColocatedSectionBoundaryKeepsTheBeatRhythmicComponent`.

Critère unique de force des deux passes suivantes, dans cet ordre : **protégé** > rang hiérarchique le plus **petit** > `finalUtility` la plus **grande** > center le plus **petit**. Aucun UUID n'intervient : déterministe.

**Passe 1 — regroupement en chaîne** : après tri, tout candidat à moins de **3 600 ticks (60 ms)** du précédent du cluster courant le rejoint. Deux candidats protégés (début et fin) ne fusionnent jamais. Survivant = le plus fort, avec les raisons de **tous** les membres cumulées sans doublon. *(Depuis la passe 0, les centres sont deux à deux distincts : le comparateur de tri est un ordre total strict, donc `sorted` — qui n'est pas stable — rend une permutation unique.)*

**Passe 2 — RÉTROGRADATION des majeures rapprochées** (et non plus suppression). Deux ancres de rang ≤ 1 distantes de moins de `minimumSlotDurationFluid` = **45 000 ticks (0,75 s)** ne peuvent pas être toutes deux frontières racines (§28.3.1). La **perdante reste dans le champ** : `hierarchyRank` porté à `demotedHierarchyRank = 4`, donc **sortie de `majorAnchorIDs`**, avec insertion de la raison §29 « **Rétrogradée : majeure trop proche** » juste avant la raison de confiance (toujours dernière). `kind`, instant, utilité et identité sont **conservés** — `.structural` reste vrai : c'est toujours une frontière structurelle, simplement plus majeure. Elle redevient un candidat de split **ordinaire**, soumis au plancher de chaque mode. Rétrogradation **sur place** (aucun `remove`), donc le tri par center croissant et les indices déjà parcourus restent valides. Une ancre **protégée** n'est jamais rétrogradée.

> **Ce que cette passe répare.** L'ancienne passe **retirait** la perdante (`merged.remove(at:)`), imposant ainsi le plancher du mode le plus **lent** à un champ d'ancres **partagé par les trois modes**. Scénario : coupure à 60,0 s (bord de section, rang 0) et retour du kick à 60,4 s (frontière de phrase, rang 1) → écart 0,4 s < 0,75 s → la phrase disparaissait, et **aucun** des trois modes ne pouvait couper sur le retour du kick, alors que 0,4 s est une case parfaitement légitime en Percutant (plancher 0,25 s) comme en Équilibré (0,40 s). `DeterministicEditScoreGenerator` portait déjà un jeu `demotedMajorIDs` implémentant exactement cette sémantique, rendu inatteignable par la suppression amont ; sa branche reste documentée « normalement inatteignable » et conservée en garde-fou. Couvert par `EditScoreGeneratorTests.testCloseMajorBoundariesDemoteTheWeakerMajor` (ex-`…MergeIntoSingleMajorAnchor`).

**Invariant préservé** (celui qu'exige `buildRoot`) : deux majeures **consécutives** sont toujours espacées d'au moins 45 000 ticks — une rétrogradée n'étant plus majeure, elle ne compte plus dans la suite. Démonstration par récurrence sur `lastMajorIndex` : écart suffisant → invariant direct ; la nouvelle perd → suite inchangée ; la précédente P perd → la majeure conservée avant P était à ≥ 45 000 ticks de P, donc à davantage encore de la nouvelle (centres croissants) : l'écart ne peut que croître.

Les **ancres majeures** = celles de `hierarchyRank <= 1` **non rétrogradées** (début, fin, bords de sections = rang 0 ; bords de phrases = rang 1).

### 4.6 Gestes (§27) — refondu par `5f00cc2`

Seuils : `anchorMatchTicks = 3 600` (60 ms) · `burstRiseMean = 0.35` · `holdStabilityMean = 0.45` · `burstMaximumPreAnchors = 3`.

**Géométrie en MESURES et non plus en temps.** `detect` reçoit désormais la `ScoreConfiguration` et calcule une `HoldGeometry` à partir des `BarEvent` (§20) :

```
barTicks = MÉDIANE des durées de mesure strictement positives
           (médiane, pas moyenne : la dernière mesure est tronquée à la durée réelle)
si aucune mesure, ou si barTicks < beatTicks  →  repli en TEMPS (§63)
```

| Champ | `barBased(barTicks)` — cas nominal | `timeBased(beatTicks)` — repli §63 |
|---|---|---|
| `sustainProbeSpan` | `barTicks` | `2 × beatTicks` |
| `exitWindowStart` | `3 × barTicks / 4` | `beatTicks` |
| `exitWindowEnd` | `5 × barTicks / 4` | `9 × beatTicks / 4` |
| `breathingSpan` | `barTicks` | `2 × beatTicks` |

Le repli reprend **exactement** les valeurs historiques : sonde de stabilité sur 2 beats, sortie dans `[impact + 1 beat ; impact + 2,25 beats]`, respiration de 2 beats. À 150 BPM en 4/4 (mesure = 1,6 s), le cas nominal donne une sortie dans [1,2 s ; 2,0 s], une respiration de 1,6 s, une zone protégée totale d'environ **3,2 s** — contre 1,2 à 1,7 s auparavant, soit une « respiration » de la longueur d'une ou deux cases percutantes ordinaires, donc imperceptible.

Pour chaque impact (par temps croissant), appariement à une ancre à ±60 ms — sinon l'impact est ignoré. Trois branches **exclusives** :

1. **`burstResolution`** — conditionné à `hasGenuineRise`, qui **reprend le `.buildUp` détecté** au lieu d'en refaire une version plus faible :
   ```
   si ∃ event  type == .buildUp  &&  geometry == .interval  &&  event.end.ticks == impact.start.ticks
      →  true
   sinon  repli historique : moyenne de tension OU de nouveauté ≥ 0,35 sur 8 échantillons
          au demi-beat avant l'impact, avec ≥ 4 échantillons valides
   ```
   La comparaison porte sur le tick de l'**événement** `.impact` et non sur le centre de l'ancre : les deux peuvent différer de `anchorMatchTicks`, et c'est bien sur l'événement que `CurvesAndEventsBuilder` fait finir son `.buildUp`, au tick exact. Le repli est laissé **à l'identique** : l'élargir à la fenêtre en mesures diluerait la moyenne sur la partie calme précédant la montée et rendrait le critère **plus** strict. Le raccourci est donc strictement **additif** — il ne peut que qualifier davantage de montées, jamais moins. C'était le trou laissé entre les deux chantiers : le `.buildUp` était émis mais `burstResolution` ne le voyait pas, car il refaisait sa mesure sur 4 temps seulement.

   **Pré-ancres — sélection par ÉCARTS DÉCROISSANTS** (et non plus « les 3 plus proches ») : centre dans `[impact − 2,5 beats, impact)`, strictement > 0, **non majeures**, non déjà groupées, triées par center croissant. On remonte le temps depuis l'impact :
   ```
   requiredGap = max(minimumGapTicks, previousGap ?? minimumGapTicks)
   candidat    = la PLUS TARDIVE des ancres telle que referenceTick − center ≥ requiredGap
   ```
   avec `minimumGapTicks = max(configuration.mostPermissiveSlotFloor.ticks, 1)` = **15 000 ticks (0,25 s)** en production. Deux exigences : (a) **réalisable quelque part** — chaque écart interne, et l'écart final vers l'impact, est ≥ au plancher du mode le plus permissif ; (b) **écarts non croissants vers l'impact** — en remontant le temps, chaque écart retenu est ≥ au précédent, donc la rafale est au pire régulière, jamais **ralentissante**. L'égalité est acceptée : une rafale de croches régulières est un burst valide, et exiger la stricte décroissance éliminerait le cas le plus fréquent en EDM. Le choix de la plus **tardive** est déterministe (les centres sont uniques après déduplication) et optimal pour la longueur du groupe (il minimise l'écart courant, donc relâche au maximum la contrainte suivante). Résultat remis en ordre chronologique.
   > L'ancienne règle « les 3 ancres les plus proches de l'impact » produisait le geste le plus **serré** possible : plus le burst était un vrai burst, plus ses écarts internes tombaient sous le plancher §28.2, donc `.infeasible` dans les **trois** modes — un geste détecté, jamais réalisable, qui en plus retirait ses ancres du pool individuel.

   Créé **seulement si ≥ 2 pré-ancres**. L'ancre d'impact rejoint le groupe uniquement si elle n'est **pas** majeure.
2. **`impactHold`** — conditionné à `hasSustain` : moyenne de stabilité ≥ 0,45 sur **4 sondes régulières** de pas `sustainProbeSpan / 4` après l'impact, **ou** un état `.sustain` démarrant dans `[impact − sustainProbeSpan/8, impact + sustainProbeSpan]` (tolérance amont d'un huitième de portée : l'état est daté au span, l'impact à la frame). Ancre de sortie : centre dans `[impact + exitWindowStart, impact + exitWindowEnd]`, utilité maximale (égalité → la plus précoce).
3. **`breathing`** — émise immédiatement après chaque `impactHold` : `start` = centre de l'ancre de sortie, `end = min(sortie + breathingSpan, durée)` — soit **une mesure**, repli 2 beats —, **`anchorIDs` vide**. Rattachée à son parent par `breathing.start == impactHold.end`.
4. **`simpleAccent`** — impact isolé : `start == end` = centre de l'impact.

Ces gestes alimentent la découpe de deux façons : les `impactHold` et `breathing` définissent les **zones sans coupe** (intérieur **strict** seulement — les bords d'un maintien restent coupables), et chaque geste à ancres devient un **candidat de split groupé** (toutes ses ancres ou aucune) — sauf s'il est écarté par les gardes du §4.8.

### 4.7 Partition racine (§28.3.1)

`boundaries` initialisées à exactement deux éléments : `[tick 0, tick durée]`. Puis les majeures **intérieures** sont triées par (rang croissant, `finalUtility` décroissante, center croissant) et insérées une à une **si et seulement si** `tick − précédente ≥ 45 000` **et** `suivante − tick ≥ 45 000` — le plancher **fluide**, le plus grand des trois.

**La racine est donc identique aux trois modes.** Sinon : `assertionFailure` en debug + rétrogradation en candidat ordinaire (branche documentée comme inatteignable grâce à la fusion amont des majeures).

### 4.8 Le raffinement glouton — cœur de la découpe

**Construction du pool de candidats** (`makeCandidates`), revue par `5f00cc2` — l'**ordre des gardes** a changé et un repli a été ajouté :

1. Un geste dont **une** ancre tombe dans l'intérieur strict d'une zone sans coupe d'un **autre** geste n'est pas enregistré.
2. **Repli §70/§28.2 — groupe définitivement infaisable** : un groupe que la seule **géométrie** interdit dans les trois modes n'est pas enregistré du tout, et ses ancres **redeviennent des candidats individuels** au lieu de disparaître du montage. Deux causes, toutes deux mode-indépendantes (c'est ce qui rend le repli sûr vis-à-vis de §70 : le verdict est identique pour les trois modes, aucun candidat n'apparaît en cours de séquence) :
   - deux membres consécutifs séparés de moins de `mostPermissiveSlotFloor` = **15 000 ticks** ;
   - un membre qui n'est pas déjà frontière **racine** et se trouve à moins de ce plancher d'une frontière racine (les racines sont communes aux trois modes et ne disparaissent jamais).
   `mostPermissiveSlotFloor` est calculé comme le **minimum réel** sur `PaceMode.allCases`, et non en présumant que Percutant est le plus petit — l'`assert` de monotonie disparaît en Release.
   Un groupe refusé pour **violation de respiration** (§27) n'est en revanche **pas** concerné : il reste un candidat de groupe atomique et ses ancres restent hors du pool individuel (invariant testé par `testBurstRefusedWhenActiveBoundaryOccupiesBreathingZone`).
3. `groupMemberIDs.formUnion` s'exécute **après** toutes les gardes, jamais avant. Auparavant, un geste dont un seul membre tombait dans l'intérieur strict d'un autre geste retirait **tous** ses membres du pool individuel alors que le candidat de groupe n'était même pas créé : les ancres disparaissaient du montage sans qu'aucune règle ne l'ait décidé.

Boucle `while true` : `try Task.checkCancellation()` en tête de **chaque** tour (seul point non borné du générateur ; le tour est atomique, l'annulation ne laisse jamais une activation à moitié appliquée), puis **tous** les candidats restants sont réévalués contre l'état courant des frontières (équivalent d'une file de priorité re-triée, §28.4).

`evaluate` — contraintes puis gain :

1. Ancres du candidat pas déjà frontières ; vide → `.fullyActive` (élagué)
2. Bornes : `0 < tick < durée`, sinon `.infeasible`
3. **Respiration après burst déjà actif** : une coupe est refusée si elle tombe dans `(burstEnd, burstEnd + 2 × plancherDuMode)`
4. **Respiration du burst candidat** (règle symétrique) : activer un burst exige que `(burstEnd, burstEnd + 2 × plancher)` soit déjà libre de toute frontière active — la fin absolue du morceau comptant comme frontière active
5. **Plancher §28.2** : sur la liste fusionnée triée, chaque tick inséré doit avoir un voisin gauche à ≥ plancher **et** un voisin droit à ≥ plancher. *(Aucune contrainte de durée maximale n'existe.)*
6. **Gain** :
   ```
   gain = Σ_intervallesTouchés [ coût(intervalleOriginal) − Σ coût(sous-intervalles) ]
        + Σ_ancresInsérées    [ finalUtility − overcut − addedCutCost ]

   coût(d)  = ( (d_secondes − cible_secondes) / cible_secondes )²
   overcut  = overcutPenalty × max(0, densitéLocale − 2) × 0.1
              densitéLocale = nb de frontières ACTIVES à |Δ| ≤ 90 000 ticks du tick inséré
   ```
   `addedCutCost = 0.5` est retiré **une fois par ancre** : un groupe de 4 ancres paie 2,0.

Un candidat n'est retenu que si `gain ≥ seuil du mode`. Départage déterministe : gain strictement supérieur, sinon à gain égal le candidat dont la première ancre a le center le plus **petit**, sinon le groupe le plus **grand**.

Activation : **toutes** les ancres du candidat gagnant sont insérées. Si c'est un burst, sa fin est mémorisée dans `activatedBurstEnds`.

### 4.9 Ce qui différencie les trois partitions

Les trois partitions sortent d'**une seule séquence d'activations**, traversée dans l'ordre `fluid → balanced → percussive`. Les tableaux `boundaries`, `candidates` et `activatedBurstEnds` sont des `inout` **partagés** : Équilibré **continue** là où Fluide s'est arrêté, Percutant continue celle d'Équilibré.

> **L'imbrication Fluide ⊆ Équilibré ⊆ Percutant (§70) est garantie par construction, sans passe de vérification.**

Seuls **trois** paramètres changent d'un mode à l'autre :

| Mode | Plancher (durée MIN de case) | Cible du coût quadratique | Seuil de gain |
|---|---|---|---|
| **Fluide** | 45 000 ticks = **0,75 s** | **2,5 s** | **0.30** |
| **Équilibré** | 24 000 ticks = **0,40 s** | **1,2 s** | **0.12** |
| **Percutant** | 15 000 ticks = **0,25 s** | **0,6 s** | **0.05** |

Effets combinés : le plancher qui se relâche rend faisables des splits refusés à l'étape précédente ; la cible qui raccourcit rend le coût quadratique favorable à des cases plus courtes ; le seuil qui baisse laisse passer des raffinements de gain marginal plus faible. Le plancher intervient aussi dans la zone de respiration des bursts (`2 × plancher`), qui rétrécit à chaque mode.

### 4.10 Finalisation et fabrication d'une case (§13.2)

`finalizeScore` travaille sur une **copie** des frontières — ses retraits n'affectent pas la séquence partagée.

1. **Résidu final §28.2** : tant que `count ≥ 3` et `durée − avant-dernière frontière < plancher`, on **retire** l'avant-dernière frontière. Si c'est une majeure, on s'arrête. La fin absolue reste toujours la dernière frontière ; un morceau plus court que le plancher garde sa case unique (§63).
2. **Gestes du mode** : conservé seulement si **toutes** ses ancres sont des frontières actives du mode. Une `breathing` est conservée seulement si son `impactHold` parent l'est.
3. **Cases** : une par paire de frontières **consécutives**.
   ```swift
   EditSlotDefinition(
       id: UUID(), index: i,
       start: MediaTime(ticks: entry.ticks),
       end:   MediaTime(ticks: exit.ticks),
       entryAnchorID: entry.anchorID,
       exitAnchorID:  exit.anchorID,
       gestureID: /* 1er geste du mode contenant ENTIÈREMENT la case, sinon nil */
   )
   ```
   `duration = end − start` est **toujours calculée**, jamais persistée (§13.2).
4. **Statistiques** : `averageDuration = MediaTime.roundedDivision(total, dividedBy: count)` (arrondi ,5 au supérieur) ; `minimumDuration`/`maximumDuration` = min/max, 0 si vide.

Par construction, les cases sont contiguës (`end[i] == start[i+1]`), triées, sans trou ni intersection, de durée strictement positive.

### 4.11 Persistance — les cases finales

`ProjectStore.selectPace(_:from:projectID:)` : garde `hasAssignments` → `paceLockedByAssignments` (§65), puis **transaction unique** — suppression de toutes les cases existantes, `insertSlotRecords`, `selectedPaceRaw`, `activeSlotIndex = 0`, `statusRaw = "assembling"`, une seule `touchAndSave` ; tout échec → `modelContext.rollback()`.

`insertSlotRecords` valide §10.1 en Swift pur : `end.ticks > start.ticks` sinon `invalidSlotDuration` ; index strictement croissant sinon `nonIncreasingSlotIndex` ; clé `(scoreModeRaw, index)` unique via un `Set` sinon `duplicateSlotKey`.

**Seules les cases du mode choisi sont persistées** ; les trois partitions restent dans `analysis/scores-v1.json`.

### 4.12 Péremption (§61) — découplée par `5f00cc2`

`ScoreLibrary.scoresAreCurrent` rend vrai **SSI** :
`meta.generatorVersion == 2` **ET** `meta.analysisVersion == DeterministicMusicAnalyzer.analysisSchemaVersion` **ET** `meta.configurationFingerprint == SHA-256(ScoreConfiguration.production)`.

**La version de MOTEUR d'analyse ne tranche plus ici, et c'est délibéré.** Elle le faisait (`meta.analysisVersion == engineVersion`), et le prix était disproportionné : la moindre correction de bug du moteur périmait d'un coup les partitions de tous les projets de tous les utilisateurs, en même temps que le cache d'analyse. Ce qu'une partition consomme est un `MusicAnalysisResult` ; ce qui doit la périmer est un changement de **forme** de ce résultat (schéma), du générateur, ou de sa configuration. Un moteur qui évolue produit un résultat différent, que le cache §69 invalide de son côté — la régénération des partitions suit alors celle de l'analyse, sans que cette règle-ci ait à l'imposer à des projets terminés (§61).

Le nom du champ reste `analysisVersion` : c'est celui déjà écrit dans tous les `scores-meta-v1.json` existants, et le renommer les rendrait illisibles donc périmés sans aucune raison de fond.

Deux champs **tracés mais non discriminants**, tous deux décodés par `decodeIfPresent` (une méta écrite avant leur ajout reste valide et ne provoque **aucune** régénération) :
- `analysisEngineVersion: Int?` — la version d'algorithme qui a produit l'analyse source, §61 « conserver la version du moteur d'analyse ». Répond à « quel moteur a produit ce montage ? » (explicabilité §29) sans périmer les projets ;
- `coreMLModelVersion: String?`.

Les trois champs historiques (`generatorVersion`, `configurationFingerprint`, `analysisVersion`) restent **obligatoires** : une méta amputée est illisible, donc périmée.

`generatorVersion` 1 → **2** est justifiée dans le code par un changement de la **logique de sélection** à `ScoreConfiguration` constante : pool de candidats (le `formUnion` d'un groupe rejeté ne retire plus ses membres du pool individuel ; un groupe géométriquement infaisable dans les trois modes se replie sur ses ancres) et gestes §27 exprimés en mesures. Sans cet incrément, tous les projets existants garderaient des partitions produites par l'ancienne logique.

> **Architecture à deux caches — exigence §69 désormais réellement tenue.** `AnalysisCache` est clé sur (empreinte audio, `engineVersion`, `analysisSchemaVersion`, empreinte `AnalysisConfiguration`) ; `ScoreLibrary` sur (`generatorVersion`, empreinte `ScoreConfiguration`, `analysisSchemaVersion`). Changer un poids §26.3 périme les partitions **sans** périmer l'analyse : `recalculateScores` relance `analyze()` qui rend le cache immédiatement, puis régénère les partitions — **aucun redécodage PCM**. Et depuis le découplage, un incrément de moteur ne périme plus aucune partition.

---

## 5. Interface (Jalon 6)

### 5.1 Progression d'analyse (§33)

Les **5 phases** et leurs libellés :

| # | Cas | Libellé | Publiée par |
|---|---|---|---|
| 1 | `audioPreparation` | « Préparation audio » | analyseur |
| 2 | `pulseAndTempo` | « Pulsation et tempo » | analyseur |
| 3 | `phrasesAndStructure` | « Phrases et structure » | analyseur |
| 4 | `buildUpsAndImpacts` | « Montées et impacts » | analyseur |
| 5 | `rhythmCreation` | « Création des rythmes » | **`AudioAnalysisActor`** |

Écran : forme d'onde 200 bins (96 pt de haut, toucher = lecture/pause), durée au centième, puis un `ProgressView()` **indéterminé** (jamais de pourcentage, §33), le libellé de la phase, et « **Phase x sur 5** ». VoiceOver : « Analyse en cours : <phase>, phase x sur 5 ».

Pilotage : `.task(id: status)` → `startAnalysisIfNeeded` (idempotent) puis **polling toutes les 300 ms**. `.onDisappear` → `cancelAnalysis` : l'analyse est annulée à la sortie, le checkpoint est conservé, la reprise est automatique (§8.1).

Échec : « L'analyse de la musique a échoué. Réessayez : les étapes déjà terminées sont conservées. » + bouton **Réessayer**.

### 5.2 Choix du rythme (§34)

Libellés : `fluid` → **Fluide**, `balanced` → **Équilibré**, `percussive` → **Percutant**. Défaut : **Équilibré** (position centrale).

Trois états :
- **`.loading`** — chargement **hors MainActor** via `Task.detached` : `scoresAreCurrent` d'abord, puis `loadScores`
- **`.needsRecalculation`** (§61) — « Les rythmes doivent être recalculés », dock `[Projets] [Recalculer]`. Le recalcul est **explicite, jamais silencieux**. Des partitions lisibles mais périmées sont traitées comme absentes.
- **`.ready`** — les **trois** rythmes présentés d'un coup d'œil, une carte par mode

Carte : coche si sélectionné + nom + « N plans » en `monospacedDigit` ; `MiniTimelineView` (28 pt) ; « moy X · min Y · max Z » au format « 1,20 s ». La sélection n'est **jamais** marquée par la seule couleur (§39) — coche + bordure `lineWidth: 2`.

`MiniTimelineView` : `Canvas` pur, un rectangle par case, positions dérivées des **ticks cumulés** (jamais d'accumulation de largeurs flottantes), séparateur de 1 pt sauf après le dernier.

Dock §36 : `[Projets] [Sélecteur 3 segments] [Utiliser ce rythme]`. CTA en `ViewThatFits` (« Utiliser ce rythme » / « Valider »). Segments à `minWidth: 44, minHeight: 52`. **Aux tailles d'accessibilité, le sélecteur passe sur sa propre ligne, au-dessus de `[Projets] [Valider]`** — la validation reste le contrôle le plus proche du pouce (§30/§81).

Validation : garde anti double-appui, puis `selectPace`. Si `paceLockedByAssignments` → alerte « Rythme verrouillé » / « Ce rythme est verrouillé par des vidéos déjà associées. Dupliquez le projet pour changer de rythme. » avec `[Dupliquer] [Annuler]` — §65, jamais de mutation destructive.

---

## 6. Tests du bloc — 124 fonctions de test

Comptage réel au worktree : `grep -c "func test"` sur les 15 fichiers ci-dessous, **124** au total (99 avant `5f00cc2`). Les fichiers de tests du projet **hors** bloc analyse/découpe (assemblage, export, preview, PhotoKit…) ne sont pas comptés ici.

| Fichier | Tests | Couverture |
|---|---|---|
| `SpectralFeatureExtractorTests` | 2 | Centroïde 440 Hz ±80 Hz, RMS stable < 5 %, silence ≤ 1e-4 |
| `OnsetDetectorTests` | 5 | Click 120 BPM → 14…18 onsets, chaque clic à ±35 ms ; silence → 0 ; impact isolé → exactement 1 à ±50 ms ; **`testDenseRollIsNotCollapsedByOnsetMerging`** et **`testDenseClickTrackKeepsOnsetsSpreadOverTheWholeRoll`** (fusion par cluster) |
| `TempoEstimatorTests` | 13 | Le vrai tempo est retenu à **150 / 165 / 174 / 180 / 200 BPM**, plus **150 / 174 / 180 avec couche de contretemps** (8 tests d'octave/alias) ; 120 BPM dans le top 2 ; Σ probabilités = 1 ; relations half/double croisées ; enveloppe plate/vide → **aucune** hypothèse ; déterminisme |
| `BeatTrackerTests` | 5 | Période médiane 0,5 s ±5 %, confiance > 0,6 ; accélération 100→140 ; mesure 4 et mesure 3, downbeats à ≤ 40 ms ; **`testUniformAccentProfileYieldsLowDownbeatConfidence`** (la confiance de barre ne s'effondre plus avec `downbeatConfidence`) |
| `AnalysisPipelineTests` | 7 | 128 BPM ±4 **strict** ; ≥ 80 % des intervalles à ±10 % ; déterminisme inter-projets à 1e-9 ; cache → JSON identique octet à octet + **aucune** progression ; annulation → checkpoint, reprise **prouvée par payload sentinelle** ; silence+impact → impact sans buildUp inventé ; **`testResultCarriesSchemaVersionWhileCacheKeysOnEngineVersion`** et **`testStartAfterCancellationReturnsImmediatelyAndRelaunchesOnce`** |
| `BuildupPipelineTests` | 4 | buildUp → impact à ±300 ms, `.interval` avec `end.ticks == impact.start.ticks` **exact**, relation `.prepares` ; **`testRiserThenSilenceGapThenImpactStillProducesBuildUpAndPrepares`** (fixture « montée + gap + impact ») ; impact isolé → aucun buildUp ; click accéléré |
| `HybridAnalyzerFallbackTests` | 3 | Registre → `nil` partout ; hybride ≡ déterministe **champ par champ** ; modèle injecté → jamais appelé |
| `EditScoreGeneratorTests` | 16 | Bloc §70 « Partitions » : structure, imbrication, majeures communes, planchers, burst en groupe atomique, respiration, **`testCloseMajorBoundariesDemoteTheWeakerMajor`** (rétrogradation, ex-« fusion »), modes distincts, **`testEveryBoundaryFallsOnTheBeatGrid`**, **`testCutDensityFollowsUtilityNotClock`**, résidu final, morceau de 3 s, ambiant sans beats, morceau vide → throw, déterminisme, statistiques |
| `ScoreGenerationPipelineTests` | 4 | Analyse → partitions bout-en-bout ; 5 phases ; silence+impact sans crash ; aller-retour JSON sans arrondi |
| `ScoreConfigurationWeightsTests` | 11 | **Un test par poids §26.3** (9) : chacun à 0 puis à 2, l'utilité de l'ancre ciblée varie dans le bon sens, et un poids non concerné la laisse **strictement** identique ; + **`testColocatedDownbeatIsNeverWeakerThanTheBeatItReplaces`** et **`testColocatedSectionBoundaryKeepsTheBeatRhythmicComponent`** (fusion des co-localisés) |
| `PaceSelectionStoreTests` | 15 | `selectPace`, revert, verrou par association, péremption (méta absente / `generatorVersion` / empreinte config / **`analysisSchemaVersion`**), `analysisEngineVersion` **tracée et non discriminante**, méta ancienne sans ce champ toujours lisible, `coreMLModelVersion` ignoré, JSON corrompu → `nil`, duplication |
| `AudioImporterTests` | 8 | §62 : extension refusée, fichier vide, octets non décodables, copie atomique / interrompue, réimport, attachement |
| `WaveformExtractorTests` | 3 | 200 bins, normalisation, silence |
| `ProjectStoreTests` | 12 | §10.1 : unicité (mode, index), index croissant, durée positive, cascade ; + **`testStartupMaintenanceNeverPurgesWhenDatabaseIsEmptyButDirectoriesExist`** et **`testStartupMaintenanceStillPurgesOrphansWhenDatabaseIsNotEmpty`** |
| `MediaTimeTests` | 16 | §70 « Temps » : ticks ↔ CMTime, affichage au centième, **non-dérive sur 1 000 cases** |

`TestAudioFactory` : WAV PCM 16 bits mono, en-têtes RIFF écrits à la main, bruit blanc par **LCG 64 bits seedé** (constantes de Knuth), jamais de `random` système. Burst de 10 ms. Convention de phase : le clic *k* tombe à `(k + 0,5) × 60/bpm` — jamais à t = 0.

---

## 7. Écarts spec ↔ code

### 7.1 Écarts assumés et documentés (niveau A)

| § | Écart |
|---|---|
| **§16.3** | **Une seule branche FFT sur trois** est calculée. `mediumBranch` et `longBranch` ne servent qu'à l'empreinte de configuration. Aucune analyse multirésolution réelle. |
| **§17** | 5 séries de features sur 14 familles. Absents : crête/facteur de crête, rolloff, flatness, ZCR, contraste spectral, HPSS, **chroma**, courbes multi-horizons. |
| **§20** | Mesures candidates **2/3/4** seulement (5/6/7 non implémentées, non testées). `meterDenominator` **codé en dur à 4**. |
| **§21** | ~~La variance par span n'est pas conservée~~ — **résorbé par `5f00cc2`** : la 3ᵉ statistique est désormais la **variance de population** (`BeatSyncFeatures.swift:253, 409`), la pente a disparu (§3.7). Reste ouvert : vecteurs **par beat uniquement**, jamais « par beat ET par mesure ». |
| **§22.1** | Similarité sur énergie/flux **sans timbre ni harmonie** → les répétitions harmoniques sont indistinguables. |
| **§22.2** | Le caractère « brusque ou progressif » d'une frontière n'est pas produit (`StructuralBoundary` n'a pas de champ d'abruptness). |
| **§22.3** | L'arbre s'arrête aux beats — **`microEvent` jamais instancié**. `repetitionGroupID` toujours `nil`. |
| **§23** | `TimedValue` ne porte que (time, value) : pente, accélération, durée de tendance, distance au max, confiance non persistées. **`vocalPresence` constante à 0.** |
| **§24** | **4 fonctions sur 11 jamais produites** : `anticipation`, `suspension`, `contrast`, `conclusion`. Décodage semi-markovien remplacé par un lissage à 2 spans. Confiance plafonnée à 0,4/0,5. |
| **§25 / §12.5** | **2 relations sur 8** : seules `contains` et `prepares`. La règle « une montée sans impact = relâchement ou fausse résolution » n'est pas implémentée — sans impact, aucun buildUp n'est simplement créé. |
| **§12.4** | 6 types d'événements sur 14 jamais instanciés : `fill`, `breakdown`, `vocalPhrase`, `release`, `suspension`, `unknown`. |
| **§13.1** | `AnchorKind.grouped` n'est **jamais assigné**. L'appartenance à un groupe passe uniquement par les `anchorIDs` d'un `EditGesture`. |
| **§26.1** | Deux sources d'attraction sans candidat : « entrée/retrait d'instrument » et « fin de fill ». |
| **§26.2** | Deux inhibitions absentes : « motif incomplet » et « phrase vocale en cours » (cette dernière est impossible : `vocalPresence = 0`). Deux autres déplacées à la sélection. |
| **§26.3** | `finalUtility` persisté **exclut** `overcutPenalty`. |
| **§27** | **4 gestes sur 8 jamais émis** : `acceleration`, `motifEcho`, `variation`, `reset`. |
| **§28.2 pt 1** | **Non implémenté** : la spec demande d'abord de *déplacer* la dernière frontière non majeure dans sa fenêtre tolérée, puis seulement de fusionner. Le code ne fait que la fusion. **Conséquence : `optimalStart/optimalEnd/toleratedStart/toleratedEnd` sont calculées et persistées mais lues NULLE PART.** |
| **§28.3 pt 6** | Pas de passe globale post-sélection ; repliée dans `overcutPenalty`, seuils de gain et respiration. |
| **§28.3 pt 7** | Aucune vérification runtime de l'imbrication — garantie par construction, seul filet un `assert` inactif en Release. |
| **§11** | `features-v1.bin` n'existe pas : les features vivent dans le checkpoint, supprimé au succès. |
| **§34** | Rendu en **plein écran routé par statut** au lieu d'une « feuille inférieure ». |
| **§37/§81** | `.ultraThinMaterial` au lieu du Liquid Glass natif iOS 26 — **toujours ouvert**, non résorbable sans compiler sur Mac. |
| **§29A / §86** | **Jalon 11 non terminé délibérément** : aucun modèle Core ML, `beatActivationModel()` et `beatActivationModelVersion()` renvoient `nil` en dur, `isHybridPathImplemented = false`, `HybridMusicAnalyzer` non câblé. Conforme à l'interdiction §29A de simuler un modèle. |

### 7.2 Écarts non signalés jusqu'ici

| § | Écart |
|---|---|
| **§16.3** | *« Les valeurs exactes doivent être configurables dans `AnalysisConfiguration`, pas dispersées dans le code. »* — **Violation frontale.** `AnalysisConfiguration` ne porte que 5 champs. `OnsetDetector`, `TempoEstimator`, `BeatTracker`, `BeatSyncFeatures` et `CurvesAndEventsBuilder` ne contiennent **aucune** occurrence de `configuration` : ~40 constantes décisives vivent dans des `private enum` non configurables. |
| **§15** | `waveform` est la **1ʳᵉ des 10 sorties** du moteur niveau A. Or `MusicAnalysisResult` n'en contient aucune : elle est produite hors moteur et **recalculée par un décodage complet à chaque affichage, sans cache** — ce qui contredit aussi §69 et §68. |
| **§16.2** | La « normalisation d'analyse non destructive » sur le flux PCM **n'est pas implémentée** : la seule normalisation existante est celle des features par quantile 0,95, en aval. |
| **§28.1 c.9** | *« Ne pas utiliser toutes les micro-ancres avant un climax »* — aucun mécanisme de réserve ni de look-ahead. Le seul terme prospectif (`expectedFutureValue`) pousse **au contraire** à couper avant un impact. |
| **§28.4** | Tension de fond : `coût(d) = ((d − cible)/cible)²` avec une cible **fixe** par mode est mathématiquement une pression d'**uniformisation** des durées. L'exemple de la spec (« le mode Percutant peut rester lent pendant une introduction et très dense sur un fill ») est combattu par la fonction de coût elle-même. |
| **Annexe A** | Le pseudocode canonique prescrit `projectStore.save(progress, …)` : la progression est **persistée**. Le code la garde en mémoire dans l'acteur. Après relance, l'écran repart de « Phase 1 sur 5 » alors que le checkpoint reprend en phase 2 — **l'affichage ment temporairement**. |
| **§61** | *« Conserver l'analyse précédente jusqu'au succès de la nouvelle »* — `AnalysisCache.save` écrase `analysis-v1.json` en place. Empreinte audio et empreinte de config ne vivent que dans les fichiers méta, pas dans `ProjectRecord`. |
| **§10.1** | L'unicité `(projectID, scoreModeRaw, index)` et la cascade sont **applicatives**, pas déclaratives : aucun `@Attribute(.unique)` ni relation SwiftData dans tout le projet. Une écriture passant à côté du helper violerait le schéma sans erreur. |
| **§72** | Corpus de référence : **4 familles sur 9** existent en audio réel. 3/4, half/double-time et ambiant sont testés sur des structures fabriquées à la main qui ne traversent **jamais** `PCMDecoder`. Absents : **6/8** et **morceau sans percussion**. Aucun manifeste d'attentes/tolérances. |
| — | `ProjectStore.saveScores(relativePath:…)` **n'utilise pas** son paramètre `relativePath` : paramètre mort dans une signature publique. |
| — | Deux implémentations divergentes du même quantile 0,95 : `SpectralFeatureExtractor` **arrondit** l'index, `BeatSyncFeatures` **tronque** — les deux commentaires se réclament pourtant de l'alignement mutuel. |
| — | ~~`MusicAnalysisResult.version` porte l'`engineVersion`~~ — **résorbé par `5f00cc2`** : le champ porte désormais `analysisSchemaVersion` (`DeterministicMusicAnalyzer.swift:374, 498`), et le cache compare `result.version == schemaVersion` (`AnalysisCache.swift:129`). Reste vrai pour les résultats **déjà sur disque**, qui portent 1 ou 2 (d'anciennes versions de moteur) et sont donc ignorés une dernière fois. |
| — | `AnchorField` : un événement `.release` reçoit la raison **« Résolution après impact » sans aucune vérification qu'un impact précède**, alors que la branche équivalente sur les états fonctionnels l'exige. Un release isolé affiche une raison fausse à l'utilisateur (§29). |
| — | ~~Fenêtre de fusion d'onsets effective 23,2 ms au lieu de 30 ms~~ — **résorbé par `5f00cc2`** : la conversion se fait par **arrondi** (`OnsetDetector.swift:156`), soit **3 frames = 34,8 ms**, la valeur représentable la plus proche des 30 ms déclarés à 86,1328125 fps. L'écart résiduel (+16 %) est celui de la quantification en frames, non un bug. |
| — | La plage 50–220 BPM n'est pas atteignable en dessous d'environ **4 s** d'enveloppe (`lagMax` plafonné par `(frameCount−1)/2`). |
| — | Aucune **contrainte de durée maximale** de case, ni dans la spec ni dans le code. Une case peut être arbitrairement longue si aucun split ne dépasse le seuil de gain. |
| — | `refine` réévalue **tous** les candidats contre **toutes** les frontières après chaque activation : O(activations × candidats × frontières), « acceptable ≤ ~6 min de musique » — **jamais mesuré**. |
| — | `intervalCost` passe par des secondes en `Double` : seul point où un flottant influence une décision de découpe, et la comparaison `gain == bestGain` est une égalité de flottants — le départage déterministe ne se déclenchera quasiment jamais en pratique. |

### 7.3 Trous de test

- La **5ᵉ phase** (`rhythmCreation`) n'est couverte par **aucun** test d'intégration réel. `AnalysisPipelineTests` vérifie au contraire qu'elle n'est **jamais** publiée par l'analyseur ; `ScoreGenerationPipelineTests` n'est qu'un garde-fou sur l'énumération. L'écran affiche pourtant « Phase x sur 5 ».
- **Aucun test ne couvre les vues** : ni `ProjectView` (polling 300 ms, `retryAnalysis`, annulation à `onDisappear`) ni `PaceSelectionView` (3 états, `loadScores`, `recalculateScores`, `validate`, alerte §65). Aucun XCUITest (§73).
- `MiniTimelineView` n'a aucun test unitaire, seulement une preview.
- **Aucun profilage §67/§68** : pic mémoire d'analyse et fluidité invérifiés.
- Le code est **écrit sous Windows et jamais ouvert dans Xcode en local** : la seule compilation est celle de la CI (`.github/workflows/build-ipa.yml`, `runs-on: macos-26`, job `build` → `xcodebuild` sans signature, job `tests` → `xcodebuild test` sur simulateur, `continue-on-error: true`). Le run **31894912740** est vert sur les deux jobs. Restent non faits : ouverture Xcode, exécution **sur appareil**, Instruments.
- **Localisation absente** : interface en français en dur, sans String Catalog (§87 non rempli, décision assumée : V1 monolingue).

### 7.4 État réel de `ml/`

Le dossier contient exactement **deux fichiers** : `ml/README.md` et `ml/model_cards/README.md`. Aucune des 8 entrées imposées par §29A (`pyproject.toml`, `configs/`, `datasets/`, `annotations/`, `training/`, `evaluation/`, `export_coreml/`) n'existe ; `model_cards/` ne contient aucune model card. Le README l'assume : *« Aucun code d'entraînement Python n'a été écrit (hors périmètre). »* C'est conforme à §29A — rien n'est simulé — mais ce n'est **pas** un pipeline d'entraînement livré.

---

## 8. Récapitulatif des constantes

### Analyse

| Paramètre | Valeur |
|---|---|
| Sample rate de travail | 22 050 Hz |
| FFT / hop (seule branche calculée) | 1 024 / 256 |
| Fenêtre | Hann dénormalisée |
| Cadence de frames | 86,1328125 fps |
| Bandes | 5 **linéaires** : 20 / 120 / 500 / 2 000 / 8 000 Hz → Nyquist 11 025 Hz |
| Plancher log | 1e-9 |
| Quantile de normalisation | 0,95 |
| Échelle temporelle canonique | 60 000 ticks/s |
| Pondérations de bande (onsets) | [1,25 · 1 · 1 · 1 · 0,75] |
| Fusion d'onsets | 30 ms déclarés → **3 frames = 34,8 ms effectifs** (arrondi), **par cluster** (écart mesuré au premier membre) |
| Seuil adaptatif *k* | 1,5 |
| Planchers d'onset | 5 % (bande) / 2 % (global) |
| Rayons | médiane 0,5 s · seuil 0,175 s |
| Plage BPM | 50–220 (tolérance ±2 % en sortie) |
| Pics d'ACF / hypothèses max | 8 / 6 |
| Doublon d'hypothèse | < 2 % |
| Tolérance half/double | 0,08 (soit \|ratio−2\| ≤ 0,16) |
| Score de tempo | **moyenne pondérée** `(1·acf(L) + 0,5·acf(2L)) / (1 + 0,5)`, poids du terme 2L compté **seulement s'il est disponible** |
| Terme sous-harmonique | **pénalité conditionnelle** et non bonus : `score /= (1 + subharmonicPenalty)` avec `subharmonicPenalty` = **1,0**, déclenchée si un pic existe à ±**0,05** de L/2 **et** vaut ≥ **0,9** de l'ACF du candidat |
| Filtre de relation entière | ancre = plus **court** pic à ≥ **0,5** du max d'ACF de la plage ; tolérance **0,04 relative à l'entier visé** ; appliqué si ≥ 2 pics, retenu si ≥ 2 survivants |
| Prior de tempo | log-normal, centre **120 BPM**, σ = **0,9 octave** |
| λ (DP beats) | 4,0 |
| Mesures candidates | {2, 3, 4}, dénominateur figé à 4 |
| Confiance d'un `BarEvent` | `clamp01(coherence + (1 − coherence) × downbeatConfidence)` — jamais < confiance du beat co-localisé |
| Grille de repli | 30 000 ticks (0,5 s), minimum 4 beats |
| Kernels de nouveauté | demi-largeurs **[2, 4, 8, 32]** = **4 / 8 / 16 / 64 temps** |
| Vecteur de similarité | **17-D** : 5 bandes × (moyenne, max, **variance de population**) + moyenne rms + moyenne flux |
| Garde de bord du damier | réponse nulle sous `max(halfWidth²/2, 1)` termes valides (convention de Foote) |
| Seuil de frontière | **absolu** `réponse brute du kernel dominant ≥ 0,8`, **puis** `max(0,3 ; moyenne locale ±8 spans × 1,2)` |
| `isSectionScope` | `dominantHalfWidth >= 32` (kernel de 64 temps uniquement) |
| Séparation minimale de section | **32 spans** |
| Confiance de frontière | ≤ 0,9 (jamais 1,0) |
| Plafond matrice de similarité | 2 000 spans |
| Impact | énergie ≥ 0,65 · montée ≥ 0,35 sur **8** spans (`impactFloorWindow`, volontairement découplée de la fenêtre de montée) |
| Silence | rms < 0,03 pendant > 0,8 s |
| BuildUp | tension ≥ 0,4 **et** énergie +0,15, mesurées sur `[windowStart, peakIndex]` |
| Fenêtre de montée §25 | `buildUpWindowBars` = **8 mesures**, plafond **64** spans, repli **8** spans, minimum **4** spans |
| `engineVersion` | **3** |
| `analysisSchemaVersion` | **1** (nouveau — c'est elle qui est écrite dans `result.version`) |
| `minimumOnsetsForTempo` | **4** |
| Garde morceau court | `rms.count < 8` |
| Empreinte | SHA-256 par blocs de 1 Mio |
| Format du checkpoint | **JSON à clés triées** ; `featureTimelineData` = plist binaire encapsulé en base64 |

### Découpe

| Paramètre | Valeur |
|---|---|
| 9 poids §26.3 | tous **1.0** |
| Fusion des **co-localisés** (passe 0) | `coLocationTicks` = **348 ticks (5,8 ms)**, composantes prises au **maximum** du groupe |
| Fusion de candidats (passe 1) | 3 600 ticks (60 ms) |
| Majeures rapprochées (passe 2) | < 45 000 ticks (0,75 s) → **rétrogradation** au rang `demotedHierarchyRank` = **4** (aucune suppression), raison « Rétrogradée : majeure trop proche » |
| Fenêtre d'anticipation | 90 000 ticks (1,5 s) |
| Maintien post-impact | 60 000 ticks (1 s), triangle culminant à 0,5 s |
| Recherche de résolution | 150 000 ticks (2,5 s) |
| Onset « fort » | salience ≥ 0,75 |
| Seuil `conditional` | confiance < 0,5 |
| Rangs hiérarchiques | 0 trackEdge/section · 1 phrase · 2 downbeat/impact · 3 beat/resolution · 4 strongOnset |
| Ancres **majeures** | rang ≤ 1 |
| `burstRiseMean` (repli de `hasGenuineRise`) | 0,35 |
| `holdStabilityMean` | 0,45 |
| Pré-ancres de burst | max **3**, minimum 2 requis ; fenêtre `[impact − 2,5 beats ; impact)` ; sélection par **écarts non croissants vers l'impact**, chacun ≥ `mostPermissiveSlotFloor` = **15 000 ticks (0,25 s)** |
| Géométrie maintien / respiration | **en mesures** : sonde = 1 mesure, sortie ∈ [3/4 ; 5/4] de mesure, respiration = 1 mesure ; repli §63 en temps : 2 beats, [1 ; 2,25] beats, 2 beats |
| `addedCutCost` | 0,5 **par ancre** |
| Fenêtre d'overcut | 90 000 ticks (1,5 s), au-delà de **2** frontières |
| `overcutDensityScale` | 0,1 |
| Planchers | 0,75 / 0,40 / 0,25 s |
| Cibles | 2,5 / 1,2 / 0,6 s |
| Seuils de gain | 0,30 / 0,12 / 0,05 |
| Respiration après burst | 2 × plancher du mode |
| `generatorVersion` | **2** |
| Validité §61 des partitions | (`generatorVersion`, empreinte `ScoreConfiguration`, **`analysisSchemaVersion`**) ; `analysisEngineVersion` et `coreMLModelVersion` **tracés, non discriminants** |

---

## 9. Statut des jalons

| Jalon | Statut |
|---|---|
| **4 — Moteur musical déterministe** | ✅ Terminé (CI verte, run 31392520681) — 🔄 **révisé par `5f00cc2`** (build-27, run 31894912740) : tempo, onsets, buildup, échelles structurelles, `engineVersion` 3 / `analysisSchemaVersion` 1 |
| **5 — Générateur de scores** | ✅ Terminé (CI verte, run 31398882782) — 🔄 **révisé par `5f00cc2`** : champ d'ancres non destructif, gestes en mesures, repli d'un groupe infaisable, génération annulable, `generatorVersion` 2 |
| **6 — Interface analyse / choix rythme** | ✅ Terminé (CI verte, run 31419878812) — 🔄 **révisé par `5f00cc2`** : la validité §61 des partitions dépend du **schéma** d'analyse, plus de la version de moteur |
| **11 — Moteur avancé Core ML** | ⛔ **Non terminé — délibérément** (§29A : aucun modèle entraîné, donc aucun modèle simulé) |

Ce qu'il faudra pour finir le Jalon 11, dans l'ordre §29A/§86 :
1. Choisir un modèle **dont la licence est validée**, corpus documenté, entraîner/distiller dans `ml/`
2. Évaluer sur le corpus de référence §72 (tolérances de placement beat/downbeat, non-régression des frontières de phrase)
3. Convertir en `.mlpackage`, vérifier les opérations Core ML supportées, comparer Float32/Float16/quantifié sur précision, taille, latence, mémoire, énergie, générer une **model card**
4. Embarquer une version **explicitement identifiée** (§61) en conservant le fallback
5. Mener la comparaison A/B §86 et n'activer le moteur avancé que si l'amélioration est **mesurable**

Tant que 1 à 5 ne sont pas faits, la V1 livrée est **niveau A** — ce que §15 prévoit explicitement.

---

## 10. Ce que la CI ne dira jamais sur ce bloc

Rendu visuel (matériaux §37, contrastes), retour haptique, fluidité et mémoire (§67/§68), et **§74 — validation humaine du moteur musical** :

> *« Les métriques techniques ne suffisent pas. »* Mesurer : marqueurs majeurs conservés par des monteurs · marqueurs supprimés · déplacement moyen · préférence entre les trois modes · cohérence perçue des accélérations · **faux drops** · **coupes excessives** · qualité de la respiration après impact. *« Favoriser la précision des grandes ancres plutôt que la quantité. »*

Aucune de ces 8 métriques n'a été relevée. C'est le vrai critère d'acceptation du bloc, et il reste entièrement ouvert.
