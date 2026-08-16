//
//  BeatGridEditScoreGeneratorTests.swift
//  MontageMusicalTests
//
//  Le générateur de partitions n'avait AUCUN test depuis le pivot : la CI
//  prouvait qu'il compilait, rien de plus. C'est réparé ici — et c'est
//  possible parce que la subdivision de grille est enfin assez simple pour
//  qu'on puisse énoncer ce qu'elle promet.
//
//  La promesse tient en une phrase : chaque coupe tombe sur un point de la
//  grille, et le mode ne change que le PAS. Tout le reste en découle.
//

import XCTest
@testable import MontageMusical

final class BeatGridEditScoreGeneratorTests: XCTestCase {

    private let generator = BeatGridEditScoreGenerator()

    // MARK: - Fabriques

    /// Analyse synthétique : `beatCount` temps réguliers de `period`
    /// secondes, mesures de 4 temps, sans rien d'autre. Aucun appel au
    /// moteur audio — on teste le générateur, pas l'analyse.
    private func makeAnalysis(
        beatCount: Int,
        period: Double = 0.5,
        durationSeconds: Double? = nil,
        firstBeatOffset: Double = 0,
        includeBars: Bool = true,
        onsetTimes: [Double] = []
    ) -> MusicAnalysisResult {
        let beats = (0..<beatCount).map { index in
            BeatEvent(
                time: MediaTime(seconds: firstBeatOffset + Double(index) * period),
                strength: 0.8,
                confidence: 0.9
            )
        }
        let duration = MediaTime(
            seconds: durationSeconds ?? (firstBeatOffset + Double(beatCount) * period)
        )
        var bars: [BarEvent] = []
        if includeBars {
            var barIndex = 0
            var beatIndex = 0
            while beatIndex + 4 <= beats.count {
                bars.append(BarEvent(
                    start: beats[beatIndex].time,
                    end: beats[beatIndex + 4 - 1].time,
                    index: barIndex,
                    confidence: 0.8
                ))
                barIndex += 1
                beatIndex += 4
            }
        }
        let onsets = onsetTimes.map { seconds in
            MusicalEvent(
                id: UUID(),
                type: .onset,
                geometry: .point,
                start: MediaTime(seconds: seconds),
                end: nil,
                salience: 0.7,
                confidence: 0.7,
                evidence: []
            )
        }
        return MusicAnalysisResult(
            version: 1,
            duration: duration,
            rhythmHypotheses: [],
            selectedRhythmHypothesisID: DeterministicMusicAnalyzer.noHypothesisID,
            beats: beats,
            bars: bars,
            structuralUnits: [],
            functionalStates: [],
            musicalEvents: onsets,
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: [], density: [], tension: [], novelty: [],
                stability: [], regularity: [], vocalPresence: [], bassPresence: []
            ),
            analysisConfidence: ConfidenceBreakdown(overall: 0.5, rhythm: 0.5, structure: 0.5, functions: 0)
        )
    }

    private func boundaries(_ score: EditScore) -> [Int64] {
        guard let first = score.slots.first else { return [] }
        return [first.start.ticks] + score.slots.map(\.end.ticks)
    }

    /// Invariants §10.1/§28.1 valables pour TOUTE partition, quel que soit le
    /// mode : couvre le morceau, contiguë, indices strictement croissants.
    private func assertStructurallyValid(
        _ score: EditScore,
        duration: MediaTime,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(score.slots.isEmpty, "au moins une case (§63)", file: file, line: line)
        XCTAssertEqual(score.slots.first?.start.ticks, 0, "démarre à 0", file: file, line: line)
        XCTAssertEqual(score.slots.last?.end.ticks, duration.ticks, "finit à la durée", file: file, line: line)
        for (offset, slot) in score.slots.enumerated() {
            XCTAssertEqual(slot.index, offset, "index = position", file: file, line: line)
            XCTAssertGreaterThan(slot.end.ticks, slot.start.ticks, "durée > 0", file: file, line: line)
            if offset > 0 {
                XCTAssertEqual(
                    score.slots[offset - 1].end.ticks, slot.start.ticks,
                    "ni trou ni chevauchement", file: file, line: line
                )
            }
        }
    }

    // MARK: - La promesse centrale

    /// Toute frontière INTERNE tombe exactement sur un temps.
    ///
    /// C'est la seule chose que ce générateur promet. Si ce test tombe, la
    /// promesse est fausse et le reste n'a pas d'importance.
    func testEveryInternalBoundaryLandsExactlyOnABeat() throws {
        let analysis = makeAnalysis(beatCount: 64, durationSeconds: 32)
        let beatTicks = Set(analysis.beats.map(\.time.ticks))
        let family = try generator.generateScores(from: analysis)

        for mode in PaceMode.allCases {
            let score = family.score(for: mode)
            let internalBoundaries = boundaries(score).dropFirst().dropLast()
            XCTAssertFalse(internalBoundaries.isEmpty, "\(mode) : aucune coupe interne")
            for tick in internalBoundaries {
                XCTAssertTrue(
                    beatTicks.contains(tick),
                    "\(mode) : la coupe à \(tick) ticks ne tombe pas sur un temps"
                )
            }
        }
    }

    /// Le pas est bien celui annoncé : le nombre de coupes internes décroît
    /// d'un facteur 2 puis 4, et chaque grille plus large est un
    /// SOUS-ENSEMBLE de la plus fine.
    func testStepHalvesAndQuartersTheCuts() throws {
        let analysis = makeAnalysis(beatCount: 64, durationSeconds: 32)
        let family = try generator.generateScores(from: analysis)

        let fine = Set(boundaries(family.everyBeat).dropFirst().dropLast())
        let half = Set(boundaries(family.everyTwoBeats).dropFirst().dropLast())
        let quarter = Set(boundaries(family.everyFourBeats).dropFirst().dropLast())

        XCTAssertGreaterThan(fine.count, half.count)
        XCTAssertGreaterThan(half.count, quarter.count)
        XCTAssertTrue(half.isSubset(of: fine), "1 temps sur 2 doit être un sous-ensemble de chaque temps")
        XCTAssertTrue(quarter.isSubset(of: half), "1 temps sur 4 doit être un sous-ensemble de 1 sur 2")

        // Facteur attendu à ±1 coupe près (les bornes du morceau décalent le
        // compte d'une unité selon la parité).
        XCTAssertEqual(Double(half.count), Double(fine.count) / 2, accuracy: 1.5)
        XCTAssertEqual(Double(quarter.count), Double(fine.count) / 4, accuracy: 1.5)
    }

    /// « 1 temps sur 4 » tombe sur les DÉBUTS DE MESURE, pas entre eux.
    ///
    /// La grille démarre volontairement AVANT le premier downbeat (deux
    /// temps d'anacrouse) : sans alignement de phase, le pas de 4 partirait
    /// du premier temps et manquerait toutes les mesures.
    func testFourBeatStepAlignsOnDownbeats() throws {
        let period = 0.5
        var analysis = makeAnalysis(beatCount: 34, period: period, durationSeconds: 17, includeBars: false)
        // Premier downbeat sur le 3ᵉ temps (index 2).
        let downbeatTicks = analysis.beats[2].time.ticks
        analysis = MusicAnalysisResult(
            version: analysis.version,
            duration: analysis.duration,
            rhythmHypotheses: [],
            selectedRhythmHypothesisID: analysis.selectedRhythmHypothesisID,
            beats: analysis.beats,
            bars: [BarEvent(
                start: MediaTime(ticks: downbeatTicks),
                end: analysis.beats[5].time,
                index: 0,
                confidence: 0.8
            )],
            structuralUnits: [],
            functionalStates: [],
            musicalEvents: [],
            eventRelations: [],
            continuousCurves: analysis.continuousCurves,
            analysisConfidence: analysis.analysisConfidence
        )

        let score = try generator.generateScores(from: analysis).everyFourBeats
        let internalBoundaries = boundaries(score).dropFirst().dropLast()
        XCTAssertFalse(internalBoundaries.isEmpty)

        let periodTicks = analysis.beats[1].time.ticks - analysis.beats[0].time.ticks
        for tick in internalBoundaries {
            let offsetFromDownbeat = tick - downbeatTicks
            XCTAssertEqual(
                offsetFromDownbeat % (4 * periodTicks), 0,
                "la coupe à \(tick) n'est pas à un multiple de 4 temps du premier downbeat"
            )
        }
    }

    // MARK: - Structure et cas limites

    func testAllModesProduceStructurallyValidScores() throws {
        let analysis = makeAnalysis(beatCount: 40, durationSeconds: 20)
        let family = try generator.generateScores(from: analysis)
        for mode in PaceMode.allCases {
            assertStructurallyValid(family.score(for: mode), duration: analysis.duration)
            XCTAssertEqual(family.score(for: mode).mode, mode)
        }
        XCTAssertEqual(family.analysisVersion, analysis.version)
    }

    /// Sans beats mais avec des onsets, la grille bascule sur les onsets :
    /// un morceau non métrique reste découpable (§63).
    func testFallsBackToOnsetsWhenNoBeats() throws {
        let onsetTimes = stride(from: 0.7, to: 9.0, by: 0.7).map { $0 }
        let analysis = makeAnalysis(
            beatCount: 0,
            durationSeconds: 10,
            includeBars: false,
            onsetTimes: onsetTimes
        )
        let score = try generator.generateScores(from: analysis).everyBeat
        assertStructurallyValid(score, duration: analysis.duration)

        let onsetTicks = Set(onsetTimes.map { MediaTime(seconds: $0).ticks })
        for tick in boundaries(score).dropFirst().dropLast() {
            XCTAssertTrue(onsetTicks.contains(tick), "la coupe à \(tick) ne tombe pas sur un onset")
        }
    }

    /// Ni beats ni onsets : une case unique, jamais une grille inventée
    /// sur du silence (§0.7).
    func testNoGridProducesSingleSlot() throws {
        let analysis = makeAnalysis(beatCount: 0, durationSeconds: 12, includeBars: false)
        let family = try generator.generateScores(from: analysis)
        for mode in PaceMode.allCases {
            let score = family.score(for: mode)
            XCTAssertEqual(score.slots.count, 1, "\(mode) : une seule case attendue")
            assertStructurallyValid(score, duration: analysis.duration)
        }
    }

    func testEmptyTrackThrows() {
        let analysis = makeAnalysis(beatCount: 8, durationSeconds: 0)
        XCTAssertThrowsError(try generator.generateScores(from: analysis)) { error in
            XCTAssertEqual(error as? GridScoreGenerationError, .emptyTrack)
        }
    }

    /// Deux temps plus rapprochés que le plancher technique (42 ms, une
    /// image à 24 im/s) ne peuvent pas être deux coupes : le second est
    /// IGNORÉ, jamais déplacé — sinon la coupe tomberait à côté du temps.
    func testCutsCloserThanOneVideoFrameAreDropped() throws {
        // Période de 20 ms : sous le plancher de 42 ms.
        let analysis = makeAnalysis(beatCount: 200, period: 0.020, durationSeconds: 4)
        let score = try generator.generateScores(from: analysis).everyBeat
        assertStructurallyValid(score, duration: analysis.duration)

        let beatTicks = Set(analysis.beats.map(\.time.ticks))
        let cuts = boundaries(score)
        for index in 1..<cuts.count {
            XCTAssertGreaterThanOrEqual(
                cuts[index] - cuts[index - 1],
                BeatGridEditScoreGenerator.minimumCutSpacingTicks,
                "deux coupes plus proches qu'une image vidéo"
            )
        }
        // Les coupes RETENUES restent malgré tout sur des temps : on écarte,
        // on ne recale pas.
        for tick in cuts.dropFirst().dropLast() {
            XCTAssertTrue(beatTicks.contains(tick), "coupe déplacée hors de la grille")
        }
    }

    /// Deux générations sur la même analyse donnent les mêmes frontières.
    func testDeterminism() throws {
        let analysis = makeAnalysis(beatCount: 48, durationSeconds: 24)
        let first = try generator.generateScores(from: analysis)
        let second = try generator.generateScores(from: analysis)
        for mode in PaceMode.allCases {
            XCTAssertEqual(
                boundaries(first.score(for: mode)),
                boundaries(second.score(for: mode)),
                "\(mode) : frontières non déterministes"
            )
        }
    }

    /// Les statistiques annoncées à l'écran du choix du rythme décrivent
    /// bien les cases produites.
    func testDurationStatisticsMatchTheSlots() throws {
        let analysis = makeAnalysis(beatCount: 40, durationSeconds: 20)
        for mode in PaceMode.allCases {
            let score = try generator.generateScores(from: analysis).score(for: mode)
            let durations = score.slots.map { $0.end.ticks - $0.start.ticks }
            XCTAssertEqual(score.minimumDuration.ticks, durations.min())
            XCTAssertEqual(score.maximumDuration.ticks, durations.max())
            XCTAssertEqual(
                score.averageDuration.ticks,
                MediaTime.roundedDivision(durations.reduce(0, +), dividedBy: Int64(durations.count))
            )
        }
    }
}
