//
//  StructureBuilder.swift
//  MontageMusical
//
//  Construction de l'arbre d'unités musicales structurelles (§22.3),
//  niveau A simplifié (Jalon 4) :
//
//      Morceau (globalArc)
//      └── Sections (frontières de grande portée §22.2)
//          └── Phrases (frontières de petite portée, ou groupes de 4 mesures)
//              └── Mesures (bars)
//                  └── Beats
//
//  `repetitionGroupID` reste nil au niveau A : la détection des répétitions
//  (§22.1 avancé) relève du moteur hybride (Jalon 11) — documenté, jamais
//  de groupe de répétition inventé (§0.7).
//

import Foundation

// Non defini par la specification — definition minimale V1.
struct StructureBuilder: Sendable {

    init() {}

    /// Construit l'arbre d'UMS complet à partir des frontières de nouveauté,
    /// des beats et des mesures suivis. `parentID` renseignés,
    /// `boundaryStrengthIn/Out` depuis les forces de frontière §22.2.
    func build(
        duration: MediaTime,
        beats: [BeatEvent],
        bars: [BarEvent],
        beatSync: BeatSynchronousFeatures
    ) -> [StructuralUnit] {
        guard duration.ticks > 0 else {
            // Morceau de durée nulle : aucun arbre possible — l'appelant
            // (DeterministicMusicAnalyzer) gère le résultat minimal §63.
            return []
        }

        var units: [StructuralUnit] = []

        // 1. Racine : le morceau entier (§22.3). Les bords du morceau sont
        //    des frontières certaines (force 1).
        let rootID = UUID()
        units.append(StructuralUnit(
            id: rootID,
            parentID: nil,
            level: .globalArc,
            start: .zero,
            end: duration,
            repetitionGroupID: nil, // niveau A — voir en-tête de fichier
            boundaryStrengthIn: 1,
            boundaryStrengthOut: 1,
            descriptors: descriptors(from: .zero, to: duration, beatSync: beatSync, beats: beats),
            confidence: 0.9
        ))

        // 2. Sections : découpe aux frontières de grande portée. Sans
        //    frontière de section, le morceau est une section unique (§63 :
        //    morceau très court ou non métrique → structure minimale valide).
        let sectionBoundaries = beatSync.boundaries
            .filter { $0.isSectionScope && $0.time > .zero && $0.time < duration }
            .sorted { $0.time < $1.time }
        let phraseBoundaries = beatSync.boundaries
            .filter { !$0.isSectionScope && $0.time > .zero && $0.time < duration }
            .sorted { $0.time < $1.time }

        var sectionCuts: [(time: MediaTime, strength: Double, confidence: Double)] = [(.zero, 1, 0.9)]
        for boundary in sectionBoundaries {
            sectionCuts.append((boundary.time, boundary.strength, boundary.confidence))
        }
        sectionCuts.append((duration, 1, 0.9))

        for index in 0..<(sectionCuts.count - 1) {
            let start = sectionCuts[index]
            let end = sectionCuts[index + 1]
            guard end.time > start.time else { continue }
            let sectionID = UUID()
            units.append(StructuralUnit(
                id: sectionID,
                parentID: rootID,
                level: .section,
                start: start.time,
                end: end.time,
                repetitionGroupID: nil,
                boundaryStrengthIn: start.strength,
                boundaryStrengthOut: end.strength,
                descriptors: descriptors(from: start.time, to: end.time, beatSync: beatSync, beats: beats),
                confidence: min(start.confidence, end.confidence)
            ))

            // 3. Phrases dans la section : frontières de petite portée, ou à
            //    défaut groupes de 4 mesures, ou à défaut la section entière.
            appendPhrases(
                sectionID: sectionID,
                sectionStart: start.time,
                sectionEnd: end.time,
                sectionEdgeStrengths: (start.strength, end.strength),
                phraseBoundaries: phraseBoundaries,
                bars: bars,
                beats: beats,
                beatSync: beatSync,
                into: &units
            )
        }

        return units
    }

