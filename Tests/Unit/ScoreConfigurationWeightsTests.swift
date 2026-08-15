//
//  ScoreConfigurationWeightsTests.swift
//  MontageMusicalTests
//
//  Poids d'utilité §26.3 : la spec exige que les poids centralisés dans
//  `ScoreConfiguration` soient « couverts par des tests ». Pour chaque
//  poids d'attraction (rhythmicStrength, structuralStrength, novelty,
//  contrast, resolutionValue, expectedFutureValue) et de pénalité
//  (inhibition, uncertaintyPenalty) : le champ d'ancres est construit
//  avec le poids à 0 puis à 2, et l'utilité finale d'une ancre CIBLÉE
//  (dont la composante correspondante est non nulle) doit varier dans le
//  bon sens ; un poids NON concerné (composante nulle sur l'ancre ciblée)
//  ne change pas cette utilité. `overcutPenalty` s'applique à la
//  SÉLECTION (densité de coupes déjà activées) : il est vérifié au niveau
//  du générateur — un poids élevé réduit le nombre de coupes actives en
//  zone dense.
//
//  L'analyse est synthétique, construite À LA MAIN (copie locale privée
//  adaptée du helper d'EditScoreGeneratorTests — méthodes privées de la
//  classe, aucune collision de symboles top-level dans le module de
//  tests) et DÉTERMINISTE : beats réguliers 0,5 s sur 40 s, sections à
//  0/20/40 s, marche d'énergie à 30 s (contraste), release à 25,6 s
//  (résolution), impact à 35 s (anticipation avant, maintien après).
//

import XCTest
@testable import MontageMusical

final class ScoreConfigurationWeightsTests: XCTestCase {

    private let generator = DeterministicEditScoreGenerator()

    // MARK: - Helpers temps (copie locale privée)

    private func tick(_ seconds: Double) -> Int64 {
        Int64((seconds * 60_000).rounded())
    }

    private func time(_ seconds: Double) -> MediaTime {
        MediaTime(ticks: tick(seconds))
    }

    private func neutralDescriptors() -> MusicalDescriptorVector {
        MusicalDescriptorVector(
            energy: 0.5, rhythmicDensity: 0.5, tension: 0.2, novelty: 0.3,
            stability: 0.5, regularity: 0.8, vocalPresence: 0, bassPresence: 0.5
        )
    }

    // MARK: - Analyse synthétique ciblée par composante

