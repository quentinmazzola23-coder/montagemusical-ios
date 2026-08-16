//
//  BeatTracker.swift
//  MontageMusical
//
//  Suivi de beats déterministe — spécification §19.1.5 (programmation
//  dynamique type Ellis, tolérante aux légères variations de tempo)
//  et §20 niveau A (mesures candidates 2/3/4, alignement des accents,
//  downbeats et mesures).
//

import Foundation

// Non défini par la spécification — définition minimale V1.
/// Résultat du suivi d'une hypothèse rythmique : beats, mesures et
/// hypothèse complétée par la mesure retenue.
struct TrackedRhythm: Sendable {
    let hypothesis: RhythmHypothesis
    let beats: [BeatEvent]
    let bars: [BarEvent]
    /// 2, 3 ou 4 au niveau A (§20).
    let meterNumerator: Int
    /// Marge relative entre la meilleure mesure candidate et la deuxième :
    /// `(meilleur − second) / meilleur`.
    ///
    /// ATTENTION — c'est une **marge inter-hypothèses de métrique**, PAS une
    /// confiance de position. Elle répond à « de combien la mesure retenue
    /// devance-t-elle la deuxième candidate ? », jamais à « à quel point le
    /// début de mesure est-il temporellement sûr ? ». Elle est
    /// structurellement bornée bas : sur un 4/4 dont le temps 1 porte un
    /// accent de +20 %, elle plafonne vers 0,08 ; sur un 4-on-the-floor
    /// rigoureusement uniforme elle vaut 0.
    ///
    /// Elle n'est donc JAMAIS recopiée dans `BarEvent.confidence`
    /// (voir `barConfidence` dans `track`) : son seul consommateur légitime
    /// est `confidenceBreakdown.rhythm`, qui pondère précisément la
    /// probabilité de l'hypothèse par la sûreté du CHOIX de la métrique.
    let downbeatConfidence: Double
}

/// Suiveur de beats déterministe (spec §19.1.5 + §20 niveau A).
///
/// Programmation dynamique type Ellis sur l'enveloppe d'onsets :
/// `score(t) = enveloppe(t) + max sur τ ∈ [t−2p, t−p/2] de
/// (score(τ) − λ·(log((t−τ)/p))²)` avec `p` la période du tempo et
/// λ ≈ 4 — la séquence suit de légères variations de tempo.
struct BeatTracker: Sendable {

    init() {}

    // MARK: - Constantes

    /// Pénalité de déviation de période (type Ellis), λ ≈ 4.
    private static let lambda = 4.0
    /// Mesures candidates au niveau A (§20) : 2, 3 ou 4 temps.
    private static let meterCandidates = [2, 3, 4]
    /// Mesure par défaut quand aucun beat n'est disponible (confiance 0).
    private static let fallbackMeter = 4

    /// Fraction du maximum d'enveloppe exigée d'une frame pour qu'elle
    /// puisse SERVIR DE DÉPART au backtrack. 0,10 : assez bas pour accepter
    /// un coup faible en fin de morceau, assez haut pour rejeter le bruit
    /// de fond (que `OnsetDetector` plafonne déjà à quelques centièmes).
    /// Voir le commentaire du backtrack pour la démonstration.
    private static let startFloorRatio = 0.10

    // MARK: - API

