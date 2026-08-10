//
//  EditScoreGeneratorTests.swift
//  MontageMusicalTests
//
//  Tests unitaires obligatoires — spécification §70, bloc « Partitions » :
//  début/fin présents ; slots triés ; aucune intersection ; aucun trou
//  interne ; durées positives ; Fluid ⊆ Balanced ⊆ Percussive ; ancres
//  majeures communes ; planchers §28.2 ; burst ajouté comme groupe ;
//  gestes filtrés par mode ; respiration après burst (zone occupée →
//  burst refusé) ; majeures rapprochées fusionnées en amont ; modes
//  distincts ; résidu final ; morceau très court ; analyse sans beats
//  (ambiant §63) ; déterminisme.
//
//  Les analyses sont synthétiques et construites À LA MAIN (aucun moteur
//  audio) : beats réguliers 120 BPM sur 60 s, sections à 0/15/30/45/60 s,
//  phrases toutes les 4 mesures, impacts à 15 s et 45 s, courbes
//  cohérentes (montée de tension vers 45 s, stabilité tenue après 15 s).
//

import XCTest
@testable import MontageMusical

final class EditScoreGeneratorTests: XCTestCase {

    private let generator = DeterministicEditScoreGenerator()

    // MARK: - Helpers temps

    private func tick(_ seconds: Double) -> Int64 {
        Int64((seconds * 60_000).rounded())
    }

    private func time(_ seconds: Double) -> MediaTime {
        MediaTime(ticks: tick(seconds))
    }

    // MARK: - Fabrique d'analyses synthétiques

    private func neutralDescriptors() -> MusicalDescriptorVector {
        MusicalDescriptorVector(
            energy: 0.5, rhythmicDensity: 0.5, tension: 0.2, novelty: 0.3,
            stability: 0.5, regularity: 0.8, vocalPresence: 0, bassPresence: 0.5
        )
    }

