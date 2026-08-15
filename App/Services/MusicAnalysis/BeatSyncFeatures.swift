//
//  BeatSyncFeatures.swift
//  MontageMusical
//
//  Synchronisation des caractéristiques sur les beats (Jalon 4, niveau A) :
//  - §21 : agrégation des caractéristiques ENTRE beats (moyenne, maximum,
//    VARIANCE par bande + rms + flux) → un vecteur par beat ;
//  - §22.1 : matrice de similarité au niveau BEAT uniquement — jamais de
//    matrice frame × frame (§67, §68) ;
//  - §22.2 : courbe de nouveauté par kernel en damier (checkerboard) le long
//    de la diagonale, plusieurs tailles (4, 8, 16 et 64 temps) ; les pics
//    deviennent des frontières avec force locale, portée structurelle
//    (taille de kernel dominante) et confiance.
//
//  Correctifs « échelles structurelles » (critique, changement 4) :
//  1. une QUATRIÈME échelle de 64 temps = 16 mesures en 4/4 a été ajoutée, et
//     `isSectionScope` lui est désormais RÉSERVÉE : à 150 BPM, l'ancien plus
//     grand kernel (16 temps = 6,4 s) avait exactement la taille d'une phrase
//     de 4 mesures et entrait en résonance avec un drop alterné A/B, étiquetant
//     « nouvelle section » toutes les 6,4 s ; une vraie section EDM fait 16 à
//     32 mesures, soit 25 à 50 s ;
//  2. la réponse du damier est rendue NULLE là où trop peu de termes sont
//     valides (convention de Foote) : à l'index 1 un seul terme survivait au
//     garde et pouvait atteindre 4,0, ce qui fixait le maximum de normalisation
//     du morceau et déflatait toutes les vraies frontières d'environ 1,4× ;
//  3. une condition ABSOLUE sur la réponse brute du kernel dominant s'ajoute au
//     seuil relatif : sans elle, la nouveauté étant normalisée par son propre
//     maximum, le détecteur ne pouvait STRUCTURELLEMENT pas rendre zéro
//     frontière — 90 s prélevées dans un drop produisaient des sections aux
//     positions du bruit, promues en ancres majeures de rang 0.
//

import Foundation

// MARK: - Passage frame d'analyse → ticks (règle transverse Jalon 4)

/// Pont frame d'analyse ↔ `MediaTime` pour l'orchestration (§9 : le temps
/// est TOUJOURS persisté en ticks).
///
/// Le sens frame → ticks délègue à la SEULE fonction utilitaire du moteur,
/// `FeatureTimeline.mediaTime(forFrame:frameRate:)` (règle transverse
/// Jalon 4 : `ticks = round(frameIndex / frameRate × 60 000)`) — aucune
/// formule de conversion locale dans les fichiers d'orchestration.
enum BeatGridTimeMapping {

    /// Instant `MediaTime` du début de la frame `frameIndex`.
    static func mediaTime(frameIndex: Int, frameRate: Double) -> MediaTime {
        FeatureTimeline.mediaTime(forFrame: frameIndex, frameRate: frameRate)
    }

    /// Index de frame le plus proche d'un instant, borné à `0..<frameCount`.
    static func frameIndex(of time: MediaTime, frameRate: Double, frameCount: Int) -> Int {
        precondition(frameRate > 0, "frameRate doit être strictement positif")
        let raw = Int((time.seconds * frameRate).rounded())
        return min(max(raw, 0), max(frameCount - 1, 0))
    }
}

// MARK: - Frontière structurelle (§22.2)

// Non defini par la specification — definition minimale V1.
/// Frontière détectée par la courbe de nouveauté (§22.2) : force locale,
/// portée structurelle (taille du kernel dominant, en beats) et confiance.
struct StructuralBoundary: Sendable, Equatable {
    /// Index du span de beat qui COMMENCE à cette frontière.
    let spanIndex: Int
    let time: MediaTime
    /// Force locale normalisée 0…1 (relative au morceau, §17 dernier alinéa).
    let strength: Double
    /// Portée structurelle : taille du kernel dominant — 4, 8, 16 ou 64 temps.
    let dominantKernelSize: Int
    /// Vrai si la frontière est de grande portée (section), faux si de
    /// petite portée (phrase).
    ///
    /// N'est vrai QUE pour l'échelle longue (64 temps = 16 mesures) : les
    /// kernels de 4/8/16 temps mesurent des ruptures de PHRASE, pas de
    /// section. Voir l'en-tête de fichier, correctif 1.
    let isSectionScope: Bool
    let confidence: Double
}

