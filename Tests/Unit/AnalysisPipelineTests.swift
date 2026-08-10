//
//  AnalysisPipelineTests.swift
//  MontageMusicalTests
//
//  Intégration bout-en-bout du moteur déterministe (Jalon 4, §79) SANS
//  interface : audio synthétique (TestAudioFactory, agent DSP) →
//  `DeterministicMusicAnalyzer.analyze` → vérifications tempo, beats,
//  durée, phases §33, déterminisme, cache §69, annulation/reprise §8/§63
//  et honnêteté des événements (§0.7 : jamais de contenu inventé).
//
//  Audio synthétique : `TestAudioFactory` (agent DSP) — WAV PCM 16 bits
//  mono écrits à la main, signaux entièrement déterministes (LCG seedé).
//  Convention de phase du click track : le clic k tombe à
//  (k + 0,5) × 60/bpm secondes.
//

import XCTest
@testable import MontageMusical

final class AnalysisPipelineTests: XCTestCase {

    private var rootURL: URL!
    private var fileStore: ProjectFileStore!
    private var cache: AnalysisCache!
    private var analyzer: DeterministicMusicAnalyzer!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "AnalysisPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileStore = ProjectFileStore(rootURL: rootURL)
        cache = AnalysisCache(fileStore: fileStore)
        analyzer = DeterministicMusicAnalyzer(cache: cache, fileStore: fileStore)
    }

    override func tearDownWithError() throws {
        analyzer = nil
        cache = nil
        fileStore = nil
        if let rootURL, FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    // MARK: - Helpers

    /// Fréquence d'échantillonnage des WAV de test (le flux d'analyse
    /// rééchantillonne à 22 050 Hz — §16.2 ; 44 100 exerce ce chemin).
    private static let wavSampleRate = 44_100

    /// Écrit un click track 128 BPM de `seconds` secondes.
    private static func writeClickTrack(seconds: Double, to url: URL) throws {
        try TestAudioFactory.writeWav(
            samples: TestAudioFactory.clickTrack(bpm: 128, seconds: seconds, sampleRate: wavSampleRate),
            sampleRate: wavSampleRate,
            to: url
        )
    }

    /// Crée un projet (arbre §11) et y place le WAV fourni par `write`.
    private func makeProject(
        write: (URL) throws -> Void,
        durationSeconds: Double
    ) throws -> (projectID: UUID, audio: ImportedAudio) {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        let audioURL = fileStore
            .subdirectoryURL(.audio, for: projectID)
            .appending(path: "original.wav")
        try write(audioURL)
        let audio = ImportedAudio(
            projectID: projectID,
            relativePath: "audio/original.wav",
            originalFilename: "original.wav",
            duration: MediaTime(seconds: durationSeconds),
            fileExtension: "wav"
        )
        return (projectID, audio)
    }

    /// Collecteur thread-safe des progressions publiées.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AnalysisProgress] = []
        func append(_ progress: AnalysisProgress) {
            lock.lock()
            items.append(progress)
            lock.unlock()
        }
        var all: [AnalysisProgress] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// Poignée d'annulation thread-safe pour le test (g).
    private final class CancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<MusicAnalysisResult, Error>?
        func store(_ task: Task<MusicAnalysisResult, Error>) {
            lock.lock()
            self.task = task
            lock.unlock()
        }
        func cancel() {
            lock.lock()
            task?.cancel()
            lock.unlock()
        }
    }

    private func checkpointURL(projectID: UUID) -> URL {
        fileStore
            .subdirectoryURL(.analysis, for: projectID)
            .appending(path: "checkpoint-v1.json")
    }

    /// Miroir `Codable` du payload rythme de phase 2 du checkpoint — mêmes
    /// clés que `RhythmCheckpointPayload` (privé dans
    /// `DeterministicMusicAnalyzer`), encodage property list binaire.
    /// Permet de fabriquer un checkpoint SENTINELLE pour prouver la
    /// consommation du checkpoint à la reprise (test g, §8.1, §63).
    private struct RhythmCheckpointPayloadMirror: Codable {
        let hypotheses: [RhythmHypothesis]
        let selectedHypothesisID: UUID
        let beats: [BeatEvent]
        let bars: [BarEvent]
        let downbeatConfidence: Double
    }

    // MARK: - (a)(b)(c)(d) Click track 128 BPM, 10 s

    func testClickTrackTempoBeatsDurationAndPhases() async throws {
        let (_, audio) = try makeProject(
            write: { try Self.writeClickTrack(seconds: 10, to: $0) },
            durationSeconds: 10
        )
        let log = ProgressLog()
        let result = try await analyzer.analyze(audio: audio, configuration: .production) { progress in
            log.append(progress)
        }

        // (a) Hypothèse RETENUE à ~128 BPM. Le prior de tempo log-normal
        // (centré 120 BPM, σ = 0,5 octave) et le bonus sous-harmonique
        // réduit rendent le choix de la famille pleine déterministe sur un
        // click track pur (§19.1). Ceinture de sécurité : on vérifie
        // d'abord que 128 figure dans la famille half/double de la retenue
        // (§63 : tempo ambigu → hypothèses conservées), puis strictement
        // que la RETENUE elle-même est à 128 ±4.
        let selected = try XCTUnwrap(
            result.rhythmHypotheses.first { $0.id == result.selectedRhythmHypothesisID },
            "L'hypothèse retenue doit figurer dans rhythmHypotheses"
        )
        var candidateTempos = [selected.tempoBPM]
        if let halfID = selected.halfTimeRelation,
           let half = result.rhythmHypotheses.first(where: { $0.id == halfID }) {
            candidateTempos.append(half.tempoBPM)
        }
        if let doubleID = selected.doubleTimeRelation,
           let double = result.rhythmHypotheses.first(where: { $0.id == doubleID }) {
            candidateTempos.append(double.tempoBPM)
        }
        XCTAssertTrue(
            candidateTempos.contains { abs($0 - 128) <= 4 },
            "128 BPM attendu dans l'hypothèse retenue ou ses relations half/double : \(candidateTempos)"
        )
        XCTAssertEqual(
            selected.tempoBPM, 128, accuracy: 4,
            "Le prior de tempo doit retenir la famille pleine (~128 BPM), pas le half-time"
        )

        // (b) Beats réguliers, période relative au tempo RETENU (jamais une
        // valeur codée en dur) : période attendue = 60/selected.tempoBPM.
        let expectedPeriod = 60.0 / selected.tempoBPM
        let expectedBeatCount = Int((10.0 * selected.tempoBPM / 60.0).rounded(.down)) - 1
        XCTAssertGreaterThanOrEqual(
            result.beats.count, expectedBeatCount,
            "≥ floor(durée × tempo retenu / 60) − 1 beats attendus sur 10 s"
        )
        let intervals = zip(result.beats.dropFirst(), result.beats)
            .map { $0.time.seconds - $1.time.seconds }
        let median = try XCTUnwrap(
            intervals.sorted().dropFirst(intervals.count / 2).first,
            "Au moins un intervalle entre beats attendu"
        )
        XCTAssertEqual(median, expectedPeriod, accuracy: expectedPeriod * 0.05)
        let regularCount = intervals.count { abs($0 - expectedPeriod) <= expectedPeriod * 0.1 }
        XCTAssertGreaterThanOrEqual(
            Double(regularCount), Double(intervals.count) * 0.8,
            "Au moins 80 % des intervalles doivent rester proches de la période retenue"
        )

        // (c) Durée ±100 ms.
        XCTAssertEqual(result.duration.seconds, 10.0, accuracy: 0.1)

        // (d) Progression : publiée au moins 4 fois, les 4 phases §33 du
        // Jalon 4 dans l'ordre, et JAMAIS « Création des rythmes »
        // (générateur de scores = Jalon 5).
        let published = log.all
        XCTAssertGreaterThanOrEqual(published.count, 4)
        var phasesInOrder: [AnalysisPhase] = []
        for progress in published where !phasesInOrder.contains(progress.phase) {
            phasesInOrder.append(progress.phase)
        }
        XCTAssertEqual(
            phasesInOrder,
            [.audioPreparation, .pulseAndTempo, .phrasesAndStructure, .buildUpsAndImpacts]
        )
        XCTAssertFalse(published.contains { $0.phase == .rhythmCreation })
    }

    // MARK: - (e) Déterminisme entre projets distincts (caches vides)

    func testDeterminismAcrossDistinctProjects() async throws {
        // Même contenu audio octet à octet dans deux projets différents.
        let sourceURL = rootURL.appending(path: "click-source.wav")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Self.writeClickTrack(seconds: 10, to: sourceURL)
        let (_, audioA) = try makeProject(
            write: { try FileManager.default.copyItem(at: sourceURL, to: $0) },
            durationSeconds: 10
        )
        let (_, audioB) = try makeProject(
            write: { try FileManager.default.copyItem(at: sourceURL, to: $0) },
            durationSeconds: 10
        )

        let resultA = try await analyzer.analyze(audio: audioA, configuration: .production) { _ in }
        let resultB = try await analyzer.analyze(audio: audioB, configuration: .production) { _ in }

        XCTAssertEqual(resultA.beats.count, resultB.beats.count, "Mêmes beats attendus (déterminisme)")
        for (beatA, beatB) in zip(resultA.beats, resultB.beats) {
            XCTAssertEqual(beatA.time.ticks, beatB.time.ticks)
            XCTAssertEqual(beatA.strength, beatB.strength, accuracy: 1e-9)
            XCTAssertEqual(beatA.confidence, beatB.confidence, accuracy: 1e-9)
        }
        let selectedA = try XCTUnwrap(resultA.rhythmHypotheses.first { $0.id == resultA.selectedRhythmHypothesisID })
        let selectedB = try XCTUnwrap(resultB.rhythmHypotheses.first { $0.id == resultB.selectedRhythmHypothesisID })
        XCTAssertEqual(selectedA.tempoBPM, selectedB.tempoBPM, accuracy: 1e-9)

        // Phases 3/4 : mêmes champs HORS UUID (les identifiants sont générés
        // à chaque analyse, tout le reste doit être identique — ticks exacts
        // §9, flottants à 1e-9 près).
        XCTAssertEqual(resultA.structuralUnits.count, resultB.structuralUnits.count,
                       "Mêmes unités structurelles attendues (déterminisme)")
        for (unitA, unitB) in zip(resultA.structuralUnits, resultB.structuralUnits) {
            XCTAssertEqual(unitA.level, unitB.level)
            XCTAssertEqual(unitA.start.ticks, unitB.start.ticks)
            XCTAssertEqual(unitA.end.ticks, unitB.end.ticks)
        }
        XCTAssertEqual(resultA.musicalEvents.count, resultB.musicalEvents.count,
                       "Mêmes événements musicaux attendus (déterminisme)")
        for (eventA, eventB) in zip(resultA.musicalEvents, resultB.musicalEvents) {
            XCTAssertEqual(eventA.type, eventB.type)
            XCTAssertEqual(eventA.start.ticks, eventB.start.ticks)
            XCTAssertEqual(eventA.end?.ticks, eventB.end?.ticks)
        }
        XCTAssertEqual(resultA.continuousCurves.energy.count, resultB.continuousCurves.energy.count,
                       "Même courbe d'énergie attendue (déterminisme)")
        for (pointA, pointB) in zip(resultA.continuousCurves.energy, resultB.continuousCurves.energy) {
            XCTAssertEqual(pointA.time.ticks, pointB.time.ticks)
            XCTAssertEqual(pointA.value, pointB.value, accuracy: 1e-9)
        }
        XCTAssertEqual(resultA.analysisConfidence.overall, resultB.analysisConfidence.overall, accuracy: 1e-9)
        XCTAssertEqual(resultA.analysisConfidence.rhythm, resultB.analysisConfidence.rhythm, accuracy: 1e-9)
        XCTAssertEqual(resultA.analysisConfidence.structure, resultB.analysisConfidence.structure, accuracy: 1e-9)
        XCTAssertEqual(resultA.analysisConfidence.functions, resultB.analysisConfidence.functions, accuracy: 1e-9)
    }

    // MARK: - (f) Cache : second analyze du MÊME projet identique (§69)

    func testSecondAnalyzeOnSameProjectReturnsIdenticalCachedResult() async throws {
        let (_, audio) = try makeProject(
            write: { try Self.writeClickTrack(seconds: 10, to: $0) },
            durationSeconds: 10
        )
        let first = try await analyzer.analyze(audio: audio, configuration: .production) { _ in }
        let secondLog = ProgressLog()
        let second = try await analyzer.analyze(audio: audio, configuration: .production) { progress in
            secondLog.append(progress)
        }

        // Identité octet à octet (encodeur à clés triées) : identifiants
        // compris — le second appel vient du cache, rien n'est recalculé.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))

        // §69 : cache complet → retour immédiat, AUCUNE phase relancée NI
        // publiée — le second appel ne doit produire aucune progression.
        XCTAssertTrue(
            secondLog.all.isEmpty,
            "Aucune progression attendue sur cache complet ; reçues : \(secondLog.all.map(\.phase))"
        )
    }

    // MARK: - (g) Annulation → checkpoint conservé → reprise (§8, §63, §79)

    func testCancellationKeepsCheckpointThenResumeSucceeds() async throws {
        let (projectID, audio) = try makeProject(
            write: { try Self.writeClickTrack(seconds: 10, to: $0) },
            durationSeconds: 10
        )
        let box = CancellationBox()
        let localAnalyzer = analyzer!
        let task = Task<MusicAnalysisResult, Error> {
            // Petit délai pour garantir que la poignée est stockée avant la
            // première publication de phase.
            try? await Task.sleep(for: .milliseconds(50))
            return try await localAnalyzer.analyze(audio: audio, configuration: .production) { progress in
                // Annule dès l'entrée en phase 2 : le checkpoint de la
                // phase 1 (« Préparation audio ») est déjà sur disque.
                if progress.phase == .pulseAndTempo {
                    box.cancel()
                }
            }
        }
        box.store(task)

        do {
            _ = try await task.value
            XCTFail("CancellationError attendue")
        } catch is CancellationError {
            // Attendu (§8 : annulation coopérative entre les phases).
        }

        // Le checkpoint du dernier jalon terminé est conservé (§63) — et son
        // CONTENU est exactement celui de la phase 1 : l'annulation a eu
        // lieu à l'entrée de la phase 2, avant le jalon de phase 2.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: checkpointURL(projectID: projectID).path(percentEncoded: false)
            ),
            "checkpoint-v1.json doit exister après annulation"
        )
        let checkpointData = try Data(contentsOf: checkpointURL(projectID: projectID))
        let checkpoint = try JSONDecoder().decode(AnalysisCheckpoint.self, from: checkpointData)
        XCTAssertEqual(
            checkpoint.completedPhases, [AnalysisPhase.audioPreparation.rawValue],
            "Seule la phase 1 (« Préparation audio ») doit être complète après annulation en phase 2"
        )
        XCTAssertFalse(checkpoint.fingerprint.isEmpty, "Empreinte audio+configuration attendue")
        XCTAssertEqual(checkpoint.engineVersion, DeterministicMusicAnalyzer.engineVersion)
        XCTAssertNotNil(checkpoint.featureTimelineData, "Caractéristiques de la phase 1 attendues")
        XCTAssertNil(checkpoint.rhythmData, "La phase 2 n'était pas terminée")

        // Preuve de CONSOMMATION du checkpoint à la reprise — méthode du
        // payload rythme SENTINELLE. Justification : l'analyseur republie la
        // progression de TOUTES les phases même en reprise (la phase 1 est
        // publiée AVANT la consultation du checkpoint dans
        // `DeterministicMusicAnalyzer.analyze`), donc l'absence d'une phase
        // dans un ProgressLog ne prouverait rien. En revanche, en
        // réécrivant le checkpoint avec des beats sentinelles à des ticks
        // connus (phases 1+2 « complètes », mêmes empreinte/version), un
        // résultat final contenant EXACTEMENT ces beats ne peut provenir que
        // du checkpoint : une analyse fraîche du click track 128 BPM ne
        // produirait jamais ces valeurs.
        let sentinelHypothesisID = UUID()
        let sentinelHypothesis = RhythmHypothesis(
            id: sentinelHypothesisID,
            tempoBPM: 60,
            tempoCurve: [TimedValue(time: .zero, value: 60)],
            meterNumerator: 4,
            meterDenominator: 4,
            phaseOffset: .zero,
            probability: 1,
            halfTimeRelation: nil,
            doubleTimeRelation: nil
        )
        // Beats sentinelles à 1 s, 2 s, … 8 s (ticks exacts §9), avec des
        // force/confiance qu'aucune vraie analyse ne reproduirait.
        let sentinelBeats = (1...8).map { index in
            BeatEvent(
                time: MediaTime(ticks: Int64(index) * 60_000),
                strength: 0.123456789,
                confidence: 0.987654321
            )
        }
        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .binary
        let sentinelRhythmData = try plistEncoder.encode(RhythmCheckpointPayloadMirror(
            hypotheses: [sentinelHypothesis],
            selectedHypothesisID: sentinelHypothesisID,
            beats: sentinelBeats,
            bars: [],
            downbeatConfidence: 0
        ))
        try cache.saveCheckpoint(
            AnalysisCheckpoint(
                fingerprint: checkpoint.fingerprint,
                engineVersion: checkpoint.engineVersion,
                completedPhases: [
                    AnalysisPhase.audioPreparation.rawValue,
                    AnalysisPhase.pulseAndTempo.rawValue,
                ],
                featureTimelineData: checkpoint.featureTimelineData,
                rhythmData: sentinelRhythmData
            ),
            projectID: projectID
        )

        // Relance → succès, et le rythme vient du checkpoint sentinelle :
        // la phase 2 a bien été SAUTÉE (reprise au niveau des phases,
        // §8.1, §63, §79).
        let result = try await analyzer.analyze(audio: audio, configuration: .production) { _ in }
        XCTAssertEqual(result.duration.seconds, 10.0, accuracy: 0.1)
        XCTAssertEqual(
            result.selectedRhythmHypothesisID, sentinelHypothesisID,
            "L'hypothèse retenue doit être celle du checkpoint sentinelle"
        )
        XCTAssertEqual(
            result.beats.count, sentinelBeats.count,
            "EXACTEMENT les beats sentinelles attendus — sinon la phase 2 a été recalculée"
        )
        for (beat, sentinel) in zip(result.beats, sentinelBeats) {
            XCTAssertEqual(beat.time.ticks, sentinel.time.ticks)
            XCTAssertEqual(beat.strength, sentinel.strength)
            XCTAssertEqual(beat.confidence, sentinel.confidence)
        }

        // Après un succès complet, le checkpoint est effacé.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: checkpointURL(projectID: projectID).path(percentEncoded: false)
            )
        )
    }

    // MARK: - (h) Silence puis impact : impact détecté, AUCUN buildUp inventé

    func testSilenceThenImpactProducesImpactWithoutInventedBuildUp() async throws {
        let silenceSeconds = 3.0
        let (_, audio) = try makeProject(
            write: {
                try TestAudioFactory.writeWav(
                    samples: TestAudioFactory.silenceThenImpact(
                        seconds: 6,
                        impactAt: silenceSeconds,
                        sampleRate: Self.wavSampleRate
                    ),
                    sampleRate: Self.wavSampleRate,
                    to: $0
                )
            },
            durationSeconds: 6
        )
        let result = try await analyzer.analyze(audio: audio, configuration: .production) { _ in }

        // Au moins un événement impact à ±150 ms de l'impact réel (§12.4).
        let impacts = result.musicalEvents.filter { $0.type == .impact }
        XCTAssertTrue(
            impacts.contains { abs($0.start.seconds - silenceSeconds) <= 0.15 },
            "Impact attendu vers \(silenceSeconds) s ; trouvés : \(impacts.map(\.start.seconds))"
        )

        // §63 « aucun drop : ne pas en inventer » : aucune montée réelle ne
        // précède l'impact (silence), donc AUCUN buildUp ni relation
        // prepares fabriqués.
        XCTAssertTrue(
            result.musicalEvents.allSatisfy { $0.type != .buildUp },
            "Aucun buildUp ne doit être inventé après un silence"
        )
        XCTAssertTrue(
            result.eventRelations.allSatisfy { $0.type != .prepares },
            "Aucune relation prepares sans montée réelle"
        )
    }
}