    /// Analyse riche : 60 s à 120 BPM (beat = 0,5 s), mesures de 2 s,
    /// phrases de 8 s, sections à 0/15/30/45/60 s, impacts à 15 s
    /// (suivi d'un maintien : stabilité 0,9 sur 15–17 s) et à 45 s
    /// (précédé d'une montée de tension 40→45 s → burst-résolution).
    private func makeRichAnalysis() -> MusicAnalysisResult {
        let durationSeconds = 60.0
        let duration = time(durationSeconds)

        // Beats : 0,5 s ; les temps de mesure (secondes paires) sont forts.
        var beats: [BeatEvent] = []
        var beatTime = 0.0
        while beatTime < durationSeconds {
            let isDownbeat = beatTime.truncatingRemainder(dividingBy: 2.0) == 0
            beats.append(BeatEvent(
                time: time(beatTime),
                strength: isDownbeat ? 0.9 : 0.7,
                confidence: 0.9
            ))
            beatTime += 0.5
        }

        // Mesures de 2 s.
        var bars: [BarEvent] = []
        var barStart = 0.0
        var barIndex = 0
        while barStart < durationSeconds {
            bars.append(BarEvent(
                start: time(barStart),
                end: time(min(barStart + 2, durationSeconds)),
                index: barIndex,
                confidence: 0.85
            ))
            barStart += 2
            barIndex += 1
        }

        // Structure : arc global, sections, phrases de 8 s.
        var units: [StructuralUnit] = []
        units.append(StructuralUnit(
            id: UUID(), parentID: nil, level: .globalArc,
            start: .zero, end: duration, repetitionGroupID: nil,
            boundaryStrengthIn: 1, boundaryStrengthOut: 1,
            descriptors: neutralDescriptors(), confidence: 0.9
        ))
        let sectionEdges = [0.0, 15.0, 30.0, 45.0, 60.0]
        for index in 0..<(sectionEdges.count - 1) {
            units.append(StructuralUnit(
                id: UUID(), parentID: nil, level: .section,
                start: time(sectionEdges[index]), end: time(sectionEdges[index + 1]),
                repetitionGroupID: nil,
                boundaryStrengthIn: 0.9, boundaryStrengthOut: 0.8,
                descriptors: neutralDescriptors(), confidence: 0.85
            ))
        }
        var phraseStart = 0.0
        while phraseStart < durationSeconds {
            let phraseEnd = min(phraseStart + 8, durationSeconds)
            units.append(StructuralUnit(
                id: UUID(), parentID: nil, level: .phrase,
                start: time(phraseStart), end: time(phraseEnd),
                repetitionGroupID: nil,
                boundaryStrengthIn: 0.7, boundaryStrengthOut: 0.6,
                descriptors: neutralDescriptors(), confidence: 0.75
            ))
            phraseStart += 8
        }

        // Courbes §23 échantillonnées au demi-beat (0,5 s), cohérentes :
        // montée d'énergie/tension 40→45 s, plateau stable 15→17 s,
        // nouveauté forte aux sections, moyenne aux phrases.
        var energyCurve: [TimedValue] = []
        var tensionCurve: [TimedValue] = []
        var noveltyCurve: [TimedValue] = []
        var stabilityCurve: [TimedValue] = []
        var densityCurve: [TimedValue] = []
        var regularityCurve: [TimedValue] = []
        var vocalCurve: [TimedValue] = []
        var bassCurve: [TimedValue] = []
        var sampleTime = 0.0
        while sampleTime <= durationSeconds {
            let instant = time(sampleTime)
            var energy = 0.55
            if sampleTime >= 15, sampleTime <= 17 { energy = 0.8 }
            if sampleTime >= 40, sampleTime <= 45 { energy = 0.55 + 0.45 * (sampleTime - 40) / 5 }
            let tension = (sampleTime >= 40 && sampleTime <= 45)
                ? 0.4 + 0.6 * (sampleTime - 40) / 5
                : 0.05
            let novelty: Double
            if sectionEdges.contains(sampleTime) {
                novelty = 0.8
            } else if sampleTime.truncatingRemainder(dividingBy: 8.0) == 0 {
                novelty = 0.4
            } else {
                novelty = 0.1
            }
            let stability = (sampleTime >= 15 && sampleTime <= 17) ? 0.9 : 0.5
            energyCurve.append(TimedValue(time: instant, value: energy))
            tensionCurve.append(TimedValue(time: instant, value: tension))
            noveltyCurve.append(TimedValue(time: instant, value: novelty))
            stabilityCurve.append(TimedValue(time: instant, value: stability))
            densityCurve.append(TimedValue(time: instant, value: 0.5))
            regularityCurve.append(TimedValue(time: instant, value: 0.8))
            vocalCurve.append(TimedValue(time: instant, value: 0))
            bassCurve.append(TimedValue(time: instant, value: 0.5))
            sampleTime += 0.5
        }

        // Impacts à 15 s et 45 s.
        let events: [MusicalEvent] = [15.0, 45.0].map { seconds in
            MusicalEvent(
                id: UUID(), type: .impact, geometry: .point,
                start: time(seconds), end: nil,
                salience: 0.9, confidence: 0.7,
                evidence: [EvidenceContribution(source: "test.energy", weight: 1)]
            )
        }

        // États dramaturgiques : maintien 15–17 s puis relâchement 17–18 s.
        let states: [FunctionalStateInterval] = [
            FunctionalStateInterval(function: .exposition, start: .zero, end: time(15), confidence: 0.4),
            FunctionalStateInterval(function: .sustain, start: time(15), end: time(17), confidence: 0.6),
            FunctionalStateInterval(function: .release, start: time(17), end: time(18), confidence: 0.6),
        ]

        let hypothesisID = UUID()
        return MusicAnalysisResult(
            version: 1,
            duration: duration,
            rhythmHypotheses: [RhythmHypothesis(
                id: hypothesisID, tempoBPM: 120, tempoCurve: [],
                meterNumerator: 4, meterDenominator: 4,
                phaseOffset: .zero, probability: 0.9,
                halfTimeRelation: nil, doubleTimeRelation: nil
            )],
            selectedRhythmHypothesisID: hypothesisID,
            beats: beats,
            bars: bars,
            structuralUnits: units,
            functionalStates: states,
            musicalEvents: events,
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: energyCurve, density: densityCurve,
                tension: tensionCurve, novelty: noveltyCurve,
                stability: stabilityCurve, regularity: regularityCurve,
                vocalPresence: vocalCurve, bassPresence: bassCurve
            ),
            analysisConfidence: ConfidenceBreakdown(
                overall: 0.8, rhythm: 0.85, structure: 0.75, functions: 0.5
            )
        )
    }

    /// Analyse « conflit de respiration » : 60 s à 120 BPM, sections à
    /// 0/45,4/60 s, impact à 45 s précédé d'une montée de tension
    /// 40→45 s. Le burst détecté (ancres 44/44,5/45 s) résout à 45 s :
    /// la majeure de section à 45,4 s — frontière RACINE, active avant
    /// tout raffinement — tombe dans sa zone de respiration
    /// (fin, fin + 2 × plancher) pour les trois modes (0,4 s < 0,5 s
    /// percutant, < 0,8 s équilibré, < 1,5 s fluide).
    private func makeBurstBreathingConflictAnalysis() -> MusicAnalysisResult {
        let durationSeconds = 60.0
        let duration = time(durationSeconds)

        // Beats réguliers 0,5 s.
        var beats: [BeatEvent] = []
        var beatTime = 0.0
        while beatTime < durationSeconds {
            beats.append(BeatEvent(time: time(beatTime), strength: 0.7, confidence: 0.9))
            beatTime += 0.5
        }

        // Structure : arc global + sections 0/45,4/60 (majeure intérieure
        // UNIQUE à 45,4 s — 0,4 s après la résolution du burst).
        var units: [StructuralUnit] = [StructuralUnit(
            id: UUID(), parentID: nil, level: .globalArc,
            start: .zero, end: duration, repetitionGroupID: nil,
            boundaryStrengthIn: 1, boundaryStrengthOut: 1,
            descriptors: neutralDescriptors(), confidence: 0.9
        )]
        let sectionEdges = [0.0, 45.4, 60.0]
        for index in 0..<(sectionEdges.count - 1) {
            units.append(StructuralUnit(
                id: UUID(), parentID: nil, level: .section,
                start: time(sectionEdges[index]), end: time(sectionEdges[index + 1]),
                repetitionGroupID: nil,
                boundaryStrengthIn: 0.9, boundaryStrengthOut: 0.8,
                descriptors: neutralDescriptors(), confidence: 0.85
            ))
        }

        // Courbes : montée de tension 40→45 s (burst réel §25), le reste
        // plat — stabilité 0,5 et nouveauté 0,1 pour n'inhiber personne.
        var energyCurve: [TimedValue] = []
        var tensionCurve: [TimedValue] = []
        var noveltyCurve: [TimedValue] = []
        var stabilityCurve: [TimedValue] = []
        var flatHalf: [TimedValue] = []
        var regularityCurve: [TimedValue] = []
        var zeroCurve: [TimedValue] = []
        var sampleTime = 0.0
        while sampleTime <= durationSeconds {
            let instant = time(sampleTime)
            let tension = (sampleTime >= 40 && sampleTime <= 45)
                ? 0.4 + 0.6 * (sampleTime - 40) / 5
                : 0.05
            energyCurve.append(TimedValue(time: instant, value: 0.55))
            tensionCurve.append(TimedValue(time: instant, value: tension))
            noveltyCurve.append(TimedValue(time: instant, value: 0.1))
            stabilityCurve.append(TimedValue(time: instant, value: 0.5))
            flatHalf.append(TimedValue(time: instant, value: 0.5))
            regularityCurve.append(TimedValue(time: instant, value: 0.8))
            zeroCurve.append(TimedValue(time: instant, value: 0))
            sampleTime += 0.5
        }

        // Impact unique à 45 s (résolution du burst) — PAS d'ancre majeure
        // (les sections sont à 45,4 s).
        let events = [MusicalEvent(
            id: UUID(), type: .impact, geometry: .point,
            start: time(45), end: nil,
            salience: 0.9, confidence: 0.7,
            evidence: [EvidenceContribution(source: "test.energy", weight: 1)]
        )]

        let hypothesisID = UUID()
        return MusicAnalysisResult(
            version: 1,
            duration: duration,
            rhythmHypotheses: [RhythmHypothesis(
                id: hypothesisID, tempoBPM: 120, tempoCurve: [],
                meterNumerator: 4, meterDenominator: 4,
                phaseOffset: .zero, probability: 0.9,
                halfTimeRelation: nil, doubleTimeRelation: nil
            )],
            selectedRhythmHypothesisID: hypothesisID,
            beats: beats,
            bars: [],
            structuralUnits: units,
            functionalStates: [],
            musicalEvents: events,
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: energyCurve, density: flatHalf,
                tension: tensionCurve, novelty: noveltyCurve,
                stability: stabilityCurve, regularity: regularityCurve,
                vocalPresence: zeroCurve, bassPresence: flatHalf
            ),
            analysisConfidence: ConfidenceBreakdown(
                overall: 0.8, rhythm: 0.85, structure: 0.75, functions: 0.5
            )
        )
    }

    /// Analyse « majeures rapprochées » : 60 s sans pulsation, sections à
    /// 0/20/60 s et une phrase 20,4→28,4 s — les majeures à 20 s (rang 0)
    /// et 20,4 s (rang 1) sont à 0,4 s < plancher fluide (0,75 s).
    private func makeCloseMajorsAnalysis() -> MusicAnalysisResult {
        let durationSeconds = 60.0
        let duration = time(durationSeconds)
        var units: [StructuralUnit] = [StructuralUnit(
            id: UUID(), parentID: nil, level: .globalArc,
            start: .zero, end: duration, repetitionGroupID: nil,
            boundaryStrengthIn: 1, boundaryStrengthOut: 1,
            descriptors: neutralDescriptors(), confidence: 0.9
        )]
        let sectionEdges = [0.0, 20.0, 60.0]
        for index in 0..<(sectionEdges.count - 1) {
            units.append(StructuralUnit(
                id: UUID(), parentID: nil, level: .section,
                start: time(sectionEdges[index]), end: time(sectionEdges[index + 1]),
                repetitionGroupID: nil,
                boundaryStrengthIn: 0.9, boundaryStrengthOut: 0.9,
                descriptors: neutralDescriptors(), confidence: 0.85
            ))
        }
        units.append(StructuralUnit(
            id: UUID(), parentID: nil, level: .phrase,
            start: time(20.4), end: time(28.4),
            repetitionGroupID: nil,
            boundaryStrengthIn: 0.7, boundaryStrengthOut: 0.6,
            descriptors: neutralDescriptors(), confidence: 0.75
        ))
        let flatCurve = [
            TimedValue(time: .zero, value: 0.3),
            TimedValue(time: duration, value: 0.3),
        ]
        let hypothesisID = UUID()
        return MusicAnalysisResult(
            version: 1,
            duration: duration,
            rhythmHypotheses: [RhythmHypothesis(
                id: hypothesisID, tempoBPM: 0, tempoCurve: [],
                meterNumerator: nil, meterDenominator: nil,
                phaseOffset: .zero, probability: 0.2,
                halfTimeRelation: nil, doubleTimeRelation: nil
            )],
            selectedRhythmHypothesisID: hypothesisID,
            beats: [],
            bars: [],
            structuralUnits: units,
            functionalStates: [],
            musicalEvents: [],
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: flatCurve, density: flatCurve, tension: flatCurve,
                novelty: flatCurve, stability: flatCurve, regularity: flatCurve,
                vocalPresence: flatCurve, bassPresence: flatCurve
            ),
            analysisConfidence: ConfidenceBreakdown(
                overall: 0.5, rhythm: 0.1, structure: 0.6, functions: 0.3
            )
        )
    }

    /// Morceau très court : 3 s, un seul beat à 1,5 s (§63). Courbes
    /// plates et basses : rien ne justifie une coupe au seuil fluide.
    private func makeShortAnalysis() -> MusicAnalysisResult {
        let duration = time(3)
        let hypothesisID = UUID()
        let flatCurve = [
            TimedValue(time: .zero, value: 0.3),
            TimedValue(time: duration, value: 0.3),
        ]
        return MusicAnalysisResult(
            version: 1,
            duration: duration,
            rhythmHypotheses: [RhythmHypothesis(
                id: hypothesisID, tempoBPM: 120, tempoCurve: [],
                meterNumerator: nil, meterDenominator: nil,
                phaseOffset: .zero, probability: 0.5,
                halfTimeRelation: nil, doubleTimeRelation: nil
            )],
            selectedRhythmHypothesisID: hypothesisID,
            beats: [BeatEvent(time: time(1.5), strength: 0.7, confidence: 0.9)],
            bars: [],
            structuralUnits: [StructuralUnit(
                id: UUID(), parentID: nil, level: .globalArc,
                start: .zero, end: duration, repetitionGroupID: nil,
                boundaryStrengthIn: 1, boundaryStrengthOut: 1,
                descriptors: neutralDescriptors(), confidence: 0.6
            )],
            functionalStates: [],
            musicalEvents: [],
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: flatCurve, density: flatCurve, tension: flatCurve,
                novelty: flatCurve, stability: flatCurve, regularity: flatCurve,
                vocalPresence: flatCurve, bassPresence: flatCurve
            ),
            analysisConfidence: ConfidenceBreakdown(
                overall: 0.5, rhythm: 0.5, structure: 0.4, functions: 0.3
            )
        )
    }

    /// Analyse ambiante (§63) : AUCUN beat, aucune mesure, aucun impact —
    /// seulement des sections (0/20/40/60 s) et une courbe de nouveauté.
    private func makeAmbientAnalysis() -> MusicAnalysisResult {
        let durationSeconds = 60.0
        let duration = time(durationSeconds)
        var units: [StructuralUnit] = [StructuralUnit(
            id: UUID(), parentID: nil, level: .globalArc,
            start: .zero, end: duration, repetitionGroupID: nil,
            boundaryStrengthIn: 1, boundaryStrengthOut: 1,
            descriptors: neutralDescriptors(), confidence: 0.6
        )]
        let sectionEdges = [0.0, 20.0, 40.0, 60.0]
        for index in 0..<(sectionEdges.count - 1) {
            units.append(StructuralUnit(
                id: UUID(), parentID: nil, level: .section,
                start: time(sectionEdges[index]), end: time(sectionEdges[index + 1]),
                repetitionGroupID: nil,
                boundaryStrengthIn: 0.7, boundaryStrengthOut: 0.6,
                descriptors: neutralDescriptors(), confidence: 0.6
            ))
        }
        var noveltyCurve: [TimedValue] = []
        var flatCurve: [TimedValue] = []
        var sampleTime = 0.0
        while sampleTime <= durationSeconds {
            let novelty = sectionEdges.contains(sampleTime) ? 0.8 : 0.1
            noveltyCurve.append(TimedValue(time: time(sampleTime), value: novelty))
            flatCurve.append(TimedValue(time: time(sampleTime), value: 0.4))
            sampleTime += 1.0
        }
        let hypothesisID = UUID()
        return MusicAnalysisResult(
            version: 1,
            duration: duration,
            rhythmHypotheses: [RhythmHypothesis(
                id: hypothesisID, tempoBPM: 0, tempoCurve: [],
                meterNumerator: nil, meterDenominator: nil,
                phaseOffset: .zero, probability: 0.2,
                halfTimeRelation: nil, doubleTimeRelation: nil
            )],
            selectedRhythmHypothesisID: hypothesisID,
            beats: [],
            bars: [],
            structuralUnits: units,
            functionalStates: [],
            musicalEvents: [],
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: flatCurve, density: flatCurve, tension: flatCurve,
                novelty: noveltyCurve, stability: flatCurve, regularity: flatCurve,
                vocalPresence: flatCurve, bassPresence: flatCurve
            ),
            analysisConfidence: ConfidenceBreakdown(
                overall: 0.4, rhythm: 0.1, structure: 0.5, functions: 0.2
            )
        )
    }

    // MARK: - Helpers de vérification

    /// Frontières d'une partition en ticks (débuts de cases + fin absolue).
    private func boundaryTicks(_ score: EditScore) -> [Int64] {
        guard let last = score.slots.last else { return [] }
        return score.slots.map(\.start.ticks) + [last.end.ticks]
    }

    private func allScores(_ family: EditScoreFamily) -> [EditScore] {
        [family.fluid, family.balanced, family.percussive]
    }

    /// Contraintes structurelles §70 : slots triés, aucune intersection,
    /// aucun trou interne, durées positives, début/fin absolus.
    private func assertStructurallyValid(
        _ score: EditScore,
        duration: MediaTime,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(score.slots.isEmpty, "\(score.mode) : aucune case", file: file, line: line)
        XCTAssertEqual(score.slots.first?.start, .zero,
                       "\(score.mode) : le début du morceau doit être la première frontière",
                       file: file, line: line)
        XCTAssertEqual(score.slots.last?.end, duration,
                       "\(score.mode) : la fin absolue doit être la dernière frontière",
                       file: file, line: line)
        for (offset, slot) in score.slots.enumerated() {
            XCTAssertEqual(slot.index, offset, "\(score.mode) : index non contigu", file: file, line: line)
            XCTAssertLessThan(slot.start, slot.end,
                              "\(score.mode) : durée nulle ou négative au plan \(offset)",
                              file: file, line: line)
            if offset > 0 {
                // end[i-1] == start[i] : ni trou interne, ni intersection.
                XCTAssertEqual(score.slots[offset - 1].end, slot.start,
                               "\(score.mode) : trou ou chevauchement entre \(offset - 1) et \(offset)",
                               file: file, line: line)
            }
        }
    }

    // MARK: - §70 : début/fin présents, structure valide

    func testStartAndEndPresentAndStructureValidInAllModes() throws {
        let analysis = makeRichAnalysis()
        let family = try generator.generateScores(from: analysis, configuration: .production)
        for score in allScores(family) {
            assertStructurallyValid(score, duration: analysis.duration)
        }
        XCTAssertEqual(family.analysisVersion, analysis.version)
    }

    // MARK: - §70 : imbrication Fluid ⊆ Balanced ⊆ Percussive

    func testBoundaryNesting() throws {
        let family = try generator.generateScores(from: makeRichAnalysis(), configuration: .production)
        let fluid = Set(boundaryTicks(family.fluid))
        let balanced = Set(boundaryTicks(family.balanced))
        let percussive = Set(boundaryTicks(family.percussive))
        XCTAssertTrue(fluid.isSubset(of: balanced),
                      "Les frontières fluides doivent être un sous-ensemble des équilibrées")
        XCTAssertTrue(balanced.isSubset(of: percussive),
                      "Les frontières équilibrées doivent être un sous-ensemble des percutantes")
    }

    // MARK: - §28.1 : ancres majeures (sections) communes aux trois modes

    func testMajorSectionAnchorsPresentInAllModes() throws {
        let family = try generator.generateScores(from: makeRichAnalysis(), configuration: .production)
        let sectionTicks = [tick(15), tick(30), tick(45)]
        for score in allScores(family) {
            let boundaries = Set(boundaryTicks(score))
            for sectionTick in sectionTicks {
                XCTAssertTrue(boundaries.contains(sectionTick),
                              "\(score.mode) : frontière de section absente à \(sectionTick) ticks")
            }
        }
    }

    // MARK: - §28.2 : planchers par mode

    func testMinimumDurationsRespectFloorsPerMode() throws {
        let family = try generator.generateScores(from: makeRichAnalysis(), configuration: .production)
        let configuration = ScoreConfiguration.production
        for score in allScores(family) {
            let floor = configuration.minimumSlotDuration(for: score.mode)
            XCTAssertGreaterThanOrEqual(score.minimumDuration, floor,
                                        "\(score.mode) : plancher §28.2 violé")
            for slot in score.slots {
                XCTAssertGreaterThanOrEqual(slot.end - slot.start, floor,
                                            "\(score.mode) : plan \(slot.index) sous le plancher")
            }
        }
    }

    // MARK: - §27/§70 : burst ajouté comme groupe (toutes ou aucune)

    func testBurstAnchorsActivateAsGroup() throws {
        let analysis = makeRichAnalysis()
        let family = try generator.generateScores(from: analysis, configuration: .production)

        // Champ et gestes reconstruits : les ticks sont déterministes
        // (seuls les UUID d'identité changent d'une exécution à l'autre).
        let field = AnchorFieldBuilder().build(from: analysis, configuration: .production)
        let gestures = GestureDetector().detect(analysis: analysis, field: field)
        let burst = try XCTUnwrap(
            gestures.first { $0.type == .burstResolution },
            "La montée de tension vers l'impact de 45 s doit produire un burst-résolution"
        )
        XCTAssertGreaterThanOrEqual(burst.anchorIDs.count, 2, "Un burst est un groupe (§27)")

        let ticksByID = Dictionary(uniqueKeysWithValues: field.anchors.map { ($0.id, $0.center.ticks) })
        let groupTicks = burst.anchorIDs.compactMap { ticksByID[$0] }
        XCTAssertEqual(groupTicks.count, burst.anchorIDs.count,
                       "Chaque ancre du groupe doit exister dans le champ")

        for score in allScores(family) {
            let boundaries = Set(boundaryTicks(score))
            let activeCount = groupTicks.filter { boundaries.contains($0) }.count
            XCTAssertTrue(activeCount == 0 || activeCount == groupTicks.count,
                          "\(score.mode) : les ancres d'un burst s'activent toutes ou aucune")
        }
        // Les écarts internes du groupe (0,5 s) passent les planchers
        // équilibré/percutant mais pas le plancher fluide (0,75 s).
        let fluidBoundaries = Set(boundaryTicks(family.fluid))
        XCTAssertTrue(groupTicks.allSatisfy { !fluidBoundaries.contains($0) },
                      "Fluide : le burst (écarts 0,5 s) ne passe pas le plancher 0,75 s")
        let percussiveBoundaries = Set(boundaryTicks(family.percussive))
        XCTAssertTrue(groupTicks.allSatisfy { percussiveBoundaries.contains($0) },
                      "Percutant : le burst doit être réalisé en groupe complet")
        // Gestes filtrés PAR MODE : un geste ne figure dans une partition
        // que si toutes ses ancres y sont des frontières actives. Le burst
        // (non réalisé en fluide, réalisé en percutant) doit donc être
        // ABSENT de `fluid.gestures` et PRÉSENT dans `percussive.gestures`
        // — le test asserte désormais les deux faces (comportement modifié
        // en conscience : avant le filtrage, chaque mode embarquait TOUS
        // les gestes, y compris ceux dont les ancres n'étaient frontières
        // nulle part dans le mode).
        XCTAssertFalse(family.fluid.gestures.contains { $0.type == .burstResolution },
                       "Fluide : un burst non réalisé ne doit pas figurer dans la partition")
        XCTAssertTrue(family.percussive.gestures.contains { $0.type == .burstResolution },
                      "Le geste burst doit figurer dans la partition percutante")
    }

    // MARK: - §28.1 : respiration après burst — burst refusé si une frontière active occupe la zone

    /// Une majeure de section à 0,4 s APRÈS la résolution du burst est une
    /// frontière racine, active avant tout raffinement : la zone de
    /// respiration (fin, fin + 2 × plancher) n'est libre dans aucun mode
    /// → le burst doit être refusé partout (activer d'abord, puis
    /// interdire les coupes suivantes, ne suffit pas quand la coupe
    /// gênante précède l'activation).
    func testBurstRefusedWhenActiveBoundaryOccupiesBreathingZone() throws {
        let analysis = makeBurstBreathingConflictAnalysis()
        let family = try generator.generateScores(from: analysis, configuration: .production)

        // Garde du scénario : le burst est bien détecté et résout à 45 s.
        let field = AnchorFieldBuilder().build(from: analysis, configuration: .production)
        let gestures = GestureDetector().detect(analysis: analysis, field: field)
        let burst = try XCTUnwrap(
            gestures.first { $0.type == .burstResolution },
            "La montée de tension vers l'impact de 45 s doit produire un burst-résolution"
        )
        XCTAssertEqual(burst.end.ticks, tick(45), "Le burst doit résoudre sur l'impact de 45 s")
        let ticksByID = Dictionary(uniqueKeysWithValues: field.anchors.map { ($0.id, $0.center.ticks) })
        let groupTicks = burst.anchorIDs.compactMap { ticksByID[$0] }
        XCTAssertGreaterThanOrEqual(groupTicks.count, 2, "Un burst est un groupe (§27)")

        for score in allScores(family) {
            let boundaries = Set(boundaryTicks(score))
            // La majeure de section reste frontière partout (§28.1)…
            XCTAssertTrue(boundaries.contains(tick(45.4)),
                          "\(score.mode) : la majeure de 45,4 s doit rester frontière")
            // …et le burst est refusé : sa respiration est impossible.
            for groupTick in groupTicks {
                XCTAssertFalse(boundaries.contains(groupTick),
                               "\(score.mode) : burst refusé attendu — frontière active à 0,4 s de sa résolution")
            }
            XCTAssertFalse(score.gestures.contains { $0.type == .burstResolution },
                           "\(score.mode) : un burst refusé ne figure pas dans la partition")
        }
    }

    // MARK: - §28.1 : deux majeures à < 0,75 s fusionnées en amont (champ d'ancres)

    /// Une frontière de section (rang 0) à 20 s et une frontière de phrase
    /// (rang 1) à 20,4 s : à moins du plancher fluide (0,75 s), elles ne
    /// peuvent pas être toutes deux frontières racines. Le builder fusionne
    /// la paire (la plus forte survit, raisons cumulées) : `majorAnchorIDs`
    /// reste cohérent et la majeure survivante est frontière des TROIS
    /// modes.
    func testCloseMajorBoundariesMergeIntoSingleMajorAnchor() throws {
        let analysis = makeCloseMajorsAnalysis()
        let field = AnchorFieldBuilder().build(from: analysis, configuration: .production)

        // Une seule ancre survit dans la zone [20 s, 20,4 s] : la section
        // (rang 0, la plus forte), raisons des deux origines cumulées.
        let zoneAnchors = field.anchors.filter {
            $0.center.ticks >= tick(20) && $0.center.ticks <= tick(20.4)
        }
        XCTAssertEqual(zoneAnchors.count, 1, "La paire de majeures doit être fusionnée")
        let survivor = try XCTUnwrap(zoneAnchors.first)
        XCTAssertEqual(survivor.center.ticks, tick(20), "La section (rang 0) doit survivre")
        XCTAssertTrue(field.majorAnchorIDs.contains(survivor.id), "La survivante reste majeure")
        XCTAssertTrue(survivor.reasons.contains("Nouvelle section"), "Raisons cumulées attendues")
        XCTAssertTrue(survivor.reasons.contains("Frontière de phrase"), "Raisons cumulées attendues")

        // La majeure fusionnée est frontière dans les trois modes (§28.1) ;
        // l'ancienne position de la phrase n'est frontière nulle part.
        let family = try generator.generateScores(from: analysis, configuration: .production)
        for score in allScores(family) {
            let boundaries = Set(boundaryTicks(score))
            XCTAssertTrue(boundaries.contains(tick(20)),
                          "\(score.mode) : la majeure fusionnée doit être frontière")
            XCTAssertFalse(boundaries.contains(tick(20.4)),
                           "\(score.mode) : l'ancre de phrase fusionnée n'existe plus")
        }
    }

    // MARK: - §80 : modes cohérents et distincts

    func testModesAreDistinct() throws {
        let family = try generator.generateScores(from: makeRichAnalysis(), configuration: .production)
        XCTAssertGreaterThan(family.percussive.slots.count, family.balanced.slots.count,
                             "Percutant doit être plus dense qu'Équilibré")
        XCTAssertGreaterThan(family.balanced.slots.count, family.fluid.slots.count,
                             "Équilibré doit être plus dense que Fluide")
    }

    // MARK: - §28.2 : résidu final

    func testFinalResidualNeverBelowFloor() throws {
        let analysis = makeRichAnalysis()
        let family = try generator.generateScores(from: analysis, configuration: .production)
        let configuration = ScoreConfiguration.production
        for score in allScores(family) {
            let lastSlot = try XCTUnwrap(score.slots.last)
            // La fin ABSOLUE reste la dernière frontière.
            XCTAssertEqual(lastSlot.end, analysis.duration)
            // Jamais de micro-case finale.
            XCTAssertGreaterThanOrEqual(
                lastSlot.end - lastSlot.start,
                configuration.minimumSlotDuration(for: score.mode),
                "\(score.mode) : micro-case finale interdite"
            )
        }
    }

    // MARK: - §63 : morceau très court → au moins une case [0, fin]

    func testVeryShortTrackProducesAtLeastOneSlot() throws {
        let analysis = makeShortAnalysis()
        let family = try generator.generateScores(from: analysis, configuration: .production)
        for score in allScores(family) {
            XCTAssertGreaterThanOrEqual(score.slots.count, 1)
            assertStructurallyValid(score, duration: analysis.duration)
        }
        // Le mode fluide reste une case unique [0, fin] : l'unique beat ne
        // justifie pas un split au seuil fluide.
        XCTAssertEqual(family.fluid.slots.count, 1)
        XCTAssertEqual(family.fluid.slots[0].start, .zero)
        XCTAssertEqual(family.fluid.slots[0].end, analysis.duration)
    }

    // MARK: - §63 : analyse sans beats (ambiant) → partition structurelle

    func testAmbientAnalysisWithoutBeatsProducesStructuralScores() throws {
        let analysis = makeAmbientAnalysis()
        let family = try generator.generateScores(from: analysis, configuration: .production)
        for score in allScores(family) {
            assertStructurallyValid(score, duration: analysis.duration)
            // Les frontières proviennent de la structure : sections à
            // 20 s et 40 s présentes.
            let boundaries = Set(boundaryTicks(score))
            XCTAssertTrue(boundaries.contains(tick(20)))
            XCTAssertTrue(boundaries.contains(tick(40)))
        }
        // Imbrication conservée même sans pulsation.
        XCTAssertTrue(Set(boundaryTicks(family.fluid))
            .isSubset(of: Set(boundaryTicks(family.balanced))))
        XCTAssertTrue(Set(boundaryTicks(family.balanced))
            .isSubset(of: Set(boundaryTicks(family.percussive))))
    }

    // MARK: - Morceau vide interdit

    func testEmptyTrackThrows() {
        let hypothesisID = UUID()
        let empty = MusicAnalysisResult(
            version: 1,
            duration: .zero,
            rhythmHypotheses: [RhythmHypothesis(
                id: hypothesisID, tempoBPM: 0, tempoCurve: [],
                meterNumerator: nil, meterDenominator: nil,
                phaseOffset: .zero, probability: 0,
                halfTimeRelation: nil, doubleTimeRelation: nil
            )],
            selectedRhythmHypothesisID: hypothesisID,
            beats: [], bars: [], structuralUnits: [], functionalStates: [],
            musicalEvents: [], eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: [], density: [], tension: [], novelty: [],
                stability: [], regularity: [], vocalPresence: [], bassPresence: []
            ),
            analysisConfidence: ConfidenceBreakdown(overall: 0, rhythm: 0, structure: 0, functions: 0)
        )
        XCTAssertThrowsError(try generator.generateScores(from: empty, configuration: .production)) { error in
            XCTAssertEqual(error as? EditScoreGenerationError, .emptyTrack)
        }
    }

    // MARK: - Déterminisme : deux générations → mêmes frontières (ticks)

    func testDeterminismSameBoundariesAcrossGenerations() throws {
        let analysis = makeRichAnalysis()
        let first = try generator.generateScores(from: analysis, configuration: .production)
        let second = try generator.generateScores(from: analysis, configuration: .production)
        XCTAssertEqual(boundaryTicks(first.fluid), boundaryTicks(second.fluid))
        XCTAssertEqual(boundaryTicks(first.balanced), boundaryTicks(second.balanced))
        XCTAssertEqual(boundaryTicks(first.percussive), boundaryTicks(second.percussive))
        // Statistiques identiques (dérivées des mêmes durées).
        XCTAssertEqual(first.percussive.averageDuration, second.percussive.averageDuration)
        XCTAssertEqual(first.percussive.minimumDuration, second.percussive.minimumDuration)
        XCTAssertEqual(first.percussive.maximumDuration, second.percussive.maximumDuration)
    }

    // MARK: - Statistiques de durée cohérentes

    func testDurationStatisticsAreConsistent() throws {
        let family = try generator.generateScores(from: makeRichAnalysis(), configuration: .production)
        for score in allScores(family) {
            let durations = score.slots.map { $0.end.ticks - $0.start.ticks }
            XCTAssertEqual(score.minimumDuration.ticks, durations.min() ?? -1)
            XCTAssertEqual(score.maximumDuration.ticks, durations.max() ?? -1)
            let total = durations.reduce(Int64(0), +)
            let expectedAverage = MediaTime.roundedDivision(total, dividedBy: Int64(durations.count))
            XCTAssertEqual(score.averageDuration.ticks, expectedAverage)
        }
    }
}