    // MARK: - Phrases

    private func appendPhrases(
        sectionID: UUID,
        sectionStart: MediaTime,
        sectionEnd: MediaTime,
        sectionEdgeStrengths: (entry: Double, exit: Double),
        phraseBoundaries: [StructuralBoundary],
        bars: [BarEvent],
        beats: [BeatEvent],
        beatSync: BeatSynchronousFeatures,
        into units: inout [StructuralUnit]
    ) {
        let inside = phraseBoundaries.filter { $0.time > sectionStart && $0.time < sectionEnd }

        var cuts: [(time: MediaTime, strength: Double, confidence: Double)]
        if !inside.isEmpty {
            cuts = inside.map { ($0.time, $0.strength, $0.confidence) }
        } else {
            // Groupes de 4 mesures (§20 : répétitions de 2/4/8 mesures
            // recherchées sans être imposées — au niveau A, un groupement
            // neutre de 4 sert de phrase par défaut, heuristique documentée).
            let sectionBars = bars.filter { $0.start >= sectionStart && $0.start < sectionEnd }
            cuts = []
            for (offset, bar) in sectionBars.enumerated()
            where offset > 0 && offset % 4 == 0 && bar.start > sectionStart && bar.start < sectionEnd {
                cuts.append((bar.start, 0.3, 0.4))
            }
        }

        var phraseCuts: [(time: MediaTime, strength: Double, confidence: Double)] =
            [(sectionStart, sectionEdgeStrengths.entry, 0.5)]
        phraseCuts.append(contentsOf: cuts)
        phraseCuts.append((sectionEnd, sectionEdgeStrengths.exit, 0.5))

        for index in 0..<(phraseCuts.count - 1) {
            let start = phraseCuts[index]
            let end = phraseCuts[index + 1]
            guard end.time > start.time else { continue }
            let phraseID = UUID()
            units.append(StructuralUnit(
                id: phraseID,
                parentID: sectionID,
                level: .phrase,
                start: start.time,
                end: end.time,
                repetitionGroupID: nil,
                boundaryStrengthIn: start.strength,
                boundaryStrengthOut: end.strength,
                descriptors: descriptors(from: start.time, to: end.time, beatSync: beatSync, beats: beats),
                confidence: min(start.confidence, end.confidence)
            ))
            appendBars(
                phraseID: phraseID,
                phraseStart: start.time,
                phraseEnd: end.time,
                bars: bars,
                beats: beats,
                beatSync: beatSync,
                into: &units
            )
        }
    }

    // MARK: - Mesures et beats

    private func appendBars(
        phraseID: UUID,
        phraseStart: MediaTime,
        phraseEnd: MediaTime,
        bars: [BarEvent],
        beats: [BeatEvent],
        beatSync: BeatSynchronousFeatures,
        into units: inout [StructuralUnit]
    ) {
        // Sans pulsation exploitable (§63 : beats/bars vides acceptés),
        // l'arbre s'arrête au niveau phrase — jamais de mesures inventées (§0.7).
        for bar in bars where bar.start >= phraseStart && bar.start < phraseEnd {
            let barStart = bar.start
            let barEnd = min(bar.end, phraseEnd)
            guard barEnd > barStart else { continue }
            let barID = UUID()
            units.append(StructuralUnit(
                id: barID,
                parentID: phraseID,
                level: .bar,
                start: barStart,
                end: barEnd,
                repetitionGroupID: nil,
                // Heuristique niveau A : une mesure est une frontière faible
                // mais réelle (downbeat) — force fixe documentée.
                boundaryStrengthIn: 0.25,
                boundaryStrengthOut: 0.25,
                descriptors: descriptors(from: barStart, to: barEnd, beatSync: beatSync, beats: beats),
                confidence: bar.confidence
            ))

            let barBeats = beats.filter { $0.time >= barStart && $0.time < barEnd }
            for (offset, beat) in barBeats.enumerated() {
                let beatEnd = offset + 1 < barBeats.count ? barBeats[offset + 1].time : barEnd
                guard beatEnd > beat.time else { continue }
                units.append(StructuralUnit(
                    id: UUID(),
                    parentID: barID,
                    level: .beat,
                    start: beat.time,
                    end: beatEnd,
                    repetitionGroupID: nil,
                    boundaryStrengthIn: min(max(beat.strength, 0), 1) * 0.5,
                    boundaryStrengthOut: offset + 1 < barBeats.count
                        ? min(max(barBeats[offset + 1].strength, 0), 1) * 0.5
                        : 0.25,
                    descriptors: descriptors(from: beat.time, to: beatEnd, beatSync: beatSync, beats: beats),
                    confidence: beat.confidence
                ))
            }
        }
    }