// MARK: - Caractéristiques synchronisées sur les beats

// Non defini par la specification — definition minimale V1.
/// Résultat de la synchronisation beat (§21) + similarité (§22.1) +
/// nouveauté (§22.2). Tout est au niveau du beat (ou d'une grille uniforme
/// de repli §63 quand le morceau n'a pas de pulsation exploitable).
struct BeatSynchronousFeatures: Sendable {

    /// Début de chaque span. Beats réels quand `isBeatAligned`, sinon
    /// grille uniforme de repli (§63 : structure par nouveauté seulement).
    let gridTimes: [MediaTime]
    /// Fin du dernier span (durée du morceau).
    let gridEnd: MediaTime
    /// Vrai si la grille est alignée sur les beats suivis.
    let isBeatAligned: Bool

    /// §21 : un vecteur par span — pour chaque bande : moyenne, maximum,
    /// VARIANCE ; puis moyenne RMS et moyenne du flux spectral.
    /// (17 dimensions : 5 bandes × 3 + rms + flux.)
    let vectors: [[Float]]
    /// §22.1 : similarité cosinus entre vecteurs de beats. Grille des spans,
    /// ou grille sous-échantillonnée par stride quand le morceau dépasse le
    /// plafond mémoire (§67, §68) — la matrice peut donc être plus petite
    /// que `spanCount × spanCount` ; `novelty` et `boundaries` restent,
    /// eux, exprimés sur les spans réels.
    let similarity: [[Float]]
    /// §22.2 : nouveauté combinée multi-kernel, normalisée 0…1, par span
    /// (`novelty[i]` = rupture à l'ENTRÉE du span `i`).
    let novelty: [Double]
    let boundaries: [StructuralBoundary]

    // Scalaires par span, normalisés relativement au morceau (§17 :
    // médiane/quantiles — jamais de valeur absolue « toujours culminante »).
    let energy: [Double]
    let bass: [Double]
    let flux: [Double]
    let centroid: [Double]
    let onsetDensity: [Double]

    var spanCount: Int { gridTimes.count }

    func spanStart(_ index: Int) -> MediaTime { gridTimes[index] }

    func spanEnd(_ index: Int) -> MediaTime {
        index + 1 < gridTimes.count ? gridTimes[index + 1] : gridEnd
    }
}

// MARK: - Extracteur

// Non defini par la specification — definition minimale V1.
struct BeatSyncFeatureExtractor: Sendable {

    /// Pas de la grille uniforme de repli (§63) : 0,5 s = 30 000 ticks.
    private static let fallbackStepTicks: Int64 = 30_000
    /// Nombre minimal de beats pour une grille alignée sur la pulsation.
    private static let minimumBeatsForGrid = 4
    /// Demi-largeurs des kernels en damier : kernels de 4, 8, 16 et **64**
    /// temps. Les trois premières échelles mesurent des ruptures de PHRASE ;
    /// la quatrième (64 temps = 16 mesures en 4/4, soit 25,6 s à 150 BPM) est
    /// la seule échelle de SECTION — voir `sectionKernelHalfWidth`.
    ///
    /// Coût du kernel long (vérification demandée par la critique) : h² = 1 024
    /// quadruples de 4 lectures par span, soit ≈ 4 M lectures pour 1 000 spans
    /// et ≈ 8 M au plafond de 2 000 spans. À comparer aux étages voisins : la
    /// matrice de similarité elle-même coûte 2 000²/2 = 2 M produits scalaires
    /// de 17 dimensions ≈ 34 M multiplications-additions, et l'autocorrélation
    /// du tempo ≈ 26 000 frames × ≈ 2 000 lags ≈ 50 M. Le surcoût est donc de
    /// l'ordre du dixième de l'étage le moins cher : négligeable.
    private static let kernelHalfWidths = [2, 4, 8, 32]

    /// Demi-largeur de l'UNIQUE échelle de section (§22.2) : 32 → kernel de
    /// 64 temps = 16 mesures en 4/4. Une section EDM fait 16 à 32 mesures ;
    /// l'ancienne valeur (kernel de 16 temps) mesurait une phrase de
    /// 4 mesures et entrait en résonance avec les alternances A/B d'un drop.
    private static let sectionKernelHalfWidth = 32

