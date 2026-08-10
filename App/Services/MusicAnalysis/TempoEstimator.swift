//
//  TempoEstimator.swift
//  MontageMusical
//
//  Estimation déterministe du tempo — spécification §19.1 (niveau A).
//  Autocorrélation de l'enveloppe d'onsets, candidats 50–220 BPM,
//  renforcement harmonique, prior de tempo log-normal (type Ellis),
//  relations half/double-time, phase par peigne d'impulsions,
//  probabilités normalisées (somme = 1).
//

import Foundation

/// Estimateur de tempo déterministe (spec §19.1).
///
/// Entrée : l'enveloppe d'onsets globale produite par `OnsetDetector`
/// (une valeur positive par frame, à la cadence `envelopeRate`).
/// Sortie : hypothèses rythmiques triées par probabilité décroissante,
/// relations half/double-time renseignées par UUID.
///
/// Déterminisme : à enveloppe identique, tempos, phases et probabilités
/// identiques. Les UUID servent uniquement d'identité relationnelle et
/// sont créés à la construction des candidats (aucune horloge, aucun
/// aléatoire dans la logique DSP).
struct TempoEstimator: Sendable {

    init() {}

    // MARK: - Constantes (spec §19.1 : candidats typiquement 50–220 BPM)

    /// Borne basse des tempos candidats (BPM).
    private static let minBPM = 50.0
    /// Borne haute des tempos candidats (BPM).
    private static let maxBPM = 220.0
    /// Nombre maximal d'hypothèses conservées.
    private static let maxHypotheses = 6
    /// Nombre maximal de pics d'autocorrélation examinés.
    private static let maxRawPeaks = 8
    /// Deux candidats dont les BPM diffèrent de moins de 2 % sont fusionnés.
    private static let duplicateTolerance = 0.02
    /// Tolérance sur le ratio ≈ 2 pour une relation half/double-time.
    private static let doubleTimeRatioTolerance = 0.08

    // MARK: - Candidat interne

    private struct Candidate {
        let id: UUID
        let bpm: Double
        let lagFrames: Double
        let score: Double
        var phaseFrame: Int
        var halfTimeRelation: UUID?
        var doubleTimeRelation: UUID?
    }

    // MARK: - API

