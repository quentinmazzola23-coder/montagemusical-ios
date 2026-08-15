//
//  OnsetDetector.swift
//  MontageMusical
//
//  Onsets et transitoires (Jalon 4, spec §79) — spec §18 : enveloppes par
//  bande, retrait de tendance locale, peak picking adaptatif, fusion des
//  pics proches. Un onset n'est jamais considéré comme un beat ou une
//  coupe (§18 dernier alinéa).
//

import Foundation

// Non defini par la specification — definition minimale V1.
/// Un onset détecté (spec §18.5 : temps, force, bande dominante, confiance).
struct OnsetEvent: Sendable, Equatable {
    /// Temps absolu en ticks canoniques (spec §9), via l'utilitaire unique
    /// `FeatureTimeline.mediaTime(forFrame:frameRate:)`.
    let time: MediaTime
    /// Force normalisée `0...1` relativement au morceau.
    let strength: Double
    /// Bande dominante `0...4` (bande §17 au flux détendancé maximal à cet
    /// instant).
    let dominantBand: Int
    /// Confiance `0...1` : force relative au voisinage.
    let confidence: Double
}

/// Détecteur d'onsets déterministe (niveau A, spec §15/§18).
///
/// Chaîne §18 : enveloppes par bande (`bandFlux` lissé) → retrait de
/// tendance locale (médiane glissante ~1 s, redressé) → peak picking
/// adaptatif (seuil = moyenne glissante + k × écart local) → fusion des
/// pics < 30 ms **par cluster** (garde le plus fort) : un cluster de fusion
/// ne peut jamais s'étendre au-delà de 30 ms, quel que soit le nombre de
/// candidats (voir `detectOnsets`, correctif 2 de la critique).
///
/// Retourne aussi l'enveloppe d'onsets globale (somme pondérée des
/// enveloppes de bande détendancées, ≥ 0, même cadence que la timeline) —
/// entrée du tempo §19.
struct OnsetDetector: Sendable {

    // Paramètres déterministes (aucun aléatoire, règle transverse Jalon 4).

    /// Pondération des bandes dans l'enveloppe globale : léger accent sur
    /// le grave (porteur du rythme, §20 « énergie basse bande ») et retrait
    /// de l'aigu (souffle). Déterministe.
    private static let bandWeights: [Float] = [1.25, 1, 1, 1, 0.75]

    /// Fusion des pics distants de moins de 30 ms (§18.4, contrat Jalon 4).
    /// Convertie en frames par ARRONDI (et non par troncature) : à
    /// 86,1328125 frames/s la fenêtre effective vaut 3 frames = 34,8 ms,
    /// c'est-à-dire la valeur représentable la plus proche des 30 ms
    /// déclarés — la troncature donnait 2 frames = 23,2 ms, soit une
    /// constante qui mentait de 23 %.
    private static let mergeWindowSeconds = 0.030

    /// Facteur k du seuil adaptatif (seuil = moyenne + k × écart local).
    private static let peakThresholdFactor: Float = 1.5

    /// Plancher absolu par bande : un pic doit atteindre 5 % du maximum de
    /// sa bande (rejette le bruit numérique d'une bande quasi silencieuse).
    private static let bandFloorRatio: Float = 0.05

    /// Plancher global : un onset doit atteindre 2 % du maximum de
    /// l'enveloppe globale (silence pur → aucun onset).
    private static let globalFloorRatio: Float = 0.02

    init() {}

    /// Détecte les onsets de la timeline (spec §18) et retourne l'enveloppe
    /// d'onsets globale (pour le tempo §19). Entièrement déterministe.
    func detectOnsets(features: FeatureTimeline) -> (onsets: [OnsetEvent], envelope: [Float]) {
        let frameCount = features.spectralFlux.count
        let bandCount = features.bandFlux.count
        guard frameCount > 0, bandCount > 0, features.frameRate > 0 else {
            return ([], [Float](repeating: 0, count: frameCount))
        }
        let frameRate = features.frameRate

        // §18.1–2 : enveloppe par bande = flux de bande lissé, puis retrait
        // de la tendance locale (médiane glissante ~1 s), redressé (≥ 0).
        let medianRadius = max(2, Int((0.5 * frameRate).rounded()))
        var detrended: [[Float]] = []
        detrended.reserveCapacity(bandCount)
        for band in 0..<bandCount {
            let smoothed = movingAverage(features.bandFlux[band], radius: 1)
            let trend = runningMedian(smoothed, radius: medianRadius)
            var values = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                values[frame] = max(0, smoothed[frame] - trend[frame])
            }
            detrended.append(values)
        }

