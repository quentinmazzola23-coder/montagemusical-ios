//
//  BuildupPipelineTests.swift
//  MontageMusicalTests
//
//  Couverture bout-en-bout des chemins POSITIFS du moteur déterministe
//  (Jalon 4, §79) que `AnalysisPipelineTests` ne couvre pas :
//  - §25 : montée réelle → buildUp (intervalle) + relation prepares vers
//    l'impact — le chemin positif, pas seulement « jamais de drop inventé » ;
//  - §19.1.5 : suivi d'un tempo VARIABLE (accelerando) par la programmation
//    dynamique type Ellis.
//
//  Audio synthétique : `TestAudioFactory` (WAV PCM 16 bits mono, signaux
//  déterministes, LCG seedé). Faisabilité vérifiée numériquement par
//  simulation de la chaîne complète (features normalisées quantile →
//  courbes tension/énergie → seuils §25) : sur `buildUp(9 s)`, la fenêtre
//  de montée avant l'impact donne meanTension ≈ 0,94–0,96 (seuil 0,4) et
//  energyRise ≈ 0,39–0,57 (seuil 0,15), quelle que soit la grille (beats
//  ou repli 0,5 s) — les seuils de `genuineRise` sont donc franchis avec
//  marge, sans ajustement ; l'attaque raffinée tombe à 8,835–8,858 s pour
//  un impact réel à 8,850 s.
//

import XCTest
@testable import MontageMusical

final class BuildupPipelineTests: XCTestCase {

    private var rootURL: URL!
    private var fileStore: ProjectFileStore!
    private var cache: AnalysisCache!
    private var analyzer: DeterministicMusicAnalyzer!

    // Même pattern d'isolation que `AnalysisPipelineTests` : dossier
    // temporaire par test, cache par projet — jamais d'état partagé.
    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "BuildupPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    /// Médiane déterministe (médiane haute pour un compte pair, comme le
    /// reste du moteur — jamais de moyenne flottante de deux éléments).
    private static func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty)
        return values.sorted()[values.count / 2]
    }

    // MARK: - §25 : buildUp → impact → prepares (chemin positif)

    func testBuildUpProducesImpactBuildUpIntervalAndPreparesRelation() async throws {
        let seconds = 9.0
        // `TestAudioFactory.buildUp` : bruit d'amplitude croissante
        // (0,05 → 0,70) puis impact final sur les 150 dernières ms (0,98).
        let impactOnsetSeconds = seconds - 0.150
        let (_, audio) = try makeProject(
            write: {
                try TestAudioFactory.writeWav(
                    samples: TestAudioFactory.buildUp(
                        seconds: seconds,
                        sampleRate: Self.wavSampleRate
                    ),
                    sampleRate: Self.wavSampleRate,
                    to: $0
                )
            },
            durationSeconds: seconds
        )
        let result = try await analyzer.analyze(audio: audio, configuration: .production) { _ in }

        // (a) Au moins un impact proche de la fin : ±300 ms autour de
        // l'attaque réelle (début du burst final, §12.4).
        let impacts = result.musicalEvents.filter { $0.type == .impact }
        let finalImpact = impacts.first { abs($0.start.seconds - impactOnsetSeconds) <= 0.3 }
        let impact = try XCTUnwrap(
            finalImpact,
            "Impact attendu vers \(impactOnsetSeconds) s ; trouvés : \(impacts.map(\.start.seconds))"
        )

        // (b) Un buildUp de géométrie INTERVALLE se terminant sur cet impact
        // (§25 : la montée prépare l'impact — end == impact.start par
        // construction, égalité exacte en ticks §9).
        let buildUps = result.musicalEvents.filter { $0.type == .buildUp }
        let preparingBuildUp = buildUps.first {
            $0.geometry == .interval && $0.end?.ticks == impact.start.ticks
        }
        let buildUp = try XCTUnwrap(
            preparingBuildUp,
            "buildUp (intervalle) se terminant à l'impact attendu ; buildUps : "
                + "\(buildUps.map { ($0.start.seconds, $0.end?.seconds ?? -1) })"
        )
        let buildUpEnd = try XCTUnwrap(buildUp.end, "Un intervalle §12.4 porte une fin")
        XCTAssertLessThan(buildUp.start, buildUpEnd, "La montée doit être un intervalle non vide")

        // (c) Relation prepares du buildUp vers l'impact (§12.5, §25).
        XCTAssertTrue(
            result.eventRelations.contains {
                $0.type == .prepares
                    && $0.sourceEventID == buildUp.id
                    && $0.targetEventID == impact.id
            },
            "Relation prepares attendue du buildUp vers l'impact"
        )
    }

    // MARK: - §19.1.5 : tempo variable suivi (accelerando)

    func testAcceleratingClickTrackBeatsFollowTempo() async throws {
        let seconds = 10.0
        let (_, audio) = try makeProject(
            write: {
                try TestAudioFactory.writeWav(
                    samples: TestAudioFactory.acceleratingClickTrack(
                        startBPM: 100,
                        endBPM: 140,
                        seconds: seconds,
                        sampleRate: Self.wavSampleRate
                    ),
                    sampleRate: Self.wavSampleRate,
                    to: $0
                )
            },
            durationSeconds: seconds
        )
        let result = try await analyzer.analyze(audio: audio, configuration: .production) { _ in }

        // Assez de beats pour des médianes signifiantes (≈ 20 clics réels).
        XCTAssertGreaterThanOrEqual(result.beats.count, 10, "≈ 20 beats attendus sur 10 s à 100→140 BPM")

        // §19.1.5 : la programmation dynamique tolère les variations de
        // tempo — les intervalles de la première moitié (≈ 0,55 s à
        // ~110 BPM) doivent rester plus longs que ceux de la seconde
        // (≈ 0,46 s à ~130 BPM). Un suivi rigide au tempo moyen donnerait
        // deux médianes égales.
        var firstHalf: [Double] = []
        var secondHalf: [Double] = []
        let midpoint = result.duration.seconds / 2
        for index in 1..<result.beats.count {
            let previous = result.beats[index - 1].time.seconds
            let current = result.beats[index].time.seconds
            let center = (previous + current) / 2
            if center < midpoint {
                firstHalf.append(current - previous)
            } else {
                secondHalf.append(current - previous)
            }
        }
        XCTAssertFalse(firstHalf.isEmpty, "Des beats sont attendus dans la première moitié")
        XCTAssertFalse(secondHalf.isEmpty, "Des beats sont attendus dans la seconde moitié")
        XCTAssertGreaterThan(
            Self.median(firstHalf),
            Self.median(secondHalf),
            "Le tempo suivi doit accélérer : médiane des intervalles 1ʳᵉ moitié > 2ᵉ moitié (§19.1.5)"
        )
    }
}