    /// Séparation minimale de deux frontières de SECTION, en spans.
    /// Portée de 8 à 32 spans en cohérence avec `sectionKernelHalfWidth` :
    /// à 8 spans, le moteur pouvait produire des « sections » de 3,2 s ;
    /// 32 spans = 8 mesures en 4/4 = la moitié de la plus petite section
    /// plausible, ce qui laisse passer une transition breakdown → drop
    /// légitimement rapprochée sans autoriser de section-phrase.
    private static let minimumSectionSeparationSpans = 32

    /// Seuil ABSOLU sur la réponse BRUTE du kernel dominant, exigé EN PLUS du
    /// seuil relatif pour émettre une frontière (§22.2, correctif 3).
    ///
    /// Justification par la plage théorique du damier sur des vecteurs
    /// standardisés : chaque terme vaut S(p,p′) + S(f,f′) − S(p,f′) − S(f,p′)
    /// avec S cosinus ∈ [−1, 1], donc chaque terme — et donc la moyenne par
    /// terme, qui EST la réponse brute — vit dans [−4, +4]. Repères :
    /// • deux blocs internement identiques et mutuellement ORTHOGONAUX
    ///   (cos croisé = 0) : 1 + 1 − 0 − 0 = **2,0** — la frontière idéale ;
    /// • matériau réel : cohésion intra ≈ 0,5…0,7 et similarité croisée
    ///   ≈ 0,0…0,2 → **1,0…1,4** ;
    /// • boucle homogène : intra ≈ croisé, l'espérance de la réponse est **0**
    ///   et il ne reste que le bruit d'échantillonnage, moyenné sur h² = 1 024
    ///   quadruples pour le kernel long — quelques centièmes.
    /// 0,8 est donc à 40 % de la frontière idéale : un ordre de grandeur
    /// au-dessus du bruit d'une boucle, bien en dessous de toute vraie
    /// transition. C'est ce seuil qui rend possible **zéro** frontière.
    private static let minimumRawNoveltyResponse = 0.8

    /// Plafond de la grille de la matrice de similarité (§67, §68 : mémoire
    /// bornée — jamais de matrice dense non plafonnée). 2 000 × 2 000 Float
    /// ≈ 16 Mo ; sans plafond, 60 min à ~2 beats/s donneraient ~7 200 spans
    /// soit ~200 Mo. Au-delà, la grille est sous-échantillonnée par stride
    /// AVANT la matrice (vecteurs agrégés par moyenne), le mapping vers les
    /// temps réels étant conservé pour les frontières.
    private static let maxSimilaritySpans = 2_000

    init() {}

