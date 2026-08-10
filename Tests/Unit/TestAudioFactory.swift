//
//  TestAudioFactory.swift
//  MontageMusicalTests
//
//  Fabrique PARTAGÉE d'audio synthétique pour tous les tests du moteur
//  musical (Jalon 4, spec §79 : « tests audio synthétiques »).
//
//  TOUT est déterministe : bruit blanc par LCG seedé, jamais de générateur
//  aléatoire système. Aucune ressource embarquée : les WAV (PCM 16 bits
//  mono, en-têtes RIFF écrits à la main) sont générés en pur Swift.
//

import Foundation

enum TestAudioFactory {

    /// Durée d'un clic/impact : burst de bruit blanc de 10 ms.
    private static let burstSeconds = 0.010

    // MARK: - Écriture WAV (PCM 16 bits mono, RIFF à la main)

    /// Écrit `samples` (`-1...1`, écrêté) en WAV PCM 16 bits mono.
    static func writeWav(samples: [Float], sampleRate: Int, to url: URL) throws {
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        data.reserveCapacity(44 + samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))             // taille du bloc fmt
        data.appendLittleEndian(UInt16(1))              // PCM linéaire
        data.appendLittleEndian(UInt16(1))              // mono
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2)) // débit octets
        data.appendLittleEndian(UInt16(2))              // alignement de bloc
        data.appendLittleEndian(UInt16(16))             // bits par échantillon
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataSize)
        for sample in samples {
            let clamped = Double(max(-1, min(1, sample)))
            let scaled = (clamped * 32_767.0).rounded()
            let value = Int16(max(-32_768.0, min(32_767.0, scaled)))
            data.appendLittleEndian(UInt16(bitPattern: value))
        }
        try data.write(to: url)
    }

    // MARK: - Signaux synthétiques

    /// Piste de clics à tempo constant : bursts de bruit blanc déterministe
    /// (LCG) de 10 ms séparés par du silence.
    ///
    /// Convention de phase : le premier clic tombe à **une demi-période**
    /// (jamais à t = 0, où une frame d'analyse centrée n'aurait pas de
    /// contexte). Le clic `k` tombe à `(k + 0,5) × 60/bpm` secondes.
    static func clickTrack(bpm: Double, seconds: Double, sampleRate: Int) -> [Float] {
        guard bpm > 0, seconds > 0, sampleRate > 0 else { return [] }
        var samples = [Float](
            repeating: 0,
            count: Int((seconds * Double(sampleRate)).rounded())
        )
        var generator = DeterministicNoise(seed: 0xC11C_7AC4)
        let period = 60.0 / bpm
        var clickIndex = 0
        while true {
            let time = (Double(clickIndex) + 0.5) * period
            guard time < seconds else { break }
            writeBurst(
                into: &samples,
                at: time,
                amplitude: 0.9,
                sampleRate: sampleRate,
                generator: &generator
            )
            clickIndex += 1
        }
        return samples
    }

    /// Piste de clics à tempo variant linéairement de `startBPM` à `endBPM`
    /// sur `seconds`. Même convention de phase que `clickTrack` : le clic
    /// `k` tombe au temps où le compte de beats vaut `k + 0,5`.
    static func acceleratingClickTrack(
        startBPM: Double,
        endBPM: Double,
        seconds: Double,
        sampleRate: Int
    ) -> [Float] {
        guard startBPM > 0, endBPM > 0, seconds > 0, sampleRate > 0 else { return [] }
        var samples = [Float](
            repeating: 0,
            count: Int((seconds * Double(sampleRate)).rounded())
        )
        var generator = DeterministicNoise(seed: 0xACCE_1E7A)
        var beat = 0.5
        while true {
            guard let time = timeOfBeat(
                beat,
                startBPM: startBPM,
                endBPM: endBPM,
                seconds: seconds
            ), time < seconds else { break }
            writeBurst(
                into: &samples,
                at: time,
                amplitude: 0.9,
                sampleRate: sampleRate,
                generator: &generator
            )
            beat += 1
        }
        return samples
    }

    /// Silence pur, puis un unique impact (burst de bruit blanc de 10 ms à
    /// 0,95) à `impactAt` secondes.
    static func silenceThenImpact(
        seconds: Double,
        impactAt: Double,
        sampleRate: Int
    ) -> [Float] {
        guard seconds > 0, sampleRate > 0 else { return [] }
        var samples = [Float](
            repeating: 0,
            count: Int((seconds * Double(sampleRate)).rounded())
        )
        var generator = DeterministicNoise(seed: 0x1147_AC71)
        if impactAt >= 0, impactAt < seconds {
            writeBurst(
                into: &samples,
                at: impactAt,
                amplitude: 0.95,
                sampleRate: sampleRate,
                generator: &generator
            )
        }
        return samples
    }

    /// Montée : bruit blanc d'amplitude croissante linéaire (0,05 → 0,70)
    /// puis impact final (burst à 0,98 sur les 150 dernières millisecondes).
    static func buildUp(seconds: Double, sampleRate: Int) -> [Float] {
        guard seconds > 0, sampleRate > 0 else { return [] }
        let count = Int((seconds * Double(sampleRate)).rounded())
        var samples = [Float](repeating: 0, count: count)
        var generator = DeterministicNoise(seed: 0xB111_D0F0)
        let impactStart = max(0, count - Int(0.150 * Double(sampleRate)))
        for index in 0..<impactStart {
            let progress = Float(index) / Float(max(impactStart - 1, 1))
            samples[index] = generator.next() * (0.05 + 0.65 * progress)
        }
        for index in impactStart..<count {
            samples[index] = generator.next() * 0.98
        }
        return samples
    }

    // MARK: - Aides privées

    /// Écrit un burst de bruit blanc déterministe de 10 ms à `time` secondes.
    private static func writeBurst(
        into samples: inout [Float],
        at time: Double,
        amplitude: Float,
        sampleRate: Int,
        generator: inout DeterministicNoise
    ) {
        let start = Int((time * Double(sampleRate)).rounded())
        let length = max(1, Int(burstSeconds * Double(sampleRate)))
        guard start >= 0, start < samples.count else { return }
        for offset in 0..<length {
            let index = start + offset
            guard index < samples.count else { break }
            samples[index] = generator.next() * amplitude
        }
    }

    /// Temps (s) auquel le compte de beats atteint `n` pour un tempo variant
    /// linéairement : beats(t) = s0·t + a·t²/2, avec s0 = startBPM/60 et
    /// a = (endBPM − startBPM)/(60·seconds).
    private static func timeOfBeat(
        _ n: Double,
        startBPM: Double,
        endBPM: Double,
        seconds: Double
    ) -> Double? {
        let initialRate = startBPM / 60
        let acceleration = (endBPM - startBPM) / (60 * seconds)
        if abs(acceleration) < 1e-12 {
            return n / initialRate
        }
        let discriminant = initialRate * initialRate + 2 * acceleration * n
        guard discriminant >= 0 else { return nil }
        return (-initialRate + discriminant.squareRoot()) / acceleration
    }
}

// MARK: - Bruit blanc déterministe (LCG seedé)

/// LCG 64 bits (constantes de Knuth) : séquence entièrement déterministe,
/// indépendante du système. Jamais de `random` système dans les tests.
private struct DeterministicNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// Prochain échantillon de bruit blanc dans `-1...1` (32 bits de poids
    /// fort de l'état — les bits bas d'un LCG sont faibles).
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let bits = UInt32(truncatingIfNeeded: state &>> 32)
        return Float(bits) / Float(UInt32.max) * 2 - 1
    }
}

// Extension file-private d'écriture little-endian. `Swift.withUnsafeBytes`
// est QUALIFIÉ : non qualifié, l'appel résout vers `Data.withUnsafeBytes`
// (méthode d'instance) et ne compile pas — piège déjà rencontré.
private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
