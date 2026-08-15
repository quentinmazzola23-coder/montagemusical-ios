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
//  ARBITRAGE D'OCTAVE ET D'ALIAS (révision) — le score précédent
//  `acf(L) + 0,5·acf(2L) + 0,25·acf(L/2)` accordait au half-time un bonus
//  STRUCTUREL : sur une pulsation régulière tous les multiples entiers de la
//  période ont sensiblement la même ACF `a`, le vrai tempo marquait 1,5·a
//  (acf(L/2) ≈ 0 sur un signal pulsé) et son half-time 1,75·a — car pour lui
//  le terme « lag/2 » retombe sur le vrai tempo et vaut `a` au lieu de 0.
//  Restait un facteur 1,1667 en faveur du half-time, que seul le prior
//  compensait, et seulement jusqu'à 165,3 BPM. Au-delà l'estimateur rendait
//  la moitié du tempo (174 → 87, 180 → 90, 200 → 100) ; avec une couche de
//  contretemps il rendait même une grille NON MÉTRIQUE à 2/3 du tempo
//  (174 → 116, 180 → 120), c'est-à-dire une pulsation sur trois.
//  Quatre correctifs, décrits en détail à leur point d'application :
//    (1) le score est une MOYENNE PONDÉRÉE et non une somme ;
//    (2) le terme sous-harmonique devient une PÉNALITÉ conditionnelle
//        et non un bonus (c'est lui qui portait l'inversion de signe) ;
//    (3) les candidats sont restreints aux lags en relation ENTIÈRE avec la
//        pulsation la plus rapide détectée — ce qui supprime l'alias 2/3 ;
//    (4) le prior est élargi à σ = 0,9 octave.
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

    // MARK: - Constantes d'arbitrage d'octave (correctifs 1 à 4)

    /// Centre du prior de tempo log-normal (BPM).
    ///
    /// Volontairement laissé à 120 et NON recentré sur le corpus visé
    /// (hardstyle 150-160, DnB 174, uptempo 180+) : un prior symétrique en
    /// log ne lève l'ambiguïté d'octave que sur la fenêtre [c/√2 ; c·√2],
    /// soit [84,9 ; 169,7] BPM ici. Recentrer sur 150 déplacerait la fenêtre
    /// sur [106 ; 212] et ferait basculer en double-time toute musique sous
    /// 106 BPM. C'est le SCORE, pas le centre, qui doit discriminer au-delà
    /// de 169,7 BPM — voir la pénalité sous-harmonique plus bas.
    private static let priorCenterBPM = 120.0

    /// Écart-type du prior, en OCTAVES.
    ///
    /// Porté de 0,5 à 0,9 : σ = 0,5 est un prior de musique généraliste qui
    /// écrase le corpus visé (prior(200) = 0,3375 contre 0,7152 à σ = 0,9).
    /// L'élargissement ne suffit pas seul à réparer l'octave — il ne fait
    /// même que RAPPROCHER le point de bascule (165,3 → 155,6 BPM à score
    /// inchangé) — mais il divise par deux l'effort demandé au score :
    /// le rapport score_vrai/score_half nécessaire pour retenir le vrai
    /// tempo tombe de 2,580 à 1,340 à 200 BPM, de 1,405 à 1,111 à 180 BPM.
    ///
    /// Valeurs du prior (centre 120, σ = 0,9) :
    ///   75 BPM → 0,7529 · 120 → 1,0000 · 150 → 0,9380
    ///  174 BPM → 0,8375 · 200 → 0,7152
    ///
    /// Rapport prior(B)/prior(B/2) sur la plage 140-190 BPM, c'est-à-dire ce
    /// que le score doit compenser pour que B batte son half-time :
    ///   140 → 1,409 · 150 → 1,246 · 160 → 1,111 · 170 → 0,997
    ///   174 → 0,956 · 180 → 0,900 · 190 → 0,818
    /// Le prior reste donc favorable au vrai tempo jusqu'à 170 BPM ; de 170 à
    /// 190 il devient défavorable d'au plus 1,223, et la pénalité
    /// sous-harmonique (facteur 2) couvre ce déficit avec une marge de 1,64×
    /// à 190 BPM et de 1,49× à 200 BPM.
    private static let priorSigmaOctaves = 0.9

    /// Tolérance RELATIVE d'écart à l'entier pour la relation candidat ↔ ancre.
    ///
    /// 4 % : la période d'un lag candidat est déjà raffinée par interpolation
    /// parabolique (précision typique ≪ 1 frame), mais un multiple d'ordre k
    /// cumule l'erreur k fois. La tolérance est donc proportionnelle à
    /// l'entier visé (4 % de k et non 4 % absolus). Elle reste bien en deçà
    /// de l'écart à discriminer : l'alias 2/3 se présente à un ratio 1,5,
    /// distant de 33 % de l'entier le plus proche.
    private static let integerRelationTolerance = 0.04

    /// Un pic d'ACF n'est éligible comme ancre de la relation entière que
    /// s'il atteint cette fraction du maximum d'ACF de la plage.
    private static let anchorStrengthRatio = 0.5

    /// Tolérance relative pour reconnaître un pic d'ACF à la moitié d'un lag.
    private static let subharmonicPeakTolerance = 0.05

    /// Un candidat est pénalisé si le pic situé à la moitié de sa période
    /// atteint cette fraction de sa propre ACF (voir la pénalité plus bas).
    private static let subharmonicDominanceRatio = 0.9

    /// Diviseur appliqué au score d'un candidat dont la demi-période porte
    /// une pulsation aussi forte que la sienne (score divisé par 1 + 1 = 2).
    private static let subharmonicPenalty = 1.0

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

        // 3 bis. CORRECTIF (3) — restriction aux lags en relation ENTIÈRE avec
        //    la pulsation détectée la plus rapide.
        //
        //    C'est le correctif qui tue l'alias 2/3, que ni la normalisation
        //    ni le prior ne traitent : avec des contretemps (hi-hats sur la
        //    croche, omniprésents en hardstyle/DnB), le pic d'ACF à 1,5·L est
        //    légitime — les kicks y tombent sur les hats — et le prior le fait
        //    gagner dès ~155 BPM. Or 1,5·L n'est ni le tempo ni son half-time :
        //    c'est une grille qui dérive contre la musique une pulsation sur
        //    trois. Un multiple non entier de la pulsation est musicalement
        //    impossible ; on l'écarte donc par construction.
        //
        //    ANCRE = le plus COURT des pics forts, et non le plus FORT.
        //    Mesuré : sur 174 BPM + contretemps, le pic d'ACF le plus fort est
        //    à 3·L (lag 89, acf 0,977) et non à L (lag 30, acf 0,936) — les
        //    lags longs captent tous les niveaux métriques à la fois. Ancré
        //    sur 3·L, le filtre REJETTE le half-time légitime (59/89 = 1,508)
        //    et CONSERVE l'alias 2/3 (45/89 = 1,978 ≈ 2, puisque 1,5·L = 3·L/2)
        //    — exactement l'inverse du but recherché. Ancré sur le plus court
        //    lag fort, la propriété de sûreté est retrouvée : tout niveau
        //    métrique est un multiple ENTIER de la pulsation la plus rapide,
        //    donc le vrai tempo ne peut jamais être éliminé par ce filtre.
        //
        //    CAS DÉGÉNÉRÉ (§63 : ne jamais inventer, ne jamais perdre) : si
        //    aucun pic n'atteint le seuil de force, ou si le filtre laisse
        //    moins de deux candidats, on garde la liste NON filtrée.
        var anchorLag: Double?
        for peak in peaks where peak.base >= Self.anchorStrengthRatio * rangeMax {
            // Les lags des pics sont deux à deux distincts : aucun départage
            // supplémentaire n'est nécessaire, le minimum est unique.
            if let current = anchorLag {
                if peak.lag < current { anchorLag = peak.lag }
            } else {
                anchorLag = peak.lag
            }
        }
        if peaks.count >= 2, let anchor = anchorLag {
            let related = peaks.filter { Self.isIntegerRelated($0.lag, to: anchor) }
            if related.count >= 2 { peaks = related }
        }
        let scoredPeaks = peaks

        /// Pic d'ACF le plus fort situé à ±5 % du lag visé, s'il en existe un.
        /// Départage explicite (force décroissante, puis lag croissant) : la
        /// liste est parcourue dans l'ordre, aucun `Set` n'intervient.
        func strongestPeak(near target: Double) -> (lag: Double, base: Double)? {
            guard target >= 1 else { return nil }
            var best: (lag: Double, base: Double)?
            for peak in scoredPeaks
            where abs(peak.lag - target) <= Self.subharmonicPeakTolerance * target {
                guard let current = best else { best = peak; continue }
                if peak.base > current.base || (peak.base == current.base && peak.lag < current.lag) {
                    best = peak
                }
            }
            return best
        }

        // 4. Score : MOYENNE PONDÉRÉE des termes de renforcement harmonique,
        //    puis pénalité sous-harmonique conditionnelle, puis prior.
        var candidates: [Candidate] = []
        for peak in scoredPeaks {
            // CORRECTIF (1) — le score était une SOMME dont la valeur dépendait
            // du nombre de termes disponibles, ce qui avantageait mécaniquement
            // les lags pour lesquels 2·L tombe encore dans la plage d'ACF
            // calculée. On n'accumule au dénominateur que les poids des termes
            // EFFECTIVEMENT ajoutés (un terme n'est ajouté que si son lag est
            // dans la plage réellement calculée) :
            //
            //    score = ( 1·max(0,acf(L)) + 0,5·max(0,acf(2L)) ) / (1 + 0,5)
            //
            // soit une moyenne pondérée sur [0 ; ~1], comparable d'un candidat
            // à l'autre quel que soit le nombre de termes disponibles.
            let ownValue = max(0, acfAt(peak.lag) ?? peak.base)
            var weightedSum = ownValue
            var weightTotal = 1.0
            if let harmonic = acfAt(peak.lag * 2) {
                weightedSum += 0.5 * max(0, harmonic)
                weightTotal += 0.5
            }
            var score = weightedSum / weightTotal

            // CORRECTIF (2) — le terme sous-harmonique change de SIGNE.
            //
            // L'ancien code AJOUTAIT 0,25·acf(L/2). Or une ACF forte à la
            // demi-période signifie que le signal pulse DEUX FOIS par période
            // candidate, donc que la grille candidate saute une pulsation sur
            // deux : c'est une preuve CONTRE le candidat, comptée comme une
            // preuve POUR. C'est cette inversion, et non le seul prior, qui
            // rendait le half-time structurellement gagnant (1,75·a contre
            // 1,5·a). Aucun σ ne pouvait la compenser : avec un prior centré
            // sur 120 et un score qui ne discrimine pas, la borne absolue est
            // 120·√2 = 169,7 BPM, donc 174, 180 et 200 BPM étaient
            // mathématiquement inatteignables.
            //
            // La pénalité est CONDITIONNELLE, et non proportionnelle à
            // acf(L/2) : une pénalité proportionnelle punirait tout tempo
            // portant des croches, ce qui est la norme du genre visé (mesuré :
            // avec des hats à 0,6 du kick, acf(L/2)/acf(L) ≈ 0,88 sur le VRAI
            // tempo). On n'applique la pénalité que si un vrai PIC d'ACF existe
            // à la demi-période ET qu'il est au moins aussi fort (90 %) que
            // celui du candidat — signature du candidat « deux fois trop lent »,
            // pour lequel ce rapport vaut ≈ 1,0.
            //
            // Conséquence structurelle intéressante : les pics ne sont
            // cherchés que dans [50 ; 220] BPM, donc un candidat à B BPM ne
            // peut être pénalisé que si 2·B ≤ 220. La pénalité ne peut donc
            // JAMAIS demoter un tempo rapide qui porte des subdivisions.
            if let subPeak = strongestPeak(near: peak.lag / 2),
               subPeak.base >= Self.subharmonicDominanceRatio * max(ownValue, 1e-6) {
                score /= (1 + Self.subharmonicPenalty)
            }

            let bpm = 60.0 * envelopeRate / peak.lag
            guard bpm >= Self.minBPM * 0.98, bpm <= Self.maxBPM * 1.02, score > 0 else { continue }
            // CORRECTIF (4) — prior de tempo log-normal type Ellis, centré
            // 120 BPM, σ = 0,9 octave, appliqué AVANT la normalisation des
            // probabilités : départage les familles half/double-time —
            // §19.1 conserve TOUTES les hypothèses avec leurs relations,
            // seul l'ordre (et donc l'hypothèse retenue) change.
            // La pénalité ci-dessus étant un simple diviseur, aucun candidat
            // ne peut être ramené à un score nul : une hypothèse peut être
            // rétrogradée, jamais perdue.
            let priorWeight = exp(
                -0.5 * pow(log2(bpm / Self.priorCenterBPM) / Self.priorSigmaOctaves, 2)
            )
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

    /// Vrai si `lag` et `anchor` sont dans un rapport proche d'un entier, dans
    /// un sens ou dans l'autre (correctif 3).
    ///
    /// La tolérance est RELATIVE à l'entier visé : un multiple d'ordre k cumule
    /// k fois l'erreur d'estimation du lag, il est donc normal de lui accorder
    /// k fois la marge. Un ratio de 1,5 (alias 2/3) est à 33 % de l'entier le
    /// plus proche : il est écarté sans ambiguïté.
    private static func isIntegerRelated(_ lag: Double, to anchor: Double) -> Bool {
        guard lag > 0, anchor > 0 else { return false }
        let ratio = lag >= anchor ? lag / anchor : anchor / lag
        let nearest = ratio.rounded()
        guard nearest >= 1 else { return false }
        return abs(ratio - nearest) <= Self.integerRelationTolerance * nearest
    }

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
