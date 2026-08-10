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