    func compute(
        features: FeatureTimeline,
        beats: [BeatEvent],
        onsets: [OnsetEvent]
    ) -> BeatSynchronousFeatures {
        let frameCount = features.rms.count
        let duration = features.duration

        // 1. Grille : beats réels, ou grille uniforme de repli (§63 :
        //    enveloppe plate/ambiant → structure par nouveauté seulement).
        let gridTimes: [MediaTime]
        let isBeatAligned: Bool
        if beats.count >= Self.minimumBeatsForGrid {
            gridTimes = beats.map(\.time)
            isBeatAligned = true
        } else {
            var times: [MediaTime] = []
            var tick: Int64 = 0
            while tick < duration.ticks {
                times.append(MediaTime(ticks: tick))
                tick += Self.fallbackStepTicks
            }
            if times.isEmpty { times = [.zero] }
            gridTimes = times
            isBeatAligned = false
        }
        let spanCount = gridTimes.count

        // 2. Bornes de frames par span (fin du dernier span = durée).
        var frameRanges: [Range<Int>] = []
        frameRanges.reserveCapacity(spanCount)
        for index in 0..<spanCount {
            let start = BeatGridTimeMapping.frameIndex(
                of: gridTimes[index], frameRate: features.frameRate, frameCount: frameCount
            )
            let endTime = index + 1 < spanCount ? gridTimes[index + 1] : duration
            var end = BeatGridTimeMapping.frameIndex(
                of: endTime, frameRate: features.frameRate, frameCount: frameCount
            )
            // Span plus court qu'une frame : au moins une frame par span
            // (l'agrégation borne elle-même contre la longueur réelle).
            if end <= start { end = start + 1 }
            frameRanges.append(start..<end)
        }

        // 3. §21 : vecteurs par span — moyenne/max/VARIANCE par bande + rms
        //    + flux. La variance remplace la pente : voir `aggregate`.
        let bandCount = features.bandEnergies.count
        var vectors: [[Float]] = []
        vectors.reserveCapacity(spanCount)
        for range in frameRanges {
            var vector: [Float] = []
            vector.reserveCapacity(bandCount * 3 + 2)
            for band in 0..<bandCount {
                let stats = Self.aggregate(features.bandEnergies[band], over: range)
                vector.append(stats.mean)
                vector.append(stats.maximum)
                vector.append(stats.variance)
            }
            vector.append(Self.aggregate(features.rms, over: range).mean)
            vector.append(Self.aggregate(features.spectralFlux, over: range).mean)
            vectors.append(vector)
        }

        // 4. Scalaires par span, normalisés relativement au morceau (§17).
        let energyRaw = frameRanges.map { Double(Self.aggregate(features.rms, over: $0).mean) }
        let bassRaw = frameRanges.map { range -> Double in
            guard bandCount > 0 else { return 0 }
            return Double(Self.aggregate(features.bandEnergies[0], over: range).mean)
        }
        let fluxRaw = frameRanges.map { Double(Self.aggregate(features.spectralFlux, over: $0).mean) }
        let centroidRaw = frameRanges.map { Double(Self.aggregate(features.spectralCentroid, over: $0).mean) }
        let densityRaw = (0..<spanCount).map { index -> Double in
            let start = gridTimes[index]
            let end = index + 1 < spanCount ? gridTimes[index + 1] : duration
            let seconds = max(end.seconds - start.seconds, 1e-6)
            let count = onsets.count { $0.time >= start && $0.time < end }
            return Double(count) / seconds
        }
        let energy = Self.normalizeByUpperQuantile(energyRaw)
        let bass = Self.normalizeByUpperQuantile(bassRaw)
        let flux = Self.normalizeByUpperQuantile(fluxRaw)
        let centroid = Self.normalizeByUpperQuantile(centroidRaw)
        let onsetDensity = Self.normalizeByUpperQuantile(densityRaw)

        // 5. §22.1 : similarité cosinus au niveau beat, sur vecteurs
        //    standardisés par dimension (sinon des features toutes positives
        //    donnent une similarité ~1 partout).
        //    §67/§68 : au-delà de `maxSimilaritySpans`, la grille est
        //    sous-échantillonnée par stride AVANT la matrice (mémoire
        //    bornée) ; les vecteurs d'un groupe sont agrégés par moyenne et
        //    l'index grossier `c` correspond au span réel `c × stride`.
        let gridStride = spanCount > Self.maxSimilaritySpans
            ? (spanCount + Self.maxSimilaritySpans - 1) / Self.maxSimilaritySpans
            : 1
        let coarseVectors = gridStride > 1
            ? Self.downsampledByMean(vectors, stride: gridStride)
            : vectors
        let similarity = Self.cosineSimilarityMatrix(Self.standardized(coarseVectors))

        // 6. §22.2 : nouveauté en damier multi-kernel + frontières,
        //    calculées sur la grille (éventuellement grossière) de la
        //    matrice, puis ramenées aux spans réels.
        let (coarseNovelty, perKernel) = Self.checkerboardNovelty(
            similarity: similarity,
            halfWidths: Self.kernelHalfWidths
        )
        let coarseGridTimes = gridStride > 1
            ? Swift.stride(from: 0, to: spanCount, by: gridStride).map { gridTimes[$0] }
            : gridTimes
        let coarseBoundaries = Self.pickBoundaries(
            novelty: coarseNovelty,
            perKernel: perKernel,
            halfWidths: Self.kernelHalfWidths,
            gridTimes: coarseGridTimes
        )
        // Mapping grille grossière → spans réels (§67/§68) : temps déjà
        // réels (premier span de chaque groupe), index de span remappé ;
        // nouveauté étendue en palier constant par groupe (une valeur par
        // span réel, contrat de `BeatSynchronousFeatures.novelty`).
        let novelty: [Double]
        let boundaries: [StructuralBoundary]
        if gridStride > 1 {
            novelty = (0..<spanCount).map { index in
                coarseNovelty[min(index / gridStride, coarseNovelty.count - 1)]
            }
            boundaries = coarseBoundaries.map { boundary in
                StructuralBoundary(
                    spanIndex: boundary.spanIndex * gridStride,
                    time: boundary.time,
                    strength: boundary.strength,
                    dominantKernelSize: boundary.dominantKernelSize,
                    isSectionScope: boundary.isSectionScope,
                    confidence: boundary.confidence
                )
            }
        } else {
            novelty = coarseNovelty
            boundaries = coarseBoundaries
        }

        return BeatSynchronousFeatures(
            gridTimes: gridTimes,
            gridEnd: duration,
            isBeatAligned: isBeatAligned,
            vectors: vectors,
            similarity: similarity,
            novelty: novelty,
            boundaries: boundaries,
            energy: energy,
            bass: bass,
            flux: flux,
            centroid: centroid,
            onsetDensity: onsetDensity
        )
    }