    /// Estime les tempos candidats à partir de l'enveloppe d'onsets (§19.1).
    ///
    /// Retourne les hypothèses triées par probabilité décroissante
    /// (au moins une si l'enveloppe n'est pas plate). Enveloppe plate,
    /// vide ou trop courte → tableau vide (§63 : rythme très faible,
    /// le niveau au-dessus produit une partition structurelle).
    func estimate(envelope: [Float], envelopeRate: Double) -> [RhythmHypothesis] {
        let frameCount = envelope.count
        guard frameCount > 0, envelopeRate > 0 else { return [] }

        // 1. Détendançage : retrait de la moyenne mobile locale (≈ 1 s),
        //    le signal devient de moyenne (localement) nulle.
        let detrended = Self.detrend(envelope, rate: envelopeRate)
        let energy = detrended.reduce(0) { $0 + $1 * $1 }
        guard energy / Double(frameCount) > 1e-12 else { return [] } // plate

        // 2. Autocorrélation normalisée sur les lags 50–220 BPM, étendue
        //    à 2 × le lag maximal pour le renforcement harmonique.
        let lagMin = max(2, Int((envelopeRate * 60.0 / Self.maxBPM).rounded()))
        let lagMaxIdeal = Int((envelopeRate * 60.0 / Self.minBPM).rounded())
        let maxLagNeeded = min(2 * lagMaxIdeal + 2, frameCount - 1)
        guard maxLagNeeded >= lagMin + 2 else { return [] }
        let lagMax = min(lagMaxIdeal, (frameCount - 1) / 2)
        guard lagMax > lagMin + 1 else { return [] }

        let meanSquare = energy / Double(frameCount)
        var acf = [Double](repeating: 0, count: maxLagNeeded + 1)
        acf[0] = 1
        for lag in 1...maxLagNeeded {
            var sum = 0.0
            for i in 0..<(frameCount - lag) {
                sum += detrended[i] * detrended[i + lag]
            }
            acf[lag] = (sum / Double(frameCount - lag)) / meanSquare
        }

        /// ACF à lag fractionnaire (interpolation linéaire), nil hors plage.
        func acfAt(_ lag: Double) -> Double? {
            guard lag >= 1 else { return nil }
            let base = Int(lag.rounded(.down))
            guard base + 1 <= maxLagNeeded else { return nil }
            let fraction = lag - Double(base)
            return acf[base] * (1 - fraction) + acf[base + 1] * fraction
        }

        // 3. Pics d'autocorrélation → tempos candidats, avec interpolation
        //    parabolique du lag pour la précision.
        guard let rangeMax = acf[lagMin...lagMax].max(), rangeMax > 0 else { return [] }
        var peaks: [(lag: Double, base: Double)] = []
        for lag in (lagMin + 1)..<lagMax {
            let previous = acf[lag - 1]
            let value = acf[lag]
            let next = acf[lag + 1]
            guard value > previous, value >= next, value > 0.2 * rangeMax else { continue }
            var refined = Double(lag)
            let curvature = previous - 2 * value + next
            if curvature < 0 {
                refined += 0.5 * (previous - next) / curvature
            }
            peaks.append((lag: refined, base: value))
        }
        guard !peaks.isEmpty else { return [] }
        peaks.sort { $0.base != $1.base ? $0.base > $1.base : $0.lag < $1.lag }
        peaks = Array(peaks.prefix(Self.maxRawPeaks))

        // 4. Score avec renforcement harmonique ASYMÉTRIQUE :
        //    score += 0,5·acf(2·lag) + 0,25·max(0, acf(lag/2)) si disponibles.
        //    Le bonus sous-harmonique (lag/2, soit 2× le tempo) est réduit à
        //    0,25 : à 0,5 symétrique, l'hypothèse half-time (lag 2L) cumule
        //    deux multiples pleins de la période — acf(L) via lag/2 et
        //    acf(4L) via 2·lag, score ≈ 2,0 — et bat systématiquement le
        //    vrai tempo (score ≈ 1,5, acf(L/2) ≈ 0 sur un signal pulsé).
        var candidates: [Candidate] = []
        for peak in peaks {
            var score = max(0, acfAt(peak.lag) ?? peak.base)
            if let harmonic = acfAt(peak.lag * 2) { score += 0.5 * max(0, harmonic) }
            if let harmonic = acfAt(peak.lag / 2) { score += 0.25 * max(0, harmonic) }
            let bpm = 60.0 * envelopeRate / peak.lag
            guard bpm >= Self.minBPM * 0.98, bpm <= Self.maxBPM * 1.02, score > 0 else { continue }
            // Prior de tempo log-normal standard type Ellis, centré 120 BPM,
            // σ = 0,5 octave, appliqué AVANT la normalisation des
            // probabilités : départage les familles half/double-time —
            // §19.1 conserve TOUTES les hypothèses avec leurs relations,
            // seul l'ordre (et donc l'hypothèse retenue) change.
            let priorWeight = exp(-0.5 * pow(log2(bpm / 120.0) / 0.5, 2))
            score *= priorWeight
            candidates.append(Candidate(
                id: UUID(),
                bpm: bpm,
                lagFrames: peak.lag,
                score: score,
                phaseFrame: 0,
                halfTimeRelation: nil,
                doubleTimeRelation: nil
            ))
        }
        guard !candidates.isEmpty else { return [] }

        // 5. Fusion des quasi-doublons (écart < 2 %), le meilleur score gagne.
        //    Tri déterministe : score décroissant, puis BPM croissant.
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.bpm < $1.bpm }
        var kept: [Candidate] = []
        for candidate in candidates
        where kept.allSatisfy({ abs(candidate.bpm - $0.bpm) / $0.bpm > Self.duplicateTolerance }) {
            kept.append(candidate)
        }
        kept = Array(kept.prefix(Self.maxHypotheses))