    /// 40 s à 120 BPM (beats 0,5 s, force 0,7, confiance 0,9). Ancres
    /// ciblées, une par composante §26.3 :
    /// - 10 s : beat pur (rhythmicStrength ; structural = 0) ;
    /// - 15 s : beat en zone neutre (novelty — courbe plate 0,2 ;
    ///   inhibition nulle : stabilité 0,5, pas d'impact avant 35 s) ;
    /// - 20 s : frontière de section (structuralStrength ; l'ancre est
    ///   CO-LOCALISÉE avec un beat et porte donc AUSSI sa composante
    ///   rythmique 0,7 — le témoin « non concerné » y est `resolutionValue`) ;
    /// - 25,6 s : release (resolutionValue ; hors grille des beats) ;
    /// - 30 s : beat sur la marche d'énergie 0,3 → 0,7 (contrast) ;
    /// - 34 s : beat 1 s avant l'impact (expectedFutureValue) ;
    /// - 35,5 s : beat 0,5 s après l'impact (inhibition — maintien
    ///   post-impact triangulaire culminant à 0,5 s) ;
    /// - 5 s : beat pur (uncertaintyPenalty via confiance 0,9 < 1).
    private func makeWeightsAnalysis() -> MusicAnalysisResult {
        let durationSeconds = 40.0
        let duration = time(durationSeconds)

        var beats: [BeatEvent] = []
        var beatTime = 0.0
        while beatTime < durationSeconds {
            beats.append(BeatEvent(time: time(beatTime), strength: 0.7, confidence: 0.9))
            beatTime += 0.5
        }

        var units: [StructuralUnit] = [StructuralUnit(
            id: UUID(), parentID: nil, level: .globalArc,
            start: .zero, end: duration, repetitionGroupID: nil,
            boundaryStrengthIn: 1, boundaryStrengthOut: 1,
            descriptors: neutralDescriptors(), confidence: 0.9
        )]
        let sectionEdges = [0.0, 20.0, 40.0]
        for index in 0..<(sectionEdges.count - 1) {
            units.append(StructuralUnit(
                id: UUID(), parentID: nil, level: .section,
                start: time(sectionEdges[index]), end: time(sectionEdges[index + 1]),
                repetitionGroupID: nil,
                boundaryStrengthIn: 0.8, boundaryStrengthOut: 0.8,
                descriptors: neutralDescriptors(), confidence: 0.85
            ))
        }

        // Courbes au demi-beat : nouveauté plate 0,2 (pas d'inhibition
        // « absence de changement »), stabilité plate 0,5 (pas de « note
        // tenue »), énergie en marche 0,3 → 0,7 à 30 s (contraste localisé),
        // tension nulle.
        var energyCurve: [TimedValue] = []
        var noveltyCurve: [TimedValue] = []
        var stabilityCurve: [TimedValue] = []
        var flatHalf: [TimedValue] = []
        var regularityCurve: [TimedValue] = []
        var zeroCurve: [TimedValue] = []
        var sampleTime = 0.0
        while sampleTime <= durationSeconds {
            let instant = time(sampleTime)
            energyCurve.append(TimedValue(time: instant, value: sampleTime < 30 ? 0.3 : 0.7))
            noveltyCurve.append(TimedValue(time: instant, value: 0.2))
            stabilityCurve.append(TimedValue(time: instant, value: 0.5))
            flatHalf.append(TimedValue(time: instant, value: 0.5))
            regularityCurve.append(TimedValue(time: instant, value: 0.8))
            zeroCurve.append(TimedValue(time: instant, value: 0))
            sampleTime += 0.5
        }

        let events: [MusicalEvent] = [
            MusicalEvent(
                id: UUID(), type: .impact, geometry: .point,
                start: time(35), end: nil,
                salience: 0.9, confidence: 0.7,
                evidence: [EvidenceContribution(source: "test.energy", weight: 1)]
            ),
            MusicalEvent(
                id: UUID(), type: .release, geometry: .point,
                start: time(25.6), end: nil,
                salience: 0.8, confidence: 0.7,
                evidence: [EvidenceContribution(source: "test.energy", weight: 1)]
            ),
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
            bars: [],
            structuralUnits: units,
            functionalStates: [],
            musicalEvents: events,
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: energyCurve, density: flatHalf,
                tension: zeroCurve, novelty: noveltyCurve,
                stability: stabilityCurve, regularity: regularityCurve,
                vocalPresence: zeroCurve, bassPresence: flatHalf
            ),
            analysisConfidence: ConfidenceBreakdown(
                overall: 0.8, rhythm: 0.85, structure: 0.75, functions: 0.5
            )
        )
    }

    // MARK: - Helpers d'assertion

    private func configuration(
        _ mutate: (inout ScoreConfiguration) -> Void
    ) -> ScoreConfiguration {
        var configuration = ScoreConfiguration.production
        mutate(&configuration)
        return configuration
    }

    /// Utilité finale de l'ancre dont le centre est exactement `ticks`,
    /// champ reconstruit avec la configuration fournie.
    private func utility(
        at ticks: Int64,
        configuration: ScoreConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        let field = AnchorFieldBuilder().build(from: makeWeightsAnalysis(), configuration: configuration)
        let anchor = try XCTUnwrap(
            field.anchors.first { $0.center.ticks == ticks },
            "Ancre attendue à \(ticks) ticks",
            file: file, line: line
        )
        return anchor.finalUtility
    }

    /// Vérifie le sens de variation d'un poids sur l'ancre ciblée (0 → 2)
    /// et l'ABSENCE d'effet d'un poids non concerné (composante nulle sur
    /// cette ancre : l'utilité doit être STRICTEMENT identique — seule une
    /// multiplication par zéro change).
    private func assertWeight(
        at targetTick: Int64,
        increases: Bool,
        varying: WritableKeyPath<ScoreConfiguration, Double>,
        unaffectedBy unrelated: WritableKeyPath<ScoreConfiguration, Double>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let zero = try utility(
            at: targetTick,
            configuration: configuration { $0[keyPath: varying] = 0 },
            file: file, line: line
        )
        let doubled = try utility(
            at: targetTick,
            configuration: configuration { $0[keyPath: varying] = 2 },
            file: file, line: line
        )
        if increases {
            XCTAssertGreaterThan(doubled, zero, "Le poids doit AUGMENTER l'utilité de l'ancre ciblée",
                                 file: file, line: line)
        } else {
            XCTAssertLessThan(doubled, zero, "Le poids doit DIMINUER l'utilité de l'ancre ciblée",
                              file: file, line: line)
        }
        let baseline = try utility(at: targetTick, configuration: .production, file: file, line: line)
        let withUnrelated = try utility(
            at: targetTick,
            configuration: configuration { $0[keyPath: unrelated] = 2 },
            file: file, line: line
        )
        XCTAssertEqual(withUnrelated, baseline,
                       "Un poids non concerné ne doit pas changer l'utilité de l'ancre ciblée",
                       file: file, line: line)
    }

    // MARK: - Poids d'attraction §26.3

    func testRhythmicStrengthWeight() throws {
        // Beat pur à 10 s : composante rythmique 0,7 ; structurelle nulle.
        try assertWeight(
            at: tick(10), increases: true,
            varying: \.rhythmicStrength, unaffectedBy: \.structuralStrength
        )
    }

    func testStructuralStrengthWeight() throws {
        // Frontière de section à 20 s, CO-LOCALISÉE avec un beat : depuis
        // la fusion des candidats co-localisés, l'ancre porte les DEUX
        // composantes (structural 0,8 du bord de section, rhythmic 0,7 du
        // beat) au lieu d'élire un survivant. Le témoin « non concerné » ne
        // peut donc plus être `rhythmicStrength` — c'est `resolutionValue`
        // qui est nul ici (le seul release de l'analyse est à 25,6 s).
        try assertWeight(
            at: tick(20), increases: true,
            varying: \.structuralStrength, unaffectedBy: \.resolutionValue
        )
    }

    func testNoveltyWeight() throws {
        // Beat à 15 s : nouveauté 0,2 (courbe plate) ; l'inhibition y est
        // nulle (stabilité 0,5, aucun impact avant 35 s, nouveauté > 0,1).
        try assertWeight(
            at: tick(15), increases: true,
            varying: \.novelty, unaffectedBy: \.inhibition
        )
    }

    func testContrastWeight() throws {
        // Beat à 30 s, sur la marche d'énergie 0,3 → 0,7 : contraste 0,4 ;
        // composante de résolution nulle.
        try assertWeight(
            at: tick(30), increases: true,
            varying: \.contrast, unaffectedBy: \.resolutionValue
        )
    }

    func testResolutionValueWeight() throws {
        // Release à 25,6 s (hors grille des beats) : composante de
        // résolution 0,8 ; composante rythmique nulle.
        try assertWeight(
            at: tick(25.6), increases: true,
            varying: \.resolutionValue, unaffectedBy: \.rhythmicStrength
        )
    }

    func testExpectedFutureValueWeight() throws {
        // Beat à 34 s, 1 s avant l'impact de 35 s : anticipation
        // 1 − 1/1,5 = 1/3 ; composante structurelle nulle.
        try assertWeight(
            at: tick(34), increases: true,
            varying: \.expectedFutureValue, unaffectedBy: \.structuralStrength
        )
    }

    // MARK: - Pénalités §26.3

    func testInhibitionWeight() throws {
        // Beat à 35,5 s, 0,5 s après l'impact : maintien post-impact au
        // sommet du triangle (inhibition 1,0) ; contraste nul (énergie
        // plate à 0,7 autour).
        try assertWeight(
            at: tick(35.5), increases: false,
            varying: \.inhibition, unaffectedBy: \.contrast
        )
    }

    func testUncertaintyPenaltyWeight() throws {
        // Beat à 5 s, confiance 0,9 : pénalité d'incertitude 0,1 ;
        // composante de résolution nulle.
        try assertWeight(
            at: tick(5), increases: false,
            varying: \.uncertaintyPenalty, unaffectedBy: \.resolutionValue
        )
    }

    // MARK: - overcutPenalty : au niveau du générateur (sélection)

    /// `overcutPenalty` ne vit pas dans l'utilité persistée des ancres
    /// (elle dépend de la densité des coupes déjà activées — voir doc de
    /// `EditAnchor.finalUtility`) : il se vérifie sur les partitions. Sur
    /// la grille dense de beats (0,5 s), un poids élevé doit réduire le
    /// nombre de coupes actives — et rester DÉTERMINISTE.
    func testOvercutPenaltyReducesActiveCutsInDenseZone() throws {
        let analysis = makeWeightsAnalysis()
        let low = try generator.generateScores(
            from: analysis,
            configuration: configuration { $0.overcutPenalty = 0 }
        )
        let high = try generator.generateScores(
            from: analysis,
            configuration: configuration { $0.overcutPenalty = 50 }
        )
        XCTAssertLessThan(
            high.percussive.slots.count, low.percussive.slots.count,
            "Un overcutPenalty élevé doit réduire le nombre de coupes en zone dense"
        )

        // Déterminisme conservé avec le poids élevé.
        let highAgain = try generator.generateScores(
            from: analysis,
            configuration: configuration { $0.overcutPenalty = 50 }
        )
        XCTAssertEqual(
            high.percussive.slots.map(\.start.ticks),
            highAgain.percussive.slots.map(\.start.ticks),
            "Deux générations identiques doivent produire les mêmes frontières"
        )
    }

    // MARK: - Ancres CO-LOCALISÉES : fusion des composantes, pas d'élection

    /// Analyse dédiée à la co-localisation — 20 s à 120 BPM :
    /// - beats tous les 0,5 s, force 0,7, confiance **0,95** (cohérence des
    ///   intervalles) ;
    /// - mesures de 2 s (downbeats à 0, 2, 4… s) de confiance **0,08** —
    ///   l'ordre de grandeur réel d'une marge inter-hypothèses de métrique ;
    /// - sections `[0 s, 9 s]` et `[9 s, 20 s]` : la frontière de 9 s tombe
    ///   sur un beat mais PAS sur un downbeat ;
    /// - courbes plates : nouveauté 0,2, énergie 0,5, stabilité 0,5, aucun
    ///   impact — donc contraste, anticipation et inhibition tous nuls, et
    ///   l'utilité se réduit à `rhythmic + structural + 0,2 − (1 − confiance)`.
    private func makeColocationAnalysis() -> MusicAnalysisResult {
        let durationSeconds = 20.0
        let duration = time(durationSeconds)

        var beats: [BeatEvent] = []
        var beatTime = 0.0
        while beatTime < durationSeconds {
            beats.append(BeatEvent(time: time(beatTime), strength: 0.7, confidence: 0.95))
            beatTime += 0.5
        }

        // Mesures de 4 temps : leur `start` EST un temps de la grille.
        var bars: [BarEvent] = []
        var barIndex = 0
        while Double(barIndex + 1) * 2.0 <= durationSeconds {
            bars.append(BarEvent(
                start: time(Double(barIndex) * 2.0),
                end: time(Double(barIndex + 1) * 2.0),
                index: barIndex,
                confidence: 0.08
            ))
            barIndex += 1
        }

        var units: [StructuralUnit] = [StructuralUnit(
            id: UUID(), parentID: nil, level: .globalArc,
            start: .zero, end: duration, repetitionGroupID: nil,
            boundaryStrengthIn: 1, boundaryStrengthOut: 1,
            descriptors: neutralDescriptors(), confidence: 0.9
        )]
        let sectionEdges = [0.0, 9.0, 20.0]
        for index in 0..<(sectionEdges.count - 1) {
            units.append(StructuralUnit(
                id: UUID(), parentID: nil, level: .section,
                start: time(sectionEdges[index]), end: time(sectionEdges[index + 1]),
                repetitionGroupID: nil,
                boundaryStrengthIn: 0.8, boundaryStrengthOut: 0.8,
                descriptors: neutralDescriptors(), confidence: 0.85
            ))
        }

        var energyCurve: [TimedValue] = []
        var noveltyCurve: [TimedValue] = []
        var stabilityCurve: [TimedValue] = []
        var flatHalf: [TimedValue] = []
        var regularityCurve: [TimedValue] = []
        var zeroCurve: [TimedValue] = []
        var sampleTime = 0.0
        while sampleTime <= durationSeconds {
            let instant = time(sampleTime)
            energyCurve.append(TimedValue(time: instant, value: 0.5))
            noveltyCurve.append(TimedValue(time: instant, value: 0.2))
            stabilityCurve.append(TimedValue(time: instant, value: 0.5))
            flatHalf.append(TimedValue(time: instant, value: 0.5))
            regularityCurve.append(TimedValue(time: instant, value: 0.8))
            zeroCurve.append(TimedValue(time: instant, value: 0))
            sampleTime += 0.5
        }

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
            functionalStates: [],
            musicalEvents: [],
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: energyCurve, density: flatHalf,
                tension: zeroCurve, novelty: noveltyCurve,
                stability: stabilityCurve, regularity: regularityCurve,
                vocalPresence: zeroCurve, bassPresence: flatHalf
            ),
            analysisConfidence: ConfidenceBreakdown(
                overall: 0.8, rhythm: 0.85, structure: 0.75, functions: 0.5
            )
        )
    }

    /// Deux candidats au tick EXACT d'un downbeat (l'ancre de mesure, rang 2,
    /// et l'ancre de beat, rang 3) ne s'éliminent plus : ils fusionnent
    /// composante par composante.
    ///
    /// Avant correctif, le classement par `hierarchyRank` AVANT `finalUtility`
    /// faisait gagner la mesure, qui portait la marge inter-hypothèses de
    /// métrique (0,08 ici) au lieu de la cohérence des intervalles (0,95).
    /// Avec `uncertaintyPenalty` = 1, l'ancre de downbeat valait
    /// `0,9 − 0,92 = −0,02` contre `0,9 − 0,05 = 0,85` pour le beat qu'elle
    /// remplaçait : chaque début de mesure devenait l'ancre la PLUS FAIBLE du
    /// niveau beat et le générateur évitait de couper sur le « 1 ».
    ///
    /// **Règle testée : une frontière de mesure ne vaut jamais MOINS que le
    /// beat qu'elle remplace.** Aujourd'hui elle vaut exactement autant —
    /// la source `downbeat` n'apporte aucune composante d'attraction propre
    /// (`rhythmic` = force du beat co-localisé, `structural` = 0) — d'où
    /// l'égalité stricte vérifiée en plus de l'inégalité.
    func testColocatedDownbeatIsNeverWeakerThanTheBeatItReplaces() throws {
        let field = AnchorFieldBuilder().build(
            from: makeColocationAnalysis(), configuration: .production
        )

        // Un seul point de coupe à 4 s : les deux candidats ont fusionné.
        XCTAssertEqual(field.anchors.filter { $0.center.ticks == tick(4) }.count, 1,
                       "Deux candidats co-localisés doivent produire UNE ancre")

        let downbeat = try XCTUnwrap(field.anchors.first { $0.center.ticks == tick(4) })
        let pureBeat = try XCTUnwrap(field.anchors.first { $0.center.ticks == tick(4.5) })

        // Rang le plus fort conservé (2 = downbeat, contre 3 = beat).
        XCTAssertEqual(downbeat.hierarchyRank, 2)
        XCTAssertEqual(pureBeat.hierarchyRank, 3)

        // MAXIMUM des confiances : 0,95 (le beat) et non 0,08 (la mesure).
        XCTAssertEqual(downbeat.confidence, 0.95, accuracy: 1e-12,
                       "La confiance fusionnée doit être le MAXIMUM des confiances")

        XCTAssertGreaterThanOrEqual(
            downbeat.finalUtility, pureBeat.finalUtility,
            "Une frontière de mesure ne doit JAMAIS valoir moins que le beat qu'elle remplace"
        )
        XCTAssertEqual(downbeat.finalUtility, pureBeat.finalUtility, accuracy: 1e-12,
                       "Égalité attendue : la source downbeat n'ajoute aucune attraction propre")

        // Raisons cumulées, et une SEULE mention de confiance, en dernier
        // (§29) — la fusion amont supprime la duplication que produisait le
        // cumul des raisons après évaluation.
        XCTAssertTrue(downbeat.reasons.contains("Downbeat fort"))
        XCTAssertTrue(downbeat.reasons.contains("Beat"))
        XCTAssertEqual(downbeat.reasons.filter { $0.hasPrefix("Confiance ") }.count, 1)
        XCTAssertEqual(downbeat.reasons.last, "Confiance 0,95")
    }

    /// Même mécanisme pour une frontière de SECTION posée sur un beat
    /// (9 s) : l'ancre cumule `structural` 0,8 et `rhythmic` 0,7 au lieu de
    /// perdre la composante rythmique du candidat évincé. La hiérarchie
    /// d'utilité section > beat devient donc STRICTE, et non plus dépendante
    /// du seul rang.
    func testColocatedSectionBoundaryKeepsTheBeatRhythmicComponent() throws {
        let field = AnchorFieldBuilder().build(
            from: makeColocationAnalysis(), configuration: .production
        )

        let section = try XCTUnwrap(field.anchors.first { $0.center.ticks == tick(9) })
        let pureBeat = try XCTUnwrap(field.anchors.first { $0.center.ticks == tick(9.5) })

        XCTAssertEqual(section.hierarchyRank, 0, "Le rang le plus fort du groupe est conservé")
        XCTAssertTrue(field.majorAnchorIDs.contains(section.id))
        XCTAssertTrue(section.reasons.contains("Nouvelle section"))
        XCTAssertTrue(section.reasons.contains("Beat"),
                      "La composante du beat co-localisé ne doit pas disparaître")

        // attraction = rhythmic 0,7 + structural 0,8 + novelty 0,2 = 1,7 ;
        // uncertainty = 1 − max(0,85 ; 0,95) = 0,05 → utilité 1,65.
        // Avant correctif, le candidat de section évinçait le beat et
        // l'attraction tombait à 1,0 (utilité 0,85, soit celle du beat seul).
        XCTAssertEqual(section.finalUtility, 1.65, accuracy: 1e-9)
        XCTAssertGreaterThan(section.finalUtility, pureBeat.finalUtility + 0.5,
                             "Une frontière de section doit dominer nettement un beat ordinaire")
    }
}
