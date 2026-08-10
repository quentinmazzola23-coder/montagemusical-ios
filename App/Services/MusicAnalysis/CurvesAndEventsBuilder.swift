//
//  CurvesAndEventsBuilder.swift
//  MontageMusical
//
//  Phase « Montées et impacts » (Jalon 4, niveau A) :
//  - §23 : courbes continues E/D/T/N/S/R/V/B en `TimedValue` par beat ;
//  - §12.4 : événements musicaux (onset, accent, downbeat, frontières,
//    impact, silence — et buildUp SEULEMENT quand une montée réelle
//    précède un impact) ;
//  - §12.5/§25 : relations minimales HONNÊTES — jamais de drop inventé
//    (§63 : « aucun drop : ne pas en inventer ») ;
//  - §24 : fonctions dramaturgiques par heuristique simple sur E/T/N,
//    lissées (au moins 2 beats par état), confiance ≤ 0,5 documentée.
//

import Foundation

// MARK: - Résultat

// Non defini par la specification — definition minimale V1.
struct CurvesAndEvents: Sendable {
    let curves: ContinuousCurves
    let functionalStates: [FunctionalStateInterval]
    let events: [MusicalEvent]
    let relations: [EventRelation]
}

// MARK: - Constructeur

// Non defini par la specification — definition minimale V1.
struct CurvesAndEventsBuilder: Sendable {

    /// Seuils déterministes du niveau A (heuristiques documentées — aucune
    /// valeur aléatoire, aucun résultat factice §0.7).
    private enum Threshold {
        /// E minimal pour un pic d'impact (valeurs normalisées 0…1).
        static let impactEnergy = 0.65
        /// Montée minimale E par rapport au plancher des spans précédents.
        static let impactRise = 0.35
        /// Fenêtre du plancher local d'un impact, en spans — alignée sur la
        /// fenêtre de montée de `genuineRise` (§25). Vérifié numériquement
        /// sur le signal buildUp synthétique (montée linéaire ~9 s puis
        /// impact final) : sur 3 spans, la montée d'un crescendo GRADUEL
        /// plafonne à ~0,26–0,33 < 0,35 et l'impact culminant la montée
        /// n'est JAMAIS détecté (le chemin positif §25 buildUp→impact était
        /// inatteignable) ; sur 8 spans elle atteint ~0,45–0,66 tout en ne
        /// créant aucun impact parasite sur un click track régulier
        /// (montées locales ~0,21 < 0,35).
        static let impactFloorWindow = 8
        /// RMS relatif considéré comme silence (§12.4 silence).
        static let silenceRMS: Float = 0.03
        /// Durée minimale d'un silence : 0,8 s (contrat Jalon 4).
        static let silenceMinimumSeconds = 0.8
        /// Tension moyenne minimale pour qualifier une montée réelle (§25).
        static let buildUpTension = 0.4
        /// Montée d'énergie minimale sur la fenêtre de montée (§25).
        static let buildUpEnergyRise = 0.15
    }

    init() {}

