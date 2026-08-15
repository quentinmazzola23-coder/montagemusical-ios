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

    /// Demi-largeur, en frames, de l'attaque déposée par chaque impulsion.
    ///
    /// **Pourquoi une attaque étalée et non un Dirac d'une seule frame.**
    /// L'enveloppe réelle produite par `OnsetDetector` est une somme pondérée
    /// de flux spectral redressé. La STFT (fenêtre 1 024, hop 256) étale tout
    /// transitoire sur `1024/256 = 4` frames, et le détecteur lisse encore par
    /// moyenne glissante de rayon 1 : une attaque y occupe donc 5 à 7 frames.
    /// Une impulsion d'UNE frame est physiquement impossible dans cette
    /// enveloppe, et elle n'est pas neutre pour la mesure : la période d'un
    /// tempo n'est pas un nombre entier de frames (174 BPM → 29,70 frames), si
    /// bien qu'un peigne de Dirac quantifié à `round(k·L)` répartit sa masse
    /// entre les lags 29 et 30 et **effondre l'ACF au vrai lag** tout en la
    /// laissant intacte aux multiples qui retombent près d'un entier. Mesuré à
    /// 200 BPM sur un Dirac d'une frame : `acf(L) = 0,134` contre
    /// `acf(3L) = 0,470`, soit une inversion d'un facteur 3,5 — un pur artefact
    /// de fixture, absent dès que l'attaque occupe 3 frames ou plus
    /// (`acf(L) = 0,695`, `acf(3L) = 0,813`). Une demi-largeur de 2 (support de
    /// 5 frames ≈ 58 ms) modélise fidèlement l'enveloppe réelle. Le cas
    /// `attackHalfWidth = 0` redonne exactement l'ancien Dirac.
    private static let defaultAttackHalfWidth = 2

    private func makeEnvelope(
        impulses: [(time: Double, amplitude: Float)],
        duration: Double,
        noiseAmplitude: Float = 0.03,
        seed: UInt64 = 7,
        attackHalfWidth: Int = TempoEstimatorTests.defaultAttackHalfWidth
    ) -> [Float] {
        let frameCount = Int((duration * envelopeRate).rounded(.up))
        var noise = DeterministicNoise(seed: seed)
        var envelope = (0..<frameCount).map { _ in noise.next() * noiseAmplitude }
        let halfWidth = max(0, attackHalfWidth)
        for impulse in impulses {
            let frame = Int((impulse.time * envelopeRate).rounded())
            // Noyau triangulaire : poids 1 au centre, décroissance linéaire
            // jusqu'à 1/(halfWidth+1) aux bords. À halfWidth = 0 le noyau vaut
            // exactement [1], c'est-à-dire l'impulsion d'origine.
            for offset in (-halfWidth)...halfWidth {
                let index = frame + offset
                guard index >= 0, index < frameCount else { continue }
                let weight = Float(1.0 - Double(abs(offset)) / Double(halfWidth + 1))
                envelope[index] += impulse.amplitude * weight
            }
        }
        return envelope
    }

    /// Impulsions périodiques.
    /// - Parameter offbeatAmplitude: si non nil, dépose en plus une impulsion
    ///   à la **mi-période** (contretemps : hi-hat sur la croche, figure
    ///   omniprésente en hardstyle et en drum'n'bass).
    private func periodicImpulses(
        bpm: Double,
        duration: Double,
        strongEvery: Int? = nil,
        offbeatAmplitude: Float? = nil
    ) -> [(time: Double, amplitude: Float)] {
        let period = 60.0 / bpm
        var impulses: [(time: Double, amplitude: Float)] = []
        var beatIndex = 0
        while Double(beatIndex) * period < duration {
            let isStrong = strongEvery.map { beatIndex.isMultiple(of: $0) } ?? false
            impulses.append((time: Double(beatIndex) * period, amplitude: isStrong ? 2 : 1))
            if let offbeat = offbeatAmplitude {
                let offbeatTime = (Double(beatIndex) + 0.5) * period
                if offbeatTime < duration {
                    impulses.append((time: offbeatTime, amplitude: offbeat))
                }
            }
            beatIndex += 1
        }
        return impulses
    }

    // MARK: - §19.1 : arbitrage d'octave et d'alias

    /// Vérifie que l'hypothèse **retenue** (la première) est le vrai tempo, que
    /// l'alias non métrique à 2/3 du tempo n'apparaît nulle part, et que le
    /// half-time reste néanmoins présent dans la liste (§63 : le moteur peut
    /// rétrograder une hypothèse, jamais la perdre).
    private func assertRetainsTrueTempo(
        _ expected: Double,
        offbeatLayer: Bool = false,
        duration: Double = 30,
        tolerance: Double = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let impulses = periodicImpulses(
            bpm: expected,
            duration: duration,
            // 0,6 de l'amplitude principale : un hi-hat reste nettement sous le
            // kick. À amplitude égale, la distinction beat / croche n'existe
            // plus dans l'autocorrélation, et l'ambiguïté est alors musicale.
            offbeatAmplitude: offbeatLayer ? 0.6 : nil
        )
        let envelope = makeEnvelope(impulses: impulses, duration: duration)
        let hypotheses = TempoEstimator().estimate(envelope: envelope, envelopeRate: envelopeRate)

        guard let top = hypotheses.first else {
            XCTFail("Aucune hypothèse pour \(expected) BPM", file: file, line: line)
            return
        }
        XCTAssertEqual(
            top.tempoBPM, expected, accuracy: tolerance,
            "Hypothèse retenue \(top.tempoBPM) au lieu de \(expected) — "
                + "toutes : \(hypotheses.map(\.tempoBPM))",
            file: file, line: line
        )
        let alias = expected * 2 / 3
        XCTAssertFalse(
            hypotheses.contains { abs($0.tempoBPM - alias) <= tolerance },
            "Alias non métrique à 2/3 du tempo (\(alias) BPM) présent : "
                + "\(hypotheses.map(\.tempoBPM))",
            file: file, line: line
        )
        XCTAssertTrue(
            hypotheses.contains { abs($0.tempoBPM - expected / 2) <= tolerance },
            "Le half-time (\(expected / 2) BPM) a été PERDU au lieu d'être "
                + "rétrogradé : \(hypotheses.map(\.tempoBPM))",
            file: file, line: line
        )
    }

    /// 150 BPM (hardstyle) — l'hypothèse retenue est le vrai tempo.
    func testRetainsTrueTempoAt150BPM() { assertRetainsTrueTempo(150) }

    /// 165 BPM — ancienne limite de bascule du prior (165,3 BPM), passait
    /// autrefois avec 4 % de marge seulement.
    func testRetainsTrueTempoAt165BPM() { assertRetainsTrueTempo(165) }

    /// 174 BPM (drum'n'bass) — rendait autrefois 87 BPM.
    func testRetainsTrueTempoAt174BPM() { assertRetainsTrueTempo(174) }

    /// 180 BPM (uptempo) — rendait autrefois 90 BPM.
    func testRetainsTrueTempoAt180BPM() { assertRetainsTrueTempo(180) }

    /// 200 BPM — rendait autrefois 100 BPM. C'est le cas le plus exigeant :
    /// le prior seul y demande au score un rapport de 1,340 en faveur du vrai
    /// tempo, fourni par la pénalité sous-harmonique (facteur 2).
    func testRetainsTrueTempoAt200BPM() { assertRetainsTrueTempo(200) }

    /// 174 BPM **avec contretemps** — la couche de croches rendait autrefois
    /// une grille non métrique à 116 BPM (= 174 × 2/3), qui n'est ni le tempo
    /// ni son half-time mais une pulsation sur trois dérivant contre la musique.
    func testRetainsTrueTempoAt174BPMWithOffbeatLayer() {
        assertRetainsTrueTempo(174, offbeatLayer: true)
    }

    /// 180 BPM **avec contretemps** — rendait autrefois 120 BPM (= 180 × 2/3).
    func testRetainsTrueTempoAt180BPMWithOffbeatLayer() {
        assertRetainsTrueTempo(180, offbeatLayer: true)
    }

    /// Le contretemps ne doit pas non plus déstabiliser un tempo déjà correct
    /// avant correctif (150 BPM passait, mais 150 + contretemps donnait 100).
    func testRetainsTrueTempoAt150BPMWithOffbeatLayer() {
        assertRetainsTrueTempo(150, offbeatLayer: true)
    }

    // MARK: - §19.1 : détection du tempo

    /// Impulsions à 120 BPM → l'hypothèse **retenue** est 120 ± 3 BPM.
    ///
    /// Ce test vérifiait auparavant la seule présence de 120 BPM dans le
    /// **top 2**, en tolérant explicitement que l'interprétation half-time
    /// à 60 BPM domine. Cette tolérance décrivait le défaut d'arbitrage
    /// d'octave, pas une propriété souhaitable : le half-time l'emportait par
    /// construction du score, indépendamment du tempo. L'assertion est donc
    /// resserrée sur la première hypothèse — celle que `DeterministicMusicAnalyzer`
    /// consomme réellement.
    func testDetects120BPMAsTopHypothesis() {
        let envelope = makeEnvelope(
            impulses: periodicImpulses(bpm: 120, duration: 16),
            duration: 16
        )
        let hypotheses = TempoEstimator().estimate(envelope: envelope, envelopeRate: envelopeRate)

        XCTAssertFalse(hypotheses.isEmpty, "Enveloppe périodique nette → au moins une hypothèse")
        guard let top = hypotheses.first else { return }
        XCTAssertEqual(
            top.tempoBPM, 120, accuracy: 3,
            "120 BPM n'est pas l'hypothèse retenue : \(hypotheses.map(\.tempoBPM))"
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

    // MARK: - Déterminisme

    /// Même enveloppe → mêmes tempos et mêmes probabilités, bit à bit.
    /// (Les UUID diffèrent par construction : ils ne portent que l'identité
    /// relationnelle, jamais un résultat DSP.)
    func testEstimationIsDeterministic() {
        let envelope = makeEnvelope(
            impulses: periodicImpulses(bpm: 174, duration: 30, offbeatAmplitude: 0.6),
            duration: 30
        )
        let first = TempoEstimator().estimate(envelope: envelope, envelopeRate: envelopeRate)
        let second = TempoEstimator().estimate(envelope: envelope, envelopeRate: envelopeRate)

        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.tempoBPM, b.tempoBPM)
            XCTAssertEqual(a.probability, b.probability)
            XCTAssertEqual(a.phaseOffset, b.phaseOffset)
        }
    }
}
