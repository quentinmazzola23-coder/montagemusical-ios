//
//  BeatTrackerTests.swift
//  MontageMusicalTests
//
//  Tests du Jalon 4 côté rythme — spec §19.1.5 et §20 niveau A,
//  acceptation §79 « tests audio synthétiques » : enveloppes synthétiques
//  en pur Swift (impulsions + bruit LCG déterministe) et FeatureTimeline
//  minimal fabriqué à la main (bandEnergies[0] = accents basses).
//

import XCTest
@testable import MontageMusical

final class BeatTrackerTests: XCTestCase {

    /// Cadence de l'enveloppe : branche courte, 22 050 / 256.
    private let envelopeRate = 86.1328125

    // MARK: - Fabrique d'enveloppes synthétiques (pur Swift)

    /// Générateur congruentiel linéaire : bruit faible, entièrement
    /// déterministe (aucun aléatoire système).
    private struct DeterministicNoise {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) // 0…1
        }
    }

    private func makeEnvelope(
        impulses: [(time: Double, amplitude: Float)],
        duration: Double,
        noiseAmplitude: Float = 0.03,
        seed: UInt64 = 7
    ) -> [Float] {
        let frameCount = Int((duration * envelopeRate).rounded(.up))
        var noise = DeterministicNoise(seed: seed)
        var envelope = (0..<frameCount).map { _ in noise.next() * noiseAmplitude }
        for impulse in impulses {
            let frame = Int((impulse.time * envelopeRate).rounded())
            if frame >= 0 && frame < frameCount {
                envelope[frame] += impulse.amplitude
            }
        }
        return envelope
    }

    /// FeatureTimeline minimal fabriqué à la main : seules les basses
    /// (bandEnergies[0]) portent de l'information, le reste est nul.
    private func makeFeatures(
        frameCount: Int,
        duration: Double,
        bassAccentFrames: [Int] = []
    ) -> FeatureTimeline {
        let zeros = [Float](repeating: 0, count: frameCount)
        var bass = zeros
        for frame in bassAccentFrames where frame >= 0 && frame < frameCount {
            bass[frame] = 1
        }
        return FeatureTimeline(
            frameRate: envelopeRate,
            duration: MediaTime(seconds: duration),
            rms: zeros,
            bandEnergies: [bass, zeros, zeros, zeros, zeros],
            spectralFlux: zeros,
            bandFlux: [zeros, zeros, zeros, zeros, zeros],
            spectralCentroid: zeros
        )
    }

    private func makeHypothesis(bpm: Double) -> RhythmHypothesis {
        RhythmHypothesis(
            id: UUID(),
            tempoBPM: bpm,
            tempoCurve: [TimedValue(time: .zero, value: bpm)],
            meterNumerator: nil,
            meterDenominator: nil,
            phaseOffset: .zero,
            probability: 1,
            halfTimeRelation: nil,
            doubleTimeRelation: nil
        )
    }

    private func intervalsInSeconds(_ beats: [BeatEvent]) -> [Double] {
        zip(beats.dropFirst(), beats).map { ($0.time - $1.time).seconds }
    }

    private func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: - §19.1.5 : tempo stable

    /// 120 BPM stable sur 8 s → beats réguliers : période médiane
    /// 0,5 s ± 5 %, au moins 12 beats, confiance > 0,6.
    func testStableTempoProducesRegularBeats() {
        let duration = 8.0
        let impulses = (0..<16).map { (time: Double($0) * 0.5, amplitude: Float(1)) }
        let envelope = makeEnvelope(impulses: impulses, duration: duration)
        let features = makeFeatures(frameCount: envelope.count, duration: duration)

        let tracked = BeatTracker().track(
            hypothesis: makeHypothesis(bpm: 120),
            envelope: envelope,
            envelopeRate: envelopeRate,
            features: features
        )

        XCTAssertGreaterThanOrEqual(tracked.beats.count, 12)
        let intervals = intervalsInSeconds(tracked.beats)
        XCTAssertEqual(median(intervals), 0.5, accuracy: 0.025, "période médiane hors ± 5 %")
        for beat in tracked.beats {
            XCTAssertGreaterThan(beat.confidence, 0.6)
        }
    }

    // MARK: - §19.1.5 : légères variations de tempo

    /// Accélération linéaire 100 → 140 BPM : les intervalles entre beats
    /// DÉCROISSENT (médiane de la première moitié > médiane de la seconde).
    func testAcceleratingTempoProducesDecreasingIntervals() {
        let duration = 12.0
        var impulses: [(time: Double, amplitude: Float)] = []
        var time = 0.0
        while time < duration {
            impulses.append((time: time, amplitude: 1))
            let instantBPM = 100.0 + (140.0 - 100.0) * (time / duration)
            time += 60.0 / instantBPM
        }
        let envelope = makeEnvelope(impulses: impulses, duration: duration)
        let features = makeFeatures(frameCount: envelope.count, duration: duration)

        let tracked = BeatTracker().track(
            hypothesis: makeHypothesis(bpm: 120),
            envelope: envelope,
            envelopeRate: envelopeRate,
            features: features
        )

        let intervals = intervalsInSeconds(tracked.beats)
        XCTAssertGreaterThanOrEqual(intervals.count, 8)
        let half = intervals.count / 2
        let firstHalfMedian = median(Array(intervals[..<half]))
        let secondHalfMedian = median(Array(intervals[half...]))
        XCTAssertGreaterThan(firstHalfMedian, secondHalfMedian,
                             "Les intervalles doivent décroître pendant l'accélération")
    }

    // MARK: - §20 niveau A : mesure et downbeats

    /// Accents renforcés tous les 4 beats (impulsions 2× plus fortes +
    /// énergie basse bande aux mêmes instants) → meterNumerator == 4 et
    /// downbeats sur les impulsions fortes (± 40 ms), index croissants.
    func testAccentsEveryFourBeatsYieldMeterFourWithAlignedDownbeats() throws {
        let duration = 12.0
        var impulses: [(time: Double, amplitude: Float)] = []
        var strongTimes: [Double] = []
        var strongFrames: [Int] = []
        var beatIndex = 0
        while Double(beatIndex) * 0.5 < duration {
            let time = Double(beatIndex) * 0.5
            let isStrong = beatIndex.isMultiple(of: 4)
            impulses.append((time: time, amplitude: isStrong ? 2 : 1))
            if isStrong {
                strongTimes.append(time)
                strongFrames.append(Int((time * envelopeRate).rounded()))
            }
            beatIndex += 1
        }
        let envelope = makeEnvelope(impulses: impulses, duration: duration)
        let features = makeFeatures(
            frameCount: envelope.count,
            duration: duration,
            bassAccentFrames: strongFrames
        )

        let tracked = BeatTracker().track(
            hypothesis: makeHypothesis(bpm: 120),
            envelope: envelope,
            envelopeRate: envelopeRate,
            features: features
        )

        XCTAssertEqual(tracked.meterNumerator, 4)
        XCTAssertEqual(tracked.hypothesis.meterNumerator, 4,
                       "L'hypothèse complétée doit porter la mesure retenue")
        XCTAssertEqual(tracked.hypothesis.meterDenominator, 4)
        XCTAssertGreaterThan(tracked.downbeatConfidence, 0)
        XCTAssertFalse(tracked.bars.isEmpty)

        for bar in tracked.bars {
            let start = bar.start.seconds
            let nearestAccent = try XCTUnwrap(strongTimes.map { abs($0 - start) }.min())
            XCTAssertLessThanOrEqual(nearestAccent, 0.040,
                                     "downbeat à \(start) s à plus de 40 ms d'un accent fort")
            XCTAssertEqual(bar.confidence, tracked.downbeatConfidence)
        }
        XCTAssertEqual(tracked.bars.map(\.index), Array(0..<tracked.bars.count),
                       "Index de mesures non croissants depuis 0")
    }

    /// Symétrique du test précédent en 3 temps (§20 niveau A : mesures
    /// candidates 2/3/4) : accents renforcés tous les 3 beats (impulsions
    /// 2× plus fortes + énergie basse bande aux mêmes instants) →
    /// meterNumerator == 3 et downbeats sur les impulsions fortes (± 40 ms),
    /// index croissants.
    func testAccentsEveryThreeBeatsYieldMeterThreeWithAlignedDownbeats() throws {
        let duration = 12.0
        var impulses: [(time: Double, amplitude: Float)] = []
        var strongTimes: [Double] = []
        var strongFrames: [Int] = []
        var beatIndex = 0
        while Double(beatIndex) * 0.5 < duration {
            let time = Double(beatIndex) * 0.5
            let isStrong = beatIndex.isMultiple(of: 3)
            impulses.append((time: time, amplitude: isStrong ? 2 : 1))
            if isStrong {
                strongTimes.append(time)
                strongFrames.append(Int((time * envelopeRate).rounded()))
            }
            beatIndex += 1
        }
        let envelope = makeEnvelope(impulses: impulses, duration: duration)
        let features = makeFeatures(
            frameCount: envelope.count,
            duration: duration,
            bassAccentFrames: strongFrames
        )

        let tracked = BeatTracker().track(
            hypothesis: makeHypothesis(bpm: 120),
            envelope: envelope,
            envelopeRate: envelopeRate,
            features: features
        )

        XCTAssertEqual(tracked.meterNumerator, 3)
        XCTAssertEqual(tracked.hypothesis.meterNumerator, 3,
                       "L'hypothèse complétée doit porter la mesure retenue")
        XCTAssertEqual(tracked.hypothesis.meterDenominator, 4)
        XCTAssertGreaterThan(tracked.downbeatConfidence, 0)
        XCTAssertFalse(tracked.bars.isEmpty)

        for bar in tracked.bars {
            let start = bar.start.seconds
            let nearestAccent = try XCTUnwrap(strongTimes.map { abs($0 - start) }.min())
            XCTAssertLessThanOrEqual(nearestAccent, 0.040,
                                     "downbeat à \(start) s à plus de 40 ms d'un accent fort")
            XCTAssertEqual(bar.confidence, tracked.downbeatConfidence)
        }
        XCTAssertEqual(tracked.bars.map(\.index), Array(0..<tracked.bars.count),
                       "Index de mesures non croissants depuis 0")
    }
}
