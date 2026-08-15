//
//  OnsetDetectorTests.swift
//  MontageMusicalTests
//
//  Détection d'onsets (Jalon 4, spec §79 : « tests audio synthétiques »)
//  sur la chaîne réelle PCMDecoder → SpectralFeatureExtractor →
//  OnsetDetector — jamais de résultats factices (spec §0.7).
//

import XCTest
@testable import MontageMusical

final class OnsetDetectorTests: XCTestCase {

    private let sampleRate = 22_050
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(
                path: "OnsetDetectorTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directoryURL,
           FileManager.default.fileExists(atPath: directoryURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directoryURL)
        }
        directoryURL = nil
    }

    // MARK: - Piste de clics 120 BPM

    func testClickTrack120BPMDetectsAboutSixteenOnsets() async throws {
        let samples = TestAudioFactory.clickTrack(
            bpm: 120, seconds: 8, sampleRate: sampleRate
        )
        let timeline = try await extractTimeline(samples: samples, name: "clics-120.wav")

        let (onsets, envelope) = OnsetDetector().detectOnsets(features: timeline)

        XCTAssertEqual(
            envelope.count, timeline.frameCount,
            "L'enveloppe globale a la même cadence que la timeline"
        )
        for (index, value) in envelope.enumerated() {
            XCTAssertGreaterThanOrEqual(value, 0, "Enveloppe ≥ 0 (frame \(index))")
        }

        // 16 clics réels (clic k à (k + 0,5) × 0,5 s) → ~16 onsets ±2.
        XCTAssertTrue(
            (14...18).contains(onsets.count),
            "16 clics attendus ±2, obtenu \(onsets.count)"
        )

        // Chaque clic réel a un onset à ±35 ms.
        let period = 60.0 / 120.0
        var clickTimes: [Double] = []
        var clickIndex = 0
        while (Double(clickIndex) + 0.5) * period < 8 {
            clickTimes.append((Double(clickIndex) + 0.5) * period)
            clickIndex += 1
        }
        XCTAssertEqual(clickTimes.count, 16, "8 s à 120 BPM → 16 clics")
        for clickTime in clickTimes {
            let matched = onsets.contains { onset in
                abs(onset.time.seconds - clickTime) <= 0.035
            }
            XCTAssertTrue(matched, "Clic à \(clickTime) s sans onset à ±35 ms")
        }

        // Contrat OnsetEvent : force 0...1, bande 0...4, confiance 0...1,
        // onsets triés par temps croissant.
        for onset in onsets {
            XCTAssertGreaterThanOrEqual(onset.strength, 0)
            XCTAssertLessThanOrEqual(onset.strength, 1)
            XCTAssertTrue((0...4).contains(onset.dominantBand))
            XCTAssertGreaterThanOrEqual(onset.confidence, 0)
            XCTAssertLessThanOrEqual(onset.confidence, 1)
        }
        for (previous, next) in zip(onsets, onsets.dropFirst()) {
            XCTAssertLessThan(
                previous.time, next.time,
                "Onsets triés strictement par temps"
            )
        }
    }

    // MARK: - Silence pur

    func testPureSilenceProducesNoOnset() async throws {
        let samples = [Float](repeating: 0, count: sampleRate * 4)
        let timeline = try await extractTimeline(samples: samples, name: "silence.wav")

        let (onsets, envelope) = OnsetDetector().detectOnsets(features: timeline)

        XCTAssertTrue(onsets.isEmpty, "Silence pur → aucun onset")
        XCTAssertEqual(envelope.count, timeline.frameCount)
    }

    // MARK: - Silence puis impact unique

    func testSilenceThenImpactProducesExactlyOneOnsetNearImpact() async throws {
        let impactAt = 2.0
        let samples = TestAudioFactory.silenceThenImpact(
            seconds: 4, impactAt: impactAt, sampleRate: sampleRate
        )
        let timeline = try await extractTimeline(samples: samples, name: "impact.wav")

        let (onsets, _) = OnsetDetector().detectOnsets(features: timeline)

        XCTAssertEqual(onsets.count, 1, "Un seul impact → exactement 1 onset")
        let onset = try XCTUnwrap(onsets.first)
        XCTAssertEqual(
            onset.time.seconds, impactAt, accuracy: 0.050,
            "Onset à ±50 ms de l'impact"
        )
    }

    // MARK: - Roulement dense : la fusion ne doit PAS s'effondrer (§18.4)

    /// Reproduit exactement la figure sur laquelle la fusion agglomérative
    /// **en chaîne** s'effondrait (correctif 2 de la critique) : une note
    /// toutes les 4 frames (46,4 ms → 21,5 notes/s, un roulement en 1/32 à
    /// 150 BPM) dont l'attaque est ÉTALÉE sur 3 bandes décalées de 0, +1 et
    /// +2 frames — l'étalement inter-bandes typique d'une vraie attaque.
    ///
    /// La suite des candidats est alors `f, f+1, f+2, f+4, f+5, f+6, …` :
    /// chaque écart consécutif vaut 1 ou 2 frames, donc ≤ `mergeGap`. Une
    /// fusion qui compare au candidat PRÉCÉDENT ne referme jamais le
    /// cluster et rend **1 onset pour tout le roulement** ; une fusion qui
    /// compare au PREMIER élément du cluster rend une note sur une.
    ///
    /// Test en boîte blanche (`FeatureTimeline` fabriquée à la main) et non
    /// sur audio : à cette densité, c'est le peak picking adaptatif §18.3 —
    /// et non la fusion — qui limite ce que la chaîne réelle peut voir (voir
    /// le test suivant). Fabriquer le `bandFlux` isole la propriété à
    /// prouver. Valeurs vérifiées numériquement par report de l'algorithme :
    /// 117 candidats (39 notes × 3 bandes) → fusion en chaîne : **1** onset ;
    /// fusion par cluster : **39** onsets, aux frames exactes des notes,
    /// séparés de 4 frames.
    func testDenseRollIsNotCollapsedByOnsetMerging() throws {
        // Cadence réelle de la branche courte (§16.3) : 22 050 / 256.
        let frameRate = 22_050.0 / 256.0
        let frameCount = 172 // ≈ 2,00 s
        let spacing = 4      // 4 frames = 46,4 ms → 21,5 notes/s
        let firstFrame = 8
        // Bandes 0/2/4 : l'attaque d'une même note n'arrive pas au même
        // instant dans le grave et dans l'aigu (transitoire réel).
        let staggeredBands: [(band: Int, offset: Int)] = [(0, 0), (2, 1), (4, 2)]

        var bandFlux = [[Float]](
            repeating: [Float](repeating: 0, count: frameCount),
            count: FeatureTimeline.bandCount
        )
        var noteFrames: [Int] = []
        var frame = firstFrame
        while frame < frameCount - 8 {
            noteFrames.append(frame)
            for (band, offset) in staggeredBands {
                let peak = frame + offset
                // Triangle 0,5 / 1 / 0,5 : le flux d'une attaque n'est pas
                // une impulsion d'une frame. Le plancher non nul entre les
                // notes est indispensable — c'est lui que la médiane
                // glissante §18.2 retire, ce qui redonne au pic le contraste
                // dont le seuil adaptatif §18.3 a besoin.
                bandFlux[band][peak] = 1
                bandFlux[band][peak - 1] = max(bandFlux[band][peak - 1], 0.5)
                bandFlux[band][peak + 1] = max(bandFlux[band][peak + 1], 0.5)
            }
            frame += spacing
        }
        XCTAssertEqual(noteFrames.count, 39, "39 notes sur 2 s (une toutes les 4 frames)")

        let zeros = [Float](repeating: 0, count: frameCount)
        let timeline = FeatureTimeline(
            frameRate: frameRate,
            duration: MediaTime(seconds: Double(frameCount) / frameRate),
            rms: zeros,
            bandEnergies: [[Float]](repeating: zeros, count: FeatureTimeline.bandCount),
            spectralFlux: zeros,
            bandFlux: bandFlux,
            spectralCentroid: zeros
        )

        let (onsets, _) = OnsetDetector().detectOnsets(features: timeline)

        // Le cœur du test : ~20 onsets par seconde, JAMAIS 1 à 3.
        XCTAssertGreaterThan(
            onsets.count, 3,
            "Un roulement de \(noteFrames.count) notes ne peut pas rendre \(onsets.count) "
                + "onsets : c'est la signature d'une fusion en chaîne sans borne de longueur"
        )
        XCTAssertTrue(
            (35...43).contains(onsets.count),
            "≈ une note sur une attendue (39 ± 4), obtenu \(onsets.count)"
        )
        let onsetsPerSecond = Double(onsets.count) / (Double(frameCount) / frameRate)
        XCTAssertGreaterThan(onsetsPerSecond, 15, "≈ 19,5 onsets/s attendus")

        // Chaque note porte un onset à ±1 frame (le survivant du cluster est
        // la frame de bande 0, la mieux pondérée dans l'enveloppe globale).
        let tolerance = 1.5 / frameRate
        for noteFrame in noteFrames {
            let expected = FeatureTimeline.mediaTime(forFrame: noteFrame, frameRate: frameRate)
            XCTAssertTrue(
                onsets.contains { abs($0.time.seconds - expected.seconds) <= tolerance },
                "Note de la frame \(noteFrame) sans onset à ±1 frame"
            )
        }

        // Invariant de la fusion par cluster : les survivants restent
        // strictement croissants.
        for (previous, next) in zip(onsets, onsets.dropFirst()) {
            XCTAssertLessThan(previous.time, next.time, "Onsets triés strictement par temps")
        }
    }

    // MARK: - Roulement dense sur la chaîne réelle (audio de synthèse)

    /// Même densité (20 clics/s pendant 2 s) mais à travers la chaîne
    /// complète WAV → STFT → OnsetDetector. Ce que ce test prouve : le
    /// roulement reste un roulement — les onsets restent nombreux et
    /// répartis sur toute la durée, jamais réduits à 1 à 3 événements.
    ///
    /// Ce qu'il ne prouve PAS, et pourquoi les bornes sont larges : à 4,3
    /// frames entre deux clics, la fenêtre de seuil adaptatif §18.3 (±15
    /// frames ≈ 3,5 clics) et le maximum local sur ±2 frames font que le
    /// peak picking ne retient déjà qu'un clic sur deux — mesuré par report
    /// de l'algorithme : **20 onsets** pour 40 clics, valeur identique avec
    /// la fusion en chaîne et avec la fusion par cluster (un burst de bruit
    /// large bande attaque les 5 bandes à la MÊME frame, il n'y a donc pas
    /// d'étalement inter-bandes pour refermer la chaîne). La discrimination
    /// des deux fusions se fait dans le test en boîte blanche ci-dessus ;
    /// celui-ci est le garde-fou de non-régression sur audio réel.
    func testDenseClickTrackKeepsOnsetsSpreadOverTheWholeRoll() async throws {
        let seconds = 2.0
        let samples = TestAudioFactory.denseClickTrack(
            clicksPerSecond: 20, seconds: seconds, sampleRate: sampleRate
        )
        let timeline = try await extractTimeline(samples: samples, name: "roulement-20hz.wav")

        let (onsets, _) = OnsetDetector().detectOnsets(features: timeline)

        XCTAssertGreaterThanOrEqual(
            onsets.count, 12,
            "40 clics en 2 s : ≈ 20 onsets mesurés, jamais 1 à 3 — obtenu \(onsets.count)"
        )
        XCTAssertLessThanOrEqual(
            onsets.count, 45,
            "Pas plus d'onsets que de clics (+ bord de morceau) — obtenu \(onsets.count)"
        )

        // Répartition : le roulement ne doit pas se réduire à une grappe.
        // Mesuré : 4, 6, 5, 5 onsets par quart de seconde.
        for quarter in 0..<4 {
            let lowerBound = 0.5 * Double(quarter)
            let upperBound = lowerBound + 0.5
            let count = onsets.count { $0.time.seconds >= lowerBound && $0.time.seconds < upperBound }
            XCTAssertGreaterThanOrEqual(
                count, 2,
                "Quart [\(lowerBound) ; \(upperBound)) s : \(count) onset(s), roulement effondré"
            )
        }
    }

    // MARK: - Aide : chaîne réelle WAV → timeline

    private func extractTimeline(
        samples: [Float],
        name: String
    ) async throws -> FeatureTimeline {
        let url = directoryURL.appending(path: name)
        try TestAudioFactory.writeWav(samples: samples, sampleRate: sampleRate, to: url)
        let extractor = SpectralFeatureExtractor(configuration: .production)
        return try await extractor.extract(url: url, decoder: PCMDecoder())
    }
}
