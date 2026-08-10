//
//  SpectralFeatureExtractorTests.swift
//  MontageMusicalTests
//
//  Extraction de caractéristiques (Jalon 4, spec §79) : cadence de la
//  branche courte (§16.3), centroïde en Hz (§17), RMS stable et normalisé
//  relativement au morceau (§17), silence → zéro.
//

import XCTest
@testable import MontageMusical

final class SpectralFeatureExtractorTests: XCTestCase {

    private let sampleRate = 22_050
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(
                path: "SpectralFeatureExtractorTests-\(UUID().uuidString)",
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

    // MARK: - Sinusoïde 440 Hz

    func testSine440HzCentroidNearFourFortyAndStableRMS() async throws {
        let timeline = try await extractTimeline(
            samples: makeSine(frequency: 440, amplitude: 0.8, seconds: 1),
            name: "sinus-440.wav"
        )

        // Cadence de la branche courte : 22 050 / 256 (spec §16.3).
        XCTAssertEqual(timeline.frameRate, 22_050.0 / 256.0)

        // Cohérence des séries : 5 bandes (§17), mêmes longueurs partout.
        let frameCount = timeline.frameCount
        XCTAssertGreaterThan(frameCount, 8)
        XCTAssertEqual(timeline.bandEnergies.count, 5)
        XCTAssertEqual(timeline.bandFlux.count, 5)
        XCTAssertEqual(timeline.spectralFlux.count, frameCount)
        XCTAssertEqual(timeline.spectralCentroid.count, frameCount)
        for band in 0..<5 {
            XCTAssertEqual(timeline.bandEnergies[band].count, frameCount)
            XCTAssertEqual(timeline.bandFlux[band].count, frameCount)
        }

        // Durée cohérente (±2 hops).
        let hopSeconds = 256.0 / 22_050.0
        XCTAssertEqual(
            timeline.duration.seconds, 1.0, accuracy: 2 * hopSeconds,
            "1 s d'audio → durée de timeline à ±2 hops"
        )

        // Frames intérieures : on écarte les frames de bord (fenêtres
        // partiellement remplies de zéros, fftSize/hop = 4 de chaque côté).
        guard frameCount > 12 else {
            XCTFail("Timeline trop courte (\(frameCount) frames) pour 1 s d'audio")
            return
        }
        let interior = 4..<(frameCount - 4)

        // Centroïde moyen proche de 440 Hz (±80 Hz), en Hz absolus (§17).
        var centroidSum = 0.0
        for frame in interior {
            centroidSum += Double(timeline.spectralCentroid[frame])
        }
        let meanCentroid = centroidSum / Double(interior.count)
        XCTAssertEqual(
            meanCentroid, 440, accuracy: 80,
            "Centroïde moyen d'une sinusoïde 440 Hz proche de 440 Hz"
        )

        // RMS stable sur une sinusoïde d'amplitude constante.
        let interiorRMS = interior.map { timeline.rms[$0] }
        let maxRMS = try XCTUnwrap(interiorRMS.max())
        let minRMS = try XCTUnwrap(interiorRMS.min())
        XCTAssertGreaterThan(maxRMS, 0)
        XCTAssertLessThanOrEqual(
            maxRMS - minRMS, 0.05 * maxRMS,
            "RMS stable (variation < 5 %) sur les frames intérieures"
        )
    }

    // MARK: - Silence

    func testSilenceGivesNearZeroRMS() async throws {
        let timeline = try await extractTimeline(
            samples: [Float](repeating: 0, count: sampleRate),
            name: "silence.wav"
        )
        XCTAssertGreaterThan(timeline.frameCount, 0)
        for (frame, value) in timeline.rms.enumerated() {
            XCTAssertLessThanOrEqual(
                abs(value), 0.0001,
                "Silence → RMS ≈ 0 (frame \(frame))"
            )
        }
    }

    // MARK: - Aides

    private func makeSine(
        frequency: Double,
        amplitude: Double,
        seconds: Double
    ) -> [Float] {
        let count = Int((seconds * Double(sampleRate)).rounded())
        var samples = [Float]()
        samples.reserveCapacity(count)
        for index in 0..<count {
            let phase = 2.0 * Double.pi * frequency * Double(index) / Double(sampleRate)
            samples.append(Float(amplitude * sin(phase)))
        }
        return samples
    }

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
