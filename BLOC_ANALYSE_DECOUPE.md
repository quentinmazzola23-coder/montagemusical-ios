# Bloc « Analyse musicale et découpe » — recueil complet

> Jalons **4** (moteur musical déterministe), **5** (générateur de partitions / découpe), **6** (interface analyse + choix du rythme) et **11** (moteur avancé Core ML, délibérément non terminé).
> Spécification de référence : `specification_application_montage_musical_ios.md` v1.0 (10 août 2026), sections §7 à §30, §33-§34, §61-§63, §68-§72, §74, §79-§81, §86, §29A, Annexe A.
> Document établi le 15 août 2026 par relecture intégrale des 26 fichiers Swift du bloc + 15 fichiers de tests + la spécification.

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
| `App/Services/MusicAnalysis/DeterministicMusicAnalyzer.swift` | Orchestrateur, `engineVersion = 2` |
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
                   ├─ AnalysisCache          empreinte SHA-256 + engineVersion + config → retour immédiat si à jour
                   ├─ PCMDecoder             mono Float32 22 050 Hz, par blocs
                   ├─ SpectralFeatureExtractor  STFT vDSP 1024/256 Hann → FeatureTimeline @ 86,1328125 fps
                   ├─ OnsetDetector          détendançage médian → peak picking adaptatif → fusion 30 ms
                   ├─ TempoEstimator         autocorrélation → renforcement harmonique → prior log-normal → phase
                   ├─ BeatTracker            DP type Ellis (λ=4) → beats ; mesure 2/3/4 → downbeats → bars
                   ├─ BeatSyncFeatureExtractor  spans → vecteurs 17-D → similarité cosinus → nouveauté damier
                   ├─ StructureBuilder       globalArc → section → phrase → bar → beat
                   └─ CurvesAndEventsBuilder 8 courbes, événements, relations, états fonctionnels
              ├─ AnalysisCache.save  +  ProjectStore.saveAnalysisResult
              ├─ phase 5 « Création des rythmes » publiée par l'ACTEUR
              └─ DeterministicEditScoreGenerator.generateScores        (hors acteur, Task.detached)
                   ├─ AnchorFieldBuilder     8 sources de candidats → évaluation §26.3 → déduplication 2 passes
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
4. Fusion des candidats distants de `max(1, Int(0.030 × frameRate))` = **2 frames**, soit **23,2 ms effectifs** (et non 30 ms), en gardant la frame d'enveloppe globale maximale
5. `OnsetEvent` : rejet si `valeur < 0.02 × max` ; `strength = valeur / maxEnveloppe` ; `dominantBand` = bande au flux détendancé maximal ; `confidence = clamp01(1 − moyenneLocale / valeur)`

### 3.5 Tempo (§19.1)

Constantes : `minBPM = 50` · `maxBPM = 220` · `maxHypotheses = 6` · `maxRawPeaks = 8` · `duplicateTolerance = 0.02` · `doubleTimeRatioTolerance = 0.08`.

1. Détendançage de l'enveloppe par soustraction de la moyenne mobile sur ≈ 1 s ; abandon si `énergie/frameCount ≤ 1e-12`
2. **Autocorrélation normalisée** (pas de tempogramme par banc de filtres) : `acf[lag] = (Σ x[i]·x[i+lag] / (N−lag)) / meanSquare`, `acf[0] = 1`. Calcul étendu jusqu'à `min(2×lagMaxIdeal+2, frameCount−1)` pour permettre le renforcement harmonique. ACF fractionnaire par interpolation **linéaire**
3. Pics : `acf[lag] > acf[lag−1]`, `acf[lag] >= acf[lag+1]`, `acf[lag] > 0.2 × maxACF` ; raffinement du lag par interpolation **parabolique** ; les 8 meilleurs sont gardés
4. **Renforcement harmonique asymétrique** :
   ```
   score = max(0, acf(lag)) + 0.5 × max(0, acf(2·lag)) + 0.25 × max(0, acf(lag/2))
   ```
   Le coefficient sous-harmonique vaut **0,25** et non 0,5 : à 0,5 symétrique, l'hypothèse half-time cumule deux multiples pleins de la période (score ≈ 2,0 contre ≈ 1,5) et bat systématiquement le vrai tempo.
