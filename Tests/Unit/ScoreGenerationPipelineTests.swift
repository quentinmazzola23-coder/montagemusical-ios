//
//  ScoreGenerationPipelineTests.swift
//  MontageMusicalTests
//
//  Intégration bout-en-bout du générateur de partitions (Jalon 5, §80)
//  SANS interface : audio synthétique (TestAudioFactory) →
//  `DeterministicMusicAnalyzer.analyze` →
//  `DeterministicEditScoreGenerator.generateScores` → vérification des
//  contraintes §28.1 (frontières triées, pas de trous, début/fin absolus,
//  imbrication Fluid ⊆ Balanced ⊆ Percussif), des planchers §28.2 par mode
//  et du round-trip Codable de `EditScoreFamily` (fichier §11
//  `analysis/scores-v1.json`).
//
//  La 5ᵉ phase §33 (« Création des rythmes ») est publiée par
//  `AudioAnalysisActor` (qui exige ProjectStore + SwiftData) : elle est
//  couverte ici au niveau `generateScores` + un test de non-régression sur
//  l'enum `AnalysisPhase` (5 cas, le 5ᵉ étant `rhythmCreation` — l'acteur
//  le référence à la compilation).
//
//  Même pattern d'isolation qu'`AnalysisPipelineTests` : dossier temporaire
//  par test, aucun état partagé.
//

import XCTest
@testable import MontageMusical

final class ScoreGenerationPipelineTests: XCTestCase {

