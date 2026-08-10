//
//  WaveformExtractorTests.swift
//  MontageMusicalTests
//
//  Waveform simple (Jalon 3, spec §78) : bins respectés, valeurs
//  normalisées 0...1 (§16.2), silence → zéro.
//
//  Même principe qu'AudioImporterTests : aucune ressource embarquée,
//  le WAV (PCM 16 bits mono 44 100 Hz) est généré en pur Swift.
//

import XCTest
@testable import MontageMusical

final class WaveformExtractorTests: XCTestCase {

    private var directoryURL: URL!
    private var extractor: WaveformExtractor!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(
                path: "WaveformExtractorTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        extractor = WaveformExtractor()
    }

    override func tearDownWithError() throws {
        extractor = nil
        if let directoryURL,
           FileManager.default.fileExists(atPath: directoryURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directoryURL)
        }
        directoryURL = nil
    }

    // MARK: - Sinusoïde pleine échelle

    func testSineWaveformHasRequestedBinCountNormalizedValues() async throws {
        let url = try writeWavFile(named: "sinus.wav", data: makeSineWavData())

        let waveform = try await extractor.waveform(for: url, binCount: 200)

        XCTAssertEqual(waveform.count, 200, "binCount respecté : 200 → 200 bins")
        for (index, value) in waveform.enumerated() {
            XCTAssertGreaterThanOrEqual(value, 0, "Bin \(index) hors plage 0...1")
            XCTAssertLessThanOrEqual(value, 1, "Bin \(index) hors plage 0...1")
        }
        let maximum = try XCTUnwrap(waveform.max())
        XCTAssertGreaterThan(
            maximum, 0.5,
            "Sinusoïde pleine échelle (à −3 dB près) → au moins un bin > 0,5"
        )
    }

    func testWaveformRespectsOtherBinCounts() async throws {
        let url = try writeWavFile(named: "sinus-50.wav", data: makeSineWavData())

        let waveform = try await extractor.waveform(for: url, binCount: 50)

        XCTAssertEqual(waveform.count, 50)
    }

    // MARK: - Silence

    func testSilenceProducesAllZeroBins() async throws {
        let silentSamples = [Int16](repeating: 0, count: 44_100)
        let url = try writeWavFile(
            named: "silence.wav",
            data: makeWavData(samples: silentSamples, sampleRate: 44_100)
        )

        let waveform = try await extractor.waveform(for: url, binCount: 200)

        XCTAssertEqual(waveform.count, 200)
        for (index, value) in waveform.enumerated() {
            XCTAssertLessThanOrEqual(value, 0.001, "Silence → bin \(index) ≈ 0")
        }
    }

    // MARK: - Helpers

    private func writeWavFile(named name: String, data: Data) throws -> URL {
        let url = directoryURL.appending(path: name)
        try data.write(to: url)
        return url
    }

    // MARK: - Génération WAV (pur Swift, sans ressource embarquée)

    /// WAV PCM 16 bits mono : sinusoïde 440 Hz à 90 % de la pleine échelle.
    private func makeSineWavData(
        durationSeconds: Double = 1.0,
        sampleRate: Int = 44_100
    ) -> Data {
        let sampleCount = Int(durationSeconds * Double(sampleRate))
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let phase = 2.0 * Double.pi * 440.0 * Double(index) / Double(sampleRate)
            let value = 0.9 * sin(phase) * 32_767.0
            samples.append(Int16(max(-32_768.0, min(32_767.0, value.rounded()))))
        }
        return makeWavData(samples: samples, sampleRate: sampleRate)
    }

    /// En-têtes RIFF/fmt/data écrits à la main (PCM 16 bits mono, little-endian).
    private func makeWavData(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))                 // taille du bloc fmt
        data.appendLittleEndian(UInt16(1))                  // PCM linéaire
        data.appendLittleEndian(UInt16(1))                  // mono
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))     // débit octets
        data.appendLittleEndian(UInt16(2))                  // alignement de bloc
        data.appendLittleEndian(UInt16(16))                 // bits par échantillon
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataSize)
        for sample in samples {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        return data
    }
}

// Non partagé : extension file-private d'écriture little-endian
// (les méthodes `private` d'une extension sont limitées à ce fichier —
// aucune collision avec l'extension équivalente d'AudioImporterTests).
private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