        // Enveloppe globale : somme pondérée des enveloppes détendancées
        // (≥ 0), même frameRate que la timeline.
        var envelope = [Float](repeating: 0, count: frameCount)
        for band in 0..<bandCount {
            let weight = Self.bandWeights[min(band, Self.bandWeights.count - 1)]
            let values = detrended[band]
            for frame in 0..<frameCount {
                envelope[frame] += weight * values[frame]
            }
        }
        guard let envelopeMax = envelope.max(), envelopeMax > 1e-9 else {
            // Enveloppe plate (silence) : aucun onset.
            return ([], envelope)
        }

        // §18.3 : peak picking adaptatif, par bande.
        let thresholdRadius = max(2, Int((0.175 * frameRate).rounded()))
        var candidates: [(frame: Int, band: Int)] = []
        for band in 0..<bandCount {
            candidates.append(contentsOf: pickPeaks(
                in: detrended[band],
                band: band,
                thresholdRadius: thresholdRadius
            ))
        }
        candidates.sort { lhs, rhs in
            lhs.frame != rhs.frame ? lhs.frame < rhs.frame : lhs.band < rhs.band
        }

        // §18.4 : fusion des pics distants de < 30 ms, **par CLUSTER** et
        // non en chaîne — on garde la frame la plus forte du cluster (valeur
        // d'enveloppe globale ; égalité → frame la plus précoce,
        // déterministe, les candidats étant triés par frame croissante).
        //
        // POURQUOI un cluster et pas une chaîne (correctif 2 de la critique).
        // L'ancienne boucle comparait l'écart au candidat PRÉCÉDENT : une
        // suite de candidats espacés chacun de ≤ `mergeGap` collapsait
        // INTÉGRALEMENT en un seul onset, sans aucune borne de longueur. Un
        // roulement en 1/32 à 150 BPM place une note toutes les 4,3 frames
        // (11,6 ms/frame) et l'étalement inter-bandes d'une même note est de
        // 2 à 3 frames : la chaîne se refermait note après note et un
        // roulement entier de 16 notes rendait 1 à 3 onsets. Cascade :
        // `onsetDensity` CHUTAIT pendant le roulement au lieu d'y culminer,
        // et la source d'ancres « Attaque marquée » (§26.1) disparaissait
        // exactement là où le montage doit s'accélérer. En comparant au
        // PREMIER élément du cluster, la fenêtre de fusion est bornée à
        // `mergeGap` frames par construction : deux notes distantes de plus
        // de 30 ms restent deux onsets, quel que soit leur étalement interne.
        //
        // Vérifié numériquement (report de l'algorithme, 3 bandes décalées de
        // 0/+1/+2 frames, une note toutes les 4 frames sur 2 s) : fusion en
        // chaîne → 1 onset ; fusion par cluster → 39 onsets, soit exactement
        // une note sur une. Voir
        // `OnsetDetectorTests.testDenseRollIsNotCollapsedByOnsetMerging`.
        //
        // ARRONDI et non troncature : `Int(0,030 × 86,1328) = 2` frames =
        // 23,2 ms, alors que la constante déclare 30 ms (§18.4) ; l'arrondi
        // donne 3 frames = 34,8 ms, la valeur représentable la plus proche
        // des 30 ms annoncés à cette cadence. 3 frames restent strictement
        // sous les 4,3 frames qui séparent deux notes d'un roulement 1/32 à
        // 150 BPM — la borne haute utile de la fenêtre.
        let mergeGap = max(1, Int((Self.mergeWindowSeconds * frameRate).rounded()))
        var mergedFrames: [Int] = []
        var bestFrame = -1
        var bestValue: Float = 0
        var clusterStartFrame = Int.min
        for candidate in candidates {
            let value = envelope[candidate.frame]
            if bestFrame >= 0, candidate.frame - clusterStartFrame <= mergeGap {
                if value > bestValue {
                    bestValue = value
                    bestFrame = candidate.frame
                }
            } else {
                if bestFrame >= 0 { mergedFrames.append(bestFrame) }
                clusterStartFrame = candidate.frame
                bestFrame = candidate.frame
                bestValue = value
            }
        }
        if bestFrame >= 0 { mergedFrames.append(bestFrame) }
        // `mergedFrames` reste strictement croissant : le survivant d'un
        // cluster appartient à `[clusterStart, clusterStart + mergeGap]` et le
        // cluster suivant démarre au-delà de cette borne.