    // MARK: - Agrégation §21

    private struct SpanStats {
        let mean: Float
        let maximum: Float
        /// Variance de population sur le span (§21) — remplace l'ancienne
        /// pente, voir la justification dans `aggregate`.
        let variance: Float
    }

    /// Moyenne, maximum et VARIANCE d'une caractéristique sur une plage de
    /// frames. Plage vide → zéros.
    ///
    /// **Pourquoi la variance et non la pente** (§21 demandait explicitement la
    /// variance ; correctif 4 de la critique). L'ancienne troisième statistique
    /// était la pente « moyenne de la 2ᵉ moitié − moyenne de la 1ʳᵉ moitié ».
    /// Elle est extrêmement sensible au placement de la grille : un span de
    /// 0,4 s à 86,13 frames/s ne contient que ≈ 34 frames, et le jitter de ±1
    /// frame du beat suivi (le même que celui déjà compensé par le maximum sur
    /// ±2 frames dans `BeatTracker`) fait basculer une frame d'attaque d'une
    /// moitié à l'autre, ce qui déplace la pente d'environ 0,3 × la moyenne du
    /// span — c'est-à-dire du même ordre que le signal lui-même. Comme les
    /// dimensions sont ensuite z-scorées, ces 5 dimensions sur 17 (soit ≈ 29 %
    /// de la norme du vecteur) entraient dans la similarité cosinus au MÊME
    /// poids que le RMS tout en n'étant que du bruit : plancher de la courbe de
    /// nouveauté remonté, donc frontières réelles écrasées à la normalisation.
    ///
    /// La variance, elle, est INVARIANTE au décalage temporel de la fenêtre :
    /// déplacer le span d'une frame ne change ni l'ensemble des valeurs (à une
    /// frame près) ni leur dispersion. Elle distingue exactement ce qu'on veut
    /// distinguer ici : un span « tenu » (nappe, variance ≈ 0) d'un span
    /// « percuté » (kick + silence, variance forte), sans dépendre de l'ordre
    /// interne des frames. Son échelle absolue (≈ 1e-3 sur des bandes
    /// normalisées 0…1) est sans importance : `standardized` z-score chaque
    /// dimension avant la similarité.
    private static func aggregate(_ values: [Float], over range: Range<Int>) -> SpanStats {
        let clamped = max(range.lowerBound, 0)..<min(range.upperBound, values.count)
        guard clamped.lowerBound < clamped.upperBound else {
            return SpanStats(mean: 0, maximum: 0, variance: 0)
        }
        var sum: Float = 0
        var maximum: Float = -.greatestFiniteMagnitude
        for index in clamped {
            sum += values[index]
            maximum = max(maximum, values[index])
        }
        let count = clamped.count
        let mean = sum / Float(count)
        // Variance de POPULATION (division par n, pas n−1) : un span d'une
        // seule frame donne 0 sans cas particulier, ce qui est la valeur
        // sémantiquement juste (aucune dispersion observable).
        var squaredDeviationSum: Float = 0
        for index in clamped {
            let delta = values[index] - mean
            squaredDeviationSum += delta * delta
        }
        let variance = squaredDeviationSum / Float(count)
        return SpanStats(mean: mean, maximum: maximum, variance: variance)
    }

    // MARK: - Normalisation relative au morceau (§17)

    /// Normalise par le 95ᵉ centile (borné 0…1) : un morceau masterisé fort
    /// n'est pas considéré comme constamment culminant (§17 dernier alinéa).
    ///
    /// Série éparse (quantile ≈ 0 — p. ex. silence + impact unique : 11
    /// spans sur 12 nuls) : repli sur le MAXIMUM de la série, aligné sur
    /// `SpectralFeatureExtractor.normalizedRelative` — sans quoi l'unique
    /// impact disparaîtrait de la série normalisée. Des zéros ne sont
    /// retournés que si le maximum lui-même est ≈ 0 (silence intégral).
    static func normalizeByUpperQuantile(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let sorted = values.sorted()
        var scale = sorted[Int(Double(sorted.count - 1) * 0.95)]
        if scale <= 1e-9 {
            scale = sorted[sorted.count - 1] // maximum
        }
        guard scale > 1e-9 else { return values.map { _ in 0 } }
        return values.map { min(max($0 / scale, 0), 1) }
    }