    // MARK: - Descripteurs agrégés (§23 par unité)

    /// Agrège le vecteur descripteur §23 sur les spans couvrant l'unité.
    ///
    /// - `tension` : approximation niveau A — montée d'énergie positive
    ///   (60 %) + montée du centroïde (40 %) entre le début et la fin de
    ///   l'unité, heuristique documentée ;
    /// - `vocalPresence` : 0 au niveau A — aucune détection vocale dans le
    ///   moteur déterministe, jamais de valeur inventée (§0.7, §15 niveau B).
    private func descriptors(
        from start: MediaTime,
        to end: MediaTime,
        beatSync: BeatSynchronousFeatures,
        beats: [BeatEvent]
    ) -> MusicalDescriptorVector {
        let spanIndices = (0..<beatSync.spanCount).filter { index in
            beatSync.spanStart(index) < end && beatSync.spanEnd(index) > start
        }
        guard !spanIndices.isEmpty else {
            return MusicalDescriptorVector(
                energy: 0, rhythmicDensity: 0, tension: 0, novelty: 0,
                stability: 0, regularity: 0, vocalPresence: 0, bassPresence: 0
            )
        }

        func mean(_ values: [Double]) -> Double {
            spanIndices.reduce(0.0) { $0 + values[$1] } / Double(spanIndices.count)
        }

        let energy = mean(beatSync.energy)
        let density = mean(beatSync.onsetDensity)
        let novelty = mean(beatSync.novelty)
        let bass = mean(beatSync.bass)

        // Tension approchée : pentes positives d'énergie et de centroïde.
        let firstIndex = spanIndices[0]
        let lastIndex = spanIndices[spanIndices.count - 1]
        let energyRise = max(beatSync.energy[lastIndex] - beatSync.energy[firstIndex], 0)
        let centroidRise = max(beatSync.centroid[lastIndex] - beatSync.centroid[firstIndex], 0)
        let tension = min(0.6 * energyRise + 0.4 * centroidRise, 1)

        // Stabilité : 1 − variance locale du flux (bornée), cf. §23 S.
        let fluxMean = mean(beatSync.flux)
        let fluxVariance = spanIndices.reduce(0.0) { partial, index in
            let delta = beatSync.flux[index] - fluxMean
            return partial + delta * delta
        } / Double(spanIndices.count)
        let stability = min(max(1 - 4 * fluxVariance, 0), 1)

        // Régularité : confiance moyenne des beats couvrant l'unité
        // (0 sans pulsation — §63, jamais de régularité inventée).
        let coveredBeats = beats.filter { $0.time >= start && $0.time < end }
        let regularity = coveredBeats.isEmpty
            ? 0
            : coveredBeats.reduce(0.0) { $0 + $1.confidence } / Double(coveredBeats.count)

        return MusicalDescriptorVector(
            energy: energy,
            rhythmicDensity: density,
            tension: tension,
            novelty: novelty,
            stability: stability,
            regularity: min(max(regularity, 0), 1),
            vocalPresence: 0, // niveau A — documenté ci-dessus
            bassPresence: bass
        )
    }
}