    func build(
        features: FeatureTimeline,
        beatSync: BeatSynchronousFeatures,
        beats: [BeatEvent],
        bars: [BarEvent],
        onsets: [OnsetEvent],
        structuralUnits: [StructuralUnit]
    ) -> CurvesAndEvents {
        let spanCount = beatSync.spanCount
        guard spanCount > 0 else {
            return CurvesAndEvents(
                curves: Self.emptyCurves,
                functionalStates: [],
                events: [],
                relations: []
            )
        }

        // MARK: §23 — courbes par beat
        let energy = beatSync.energy
        let tension = Self.tensionCurve(energy: energy, centroid: beatSync.centroid)
        let stability = Self.stabilityCurve(flux: beatSync.flux)
        let regularity = Self.regularityCurve(beats: beats, isBeatAligned: beatSync.isBeatAligned, spanCount: spanCount)

        func timed(_ values: [Double]) -> [TimedValue] {
            (0..<spanCount).map { TimedValue(time: beatSync.gridTimes[$0], value: values[$0]) }
        }
        let curves = ContinuousCurves(
            energy: timed(energy),
            density: timed(beatSync.onsetDensity),
            tension: timed(tension),
            novelty: timed(beatSync.novelty),
            stability: timed(stability),
            regularity: timed(regularity),
            // V : 0 constant au niveau A — aucune détection vocale dans le
            // moteur déterministe (§15 niveau B), jamais de valeur inventée.
            vocalPresence: timed([Double](repeating: 0, count: spanCount)),
            bassPresence: timed(beatSync.bass)
        )

        // MARK: §12.4 — événements
        var events: [MusicalEvent] = []
        var relations: [EventRelation] = []

        // Onsets : points, salience = force (§18 : temps, force, confiance).
        for onset in onsets {
            events.append(MusicalEvent(
                id: UUID(),
                type: .onset,
                geometry: .point,
                start: onset.time,
                end: nil,
                salience: Self.clamp01(onset.strength),
                confidence: Self.clamp01(onset.confidence),
                evidence: [EvidenceContribution(source: "onset.bandFlux", weight: 1)]
            ))
        }

        // Accents : onsets forts (80ᵉ centile des forces, plancher 0,6).
        let strengths = onsets.map(\.strength)
        if !strengths.isEmpty {
            let sorted = strengths.sorted()
            let accentThreshold = max(sorted[Int(Double(sorted.count - 1) * 0.8)], 0.6)
            for onset in onsets where onset.strength >= accentThreshold {
                events.append(MusicalEvent(
                    id: UUID(),
                    type: .accent,
                    geometry: .point,
                    start: onset.time,
                    end: nil,
                    salience: Self.clamp01(onset.strength),
                    confidence: Self.clamp01(onset.confidence),
                    evidence: [EvidenceContribution(source: "onset.strength", weight: 1)]
                ))
            }
        }

        // Downbeats : points aux débuts de mesures (§20).
        for bar in bars {
            let matchedBeat = beats.first {
                abs($0.time.ticks - bar.start.ticks) <= Int64(3_000) // ±50 ms
            }
            events.append(MusicalEvent(
                id: UUID(),
                type: .downbeat,
                geometry: .point,
                start: bar.start,
                end: nil,
                salience: Self.clamp01(matchedBeat?.strength ?? 0.5),
                confidence: Self.clamp01(bar.confidence),
                evidence: [EvidenceContribution(source: "meter.downbeat", weight: 1)]
            ))
        }

        // Frontières de phrase et de section (§22.2), salience = force.
        var sectionBoundaryEvents: [MusicalEvent] = []
        var phraseBoundaryEvents: [MusicalEvent] = []
        for boundary in beatSync.boundaries {
            let event = MusicalEvent(
                id: UUID(),
                type: boundary.isSectionScope ? .sectionBoundary : .phraseBoundary,
                geometry: .point,
                start: boundary.time,
                end: nil,
                salience: Self.clamp01(boundary.strength),
                confidence: Self.clamp01(boundary.confidence),
                evidence: [EvidenceContribution(
                    source: "novelty.checkerboard.\(boundary.dominantKernelSize)",
                    weight: 1
                )]
            )
            events.append(event)
            if boundary.isSectionScope {
                sectionBoundaryEvents.append(event)
            } else {
                phraseBoundaryEvents.append(event)
            }
        }

        // Impacts : pic d'énergie précédé d'une montée franche depuis le
        // plancher local (un départ depuis le silence est une montée
        // maximale). Temps raffiné à la frame de plus forte attaque.
        let impacts = Self.detectImpacts(
            energy: energy,
            beatSync: beatSync,
            features: features
        )
        var impactEvents: [(event: MusicalEvent, spanIndex: Int)] = []
        for impact in impacts {
            let event = MusicalEvent(
                id: UUID(),
                type: .impact,
                geometry: .point,
                start: impact.time,
                end: nil,
                salience: impact.salience,
                confidence: impact.confidence,
                evidence: [
                    EvidenceContribution(source: "energy.peak", weight: 0.5),
                    EvidenceContribution(source: "energy.rise", weight: 0.5),
                ]
            )
            events.append(event)
            impactEvents.append((event, impact.spanIndex))
        }

        // Silences : intervalles rms ≈ 0 de plus de 0,8 s.
        events.append(contentsOf: Self.detectSilences(features: features))

        // MARK: §12.5/§25 — relations minimales HONNÊTES

        // sectionBoundary CONTAINS phraseBoundary au même instant (±1 beat).
        let containsTolerance = Self.beatToleranceTicks(beatSync: beatSync)
        for section in sectionBoundaryEvents {
            for phrase in phraseBoundaryEvents
            where abs(section.start.ticks - phrase.start.ticks) <= containsTolerance {
                relations.append(EventRelation(
                    id: UUID(),
                    type: .contains,
                    sourceEventID: section.id,
                    targetEventID: phrase.id,
                    confidence: min(section.confidence, phrase.confidence)
                ))
            }
        }

        // accumulation PREPARES impact — SEULEMENT si une montée de tension
        // précède réellement l'impact (§25, §63 : jamais de drop inventé ;
        // pas de montée → pas de buildUp, pas de relation).
        for (impactEvent, spanIndex) in impactEvents {
            guard let rise = Self.genuineRise(
                before: spanIndex,
                energy: energy,
                tension: tension,
                beatSync: beatSync
            ) else { continue }
            let buildUp = MusicalEvent(
                id: UUID(),
                type: .buildUp,
                geometry: .interval,
                start: rise.start,
                end: impactEvent.start,
                salience: rise.salience,
                confidence: 0.45,
                evidence: [
                    EvidenceContribution(source: "tension.rise", weight: 0.6),
                    EvidenceContribution(source: "energy.rise", weight: 0.4),
                ]
            )
            events.append(buildUp)
            relations.append(EventRelation(
                id: UUID(),
                type: .prepares,
                sourceEventID: buildUp.id,
                targetEventID: impactEvent.id,
                confidence: 0.45
            ))
        }

        // MARK: §24 — fonctions dramaturgiques (heuristique niveau A)
        let functionalStates = Self.functionalStates(
            structuralUnits: structuralUnits,
            beatSync: beatSync,
            energy: energy,
            tension: tension,
            novelty: beatSync.novelty,
            impactSpanIndices: Set(impactEvents.map(\.spanIndex))
        )

        return CurvesAndEvents(
            curves: curves,
            functionalStates: functionalStates,
            events: events,
            relations: relations
        )
    }