    // MARK: - Similarité §22.1

    /// Sous-échantillonnage de la grille (§67, §68) : agrège les vecteurs
    /// par MOYENNE sur des groupes de `stride` spans consécutifs — appelé
    /// uniquement quand `spanCount > maxSimilaritySpans`, AVANT toute
    /// construction de matrice.
    private static func downsampledByMean(_ vectors: [[Float]], stride: Int) -> [[Float]] {
        guard stride > 1, let dimensions = vectors.first?.count else { return vectors }
        var result: [[Float]] = []
        result.reserveCapacity((vectors.count + stride - 1) / stride)
        var start = 0
        while start < vectors.count {
            let end = min(start + stride, vectors.count)
            var mean = [Float](repeating: 0, count: dimensions)
            for index in start..<end {
                for dimension in 0..<min(dimensions, vectors[index].count) {
                    mean[dimension] += vectors[index][dimension]
                }
            }
            let count = Float(end - start)
            for dimension in 0..<dimensions { mean[dimension] /= count }
            result.append(mean)
            start = end
        }
        return result
    }

    /// Standardise chaque dimension (z-score sur l'ensemble des spans).
    private static func standardized(_ vectors: [[Float]]) -> [[Float]] {
        guard let dimensions = vectors.first?.count, dimensions > 0 else { return vectors }
        var result = vectors
        for dimension in 0..<dimensions {
            var sum: Float = 0
            for vector in vectors { sum += vector[dimension] }
            let mean = sum / Float(vectors.count)
            var varianceSum: Float = 0
            for vector in vectors {
                let delta = vector[dimension] - mean
                varianceSum += delta * delta
            }
            let deviation = (varianceSum / Float(vectors.count)).squareRoot()
            let safeDeviation = max(deviation, 1e-6)
            for index in vectors.indices {
                result[index][dimension] = (vectors[index][dimension] - mean) / safeDeviation
            }
        }
        return result
    }

    /// Matrice de similarité cosinus spans × spans (niveau beat — §22.1 :
    /// jamais frame × frame).
    private static func cosineSimilarityMatrix(_ vectors: [[Float]]) -> [[Float]] {
        let count = vectors.count
        guard count > 0 else { return [] }
        let norms = vectors.map { vector -> Float in
            var sum: Float = 0
            for value in vector { sum += value * value }
            return max(sum.squareRoot(), 1e-6)
        }
        var matrix = [[Float]](repeating: [Float](repeating: 0, count: count), count: count)
        for row in 0..<count {
            matrix[row][row] = 1
            for column in (row + 1)..<count {
                var dot: Float = 0
                let lhs = vectors[row]
                let rhs = vectors[column]
                for dimension in 0..<min(lhs.count, rhs.count) {
                    dot += lhs[dimension] * rhs[dimension]
                }
                let value = dot / (norms[row] * norms[column])
                matrix[row][column] = value
                matrix[column][row] = value
            }
        }
        return matrix
    }

    // MARK: - Nouveauté §22.2