    private var rootURL: URL!
    private var fileStore: ProjectFileStore!
    private var cache: AnalysisCache!
    private var analyzer: DeterministicMusicAnalyzer!
    private var generator: DeterministicEditScoreGenerator!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ScoreGenerationPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileStore = ProjectFileStore(rootURL: rootURL)
        cache = AnalysisCache(fileStore: fileStore)
        analyzer = DeterministicMusicAnalyzer(cache: cache, fileStore: fileStore)
        generator = DeterministicEditScoreGenerator()
    }

    override func tearDownWithError() throws {
        generator = nil
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
    /// rééchantillonne à 22 050 Hz — §16.2).
    private static let wavSampleRate = 44_100

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

    /// Analyse un click track 128 BPM de 10 s puis génère la famille de
    /// partitions (chemin partagé des tests a et d).
    private func makeClickTrackFamily() async throws -> (family: EditScoreFamily, result: MusicAnalysisResult) {
        let (_, audio) = try makeProject(
            write: { url in
                try TestAudioFactory.writeWav(
                    samples: TestAudioFactory.clickTrack(
                        bpm: 128,
                        seconds: 10,
                        sampleRate: Self.wavSampleRate
                    ),
                    sampleRate: Self.wavSampleRate,
                    to: url
                )
            },
            durationSeconds: 10
        )
        let result = try await analyzer.analyze(audio: audio, configuration: .production) { _ in }
        let family = try generator.generateScores(from: result, configuration: .production)
        return (family, result)
    }

    /// Plancher §28.2 du mode, lu depuis la configuration (jamais codé en
    /// dur deux fois) : fluid 45 000, balanced 24 000, percussive
    /// 15 000 ticks.
    private func floorTicks(for mode: PaceMode, configuration: ScoreConfiguration) -> Int64 {
        switch mode {
        case .fluid: return configuration.minimumSlotDurationFluid.ticks
        case .balanced: return configuration.minimumSlotDurationBalanced.ticks
        case .percussive: return configuration.minimumSlotDurationPercussive.ticks
        }
    }

    /// Vérifie qu'une partition est VALIDE (§28.1, §28.2) :
    /// - au moins une case ;
    /// - début du morceau = première frontière (0) ;
    /// - fin ABSOLUE du morceau = dernière frontière (`duration`) ;
    /// - frontières triées, aucune durée nulle/négative, AUCUN trou
    ///   (chaque case commence exactement où la précédente finit) ;
    /// - indices strictement croissants (contrainte §10.1 d'`insertSlots`) ;
    /// - chaque durée ≥ plancher §28.2 du mode.
    private func assertValidScore(
        _ score: EditScore,
        mode: PaceMode,
        duration: MediaTime,
        configuration: ScoreConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(score.mode, mode, "Mode incohérent", file: file, line: line)
        XCTAssertFalse(score.slots.isEmpty, "[\(mode)] au moins une case attendue (§63)", file: file, line: line)
        XCTAssertEqual(
            score.slots.first?.start.ticks, 0,
            "[\(mode)] le début du morceau est toujours une ancre (§28.1)",
            file: file, line: line
        )
        XCTAssertEqual(
            score.slots.last?.end.ticks, duration.ticks,
            "[\(mode)] la fin ABSOLUE du morceau est la dernière frontière (§28.1, §28.2.4)",
            file: file, line: line
        )
        let floor = floorTicks(for: mode, configuration: configuration)
        var previousEndTicks: Int64 = 0
        var previousIndex: Int?
        for slot in score.slots {
            XCTAssertEqual(
                slot.start.ticks, previousEndTicks,
                "[\(mode)] case \(slot.index) : trou ou chevauchement (start \(slot.start.ticks) ≠ fin précédente \(previousEndTicks))",
                file: file, line: line
            )
            XCTAssertGreaterThan(
                slot.end.ticks, slot.start.ticks,
                "[\(mode)] case \(slot.index) : durée nulle ou négative (§28.1)",
                file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(
                slot.duration.ticks, floor,
                "[\(mode)] case \(slot.index) : durée \(slot.duration.ticks) ticks < plancher §28.2 (\(floor))",
                file: file, line: line
            )
            if let previousIndex {
                XCTAssertGreaterThan(
                    slot.index, previousIndex,
                    "[\(mode)] indices non strictement croissants (§10.1)",
                    file: file, line: line
                )
            }
            previousIndex = slot.index
            previousEndTicks = slot.end.ticks
        }
    }

    /// Ensemble des frontières (ticks exacts §9) d'une partition : tous les
    /// débuts de case + la fin de la dernière (contiguïté vérifiée par
    /// ailleurs — l'ensemble couvre donc toutes les frontières).
    private func boundaryTicks(_ score: EditScore) -> Set<Int64> {
        var ticks = Set(score.slots.map { $0.start.ticks })
        if let last = score.slots.last {
            ticks.insert(last.end.ticks)
        }
        return ticks
    }

    // MARK: - (a) Click track 128 BPM, 10 s : trois partitions valides et imbriquées

    func testClickTrackProducesThreeValidNestedScores() async throws {
        let (family, result) = try await makeClickTrackFamily()
        let configuration = ScoreConfiguration.production

        // Trois partitions valides : frontières triées, pas de trous,
        // durées ≥ planchers §28.2, fin absolue == result.duration.
        assertValidScore(family.fluid, mode: .fluid, duration: result.duration, configuration: configuration)
        assertValidScore(family.balanced, mode: .balanced, duration: result.duration, configuration: configuration)
        assertValidScore(family.percussive, mode: .percussive, duration: result.duration, configuration: configuration)

        // Imbrication §28.1 sur les ticks : chaque frontière de Fluide est
        // une frontière d'Équilibré, chaque frontière d'Équilibré est une
        // frontière de Percutant (augmenter la densité AJOUTE des ancres,
        // n'en déplace jamais — §2).
        let fluidBoundaries = boundaryTicks(family.fluid)
        let balancedBoundaries = boundaryTicks(family.balanced)
        let percussiveBoundaries = boundaryTicks(family.percussive)
        XCTAssertTrue(
            fluidBoundaries.isSubset(of: balancedBoundaries),
            "Fluide ⊄ Équilibré : frontières orphelines \(fluidBoundaries.subtracting(balancedBoundaries).sorted())"
        )
        XCTAssertTrue(
            balancedBoundaries.isSubset(of: percussiveBoundaries),
            "Équilibré ⊄ Percutant : frontières orphelines \(balancedBoundaries.subtracting(percussiveBoundaries).sorted())"
        )

        // Densité croissante : percussive ≥ balanced ≥ fluid (§2, §80).
        XCTAssertGreaterThanOrEqual(family.percussive.slots.count, family.balanced.slots.count)
        XCTAssertGreaterThanOrEqual(family.balanced.slots.count, family.fluid.slots.count)
    }

    // MARK: - (b) Non-régression : l'enum §33 a bien 5 cas, le 5ᵉ est la création des rythmes

    /// La publication de la 5ᵉ phase par `AudioAnalysisActor` exige un
    /// `ProjectStore` complet (SwiftData) — hors de portée d'un test
    /// unitaire du pipeline. Garde-fou : `AnalysisPhase` compte exactement
    /// 5 cas §33 et se termine par `rhythmCreation` (« Création des
    /// rythmes ») ; l'acteur référence `.rhythmCreation` à la compilation
    /// (`runAnalysis`), donc renommer/supprimer le cas casse la build.
    func testAnalysisPhaseHasFiveCasesEndingWithRhythmCreation() {
        XCTAssertEqual(AnalysisPhase.allCases.count, 5, "Les 5 phases §33 sont attendues")
        XCTAssertEqual(AnalysisPhase.allCases.last, .rhythmCreation)
        XCTAssertEqual(AnalysisPhase.rhythmCreation.displayLabel, "Création des rythmes")
    }

    // MARK: - (c) Silence puis impact, 6 s : partitions valides avec très peu d'ancres

    func testSilenceThenImpactProducesValidScoresWithoutCrash() async throws {
        let (_, audio) = try makeProject(
            write: { url in
                try TestAudioFactory.writeWav(
                    samples: TestAudioFactory.silenceThenImpact(
                        seconds: 6,
                        impactAt: 3,
                        sampleRate: Self.wavSampleRate
                    ),
                    sampleRate: Self.wavSampleRate,
                    to: url
                )
            },
            durationSeconds: 6
        )
        let result = try await analyzer.analyze(audio: audio, configuration: .production) { _ in }
        let family = try generator.generateScores(from: result, configuration: .production)
        let configuration = ScoreConfiguration.production

        // Peu d'ancres (aucune pulsation) : au moins 1 case par mode (§63 :
        // « morceau très court : garantir au moins une case »), fin absolue
        // conservée, mêmes invariants §28.1/§28.2 — sans crash.
        for (mode, score) in [
            (PaceMode.fluid, family.fluid),
            (PaceMode.balanced, family.balanced),
            (PaceMode.percussive, family.percussive),
        ] {
            XCTAssertGreaterThanOrEqual(score.slots.count, 1, "[\(mode)] au moins une case")
            assertValidScore(score, mode: mode, duration: result.duration, configuration: configuration)
        }
    }

    // MARK: - (d) Round-trip Codable : encodage JSON puis décodage == mêmes frontières

    /// `EditScoreFamily` est écrit en JSON dans `analysis/scores-v1.json`
    /// (§11) par `AudioAnalysisActor` : le round-trip Codable doit
    /// préserver EXACTEMENT les frontières (ticks entiers §9 — aucun
    /// arrondi de sérialisation toléré).
    func testEditScoreFamilyJSONRoundTripPreservesBoundaries() async throws {
        let (family, _) = try await makeClickTrackFamily()

        // Même convention d'encodage que l'acteur (clés triées, atomicité
        // hors sujet ici).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(family)
        let decoded = try JSONDecoder().decode(EditScoreFamily.self, from: data)

        XCTAssertEqual(decoded.analysisVersion, family.analysisVersion)
        for (original, redecoded) in [
            (family.fluid, decoded.fluid),
            (family.balanced, decoded.balanced),
            (family.percussive, decoded.percussive),
        ] {
            XCTAssertEqual(redecoded.mode, original.mode)
            XCTAssertEqual(redecoded.slots.count, original.slots.count, "[\(original.mode)] même nombre de cases")
            for (slotA, slotB) in zip(original.slots, redecoded.slots) {
                XCTAssertEqual(slotB.id, slotA.id)
                XCTAssertEqual(slotB.index, slotA.index)
                XCTAssertEqual(slotB.start.ticks, slotA.start.ticks, "[\(original.mode)] frontière de début altérée")
                XCTAssertEqual(slotB.end.ticks, slotA.end.ticks, "[\(original.mode)] frontière de fin altérée")
                XCTAssertEqual(slotB.entryAnchorID, slotA.entryAnchorID)
                XCTAssertEqual(slotB.exitAnchorID, slotA.exitAnchorID)
            }
            XCTAssertEqual(redecoded.averageDuration.ticks, original.averageDuration.ticks)
            XCTAssertEqual(redecoded.minimumDuration.ticks, original.minimumDuration.ticks)
            XCTAssertEqual(redecoded.maximumDuration.ticks, original.maximumDuration.ticks)
        }
    }
}