    /// Suit l'hypothèse rythmique sur l'enveloppe d'onsets et estime la
    /// mesure au niveau A. Enveloppe vide ou plate → aucun beat, aucune
    /// mesure, confiance 0 (jamais de résultats factices, §0.7).
    func track(
        hypothesis: RhythmHypothesis,
        envelope: [Float],
        envelopeRate: Double,
        features: FeatureTimeline
    ) -> TrackedRhythm {
        let frameCount = envelope.count
        guard frameCount > 0,
              envelopeRate > 0,
              hypothesis.tempoBPM > 0,
              let envelopeMax = envelope.max(),
              envelopeMax > 0 else {
            return TrackedRhythm(
                hypothesis: hypothesis,
                beats: [],
                bars: [],
                meterNumerator: Self.fallbackMeter,
                downbeatConfidence: 0
            )
        }

        // Enveloppe normalisée 0…1 (score DP et force des beats).
        let maxValue = Double(envelopeMax)
        let env = envelope.map { Double($0) / maxValue }

        // ---- §19.1.5 — programmation dynamique type Ellis ----
        let period = envelopeRate * 60.0 / hypothesis.tempoBPM
        let windowLow = max(1, Int((period / 2).rounded(.down)))
        let windowHigh = max(windowLow + 1, Int((2 * period).rounded(.up)))

        var score = [Double](repeating: 0, count: frameCount)
        var backlink = [Int](repeating: -1, count: frameCount)
        for t in 0..<frameCount {
            var best = 0.0 // démarrage libre : un antérieur n'est retenu que s'il apporte un gain
            var bestTau = -1
            if t >= windowLow {
                let low = max(0, t - windowHigh)
                let high = t - windowLow
                for tau in low...high {
                    let delta = Double(t - tau)
                    let deviation = log(delta / period)
                    let value = score[tau] - Self.lambda * deviation * deviation
                    if value > best {
                        best = value
                        bestTau = tau
                    }
                }
            }
            score[t] = env[t] + best
            backlink[t] = bestTau
        }

        // Backtrack depuis le meilleur score de la dernière période — mais
        // en exigeant que la frame de départ porte un ÉVÉNEMENT.
        //
        // `score` est cumulatif : dans la queue du morceau il vaut à peu
        // près la même chose partout, puisque toutes les frames héritent du
        // score accumulé sur les beats précédents. L'argmax sur la dernière
        // période ne se joue donc que sur le terme LOCAL `env[t]`. Si cette
        // fenêtre ne contient aucune attaque — fin en fade-out, en silence,
        // ou simplement queue plus courte qu'une période après le dernier
        // coup — l'argmax tombe sur un maximum de BRUIT, et le dernier beat
        // est posé n'importe où dans la fenêtre : jusqu'à une demi-période
        // hors phase. Tout le backtrack étant chaîné par `backlink`, une
        // seule frame de départ fausse décale la grille entière.
        //
        // Correctif : on ne retient comme départ qu'une frame dont
        // l'enveloppe atteint `startFloorRatio` du maximum, et on élargit la
        // fenêtre période par période vers l'arrière tant qu'aucune ne
        // qualifie. Repli sur l'argmax brut si le morceau entier est sous le
        // plancher (enveloppe plate — cas déjà traité en amont, gardé ici
        // pour ne jamais rendre de grille vide).
        let periodFrames = max(1, Int(period.rounded()))
        let startFloor = (env.max() ?? 0) * Self.startFloorRatio

        var cursor = -1
        var windowStart = max(0, frameCount - periodFrames)
        var windowEnd = frameCount
        while cursor < 0 && windowEnd > 0 {
            for t in windowStart..<windowEnd where env[t] >= startFloor {
                if cursor < 0 || score[t] > score[cursor] { cursor = t }
            }
            windowEnd = windowStart
            windowStart = max(0, windowStart - periodFrames)
        }
        if cursor < 0 {
            cursor = max(0, frameCount - periodFrames)
            for t in cursor..<frameCount where score[t] > score[cursor] {
                cursor = t
            }
        }
        var beatFrames: [Int] = []
        var walk = cursor
        while walk >= 0 {
            beatFrames.append(walk)
            walk = backlink[walk]
        }
        beatFrames.reverse()

        // Confiance = cohérence des intervalles
        // (1 − écart-type relatif des périodes, borné 0…1).
        var coherence = 0.0
        if beatFrames.count >= 3 {
            let intervals = zip(beatFrames.dropFirst(), beatFrames).map { Double($0 - $1) }
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            if mean > 0 {
                let variance = intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                    / Double(intervals.count)
                coherence = min(1, max(0, 1 - variance.squareRoot() / mean))
            }
        }

        let beats = beatFrames.map { frame in
            BeatEvent(
                // Conversion frame → ticks par l'utilitaire UNIQUE du moteur
                // (règle transverse Jalon 4, arrondi ,5 supérieur).
                time: FeatureTimeline.mediaTime(forFrame: Double(frame), frameRate: envelopeRate),
                strength: min(1, max(0, env[frame])),
                confidence: coherence
            )
        }

        // ---- §20 niveau A — mesures candidates 2/3/4 ----
        // Score d'alignement d'un couple (mesure m, décalage) : somme de
        // (énergie basse bande 20–120 Hz + force d'onset) aux beats
        // downbeat-candidats, normalisée par leur nombre afin de comparer
        // équitablement des mesures de longueurs différentes.
        let bassBand = features.bandEnergies.first ?? []
        var bassAtBeat = beatFrames.map { frame -> Double in
            guard !bassBand.isEmpty else { return 0 }
            let featureFrame = Int(((Double(frame) / envelopeRate) * features.frameRate).rounded())
            // Sur audio réel, le beat suivi jitte de ±1 frame : une lecture à
            // la frame exacte annulerait la contribution basse dès que le
            // pic 20–120 Hz tombe à côté — on lit donc le MAXIMUM de la
            // basse bande sur ±2 frames autour de la frame convertie.
            let low = max(featureFrame - 2, 0)
            let high = min(featureFrame + 2, bassBand.count - 1)
            guard low <= high else { return 0 }
            var maximum: Float = 0
            for index in low...high { maximum = max(maximum, bassBand[index]) }
            return Double(maximum)
        }
        if let maxBass = bassAtBeat.max(), maxBass > 0 {
            bassAtBeat = bassAtBeat.map { $0 / maxBass }
        }
        let onsetAtBeat = beatFrames.map { env[$0] }

        var bestMeter = Self.fallbackMeter
        var bestOffset = 0
        var bestScore = -1.0
        var secondScore = -1.0
        for meter in Self.meterCandidates {
            for offset in 0..<meter {
                var total = 0.0
                var count = 0
                var beatIndex = offset
                while beatIndex < beatFrames.count {
                    total += bassAtBeat[beatIndex] + onsetAtBeat[beatIndex]
                    count += 1
                    beatIndex += meter
                }
                guard count > 0 else { continue }
                let alignment = total / Double(count)
                if alignment > bestScore {
                    secondScore = bestScore
                    bestScore = alignment
                    bestMeter = meter
                    bestOffset = offset
                } else if alignment > secondScore {
                    secondScore = alignment
                }
            }
        }

        // downbeatConfidence = marge relative entre meilleur et deuxième.
        var downbeatConfidence = 0.0
        if bestScore > 0, secondScore >= 0 {
            downbeatConfidence = min(1, max(0, (bestScore - secondScore) / bestScore))
        }

        // ---- Confiance d'un BarEvent = confiance de POSITION ----
        //
        // Défaut corrigé : `downbeatConfidence` était recopiée telle quelle
        // dans chaque `BarEvent`. Or c'est une MARGE INTER-HYPOTHÈSES DE
        // MÉTRIQUE (« la mesure 4 l'emporte-t-elle nettement sur la 3 ? »),
        // structurellement bornée à ~0,03–0,10 même sur un 4/4 parfaitement
        // détecté — et exactement 0 sur un 4-on-the-floor uniforme.
        // `AnchorField` lit `bar.confidence` comme la confiance de POSITION
        // de l'ancre « Downbeat » et en tire, avec `uncertaintyPenalty` = 1,
        // `uncertainty = 1 − confidence` ≈ 0,92 — contre ≈ 0,1 pour l'ancre
        // de beat co-localisée (qui porte, elle, la cohérence des
        // intervalles). Chaque début de mesure devenait ainsi l'ancre la
        // plus FAIBLE du niveau beat et le générateur évitait de couper sur
        // le « 1 » : l'inverse exact de ce qu'on veut sur de l'EDM.
        //
        // Ce qu'un `BarEvent` affirme d'abord, c'est la position de son
        // début — et ce début EST le temps `beats[downbeatIndices[k]]`,
        // construit à partir de la même frame. Sa position est donc
        // exactement aussi sûre que celle de ce beat, c'est-à-dire
        // `coherence` (cohérence des intervalles de la grille, §19.1.5).
        // La marge métrique ne peut que RENFORCER cette certitude — elle
        // dit que le beat retenu est bien un « 1 » —, jamais l'affaiblir.
        // D'où la combinaison monotone, bornée 0…1 par construction :
        //
        //     barConfidence = coherence + (1 − coherence) × downbeatConfidence
        //
        // - vaut EXACTEMENT `coherence` quand rien ne distingue les temps
        //   (`downbeatConfidence` = 0) : aucune certitude inventée (§63) ;
        // - n'est JAMAIS inférieure à la confiance du beat co-localisé
        //   (invariant couvert par `BeatTrackerTests`) ;
        // - tend vers 1 quand la mesure s'impose nettement.
        //
        // `downbeatConfidence` reste rendue telle quelle par `TrackedRhythm`
        // pour `confidenceBreakdown.rhythm`, où elle a un sens réel.
        let barConfidence = min(1, max(0, coherence + (1 - coherence) * downbeatConfidence))

        // Bars : BarEvent successifs entre downbeats (index croissant).
        // Les beats situés avant le premier downbeat ne sont rattachés à
        // aucune mesure : les bars commencent au premier downbeat.
        var downbeatIndices: [Int] = []
        var downbeatIndex = bestOffset
        while downbeatIndex < beats.count {
            downbeatIndices.append(downbeatIndex)
            downbeatIndex += bestMeter
        }
        var bars: [BarEvent] = []
        if downbeatIndices.count >= 2 {
            for barIndex in 0..<(downbeatIndices.count - 1) {
                bars.append(BarEvent(
                    start: beats[downbeatIndices[barIndex]].time,
                    end: beats[downbeatIndices[barIndex + 1]].time,
                    index: barIndex,
                    confidence: barConfidence
                ))
            }
        }

        // Hypothèse d'entrée complétée (§20) : mesure retenue, dénominateur 4.
        let completedHypothesis = RhythmHypothesis(
            id: hypothesis.id,
            tempoBPM: hypothesis.tempoBPM,
            tempoCurve: hypothesis.tempoCurve,
            meterNumerator: bestMeter,
            meterDenominator: 4,
            phaseOffset: hypothesis.phaseOffset,
            probability: hypothesis.probability,
            halfTimeRelation: hypothesis.halfTimeRelation,
            doubleTimeRelation: hypothesis.doubleTimeRelation
        )

        return TrackedRhythm(
            hypothesis: completedHypothesis,
            beats: beats,
            bars: bars,
            meterNumerator: bestMeter,
            downbeatConfidence: downbeatConfidence
        )
    }
}