    /// Kernel en damier le long de la diagonale : pour chaque frontière
    /// candidate `i` (entrée du span `i`), cohésion passé + cohésion futur −
    /// 2 × similarité croisée, moyennée sur les termes valides.
    ///
    /// Retourne la courbe combinée normalisée 0…1 et les courbes par kernel
    /// BRUTES (échelle commune : la réponse moyenne du damier, déjà
    /// comparable entre tailles grâce à la moyenne par terme). La portée
    /// structurelle (kernel dominant) se détermine sur ces réponses brutes —
    /// comparer des courbes chacune normalisée par SON propre maximum
    /// n'aurait aucune signification. La normalisation par kernel n'est
    /// utilisée QUE pour construire la courbe combinée (chaque échelle y
    /// pèse pareil).
    ///
    /// **Bords (convention de Foote)** : la réponse est rendue NULLE tant que
    /// le nombre de quadruples valides est insuffisant. Sans ce garde, à
    /// `index = 1` un SEUL terme (u = 0, v = 0) survivait au garde de bornes
    /// quelle que soit la demi-largeur : la valeur y vaut `2 − 2·S[0][1]`,
    /// bornée par 4,0, alors qu'une vraie frontière moyennée sur 1 024 termes
    /// plafonne vers 2,8-3,6. Sur un morceau à fade-in, `novelty[1]` fixait
    /// donc à lui seul le maximum de normalisation des trois kernels et
    /// déflatait toute la courbe d'environ 1,43× : les frontières réelles à
    /// ≈ 0,42 passaient sous le seuil de 0,3 et disparaissaient.
    private static func checkerboardNovelty(
        similarity: [[Float]],
        halfWidths: [Int]
    ) -> (combined: [Double], perKernel: [[Double]]) {
        let count = similarity.count
        guard count > 1 else {
            return ([Double](repeating: 0, count: count), halfWidths.map { _ in [Double](repeating: 0, count: count) })
        }
        var perKernelRaw: [[Double]] = []
        for halfWidth in halfWidths {
            // Nombre minimal de quadruples valides pour qu'une réponse ait un
            // sens. `terms` vaut exactement min(halfWidth, index, count−index)²
            // (le garde de bornes ci-dessous découple u et v) : exiger
            // halfWidth²/2 revient à exiger min(index, count−index) ≥ 0,71 ×
            // halfWidth, c'est-à-dire à annuler la réponse sur les ≈ halfWidth
            // premiers et derniers spans — la convention de Foote.
            // Plancher à 1 : garantit `terms > 0` dans la branche de division
            // même si une demi-largeur de 1 était un jour ajoutée.
            let minimumTerms = max(halfWidth * halfWidth / 2, 1)
            var curve = [Double](repeating: 0, count: count)
            for index in 1..<count {
                var sum = 0.0
                var terms = 0
                for u in 0..<halfWidth {
                    for v in 0..<halfWidth {
                        let pastU = index - 1 - u
                        let pastV = index - 1 - v
                        let futureU = index + u
                        let futureV = index + v
                        guard pastU >= 0, pastV >= 0, futureU < count, futureV < count else { continue }
                        sum += Double(similarity[pastU][pastV])
                        sum += Double(similarity[futureU][futureV])
                        sum -= Double(similarity[pastU][futureV])
                        sum -= Double(similarity[futureU][pastV])
                        terms += 1
                    }
                }
                // Trop peu de termes → 0 (et non une moyenne sur 1 terme).
                // Conséquence attendue et voulue : sur un morceau plus court
                // que ≈ 2 × 0,71 × 32 ≈ 46 spans, le kernel de section est
                // identiquement nul → aucune frontière de section, le morceau
                // forme UNE section (StructureBuilder gère déjà ce cas). La
                // courbe combinée reste correcte : une courbe identiquement
                // nulle contribue 0 à la moyenne des kernels, et la
                // normalisation finale par le maximum annule exactement l'effet
                // du diviseur — le résultat est le même qu'avec 3 kernels.
                curve[index] = terms >= minimumTerms ? max(sum / Double(terms), 0) : 0
            }
            perKernelRaw.append(curve)
        }
        // Courbe combinée : chaque kernel normalisé par SON maximum pour
        // peser pareil, puis moyenne et normalisation finale (relative au
        // morceau, §17 dernier alinéa).
        let perKernelScaled = perKernelRaw.map { curve -> [Double] in
            let maximum = curve.max() ?? 0
            guard maximum > 1e-9 else { return curve }
            return curve.map { $0 / maximum }
        }
        var combined = [Double](repeating: 0, count: count)
        for index in 0..<count {
            var sum = 0.0
            for curve in perKernelScaled { sum += curve[index] }
            combined[index] = sum / Double(perKernelScaled.count)
        }
        let maximum = combined.max() ?? 0
        if maximum > 1e-9 {
            combined = combined.map { $0 / maximum }
        }
        return (combined, perKernelRaw)
    }