        // 6. Phase : corrélation croisée de l'enveloppe brute avec un
        //    peigne d'impulsions au tempo candidat.
        for index in kept.indices {
            kept[index].phaseFrame = Self.bestCombPhase(
                envelope: envelope,
                periodFrames: kept[index].lagFrames
            )
        }

        // 7. Relations half/double-time : appariement des paires (t, ≈ 2t)
        //    par écart croissant au ratio 2 (chaque extrémité au plus une fois).
        var matches: [(difference: Double, slow: Int, fast: Int)] = []
        for slow in kept.indices {
            for fast in kept.indices where fast != slow {
                let ratio = kept[fast].bpm / kept[slow].bpm
                let difference = abs(ratio - 2)
                if difference <= 2 * Self.doubleTimeRatioTolerance {
                    matches.append((difference: difference, slow: slow, fast: fast))
                }
            }
        }
        matches.sort {
            $0.difference != $1.difference
                ? $0.difference < $1.difference
                : ($0.slow, $0.fast) < ($1.slow, $1.fast)
        }
        for match in matches
        where kept[match.slow].doubleTimeRelation == nil && kept[match.fast].halfTimeRelation == nil {
            kept[match.slow].doubleTimeRelation = kept[match.fast].id
            kept[match.fast].halfTimeRelation = kept[match.slow].id
        }

        // 8. Probabilités normalisées (somme = 1), déjà triées en 5.
        let totalScore = kept.reduce(0) { $0 + $1.score }
        return kept.map { candidate in
            RhythmHypothesis(
                id: candidate.id,
                tempoBPM: candidate.bpm,
                // Niveau A : courbe de tempo constante.
                tempoCurve: [TimedValue(time: .zero, value: candidate.bpm)],
                // La mesure est estimée par `BeatTracker` (§20), pas ici.
                meterNumerator: nil,
                meterDenominator: nil,
                // Conversion frame → ticks par l'utilitaire UNIQUE du moteur
                // (règle transverse Jalon 4, arrondi ,5 supérieur).
                phaseOffset: FeatureTimeline.mediaTime(
                    forFrame: Double(candidate.phaseFrame),
                    frameRate: envelopeRate
                ),
                probability: candidate.score / totalScore,
                halfTimeRelation: candidate.halfTimeRelation,
                doubleTimeRelation: candidate.doubleTimeRelation
            )
        }
    }

    // MARK: - Aides privées

    /// Retrait de la tendance locale : soustraction de la moyenne mobile
    /// sur une fenêtre d'environ une seconde (spec §19.1, préalable à
    /// l'autocorrélation).
    private static func detrend(_ envelope: [Float], rate: Double) -> [Double] {
        let frameCount = envelope.count
        let window = max(1, Int(rate.rounded()))
        let halfWindow = window / 2
        var prefix = [Double](repeating: 0, count: frameCount + 1)
        for i in 0..<frameCount {
            prefix[i + 1] = prefix[i] + Double(envelope[i])
        }
        var result = [Double](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let low = max(0, i - halfWindow)
            let high = min(frameCount, i + halfWindow + 1)
            let localMean = (prefix[high] - prefix[low]) / Double(high - low)
            result[i] = Double(envelope[i]) - localMean
        }
        return result
    }

    /// Meilleur décalage (en frames entières) d'un peigne d'impulsions à la
    /// période donnée, par corrélation croisée avec l'enveloppe brute.
    /// Le peigne avance par pas fractionnaires pour éviter la dérive.
    private static func bestCombPhase(envelope: [Float], periodFrames: Double) -> Int {
        let frameCount = envelope.count
        let periodInt = max(1, Int(periodFrames.rounded()))
        var bestSum = -Double.infinity
        var bestPhase = 0
        for phase in 0..<min(periodInt, frameCount) {
            var sum = 0.0
            var position = Double(phase)
            while true {
                let index = Int(position.rounded())
                if index >= frameCount { break }
                sum += Double(envelope[index])
                position += periodFrames
            }
            if sum > bestSum {
                bestSum = sum
                bestPhase = phase
            }
        }
        return bestPhase
    }
}
