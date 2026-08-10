//
//  TempoEstimatorTests.swift
//  MontageMusicalTests
//
//  Tests du Jalon 4 côté rythme — spec §19.1 et acceptation §79
//  « tests audio synthétiques » : enveloppes d'onsets synthétiques en
//  pur Swift (impulsions périodiques + bruit LCG faible et déterministe),
//  sans dépendance aux fichiers DSP ni à des fichiers audio.
//

import XCTest
@testable import MontageMusical

final class TempoEstimatorTests: XCTestCase {

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

    private func periodicImpulses(
        bpm: Double,
        duration: Double,
        strongEvery: Int? = nil
    ) -> [(time: Double, amplitude: Float)] {
        let period = 60.0 / bpm
        var impulses: [(time: Double, amplitude: Float)] = []
        var beatIndex = 0
        while Double(beatIndex) * period < duration {
            let isStrong = strongEvery.map { beatIndex.isMultiple(of: $0) } ?? false
            impulses.append((time: Double(beatIndex) * period, amplitude: isStrong ? 2 : 1))
            beatIndex += 1
        }
        return impulses
    }

    // MARK: - §19.1 : détection du tempo

    /// Impulsions à 120 BPM → une hypothèse à 120 ± 3 BPM dans le top 2
    /// (l'interprétation half-time 60 BPM peut légitimement dominer).
    func testDetects120BPMInTopTwoHypotheses() {
        let envelope = makeEnvelope(
            impulses: periodicImpulses(bpm: 120, duration: 16),
            duration: 16
        )
        let hypotheses = TempoEstimator().estimate(envelope: envelope, envelopeRate: envelopeRate)

        XCTAssertFalse(hypotheses.isEmpty, "Enveloppe périodique nette → au moins une hypothèse")
        let topTwo = hypotheses.prefix(2)
        XCTAssertTrue(
            topTwo.contains { abs($0.tempoBPM - 120) <= 3 },
            "120 BPM absent du top 2 : \(topTwo.map(\.tempoBPM))"
        )
    }

    /// Contrat §19.1 : probabilités normalisées (somme = 1) et triées par
    /// ordre décroissant ; niveau A : courbe de tempo constante démarrant
    /// à zéro ; la mesure n'est pas renseignée ici (estimée par BeatTracker).
    func testHypothesesContractProbabilitiesCurveAndMeter() throws {
        let envelope = makeEnvelope(
            impulses: periodicImpulses(bpm: 120, duration: 16),
            duration: 16
        )
        let hypotheses = TempoEstimator().estimate(envelope: envelope, envelopeRate: envelopeRate)

        let probabilitySum = hypotheses.reduce(0) { $0 + $1.probability }
        XCTAssertEqual(probabilitySum, 1.0, accuracy: 1e-9)
        for pair in zip(hypotheses, hypotheses.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.probability, pair.1.probability,
                                        "Hypothèses non triées par probabilité décroissante")
        }
        let top = try XCTUnwrap(hypotheses.first)
        XCTAssertEqual(top.tempoCurve.count, 1)
        XCTAssertEqual(top.tempoCurve[0].time, .zero)
        XCTAssertEqual(top.tempoCurve[0].value, top.tempoBPM)
        XCTAssertNil(top.meterNumerator)
        XCTAssertNil(top.meterDenominator)
    }

    // MARK: - §19.1 : relations half/double-time

    /// Accents un beat sur deux à 120 BPM → les hypothèses 60 et 120 BPM
    /// coexistent et leurs UUID se référencent mutuellement.
    func testHalfAndDoubleTimeRelationsReferenceEachOther() throws {
        let envelope = makeEnvelope(
            impulses: periodicImpulses(bpm: 120, duration: 16, strongEvery: 2),
            duration: 16
        )
        let hypotheses = TempoEstimator().estimate(envelope: envelope, envelopeRate: envelopeRate)

        let fast = try XCTUnwrap(
            hypotheses.first { abs($0.tempoBPM - 120) <= 4 },
            "120 BPM absent : \(hypotheses.map(\.tempoBPM))"
        )
        let slow = try XCTUnwrap(
            hypotheses.first { abs($0.tempoBPM - 60) <= 3 },
            "60 BPM absent : \(hypotheses.map(\.tempoBPM))"
        )
        XCTAssertEqual(fast.halfTimeRelation, slow.id,
                       "L'hypothèse 120 doit référencer 60 comme half-time")
        XCTAssertEqual(slow.doubleTimeRelation, fast.id,
                       "L'hypothèse 60 doit référencer 120 comme double-time")
    }

    // MARK: - §63 : enveloppe plate ou vide

    /// Enveloppe plate ou vide → aucune hypothèse (le niveau au-dessus
    /// produit une partition structurelle, jamais un tempo factice §0.7).
    func testFlatOrEmptyEnvelopeYieldsNoHypothesis() {
        let flat = [Float](repeating: 0.5, count: 2_000)
        XCTAssertTrue(TempoEstimator().estimate(envelope: flat, envelopeRate: envelopeRate).isEmpty)
        XCTAssertTrue(TempoEstimator().estimate(envelope: [], envelopeRate: envelopeRate).isEmpty)
    }
}