5. **Prior log-normal type Ellis**, appliqué avant normalisation :
   ```
   priorWeight = exp(−0.5 × (log2(bpm/120) / 0.5)²)     // centre 120 BPM, σ = 0,5 OCTAVE
   score *= priorWeight
   ```
6. Déduplication : écart relatif > 2 % avec tous les gardés, plafond 6 hypothèses
7. **Phase par peigne d'impulsions** : pour chaque décalage entier de 0 à `round(period)−1`, somme de l'enveloppe **brute** aux positions `phase + k×periodFrames` (avance fractionnaire, index par `round`) ; le décalage de somme maximale gagne
8. Relations half/double : appariement des paires dont `|bpmRapide/bpmLent − 2| ≤ 0.16`, chaque extrémité appariée au plus une fois
9. `probability = score / Σ scores` (somme exactement 1)

Sortie : `tempoCurve` **constante** à une seule valeur (niveau A), `meterNumerator/Denominator = nil` (laissés au `BeatTracker`).

> Le prior log-normal et l'asymétrie 0,5/0,25 sont un **choix d'implémentation non décrit par la spec**. Ils modifient l'ordre des hypothèses, donc celle que retient l'analyseur (`hypotheses.first`). Toutes les hypothèses restent conservées avec leurs relations (§63).

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

Cas dégénéré (enveloppe vide/plate, BPM ≤ 0) : aucun beat, aucune barre, mesure 4, confiance 0.

### 3.7 Similarité et nouveauté (§21, §22)

Constantes : `fallbackStepTicks = 30 000` (0,5 s) · `minimumBeatsForGrid = 4` · `kernelHalfWidths = [2, 4, 8]` (kernels de **4, 8 et 16 beats**) · `maxSimilaritySpans = 2 000` (plafond ≈ 16 Mo).

- Grille = beats réels si ≥ 4 beats, sinon grille uniforme tous les 30 000 ticks avec `isBeatAligned = false`
- **Vecteur 17-D** par span : pour chacune des 5 bandes → moyenne, maximum, **pente** (= moyenne de la 2ᵉ moitié − moyenne de la 1ʳᵉ moitié), + moyenne du rms + moyenne du flux. *(La variance exigée par §21 n'est pas conservée.)*
- Scalaires par span : energy, bass, flux, centroid, `onsetDensity` (onsets/seconde), chacun normalisé par quantile 0,95 borné 0…1
- Si `spanCount > 2000` : sous-échantillonnage par stride avec agrégation par **moyenne** avant toute matrice
- Vecteurs standardisés dimension par dimension (z-score, plancher 1e-6), **matrice de similarité cosinus** symétrique, diagonale à 1
- **Nouveauté par kernel en damier** le long de la diagonale, pour chaque h ∈ {2,4,8} :
  ```
  N[i] = ( Σ_{u,v<h} S[i−1−u][i−1−v] + S[i+u][i+v] − S[i−1−u][i+v] − S[i+u][i−1−v] ) / nbTermesValides
  ```
  redressée à ≥ 0. La courbe combinée normalise chaque kernel par son propre maximum, moyenne les 3, renormalise.
- **Frontières** : maximum local sur ±2 spans, seuil adaptatif `valeur >= max(0.3, moyenneLocale(±8 spans) × 1.2)`, kernel dominant = réponse brute maximale, `isSectionScope = (kernelSize >= 16)`, `confidence = min(0.3 + 0.6 × strength, 0.9)` — **jamais 1,0 au niveau A**. Deux frontières de section distantes de moins de 8 spans fusionnent.

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

> `impactFloorWindow = 8` est justifié numériquement : sur 3 spans, la montée d'un crescendo graduel plafonne à 0,26–0,33 (< 0,35) et l'impact n'était jamais détecté ; sur 8 spans elle atteint 0,45–0,66 sans créer d'impact parasite sur click track.

**Événements produits** : `.onset` (un par onset) · `.accent` (force > `max(80ᵉ centile, 0.6)`) · `.downbeat` (salience du beat apparié à ±3 000 ticks = ±50 ms, sinon 0,5) · `.sectionBoundary` / `.phraseBoundary` · `.impact` · `.silence`.

**Impacts** : maximum local d'énergie ≥ 0,65, montée ≥ 0,35 par rapport au **minimum des 8 spans précédents**, séparation minimale de 2 spans. `salience = min(0.5×valeur + 0.5×montée, 1)`, `confidence = min(0.3 + 0.4×montée, 0.7)`. Temps **raffiné à la frame de dérivée RMS maximale** dans le span, fenêtre élargie de 0,15 s vers l'arrière.

**Relations** : `contains` (section → phrases au même instant à ±1 beat) et `prepares` (buildUp → impact), **uniquement si `genuineRise` est validé** : fenêtre des 8 spans précédents, tension moyenne ≥ 0,4 **et** montée d'énergie ≥ 0,15. Sinon aucun buildUp et aucune relation — règle « ne jamais inventer de drop ».

**Fonctions dramaturgiques**, par span, dans l'ordre : `impact` → `transition` (novelty ≥ 0,6) → `accumulation` (tension ≥ 0,45 et Δénergie ≥ 0) → `sustain` (energy ≥ 0,6 et |Δ| ≤ 0,08) → `release` (Δ ≤ −0,15) → `exposition`. Lissage absorbant les runs < 2 spans. Confiance **fixe** 0,4 (0,3 pour une section plus courte qu'un span).