        // §18.5 : temps (ticks §9), force 0...1, bande dominante, confiance.
        let envelopeMean = movingAverage(envelope, radius: thresholdRadius)
        var onsets: [OnsetEvent] = []
        onsets.reserveCapacity(mergedFrames.count)
        for frame in mergedFrames {
            let value = envelope[frame]
            guard value >= Self.globalFloorRatio * envelopeMax else { continue }

            // Bande dominante = bande au flux (détendancé) maximal à cet
            // instant ; égalité → bande la plus basse, déterministe.
            var dominantBand = 0
            var dominantValue: Float = -1
            for band in 0..<bandCount where detrended[band][frame] > dominantValue {
                dominantValue = detrended[band][frame]
                dominantBand = band
            }

            // Confiance = force relative au voisinage : 1 − moyenne
            // locale / pic (pic isolé → ~1, pic noyé → ~0).
            let relative = 1 - envelopeMean[frame] / max(value, Float(1e-9))
            let confidence = Double(max(0, min(1, relative)))

            onsets.append(OnsetEvent(
                time: FeatureTimeline.mediaTime(forFrame: frame, frameRate: frameRate),
                strength: Double(value / envelopeMax),
                dominantBand: dominantBand,
                confidence: confidence
            ))
        }
        return (onsets, envelope)
    }

    // MARK: - Peak picking adaptatif (§18.3)

    /// Pics d'une enveloppe de bande : maximum local (±2 frames) au-dessus
    /// du seuil adaptatif `moyenne glissante + k × écart local` et du
    /// plancher de bande. Égalité de valeurs → seule la frame la plus
    /// précoce est retenue (déterministe).
    private func pickPeaks(
        in values: [Float],
        band: Int,
        thresholdRadius: Int
    ) -> [(frame: Int, band: Int)] {
        let frameCount = values.count
        guard frameCount > 2, let maxValue = values.max(), maxValue > 1e-9 else {
            return []
        }
        let localMean = movingAverage(values, radius: thresholdRadius)
        var deviation = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            deviation[frame] = abs(values[frame] - localMean[frame])
        }
        let localDeviation = movingAverage(deviation, radius: thresholdRadius)
        let floorValue = Self.bandFloorRatio * maxValue

        var peaks: [(frame: Int, band: Int)] = []
        for frame in 0..<frameCount {
            let value = values[frame]
            guard value >= floorValue,
                  value > localMean[frame]
                    + Self.peakThresholdFactor * localDeviation[frame] else {
                continue
            }
            var isLocalMax = true
            let lowerBound = max(0, frame - 2)
            let upperBound = min(frameCount - 1, frame + 2)
            for neighbor in lowerBound...upperBound where neighbor != frame {
                if values[neighbor] > value
                    || (values[neighbor] == value && neighbor < frame) {
                    isLocalMax = false
                    break
                }
            }
            if isLocalMax {
                peaks.append((frame: frame, band: band))
            }
        }
        return peaks
    }

    // MARK: - Utilitaires déterministes

    /// Moyenne glissante centrée (fenêtre `±radius`, bords rétrécis) via
    /// sommes préfixes en `Double` — O(n), ordre d'opérations fixe.
    private func movingAverage(_ values: [Float], radius: Int) -> [Float] {
        let count = values.count
        guard count > 0 else { return [] }
        var prefix = [Double](repeating: 0, count: count + 1)
        for index in 0..<count {
            prefix[index + 1] = prefix[index] + Double(values[index])
        }
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let lowerBound = max(0, index - radius)
            let upperBound = min(count - 1, index + radius)
            let sum = prefix[upperBound + 1] - prefix[lowerBound]
            result[index] = Float(sum / Double(upperBound - lowerBound + 1))
        }
        return result
    }

    /// Médiane glissante centrée (fenêtre `±radius`, bords rétrécis) par
    /// fenêtre triée entretenue (insertion/retrait dichotomiques) — O(n·w).
    private func runningMedian(_ values: [Float], radius: Int) -> [Float] {
        let count = values.count
        guard count > 0 else { return [] }
        let effectiveRadius = max(1, radius)
        var window: [Float] = []
        window.reserveCapacity(2 * effectiveRadius + 2)
        for index in 0...min(count - 1, effectiveRadius) {
            insertSorted(&window, values[index])
        }
        var result = [Float](repeating: 0, count: count)
        result[0] = window[window.count / 2]
        for index in 1..<count {
            let incoming = index + effectiveRadius
            if incoming < count {
                insertSorted(&window, values[incoming])
            }
            let outgoing = index - effectiveRadius - 1
            if outgoing >= 0 {
                removeSorted(&window, values[outgoing])
            }
            result[index] = window[window.count / 2]
        }
        return result
    }

    /// Insertion dans un tableau trié (borne inférieure dichotomique).
    private func insertSorted(_ window: inout [Float], _ value: Float) {
        var low = 0
        var high = window.count
        while low < high {
            let mid = (low + high) / 2
            if window[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        window.insert(value, at: low)
    }

    /// Retrait d'une occurrence d'une valeur d'un tableau trié.
    private func removeSorted(_ window: inout [Float], _ value: Float) {
        var low = 0
        var high = window.count
        while low < high {
            let mid = (low + high) / 2
            if window[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low < window.count, window[low] == value {
            window.remove(at: low)
        }
    }
}
