//
//  BeatSyncFeatures.swift
//  MontageMusical
//
//  Synchronisation des caractéristiques sur les beats (Jalon 4, niveau A) :
//  - §21 : agrégation des caractéristiques ENTRE beats (moyenne, maximum,
//    pente par bande + rms + flux) → un vecteur par beat ;
//  - §22.1 : matrice de similarité au niveau BEAT uniquement — jamais de
//    matrice frame × frame (§67, §68) ;
//  - §22.2 : courbe de nouveauté par kernel en damier (checkerboard) le long
//    de la diagonale, plusieurs tailles (4, 8, 16 beats) ; les pics
//    deviennent des frontières avec force locale, portée structurelle
//    (taille de kernel dominante) et confiance.
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
    /// Portée structurelle : taille du kernel dominant — 4, 8 ou 16 beats.
    let dominantKernelSize: Int
    /// Vrai si la frontière est de grande portée (section), faux si de
    /// petite portée (phrase).
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
    /// pente ; puis moyenne RMS et moyenne du flux spectral.
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
    /// Demi-largeurs des kernels en damier : kernels de 4, 8 et 16 beats.
    private static let kernelHalfWidths = [2, 4, 8]
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

        // 3. §21 : vecteurs par span — moyenne/max/pente par bande + rms + flux.
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
                vector.append(stats.slope)
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
        let slope: Float
    }

    /// Moyenne, maximum et pente (différence des moyennes des deux moitiés)
    /// d'une caractéristique sur une plage de frames. Plage vide → zéros.
    private static func aggregate(_ values: [Float], over range: Range<Int>) -> SpanStats {
        let clamped = max(range.lowerBound, 0)..<min(range.upperBound, values.count)
        guard clamped.lowerBound < clamped.upperBound else {
            return SpanStats(mean: 0, maximum: 0, slope: 0)
        }
        var sum: Float = 0
        var maximum: Float = -.greatestFiniteMagnitude
        for index in clamped {
            sum += values[index]
            maximum = max(maximum, values[index])
        }
        let count = clamped.count
        let mean = sum / Float(count)
        // Pente simple et robuste : moyenne seconde moitié − première moitié.
        let middle = clamped.lowerBound + count / 2
        var firstSum: Float = 0
        var secondSum: Float = 0
        for index in clamped.lowerBound..<middle { firstSum += values[index] }
        for index in middle..<clamped.upperBound { secondSum += values[index] }
        let firstCount = max(middle - clamped.lowerBound, 1)
        let secondCount = max(clamped.upperBound - middle, 1)
        let slope = secondSum / Float(secondCount) - firstSum / Float(firstCount)
        return SpanStats(mean: mean, maximum: maximum, slope: slope)
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
                curve[index] = terms > 0 ? max(sum / Double(terms), 0) : 0
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

    /// Peak picking sur la nouveauté combinée : maximum local au-dessus de
    /// la tendance locale → frontière (§22.2 : force locale, portée =
    /// kernel dominant, confiance). `perKernel` contient les réponses
    /// BRUTES des kernels (échelle commune) : la dominance s'y compare
    /// directement.
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
            // Seuil adaptatif : au-dessus de la moyenne locale (±8 spans).
            let windowStart = max(index - 8, 1)
            let windowEnd = min(index + 8, count - 1)
            var localSum = 0.0
            for neighbor in windowStart...windowEnd { localSum += novelty[neighbor] }
            let localMean = localSum / Double(windowEnd - windowStart + 1)
            guard value >= max(0.3, localMean * 1.2) else { continue }

            // Portée structurelle : kernel dominant (4, 8 ou 16 beats).
            var dominantKernelIndex = 0
            var dominantResponse = -Double.infinity
            for kernelIndex in perKernel.indices where perKernel[kernelIndex][index] > dominantResponse {
                dominantResponse = perKernel[kernelIndex][index]
                dominantKernelIndex = kernelIndex
            }
            let kernelSize = halfWidths[dominantKernelIndex] * 2
            // Confiance : heuristique déterministe fondée sur la force —
            // jamais 1,0 au niveau A (moteur simple, §15).
            let confidence = min(0.3 + 0.6 * value, 0.9)
            boundaries.append(StructuralBoundary(
                spanIndex: index,
                time: gridTimes[index],
                strength: value,
                dominantKernelSize: kernelSize,
                isSectionScope: kernelSize >= 16,
                confidence: confidence
            ))
        }
        // Séparation minimale des frontières de section (8 spans) : garder
        // la plus forte — évite des « sections » de deux beats.
        var filtered: [StructuralBoundary] = []
        for boundary in boundaries {
            if boundary.isSectionScope,
               let lastIndex = filtered.lastIndex(where: { $0.isSectionScope }),
               boundary.spanIndex - filtered[lastIndex].spanIndex < 8 {
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
