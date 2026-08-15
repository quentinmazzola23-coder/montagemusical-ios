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
//  Ajouts (correctifs de la critique, trous d'oracle 13b et §28.4) :
//  - `testEveryBoundaryFallsOnTheBeatGrid` : TOUTE frontière de TOUT mode
//    coïncide avec un beat, tolérance nulle — la promesse centrale du
//    produit n'était vérifiée nulle part ;
//  - `testCutDensityFollowsUtilityNotClock` : la densité de coupe suit
//    l'utilité (§28.4), mesurée sur une fixture à deux zones ;
//  - `testModesAreDistinct` durci en inégalités STRICTES et en
//    sous-ensembles PROPRES (avec des `>=`, trois partitions identiques
//    satisfaisaient le test).
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
    ///
    /// NOTE — l'analyse fournit des `BarEvent` (mesures de 2 s), donc le
    /// détecteur de gestes travaille en MESURES : le maintien de l'impact
    /// de 15 s cherche sa sortie dans [16,5 s ; 17,5 s] (≈ une mesure) et
    /// la respiration qui suit dure une mesure. La zone protégée fait donc
    /// ~2 mesures au lieu de ~1,5 beat — c'est l'objet du correctif S2.
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

    /// Analyse « deux zones d'utilité » (§28.4) : 64 s à 120 BPM, deux
    /// sections de 32 s séparées à 32 s, MÊME grille de beats partout
    /// (0,5 s) — seule l'UTILITÉ des ancres change d'une zone à l'autre.
    ///
    /// Zone basse (intro, 0–32 s) : beats faibles (force 0,20) et peu sûrs
    /// (confiance 0,55 → pénalité d'incertitude 0,45), nouveauté 0,02 (donc
    /// inhibition `noChange` = 0,4), énergie plate.
    ///   utilité ≈ 0,20 + 0,02 − 0,40 − 0,45 = **−0,63**
    /// Zone haute (drop, 32–64 s) : beats forts (0,95) et sûrs (0,95),
    /// nouveauté 0,30, trois impacts à 34/44/54 s.
    ///   utilité ≈ 0,95 + 0,30 − 0,05 = **+1,20**
    ///
    /// ÉCART D'UTILITÉ ≈ **1,83**, au-dessus du point de bascule d'environ
    /// **1,1** identifié par la critique : en dessous, le coût quadratique
    /// (`targetSlotDuration`) domine seul et la cadence devient plate dans
    /// les deux zones ; au-dessus, elle se différencie. C'est le paramètre
    /// que ce test documente, et la raison pour laquelle il n'utilise PAS
    /// des utilités extrêmes : les valeurs ci-dessus sont celles qu'un
    /// morceau réellement contrasté produit.
    ///
    /// Aucune mesure (`bars` vide) : on évite ainsi les ancres de downbeat,
    /// qui donneraient deux utilités différentes à l'intérieur d'une même
    /// zone et brouilleraient la mesure. Stabilité 0,30 et tension 0,10
    /// partout : ni maintien (§27 `impactHold`, seuil 0,45) ni montée
    /// (§27 `burstResolution`, seuil 0,35) — les impacts restent de simples
    /// accents, donc aucune zone sans coupe ne vient perturber la densité.
    private func makeContrastedUtilityAnalysis() -> MusicAnalysisResult {
        let durationSeconds = 64.0
        let dropStartSeconds = 32.0
        let duration = time(durationSeconds)

        // Grille de beats IDENTIQUE dans les deux zones : seules la force
        // et la confiance changent.
        var beats: [BeatEvent] = []
        var beatTime = 0.0
        while beatTime < durationSeconds {
            let isDrop = beatTime >= dropStartSeconds
            beats.append(BeatEvent(
                time: time(beatTime),
                strength: isDrop ? 0.95 : 0.20,
                confidence: isDrop ? 0.95 : 0.55
            ))
            beatTime += 0.5
        }

        // Structure : arc global + deux sections. Aucune phrase : les
        // seules frontières RACINES sont 0 / 32 / 64 s, ce qui laisse
        // chaque zone entièrement au raffinement.
        var units: [StructuralUnit] = [StructuralUnit(
            id: UUID(), parentID: nil, level: .globalArc,
            start: .zero, end: duration, repetitionGroupID: nil,
            boundaryStrengthIn: 1, boundaryStrengthOut: 1,
            descriptors: neutralDescriptors(), confidence: 0.9
        )]
        let sectionEdges = [0.0, dropStartSeconds, durationSeconds]
        for index in 0..<(sectionEdges.count - 1) {
            units.append(StructuralUnit(
                id: UUID(), parentID: nil, level: .section,
                start: time(sectionEdges[index]), end: time(sectionEdges[index + 1]),
                repetitionGroupID: nil,
                boundaryStrengthIn: 0.9, boundaryStrengthOut: 0.9,
                descriptors: neutralDescriptors(), confidence: 0.85
            ))
        }

        var energyCurve: [TimedValue] = []
        var tensionCurve: [TimedValue] = []
        var noveltyCurve: [TimedValue] = []
        var stabilityCurve: [TimedValue] = []
        var flatCurve: [TimedValue] = []
        var zeroCurve: [TimedValue] = []
        var sampleTime = 0.0
        while sampleTime <= durationSeconds {
            let instant = time(sampleTime)
            let isDrop = sampleTime >= dropStartSeconds
            energyCurve.append(TimedValue(time: instant, value: isDrop ? 0.75 : 0.30))
            tensionCurve.append(TimedValue(time: instant, value: isDrop ? 0.10 : 0.05))
            noveltyCurve.append(TimedValue(time: instant, value: isDrop ? 0.30 : 0.02))
            stabilityCurve.append(TimedValue(time: instant, value: 0.30))
            flatCurve.append(TimedValue(time: instant, value: 0.5))
            zeroCurve.append(TimedValue(time: instant, value: 0))
            sampleTime += 0.5
        }

        // Impacts du drop, sur des temps, espacés de 10 s.
        let events: [MusicalEvent] = [34.0, 44.0, 54.0].map { seconds in
            MusicalEvent(
                id: UUID(), type: .impact, geometry: .point,
                start: time(seconds), end: nil,
                salience: 0.9, confidence: 0.7,
                evidence: [EvidenceContribution(source: "test.energy", weight: 1)]
            )
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
            bars: [],
            structuralUnits: units,
            functionalStates: [],
            musicalEvents: events,
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: energyCurve, density: flatCurve,
                tension: tensionCurve, novelty: noveltyCurve,
                stability: stabilityCurve, regularity: flatCurve,
                vocalPresence: zeroCurve, bassPresence: flatCurve
            ),
            analysisConfidence: ConfidenceBreakdown(
                overall: 0.7, rhythm: 0.8, structure: 0.7, functions: 0.4
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
        let gestures = GestureDetector().detect(
            analysis: analysis, field: field, configuration: .production
        )
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
        let gestures = GestureDetector().detect(
            analysis: analysis, field: field, configuration: .production
        )
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

    // MARK: - §28.1 : deux majeures à < 0,75 s — la plus faible est RÉTROGRADÉE

    /// Une frontière de section (rang 0) à 20 s et une frontière de phrase
    /// (rang 1) à 20,4 s : à moins du plancher fluide (0,75 s), elles ne
    /// peuvent pas être toutes deux frontières RACINES (§28.3.1).
    ///
    /// REMPLACE `testCloseMajorBoundariesMergeIntoSingleMajorAnchor`. La
    /// passe 2 de `AnchorFieldBuilder` ne SUPPRIME plus la perdante — elle la
    /// RÉTROGRADE (rang 4, sortie de `majorAnchorIDs`). L'ancienne propriété
    /// (« l'ancre de 20,4 s n'existe plus ») décrivait un défaut : le champ
    /// d'ancres est PARTAGÉ par les trois modes, et supprimer imposait le
    /// plancher du mode le plus lent (0,75 s) à Percutant (0,25 s) — 0,4 s
    /// est pourtant une case parfaitement légitime en Percutant.
    ///
    /// Ce qui est vérifié maintenant :
    /// 1. une SEULE majeure dans la zone (la section, rang 0) ;
    /// 2. la perdante est TOUJOURS dans `anchors`, au rang rétrogradé, hors
    ///    de `majorAnchorIDs`, et porte la raison §29 de rétrogradation ;
    /// 3. la majeure conservée est frontière des TROIS modes (§28.1) ;
    /// 4. l'invariant exigé par `buildRoot` tient toujours : deux majeures
    ///    consécutives sont espacées d'au moins le plancher fluide.
    func testCloseMajorBoundariesDemoteTheWeakerMajor() throws {
        let analysis = makeCloseMajorsAnalysis()
        let field = AnchorFieldBuilder().build(from: analysis, configuration: .production)

        let zoneAnchors = field.anchors
            .filter { $0.center.ticks >= tick(20) && $0.center.ticks <= tick(20.4) }
            .sorted { $0.center.ticks < $1.center.ticks }
        XCTAssertEqual(zoneAnchors.count, 2,
                       "La perdante est rétrogradée, jamais retirée du champ")

        let major = try XCTUnwrap(zoneAnchors.first)
        XCTAssertEqual(major.center.ticks, tick(20), "La section (rang 0) reste majeure")
        XCTAssertTrue(field.majorAnchorIDs.contains(major.id))
        XCTAssertTrue(major.reasons.contains("Nouvelle section"))

        let demoted = try XCTUnwrap(zoneAnchors.last)
        XCTAssertEqual(demoted.center.ticks, tick(20.4))
        XCTAssertFalse(field.majorAnchorIDs.contains(demoted.id),
                       "Une rétrogradée sort de `majorAnchorIDs`")
        XCTAssertEqual(demoted.hierarchyRank, 4, "Rang de rétrogradation")
        XCTAssertTrue(demoted.reasons.contains("Frontière de phrase"),
                      "L'ancre garde sa propre raison d'origine")
        XCTAssertTrue(demoted.reasons.contains("Rétrogradée : majeure trop proche"),
                      "Explicabilité §29 : la rétrogradation doit être dite")

        // Invariant exigé par `buildRoot` : deux majeures CONSÉCUTIVES sont
        // espacées d'au moins le plancher fluide.
        let majorTicks = field.anchors
            .filter { field.majorAnchorIDs.contains($0.id) }
            .map(\.center.ticks)
            .sorted()
        let fluidFloor = ScoreConfiguration.production.minimumSlotDurationFluid.ticks
        for (previous, next) in zip(majorTicks, majorTicks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                next - previous, fluidFloor,
                "Deux majeures consécutives doivent rester à ≥ plancher fluide"
            )
        }

        // La majeure conservée est frontière dans les trois modes (§28.1).
        let family = try generator.generateScores(from: analysis, configuration: .production)
        for score in allScores(family) {
            let boundaries = Set(boundaryTicks(score))
            XCTAssertTrue(boundaries.contains(tick(20)),
                          "\(score.mode) : la majeure conservée doit être frontière")
        }
    }

    // MARK: - §80 : modes cohérents et distincts

    /// DURCI : toutes les inégalités sont STRICTES, et l'imbrication est
    /// asserted comme sous-ensemble PROPRE. Avec des `>=`, trois partitions
    /// rigoureusement IDENTIQUES satisfont le test — c'est exactement le
    /// scénario de régression qu'il doit attraper (un mode qui cesse de
    /// raffiner, un plancher mal lu, une séquence d'activations épuisée dès
    /// Fluide). Les trois durées moyennes sont ici légitimement STRICTEMENT
    /// décroissantes : la durée totale est la même dans les trois modes,
    /// donc un nombre de cases strictement croissant impose une moyenne
    /// strictement décroissante.
    func testModesAreDistinct() throws {
        let family = try generator.generateScores(from: makeRichAnalysis(), configuration: .production)
        XCTAssertGreaterThan(family.percussive.slots.count, family.balanced.slots.count,
                             "Percutant doit être plus dense qu'Équilibré")
        XCTAssertGreaterThan(family.balanced.slots.count, family.fluid.slots.count,
                             "Équilibré doit être plus dense que Fluide")

        // Durées moyennes strictement décroissantes.
        XCTAssertGreaterThan(family.fluid.averageDuration.ticks,
                             family.balanced.averageDuration.ticks,
                             "Fluide doit avoir des plans strictement plus longs qu'Équilibré")
        XCTAssertGreaterThan(family.balanced.averageDuration.ticks,
                             family.percussive.averageDuration.ticks,
                             "Équilibré doit avoir des plans strictement plus longs que Percutant")

        // Imbrication §70 en sous-ensemble PROPRE : inclusion ET différence.
        let fluid = Set(boundaryTicks(family.fluid))
        let balanced = Set(boundaryTicks(family.balanced))
        let percussive = Set(boundaryTicks(family.percussive))
        XCTAssertTrue(fluid.isStrictSubset(of: balanced),
                      "Équilibré doit ajouter au moins une frontière à Fluide")
        XCTAssertTrue(balanced.isStrictSubset(of: percussive),
                      "Percutant doit ajouter au moins une frontière à Équilibré")
    }

    // MARK: - §19/§26 : TOUTES les frontières tombent sur la grille de beats

    /// Le trou d'oracle le plus criant de la suite d'origine : aucune
    /// assertion ne garantissait que les coupes tombent sur des TEMPS. Une
    /// régression du champ d'ancres (fenêtre optimale utilisée comme
    /// centre, déplacement §28.2 réintroduit, arrondi en secondes) rendrait
    /// des frontières hors grille sans qu'aucun test ne bronche, alors que
    /// c'est la promesse centrale du produit.
    ///
    /// TOLÉRANCE NULLE, et c'est le seul choix défendable ici : `MediaTime`
    /// est un compteur de ticks ENTIERS, `AnchorFieldBuilder` recopie
    /// verbatim le tick de l'événement source dans `center`, et le
    /// générateur ne peut poser une frontière qu'AU `center` d'une ancre —
    /// aucun chemin flottant n'intervient. Une tolérance non nulle
    /// masquerait exactement le défaut recherché.
    ///
    /// Deux exceptions admises, et deux seulement : le tick 0 et la fin
    /// ABSOLUE du morceau, frontières imposées par §28.1 qui ne coïncident
    /// pas nécessairement avec un temps (ici la fixture dure 60 s alors que
    /// le dernier beat est à 59,5 s).
    func testEveryBoundaryFallsOnTheBeatGrid() throws {
        let analysis = makeRichAnalysis()
        let family = try generator.generateScores(from: analysis, configuration: .production)
        let beatGrid = Set(analysis.beats.map(\.time.ticks))
        XCTAssertFalse(beatGrid.isEmpty, "Fixture invalide : aucune pulsation")

        for score in allScores(family) {
            let boundaries = boundaryTicks(score)
            XCTAssertGreaterThan(boundaries.count, 2,
                                 "\(score.mode) : partition trop pauvre pour que le test ait du sens")
            for boundary in boundaries {
                // Seules exceptions : les deux frontières imposées §28.1.
                if boundary == 0 || boundary == analysis.duration.ticks { continue }
                XCTAssertTrue(
                    beatGrid.contains(boundary),
                    "\(score.mode) : frontière à \(boundary) ticks hors de la grille de beats"
                )
            }
        }
    }

    // MARK: - §28.4 : la densité de coupe suit l'UTILITÉ, pas l'horloge

    /// Propriété §28.4 — « les coupes vont où le gain est maximal, pas
    /// uniformément » — jusqu'ici jamais testée. Deux zones de 32 s à la
    /// MÊME grille de beats : une intro d'utilité ≈ −0,63 et un drop
    /// d'utilité ≈ +1,20 (voir `makeContrastedUtilityAnalysis`). Si le
    /// moteur ne faisait que viser `targetSlotDuration`, les deux zones
    /// auraient la même cadence.
    ///
    /// Attendu en Percutant (cible 0,6 s, seuil 0,05, plancher 0,25 s) :
    /// - intro, découpe d'un intervalle de 1,0 s en 0,5 + 0,5 :
    ///   gain = 0,389 (intervalles) − 0,63 (utilité) − 0,5 (coupe) ≈ −0,74
    ///   → REFUSÉ, la zone se stabilise vers 1,0 s ;
    /// - drop, même découpe : 0,389 + 1,20 − 0,5 − surdécoupage (≈ 0,4)
    ///   ≈ +0,69 → ACCEPTÉ, la zone descend au pas de la grille (0,5 s).
    /// Soit un facteur de cadence ≈ 2. Le seuil de l'assertion est fixé à
    /// **1,5** pour laisser respirer les perturbations locales (inhibition
    /// `postImpactHold` juste après chaque impact, anticipation juste
    /// avant), sans jamais pouvoir être satisfait par une cadence plate.
    ///
    /// POINT DE BASCULE documenté : avec les constantes V1 (`addedCutCost`
    /// 0,5, `overcutDensityScale` 0,1, seuils 0,05/0,12/0,30), la
    /// différenciation apparaît à partir d'un écart d'utilité d'environ
    /// **1,1** entre les deux zones. La fixture est à ≈ 1,83. Un master
    /// très écrasé passerait sous ce seuil et rendrait la cadence plate :
    /// c'est une propriété du réglage, pas un défaut du test.
    func testCutDensityFollowsUtilityNotClock() throws {
        let analysis = makeContrastedUtilityAnalysis()
        let family = try generator.generateScores(from: analysis, configuration: .production)
        let score = family.percussive
        assertStructurallyValid(score, duration: analysis.duration)

        let border = tick(32)
        let lowUtilityZone = score.slots.filter { $0.end.ticks <= border }
        let highUtilityZone = score.slots.filter { $0.start.ticks >= border }
        XCTAssertFalse(lowUtilityZone.isEmpty, "Zone d'intro vide")
        XCTAssertFalse(highUtilityZone.isEmpty, "Zone de drop vide")
        XCTAssertEqual(lowUtilityZone.count + highUtilityZone.count, score.slots.count,
                       "La frontière de section à 32 s doit être une coupe : aucune case ne l'enjambe")

        func averageDurationSeconds(_ slots: [EditSlotDefinition]) -> Double {
            let total = slots.reduce(Int64(0)) { $0 + ($1.end.ticks - $1.start.ticks) }
            return Double(total) / Double(slots.count) / 60_000
        }
        let lowAverage = averageDurationSeconds(lowUtilityZone)
        let highAverage = averageDurationSeconds(highUtilityZone)

        // Cadence = coupes par seconde = 1 / durée moyenne : le rapport des
        // cadences est donc le rapport INVERSE des durées moyennes.
        let cadenceRatio = lowAverage / highAverage
        XCTAssertGreaterThanOrEqual(
            cadenceRatio, 1.5,
            """
            §28.4 : la zone à forte utilité doit être nettement plus dense. \
            Moyennes mesurées — intro \(lowAverage) s, drop \(highAverage) s, \
            rapport \(cadenceRatio).
            """
        )
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