### 3.10 Orchestration, cache, reprise

`engineVersion = 2` · `minimumOnsetsForTempo = 4` · `noHypothesisID` = UUID nul déterministe.

Ordre exact d'`analyze` :
1. Empreinte audio **SHA-256** (blocs de 1 Mio) + `configurationFingerprint` (`sr22050-s1024.256-m2048.512-l4096.1024-whann`)
2. Cache à jour → **retour immédiat, aucune progression publiée**
3. Chargement du checkpoint, invalidé si `engineVersion` diffère
4. Phase 1 « Préparation audio » → checkpoint (plist binaire)
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

`try Task.checkCancellation()` entre **chaque** phase. Annulation → statut inchangé (`analyzing`), reprise à la réouverture. Le cache exige la **conjonction** : empreinte audio ET `engineVersion` ET empreinte de config ET `result.version == engineVersion`. `save` écrit le **résultat d'abord**, la méta ensuite (une méta sans résultat validerait un cache vide), les deux atomiquement, JSON à clés triées.

`AudioAnalysisActor` : garde de réentrance (`startingProjects`), rejoint une analyse en cours, ré-vérifie tous les gardes par appel récursif si la tâche existante est annulée, lit la durée réelle via `AVURLAsset` (**jamais inventée**), publie lui-même la phase 5, génère les partitions hors acteur via `Task.detached`, impose une progression **monotone** (les `Task` du callback n'ont aucun ordre FIFO garanti).

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

### 4.5 Déduplication — deux passes

Critère unique de force, dans cet ordre : **protégé** > rang hiérarchique le plus **petit** > `finalUtility` la plus **grande** > center le plus **petit**. Aucun UUID n'intervient : déterministe.

**Passe 1 — regroupement en chaîne** : après tri, tout candidat à moins de **3 600 ticks (60 ms)** du précédent du cluster courant le rejoint. Deux candidats protégés (début et fin) ne fusionnent jamais. Survivant = le plus fort, avec les raisons de **tous** les membres cumulées sans doublon.

**Passe 2 — fusion élargie des majeures** : deux ancres de rang ≤ 1 distantes de moins de `minimumSlotDurationFluid` = **45 000 ticks (0,75 s)** fusionnent. Motif : deux majeures plus proches que le plancher fluide ne peuvent pas être toutes deux frontières racines, ce qui rendrait `majorAnchorIDs` incohérent avec « les ancres majeures restent dans les trois modes » (§28.1).

**Invariant obtenu** : deux majeures consécutives sont toujours espacées d'au moins 45 000 ticks.

Les **ancres majeures** = toutes celles de `hierarchyRank <= 1` (début, fin, bords de sections = rang 0 ; bords de phrases = rang 1).

### 4.6 Gestes (§27)

Seuils : `anchorMatchTicks = 3 600` (60 ms) · `burstRiseMean = 0.35` · `holdStabilityMean = 0.45` · `burstMaximumPreAnchors = 3`.

Pour chaque impact (par temps croissant), appariement à une ancre à ±60 ms — sinon l'impact est ignoré. Trois branches **exclusives** :

1. **`burstResolution`** — conditionné à `hasGenuineRise` : moyenne de tension **ou** de nouveauté ≥ 0,35 sur 8 échantillons pris tous les demi-beats **avant** l'impact, avec ≥ 4 échantillons valides. Pré-ancres : centre dans `[impact − 2,5 beats, impact)`, strictement > 0, **non majeures**, non déjà groupées ; les 3 plus proches, remises en ordre chronologique. Créé **seulement si ≥ 2 pré-ancres**. L'ancre d'impact rejoint le groupe uniquement si elle n'est pas majeure.
2. **`impactHold`** — conditionné à `hasSustain` : moyenne de stabilité ≥ 0,45 sur 4 échantillons au demi-beat **après** l'impact, **ou** un état `.sustain` démarrant dans `[impact − beatTicks/4, impact + 2·beatTicks]`. Ancre de sortie : centre dans `[impact + 1 beat, impact + 2,25 beats]`, utilité maximale.
3. **`breathing`** — émise immédiatement après chaque `impactHold` : `start` = centre de l'ancre de sortie, `end = min(sortie + 2·beatTicks, durée)`, **`anchorIDs` vide**. Rattachée à son parent par `breathing.start == impactHold.end`.
4. **`simpleAccent`** — impact isolé : `start == end` = centre de l'impact.

Ces gestes alimentent la découpe de deux façons : les `impactHold` et `breathing` définissent les **zones sans coupe** (intérieur **strict** seulement — les bords d'un maintien restent coupables), et chaque geste à ancres devient un **candidat de split groupé** (toutes ses ancres ou aucune).

### 4.7 Partition racine (§28.3.1)

`boundaries` initialisées à exactement deux éléments : `[tick 0, tick durée]`. Puis les majeures **intérieures** sont triées par (rang croissant, `finalUtility` décroissante, center croissant) et insérées une à une **si et seulement si** `tick − précédente ≥ 45 000` **et** `suivante − tick ≥ 45 000` — le plancher **fluide**, le plus grand des trois.

**La racine est donc identique aux trois modes.** Sinon : `assertionFailure` en debug + rétrogradation en candidat ordinaire (branche documentée comme inatteignable grâce à la fusion amont des majeures).

### 4.8 Le raffinement glouton — cœur de la découpe

Boucle `while true` : à **chaque** tour, **tous** les candidats restants sont réévalués contre l'état courant des frontières (équivalent d'une file de priorité re-triée, §28.4).

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

### 4.12 Péremption (§61)

`ScoreLibrary.scoresAreCurrent` rend vrai **SSI** :
`meta.generatorVersion == 1` **ET** `meta.analysisVersion == engineVersion` **ET** `meta.configurationFingerprint == SHA-256(ScoreConfiguration.production)`.

`coreMLModelVersion` est **tracé mais non discriminant**.

> **Architecture à deux caches — exigence §69 respectée.** `AnalysisCache` est clé sur (empreinte audio, `engineVersion`, empreinte `AnalysisConfiguration`) ; `ScoreLibrary` sur (`generatorVersion`, empreinte `ScoreConfiguration`, `analysisVersion`). Changer un poids §26.3 périme les partitions **sans** périmer l'analyse : `recalculateScores` relance `analyze()` qui rend le cache immédiatement, puis régénère les partitions — **aucun redécodage PCM**. C'est exactement « une nouvelle partition ne doit pas obligatoirement redécoder la musique ».

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

## 6. Tests du bloc — 99 tests

| Fichier | Tests | Couverture |
|---|---|---|
| `SpectralFeatureExtractorTests` | 2 | Centroïde 440 Hz ±80 Hz, RMS stable < 5 %, silence ≤ 1e-4 |
| `OnsetDetectorTests` | 3 | Click 120 BPM → 14…18 onsets, chaque clic à ±35 ms ; silence → 0 ; impact isolé → exactement 1 à ±50 ms |
| `TempoEstimatorTests` | 4 | 120 BPM dans le top 2 ; Σ probabilités = 1 ; relations half/double croisées ; enveloppe plate/vide → **aucune** hypothèse |
| `BeatTrackerTests` | 4 | Période médiane 0,5 s ±5 %, confiance > 0,6 ; accélération 100→140 ; mesure 4 et mesure 3, downbeats à ≤ 40 ms |
| `AnalysisPipelineTests` | 5 | 128 BPM ±4 **strict** ; ≥ 80 % des intervalles à ±10 % ; déterminisme inter-projets à 1e-9 ; cache → JSON identique octet à octet + **aucune** progression ; annulation → checkpoint, reprise **prouvée par payload sentinelle** ; silence+impact → impact sans buildUp inventé |
| `BuildupPipelineTests` | 2 | buildUp → impact à ±300 ms, `.interval` avec `end.ticks == impact.start.ticks` **exact**, relation `.prepares` ; click accéléré |
| `HybridAnalyzerFallbackTests` | 3 | Registre → `nil` partout ; hybride ≡ déterministe **champ par champ** ; modèle injecté → `predictCallCount == 0` |
| `EditScoreGeneratorTests` | 14 | Bloc §70 « Partitions » complet : structure, imbrication, majeures communes, planchers, burst en groupe atomique, respiration, fusion des majeures proches, modes distincts, résidu final, morceau de 3 s, ambiant sans beats, morceau vide → throw, déterminisme, statistiques |
| `ScoreGenerationPipelineTests` | 4 | Analyse → partitions bout-en-bout ; 5 phases ; silence+impact sans crash ; aller-retour JSON sans arrondi |
| `ScoreConfigurationWeightsTests` | 9 | **Un test par poids §26.3** : chacun à 0 puis à 2, l'utilité de l'ancre ciblée varie dans le bon sens, et un poids non concerné la laisse **strictement** identique |
| `PaceSelectionStoreTests` | 12 | `selectPace`, revert, verrou par association, péremption (méta absente / generatorVersion / empreinte config / analysisVersion), JSON corrompu → `nil`, duplication |
| `AudioImporterTests` | 8 | §62 : types refusés, fichier vide, DRM, piste non décodable, copie atomique/interrompue |
| `WaveformExtractorTests` | 3 | 200 bins, normalisation, VBR |
| `ProjectStoreTests` | 10 | §10.1 : unicité (mode, index), index croissant, durée positive, cascade |
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
| **§21** | La **variance** par span n'est pas conservée (moyenne/max/pente seulement). Vecteurs par beat uniquement, jamais « par beat ET par mesure ». |
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
| — | `MusicAnalysisResult.version` porte l'`engineVersion`, pas une version de schéma. Tout incrément de moteur invalide les résultats même sans changement de schéma (voulu pour le cache, mais le champ ne décrit plus le schéma). |
| — | `AnchorField` : un événement `.release` reçoit la raison **« Résolution après impact » sans aucune vérification qu'un impact précède**, alors que la branche équivalente sur les états fonctionnels l'exige. Un release isolé affiche une raison fausse à l'utilisateur (§29). |
| — | Fenêtre de fusion d'onsets **effective : 23,2 ms**, pas 30 ms (troncature `Int(0.030 × 86,13) = 2` frames). |
| — | La plage 50–220 BPM n'est pas atteignable en dessous d'environ **4 s** d'enveloppe (`lagMax` plafonné par `(frameCount−1)/2`). |
| — | Aucune **contrainte de durée maximale** de case, ni dans la spec ni dans le code. Une case peut être arbitrairement longue si aucun split ne dépasse le seuil de gain. |
| — | `refine` réévalue **tous** les candidats contre **toutes** les frontières après chaque activation : O(activations × candidats × frontières), « acceptable ≤ ~6 min de musique » — **jamais mesuré**. |
| — | `intervalCost` passe par des secondes en `Double` : seul point où un flottant influence une décision de découpe, et la comparaison `gain == bestGain` est une égalité de flottants — le départage déterministe ne se déclenchera quasiment jamais en pratique. |

### 7.3 Trous de test

- La **5ᵉ phase** (`rhythmCreation`) n'est couverte par **aucun** test d'intégration réel. `AnalysisPipelineTests` vérifie au contraire qu'elle n'est **jamais** publiée par l'analyseur ; `ScoreGenerationPipelineTests` n'est qu'un garde-fou sur l'énumération. L'écran affiche pourtant « Phase x sur 5 ».
- **Aucun test ne couvre les vues** : ni `ProjectView` (polling 300 ms, `retryAnalysis`, annulation à `onDisappear`) ni `PaceSelectionView` (3 états, `loadScores`, `recalculateScores`, `validate`, alerte §65). Aucun XCUITest (§73).
- `MiniTimelineView` n'a aucun test unitaire, seulement une preview.
- **Aucun profilage §67/§68** : pic mémoire d'analyse et fluidité invérifiés.
- Le projet **n'a jamais été compilé** (généré sous Windows) — vérification Mac ⌘B/⌘U requise sur tous les jalons.
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
| Fusion d'onsets | 30 ms déclarés → **23,2 ms effectifs** |
| Seuil adaptatif *k* | 1,5 |
| Planchers d'onset | 5 % (bande) / 2 % (global) |
| Rayons | médiane 0,5 s · seuil 0,175 s |
| Plage BPM | 50–220 (tolérance ±2 % en sortie) |
| Pics d'ACF / hypothèses max | 8 / 6 |
| Doublon d'hypothèse | < 2 % |
| Tolérance half/double | 0,08 (soit \|ratio−2\| ≤ 0,16) |
| Renforcement harmonique | ×0,5 (2·lag) et **×0,25** (lag/2) |
| Prior de tempo | log-normal, centre **120 BPM**, σ = **0,5 octave** |
| λ (DP beats) | 4,0 |
| Mesures candidates | {2, 3, 4}, dénominateur figé à 4 |
| Grille de repli | 30 000 ticks (0,5 s), minimum 4 beats |
| Kernels de nouveauté | 4 / 8 / 16 beats |
| Seuil de frontière | `max(0,3 ; moyenne locale × 1,2)` |
| Séparation minimale de section | 8 spans |
| Confiance de frontière | ≤ 0,9 (jamais 1,0) |
| Plafond matrice de similarité | 2 000 spans |
| Impact | énergie ≥ 0,65 · montée ≥ 0,35 sur 8 spans |
| Silence | rms < 0,03 pendant > 0,8 s |
| BuildUp | tension ≥ 0,4 **et** énergie +0,15 |
| `engineVersion` | **2** |
| `minimumOnsetsForTempo` | **4** |
| Garde morceau court | `rms.count < 8` |
| Empreinte | SHA-256 par blocs de 1 Mio |

### Découpe

| Paramètre | Valeur |
|---|---|
| 9 poids §26.3 | tous **1.0** |
| Fusion de candidats | 3 600 ticks (60 ms) |
| Fusion des majeures | 45 000 ticks (0,75 s) |
| Fenêtre d'anticipation | 90 000 ticks (1,5 s) |
| Maintien post-impact | 60 000 ticks (1 s), triangle culminant à 0,5 s |
| Recherche de résolution | 150 000 ticks (2,5 s) |
| Onset « fort » | salience ≥ 0,75 |
| Seuil `conditional` | confiance < 0,5 |
| Rangs hiérarchiques | 0 trackEdge/section · 1 phrase · 2 downbeat/impact · 3 beat/resolution · 4 strongOnset |
| Ancres **majeures** | rang ≤ 1 |
| `burstRiseMean` | 0,35 |
| `holdStabilityMean` | 0,45 |
| Pré-ancres de burst | max 3, minimum 2 requis |
| `addedCutCost` | 0,5 **par ancre** |
| Fenêtre d'overcut | 90 000 ticks (1,5 s), au-delà de **2** frontières |
| `overcutDensityScale` | 0,1 |
| Planchers | 0,75 / 0,40 / 0,25 s |
| Cibles | 2,5 / 1,2 / 0,6 s |
| Seuils de gain | 0,30 / 0,12 / 0,05 |
| Respiration après burst | 2 × plancher du mode |
| `generatorVersion` | **1** |

---

## 9. Statut des jalons

| Jalon | Statut |
|---|---|
| **4 — Moteur musical déterministe** | ✅ Terminé (CI verte, run 31392520681) |
| **5 — Générateur de scores** | ✅ Terminé (CI verte, run 31398882782) |
| **6 — Interface analyse / choix rythme** | ✅ Terminé (CI verte, run 31419878812) |
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
