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
//  S'ajoute la figure CANONIQUE du genre, que la fixture ci-dessus ne
//  contient pas : montée → GAP DE SILENCE → impact. Elle est le seul cas
//  où l'ancienne mesure `energy[fin de fenêtre] − energy[début]` change de
//  SIGNE (mesuré : −0,68 sur une grille de 0,5 s) — l'impact était détecté,
//  le `.buildUp` jamais. Valeurs simulées après correctif (montée mesurée
//  jusqu'à son sommet), pour des spans de 0,4 / 0,5 / 0,6 s :
//  energyRise +0,30 / +0,37 / +0,90 selon la largeur de fenêtre, et
//  meanTension 0,81 à 0,94 (seuils 0,15 et 0,4).
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

    // MARK: - §25 : montée + GAP DE SILENCE + impact (figure canonique EDM)

    /// La figure du genre : riser, un à deux temps de VIDE, puis le drop.
    /// C'est le cas que le moteur ne voyait pas — l'impact était détecté,
    /// le `.buildUp` jamais, donc ni relation `.prepares`, ni
    /// `burstResolution`, ni densification pendant la montée.
    ///
    /// Le gap fait 1 s (et non 250 ms) pour une raison mesurable : il faut
    /// qu'au moins un span tombe ENTIÈREMENT dans le silence. Un gap plus
    /// court ne donne que des spans « à cheval » sur le silence ET l'impact,
    /// dont l'énergie intermédiaire masque le creux — le test ne prouverait
    /// alors plus rien, puisque la différence de bornes redeviendrait
    /// positive et passerait AUSSI avec l'ancien code.
    ///
    /// Grille attendue : la simulation ne détecte que 2 onsets sur ce signal
    /// (bruit lisse), soit moins que `minimumOnsetsForTempo = 4` → aucune
    /// hypothèse de tempo → grille de repli 0,5 s (§63). Les assertions
    /// restent vraies pour des spans de 0,4 / 0,5 / 0,6 s, donc aussi si une
    /// grille de beats devait finalement être construite.
    func testRiserThenSilenceGapThenImpactStillProducesBuildUpAndPrepares() async throws {
        let rampSeconds = 8.0
        let gapSeconds = 1.0
        let impactSeconds = 0.5
        let seconds = rampSeconds + gapSeconds + impactSeconds
        let impactOnsetSeconds = rampSeconds + gapSeconds // 9,0 s
        let (_, audio) = try makeProject(
            write: {
                try TestAudioFactory.writeWav(
                    samples: TestAudioFactory.buildUpWithSilenceGap(
                        rampSeconds: rampSeconds,
                        gapSeconds: gapSeconds,
                        impactSeconds: impactSeconds,
                        sampleRate: Self.wavSampleRate
                    ),
                    sampleRate: Self.wavSampleRate,
                    to: $0
                )
            },
            durationSeconds: seconds
        )
        let result = try await analyzer.analyze(audio: audio, configuration: .production) { _ in }

        // (a) L'impact du drop est le DERNIER impact du morceau. (Le sommet
        // du riser peut lui aussi être détecté comme impact : la
        // normalisation quantile §17 écrête le haut de la montée à 1,0 comme
        // le drop. Ce n'est pas ce qu'on teste ici.)
        let impacts = result.musicalEvents
            .filter { $0.type == .impact }
            .sorted { $0.start < $1.start }
        let impact = try XCTUnwrap(
            impacts.last,
            "Impact attendu vers \(impactOnsetSeconds) s ; aucun impact détecté"
        )
        // Le temps raffiné (frame de dérivée RMS maximale, fenêtre élargie de
        // 150 ms vers l'arrière) tombe entre l'attaque réelle et la fin du
        // morceau selon le span porteur : borne large et explicite.
        XCTAssertGreaterThanOrEqual(
            impact.start.seconds, impactOnsetSeconds - 0.2,
            "L'impact doit tomber APRÈS le gap de silence ; trouvés : \(impacts.map(\.start.seconds))"
        )
        // Marge d'une frame (11,6 ms) : `frameCount` couvre jusqu'à un hop
        // de plus que le PCM réellement consommé (voir `FeatureTimeline`).
        XCTAssertLessThanOrEqual(impact.start.seconds, seconds + 0.05)

        // (b) Un buildUp d'INTERVALLE se terminant EXACTEMENT sur cet impact
        // (égalité en ticks §9, jamais en secondes flottantes).
        let buildUps = result.musicalEvents.filter { $0.type == .buildUp }
        let preparingBuildUp = buildUps.first {
            $0.geometry == .interval && $0.end?.ticks == impact.start.ticks
        }
        let buildUp = try XCTUnwrap(
            preparingBuildUp,
            "buildUp attendu malgré le gap de silence ; buildUps : "
                + "\(buildUps.map { ($0.start.seconds, $0.end?.seconds ?? -1) })"
        )
        let buildUpEnd = try XCTUnwrap(buildUp.end, "Un intervalle §12.4 porte une fin")
        XCTAssertLessThan(buildUp.start, buildUpEnd, "La montée doit être un intervalle non vide")

        // (c) La montée commence DANS le riser, pas dans le gap : c'est la
        // preuve que la fenêtre couvre la figure et pas seulement le vide.
        XCTAssertLessThan(
            buildUp.start.seconds, rampSeconds,
            "La montée doit démarrer pendant le riser (avant \(rampSeconds) s)"
        )

        // (d) Relation prepares du buildUp vers l'impact (§12.5, §25).
        XCTAssertTrue(
            result.eventRelations.contains {
                $0.type == .prepares
                    && $0.sourceEventID == buildUp.id
                    && $0.targetEventID == impact.id
            },
            "Relation prepares attendue du buildUp vers l'impact malgré le gap"
        )
    }

    // MARK: - §0.7/§63 : le garde-fou — silence + impact isolé, AUCUN buildUp

    /// Contrepartie NON NÉGOCIABLE des deux tests ci-dessus : élargir la
    /// fenêtre de montée à ~8 mesures et mesurer la montée jusqu'à son
    /// sommet rend `genuineRise` plus permissif — cette permissivité ne doit
    /// JAMAIS aller jusqu'à fabriquer un drop là où il n'y a rien (§63
    /// « aucun drop : ne pas en inventer »).
    ///
    /// Le même invariant est vérifié bout-en-bout par
    /// `AnalysisPipelineTests.testSilenceThenImpactProducesImpactWithoutInventedBuildUp` ;
    /// il est DÉLIBÉRÉMENT dupliqué ici, dans le fichier qui exerce le
    /// chemin positif, pour qu'aucun élargissement futur de la fenêtre ne
    /// puisse passer au vert sans le croiser.
    ///
    /// Mécanique : avant l'impact, tous les spans sont à énergie nulle
    /// (silence pur), donc le sommet de la fenêtre est son premier span et
    /// la montée mesurée vaut 0 < 0,15.
    func testIsolatedImpactAfterSilenceProducesNoBuildUpNorPrepares() async throws {
        let seconds = 6.0
        let impactAt = 3.0
        let (_, audio) = try makeProject(
            write: {
                try TestAudioFactory.writeWav(
                    samples: TestAudioFactory.silenceThenImpact(
                        seconds: seconds,
                        impactAt: impactAt,
                        sampleRate: Self.wavSampleRate
                    ),
                    sampleRate: Self.wavSampleRate,
                    to: $0
                )
            },
            durationSeconds: seconds
        )
        let result = try await analyzer.analyze(audio: audio, configuration: .production) { _ in }

        // L'impact, lui, doit rester détecté : on ne prouve rien en ne
        // détectant rien.
        let impacts = result.musicalEvents.filter { $0.type == .impact }
        XCTAssertTrue(
            impacts.contains { abs($0.start.seconds - impactAt) <= 0.15 },
            "Impact attendu vers \(impactAt) s ; trouvés : \(impacts.map(\.start.seconds))"
        )
        XCTAssertTrue(
            result.musicalEvents.allSatisfy { $0.type != .buildUp },
            "Aucune montée n'existe avant cet impact : aucun buildUp ne doit être inventé"
        )
        XCTAssertTrue(
            result.eventRelations.allSatisfy { $0.type != .prepares },
            "Aucune relation prepares sans montée réelle"
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