    // MARK: - Courbes dérivées (§23)

    /// T : tension approchée = pente d'énergie lissée positive (60 %) +
    /// centroïde croissant (40 %), normalisée relativement au morceau.
    private static func tensionCurve(energy: [Double], centroid: [Double]) -> [Double] {
        let count = energy.count
        guard count > 1 else { return [Double](repeating: 0, count: count) }
        let energySlope = smoothedPositiveSlope(energy)
        let centroidSlope = smoothedPositiveSlope(centroid)
        var raw = [Double](repeating: 0, count: count)
        for index in 0..<count {
            raw[index] = 0.6 * energySlope[index] + 0.4 * centroidSlope[index]
        }
        return BeatSyncFeatureExtractor.normalizeByUpperQuantile(raw)
    }

    /// Pente lissée (moyenne mobile sur 3), partie positive uniquement.
    private static func smoothedPositiveSlope(_ values: [Double]) -> [Double] {
        let count = values.count
        guard count > 1 else { return [Double](repeating: 0, count: count) }
        var deltas = [Double](repeating: 0, count: count)
        for index in 1..<count {
            deltas[index] = values[index] - values[index - 1]
        }
        var smoothed = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let start = max(index - 1, 0)
            let end = min(index + 1, count - 1)
            var sum = 0.0
            for neighbor in start...end { sum += deltas[neighbor] }
            smoothed[index] = max(sum / Double(end - start + 1), 0)
        }
        return smoothed
    }

    /// S : stabilité = 1 − variance locale du flux (fenêtre ±2 spans),
    /// normalisée par le 95ᵉ centile des variances du morceau.
    private static func stabilityCurve(flux: [Double]) -> [Double] {
        let count = flux.count
        guard count > 0 else { return [] }
        var variances = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let start = max(index - 2, 0)
            let end = min(index + 2, count - 1)
            let window = Array(flux[start...end])
            let mean = window.reduce(0, +) / Double(window.count)
            variances[index] = window.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)
        }
        let normalized = BeatSyncFeatureExtractor.normalizeByUpperQuantile(variances)
        return normalized.map { min(max(1 - $0, 0), 1) }
    }

    /// R : régularité = confiance locale des beats (moyenne mobile sur 5).
    /// Grille de repli (§63, pas de pulsation) → 0, jamais de régularité
    /// inventée.
    private static func regularityCurve(beats: [BeatEvent], isBeatAligned: Bool, spanCount: Int) -> [Double] {
        guard isBeatAligned, beats.count == spanCount else {
            return [Double](repeating: 0, count: spanCount)
        }
        var result = [Double](repeating: 0, count: spanCount)
        for index in 0..<spanCount {
            let start = max(index - 2, 0)
            let end = min(index + 2, spanCount - 1)
            var sum = 0.0
            for neighbor in start...end { sum += beats[neighbor].confidence }
            result[index] = min(max(sum / Double(end - start + 1), 0), 1)
        }
        return result
    }

    // MARK: - Impacts

    private struct DetectedImpact {
        let spanIndex: Int
        let time: MediaTime
        let salience: Double
        let confidence: Double
    }

    /// Pic d'énergie local ≥ seuil, précédé d'une montée franche par rapport
    /// au plancher des `impactFloorWindow` spans précédents (fenêtre §25 —
    /// un impact culmine sa propre montée). Le temps est raffiné à la frame
    /// de plus forte attaque (dérivée RMS maximale) dans le span — précision
    /// frame (≈ 12 ms), conversion par la fonction unique frame → ticks.
    private static func detectImpacts(
        energy: [Double],
        beatSync: BeatSynchronousFeatures,
        features: FeatureTimeline
    ) -> [DetectedImpact] {
        let count = energy.count
        guard count > 1 else { return [] }
        var impacts: [DetectedImpact] = []
        for index in 1..<count {
            let value = energy[index]
            guard value >= Threshold.impactEnergy else { continue }
            // Maximum local (voisin précédent ≤, voisin suivant <).
            guard energy[index - 1] <= value else { continue }
            if index + 1 < count, energy[index + 1] > value { continue }
            // Montée depuis le plancher local (fenêtre `impactFloorWindow`).
            let floorStart = max(index - Threshold.impactFloorWindow, 0)
            let localFloor = energy[floorStart..<index].min() ?? 0
            let rise = value - localFloor
            guard rise >= Threshold.impactRise else { continue }
            // Plateau écrêté par la normalisation quantile (§17, bornée
            // 0…1) : plusieurs spans consécutifs à la même valeur rendent
            // la position de l'attaque invisible au niveau span — le
            // raffinement frame balaie alors le plateau ENTIER (l'attaque
            // réelle peut se trouver dans n'importe lequel de ses spans ;
            // vérifié numériquement : crescendo saturé + impact final,
            // l'attaque est dans le DERNIER span du plateau).
            var plateauEnd = index
            while plateauEnd + 1 < count, energy[plateauEnd + 1] >= value - 1e-9 {
                plateauEnd += 1
            }
            // Séparation minimale de 2 spans : garder le plus saillant.
            let salience = min(0.5 * value + 0.5 * rise, 1)
            if let last = impacts.last, index - last.spanIndex < 2 {
                if salience > last.salience {
                    impacts.removeLast()
                } else {
                    continue
                }
            }
            impacts.append(DetectedImpact(
                spanIndex: index,
                time: refinedAttackTime(
                    spanIndex: index,
                    plateauEndIndex: plateauEnd,
                    beatSync: beatSync,
                    features: features
                ),
                salience: salience,
                confidence: min(0.3 + 0.4 * rise, 0.7)
            ))
        }
        return impacts
    }

    /// Frame de plus forte dérivée RMS positive dans le span (fenêtre
    /// élargie de 150 ms vers l'arrière pour couvrir une attaque à cheval
    /// sur la frontière du span). Quand l'impact appartient à un plateau
    /// écrêté (voir `detectImpacts`), la recherche s'étend jusqu'à la fin
    /// du dernier span du plateau (`plateauEndIndex`).
    private static func refinedAttackTime(
        spanIndex: Int,
        plateauEndIndex: Int,
        beatSync: BeatSynchronousFeatures,
        features: FeatureTimeline
    ) -> MediaTime {
        let frameCount = features.rms.count
        let spanStart = beatSync.spanStart(spanIndex)
        let spanEnd = beatSync.spanEnd(max(plateauEndIndex, spanIndex))
        guard frameCount > 1 else { return spanStart }
        let lookBackFrames = Int((0.15 * features.frameRate).rounded())
        let startFrame = max(
            BeatGridTimeMapping.frameIndex(of: spanStart, frameRate: features.frameRate, frameCount: frameCount)
                - lookBackFrames,
            1
        )
        let endFrame = max(
            BeatGridTimeMapping.frameIndex(of: spanEnd, frameRate: features.frameRate, frameCount: frameCount),
            startFrame + 1
        )
        var bestFrame = startFrame
        var bestDelta: Float = -.greatestFiniteMagnitude
        for frame in startFrame..<min(endFrame, frameCount) {
            let delta = features.rms[frame] - features.rms[frame - 1]
            if delta > bestDelta {
                bestDelta = delta
                bestFrame = frame
            }
        }
        return BeatGridTimeMapping.mediaTime(frameIndex: bestFrame, frameRate: features.frameRate)
    }

    // MARK: - Silences

    /// Intervalles de RMS relatif ≈ 0 plus longs que 0,8 s (§12.4 silence).
    private static func detectSilences(features: FeatureTimeline) -> [MusicalEvent] {
        let frameCount = features.rms.count
        guard frameCount > 0, features.frameRate > 0 else { return [] }
        var events: [MusicalEvent] = []
        var runStart: Int?
        func closeRun(at endFrame: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let seconds = Double(endFrame - start) / features.frameRate
            guard seconds > Threshold.silenceMinimumSeconds else { return }
            events.append(MusicalEvent(
                id: UUID(),
                type: .silence,
                geometry: .interval,
                start: BeatGridTimeMapping.mediaTime(frameIndex: start, frameRate: features.frameRate),
                end: BeatGridTimeMapping.mediaTime(frameIndex: endFrame, frameRate: features.frameRate),
                salience: min(seconds / 4, 1),
                confidence: 0.7,
                evidence: [EvidenceContribution(source: "rms.floor", weight: 1)]
            ))
        }
        for frame in 0..<frameCount {
            if features.rms[frame] < Threshold.silenceRMS {
                if runStart == nil { runStart = frame }
            } else {
                closeRun(at: frame)
            }
        }
        closeRun(at: frameCount)
        return events
    }

    // MARK: - Montée réelle avant impact (§25)

    private struct GenuineRise {
        let start: MediaTime
        let salience: Double
    }

    /// Une montée est réelle si, sur la fenêtre des 8 spans précédant
    /// l'impact (au moins 4), la tension moyenne dépasse le seuil ET
    /// l'énergie monte globalement. Sinon : aucun buildUp, aucune relation
    /// (§63 : ne jamais inventer de drop/montée).
    private static func genuineRise(
        before spanIndex: Int,
        energy: [Double],
        tension: [Double],
        beatSync: BeatSynchronousFeatures
    ) -> GenuineRise? {
        let windowStart = max(spanIndex - 8, 0)
        let windowEnd = spanIndex // exclusif
        guard windowEnd - windowStart >= 4 else { return nil }
        let tensionWindow = tension[windowStart..<windowEnd]
        let meanTension = tensionWindow.reduce(0, +) / Double(tensionWindow.count)
        guard meanTension >= Threshold.buildUpTension else { return nil }
        let energyRise = energy[windowEnd - 1] - energy[windowStart]
        guard energyRise >= Threshold.buildUpEnergyRise else { return nil }
        return GenuineRise(
            start: beatSync.spanStart(windowStart),
            salience: min(0.5 * meanTension + 0.5 * energyRise, 1)
        )
    }

    // MARK: - Fonctions dramaturgiques (§24)

    /// Heuristique simple par section sur E/T/N, lissage à 2 spans minimum
    /// par état. Confiance 0,4 (≤ 0,5) : heuristique niveau A documentée —
    /// le décodage semi-markovien complet relève du moteur avancé.
    private static func functionalStates(
        structuralUnits: [StructuralUnit],
        beatSync: BeatSynchronousFeatures,
        energy: [Double],
        tension: [Double],
        novelty: [Double],
        impactSpanIndices: Set<Int>
    ) -> [FunctionalStateInterval] {
        let sections = structuralUnits
            .filter { $0.level == .section }
            .sorted { $0.start < $1.start }
        let scopes: [(start: MediaTime, end: MediaTime)] = sections.isEmpty
            ? structuralUnits
                .filter { $0.level == .globalArc }
                .map { ($0.start, $0.end) }
            : sections.map { ($0.start, $0.end) }
        guard !scopes.isEmpty else { return [] }

        var deltas = [Double](repeating: 0, count: energy.count)
        for index in 1..<max(energy.count, 1) {
            deltas[index] = energy[index] - energy[index - 1]
        }

        var intervals: [FunctionalStateInterval] = []
        for scope in scopes {
            let spanIndices = (0..<beatSync.spanCount).filter { index in
                beatSync.spanStart(index) >= scope.start && beatSync.spanStart(index) < scope.end
            }
            guard !spanIndices.isEmpty else {
                // Section plus courte qu'un span : un seul état neutre.
                intervals.append(FunctionalStateInterval(
                    function: .exposition, start: scope.start, end: scope.end, confidence: 0.3
                ))
                continue
            }

            // Classification par span.
            var states: [MusicalFunction] = spanIndices.map { index in
                if impactSpanIndices.contains(index) { return .impact }
                if novelty[index] >= 0.6 { return .transition }
                if tension[index] >= 0.45 && deltas[index] >= 0 { return .accumulation }
                if energy[index] >= 0.6 && abs(deltas[index]) <= 0.08 { return .sustain }
                if deltas[index] <= -0.15 { return .release }
                return .exposition
            }

            // Lissage : au moins 2 spans par état — les runs de longueur 1
            // sont absorbés par le run précédent (ou suivant en tête).
            states = smoothed(states, minimumRunLength: 2)

            // Runs → intervalles.
            var runStart = 0
            for index in 1...states.count {
                if index == states.count || states[index] != states[runStart] {
                    let startTime = beatSync.spanStart(spanIndices[runStart])
                    let endTime = index == states.count
                        ? scope.end
                        : beatSync.spanStart(spanIndices[index])
                    if endTime > startTime {
                        intervals.append(FunctionalStateInterval(
                            function: states[runStart],
                            start: max(startTime, scope.start),
                            end: endTime,
                            confidence: 0.4 // heuristique niveau A (≤ 0,5)
                        ))
                    }
                    runStart = index
                }
            }
        }
        return intervals
    }

    /// Absorbe les runs plus courts que `minimumRunLength` dans leur voisin.
    private static func smoothed(
        _ states: [MusicalFunction],
        minimumRunLength: Int
    ) -> [MusicalFunction] {
        guard states.count > 1 else { return states }
        var result = states
        var changed = true
        while changed {
            changed = false
            var index = 0
            while index < result.count {
                var runEnd = index
                while runEnd + 1 < result.count, result[runEnd + 1] == result[index] {
                    runEnd += 1
                }
                let runLength = runEnd - index + 1
                if runLength < minimumRunLength, result.count > runLength {
                    let replacement: MusicalFunction
                    if index > 0 {
                        replacement = result[index - 1]
                    } else if runEnd + 1 < result.count {
                        replacement = result[runEnd + 1]
                    } else {
                        break
                    }
                    for position in index...runEnd { result[position] = replacement }
                    changed = true
                }
                index = runEnd + 1
            }
        }
        return result
    }

    // MARK: - Utilitaires

    private static var emptyCurves: ContinuousCurves {
        ContinuousCurves(
            energy: [], density: [], tension: [], novelty: [],
            stability: [], regularity: [], vocalPresence: [], bassPresence: []
        )
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// Tolérance « même instant ±1 beat » pour la relation contains :
    /// intervalle médian des beats (grille alignée), sinon 0,5 s.
    private static func beatToleranceTicks(beatSync: BeatSynchronousFeatures) -> Int64 {
        guard beatSync.isBeatAligned, beatSync.gridTimes.count > 1 else { return 30_000 }
        var intervals: [Int64] = []
        for index in 1..<beatSync.gridTimes.count {
            intervals.append(beatSync.gridTimes[index].ticks - beatSync.gridTimes[index - 1].ticks)
        }
        let sorted = intervals.sorted()
        return sorted[sorted.count / 2]
    }
}