    /// Peak picking sur la nouveauté combinée : maximum local, réponse brute
    /// du kernel dominant au-dessus d'un seuil ABSOLU, puis nouveauté
    /// normalisée au-dessus de la tendance locale → frontière (§22.2 : force
    /// locale, portée = kernel dominant, confiance). `perKernel` contient les
    /// réponses BRUTES des kernels (échelle commune) : la dominance ET la
    /// condition absolue s'y comparent directement.
    ///
    /// Le détecteur PEUT ne rien retourner : une boucle homogène n'a aucune
    /// frontière, et `StructureBuilder` traite alors le morceau comme une
    /// section unique (§63) — c'est le comportement voulu, pas un cas dégradé.
    private static func pickBoundaries(
        novelty: [Double],
        perKernel: [[Double]],
        halfWidths: [Int],
        gridTimes: [MediaTime]
    ) -> [StructuralBoundary] {
        let count = novelty.count
        guard count > 2 else { return [] }
        var boundaries: [StructuralBoundary] = []
        for index in 1..<count {
            let value = novelty[index]
            guard value > 0 else { continue }
            // Maximum local sur ±2 spans.
            var isLocalMax = true
            for offset in -2...2 where offset != 0 {
                let neighbor = index + offset
                guard neighbor >= 1, neighbor < count else { continue }
                if novelty[neighbor] > value
                    || (novelty[neighbor] == value && neighbor < index) {
                    isLocalMax = false
                    break
                }
            }
            guard isLocalMax else { continue }

            // Portée structurelle : kernel dominant (4, 8, 16 ou 64 temps),
            // déterminé sur les réponses BRUTES (échelle commune). Départage
            // explicite à égalité : `>` strict conserve le PREMIER kernel
            // atteignant le maximum, donc la plus PETITE échelle — une
            // égalité parfaite ne doit jamais promouvoir une phrase en
            // section (déterminisme, aucune dépendance à l'ordre d'itération).
            var dominantKernelIndex = 0
            var dominantResponse = -Double.infinity
            for kernelIndex in perKernel.indices
            where kernelIndex < halfWidths.count && perKernel[kernelIndex][index] > dominantResponse {
                dominantResponse = perKernel[kernelIndex][index]
                dominantKernelIndex = kernelIndex
            }
            // Aucune courbe exploitable (cas impossible avec `kernelHalfWidths`
            // constante, mais la borne évite tout accès hors plage) : pas de
            // frontière plutôt qu'une portée inventée.
            guard dominantKernelIndex < halfWidths.count, dominantResponse > -Double.infinity else { continue }
            let dominantHalfWidth = halfWidths[dominantKernelIndex]
            let kernelSize = dominantHalfWidth * 2

            // Condition ABSOLUE (correctif 3) : la réponse brute du kernel
            // dominant doit dépasser `minimumRawNoveltyResponse`. Les deux
            // seuils ci-dessous sont RELATIFS (`novelty` est normalisée par
            // son propre maximum, deux fois) et ne peuvent donc pas, seuls,
            // rendre zéro frontière : sur une boucle homogène — 90 s prélevées
            // dans un drop, l'usage visé — ils promeuvent les pics de bruit en
            // frontières de rang 0. C'est ce garde-ci, et lui seul, qui permet
            // au détecteur de ne rien émettre.
            guard dominantResponse >= Self.minimumRawNoveltyResponse else { continue }

            // Seuil adaptatif : au-dessus de la moyenne locale (±8 spans).
            let windowStart = max(index - 8, 1)
            let windowEnd = min(index + 8, count - 1)
            var localSum = 0.0
            for neighbor in windowStart...windowEnd { localSum += novelty[neighbor] }
            let localMean = localSum / Double(windowEnd - windowStart + 1)
            guard value >= max(0.3, localMean * 1.2) else { continue }
            // Confiance : heuristique déterministe fondée sur la force —
            // jamais 1,0 au niveau A (moteur simple, §15).
            let confidence = min(0.3 + 0.6 * value, 0.9)
            boundaries.append(StructuralBoundary(
                spanIndex: index,
                time: gridTimes[index],
                strength: value,
                dominantKernelSize: kernelSize,
                // Portée de SECTION réservée à l'échelle longue (correctif 1) :
                // seul un kernel de 64 temps = 16 mesures atteste d'une
                // section. Les kernels 4/8/16 temps mesurent une phrase, et
                // c'est précisément l'ancien `kernelSize >= 16` qui faisait
                // passer une alternance A/B de 4 mesures pour une section.
                isSectionScope: dominantHalfWidth >= Self.sectionKernelHalfWidth,
                confidence: confidence
            ))
        }
        // Séparation minimale des frontières de section
        // (`minimumSectionSeparationSpans` = 32 spans) : garder la plus forte —
        // évite des « sections » plus courtes qu'une phrase.
        var filtered: [StructuralBoundary] = []
        for boundary in boundaries {
            if boundary.isSectionScope,
               let lastIndex = filtered.lastIndex(where: { $0.isSectionScope }),
               boundary.spanIndex - filtered[lastIndex].spanIndex < Self.minimumSectionSeparationSpans {
                if boundary.strength > filtered[lastIndex].strength {
                    filtered[lastIndex] = boundary
                }
                continue
            }
            filtered.append(boundary)
        }
        return filtered
    }
}
