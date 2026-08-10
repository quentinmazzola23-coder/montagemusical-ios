//
//  MediaTimeTests.swift
//  MontageMusicalTests
//
//  Tests obligatoires du bloc « Temps » (spec §70) :
//  - conversion secondes ↔ ticks ↔ CMTime ;
//  - affichage au centième ;
//  - absence de dérive après 1 000 cases ;
//  - durée calculée par différence ;
//  - cadence 29,97/59,94.
//

import XCTest
@testable import MontageMusical
#if canImport(CoreMedia)
import CoreMedia
#endif

final class MediaTimeTests: XCTestCase {

    // MARK: - Conversion secondes ↔ ticks ↔ CMTime

    /// Exemple de la spec §9 : 8,431764 s × 60 000 = 505 905,84
    /// → arrondi au tick le plus proche = 505 906.
    func testSecondsToTicksRoundsToNearestTick() {
        XCTAssertEqual(MediaTime(seconds: 8.431764).ticks, 505_906)
    }

    /// La valeur dérivée `seconds` reflète exactement les ticks stockés.
    /// 505 906 / 60 000 = 8,43176666… (littéral recalculé à la main,
    /// indépendant de la formule de l'implémentation).
    func testTicksToSecondsIsDerivedValue() {
        XCTAssertEqual(MediaTime(ticks: 505_906).seconds, 8.431766666666667, accuracy: 1e-12)
        XCTAssertEqual(MediaTime(ticks: 60_000).seconds, 1.0)
        XCTAssertEqual(MediaTime.zero.seconds, 0.0)
    }

    #if canImport(CoreMedia)
    /// Round-trip ticks → CMTime → ticks sans aucune perte à timescale 60 000.
    func testCMTimeRoundTripIsLosslessAtCanonicalTimescale() throws {
        let samples: [Int64] = [0, 1, 599, 600, 505_906, 2_002_000,
                                3_599_994, 60_000 * 3_600, 9_876_543_210]
        for ticks in samples {
            let time = MediaTime(ticks: ticks)
            XCTAssertEqual(time.cmTime.value, CMTimeValue(ticks))
            XCTAssertEqual(time.cmTime.timescale, 60_000)
            XCTAssertEqual(try XCTUnwrap(MediaTime(cmTime: time.cmTime)).ticks, ticks,
                           "Round-trip avec perte pour \(ticks) ticks")
        }
    }

    /// Un CMTime de timescale étrangère (ex. audio 44 100 Hz) est converti
    /// au tick canonique le plus proche.
    func testForeignTimescaleCMTimeConvertsToNearestTick() throws {
        // 1 échantillon à 44 100 Hz = 60 000/44 100 = 1,3605 ticks → 1.
        XCTAssertEqual(try XCTUnwrap(MediaTime(cmTime: CMTime(value: 1, timescale: 44_100))).ticks, 1)
        // 3 échantillons = 4,0816 ticks → 4.
        XCTAssertEqual(try XCTUnwrap(MediaTime(cmTime: CMTime(value: 3, timescale: 44_100))).ticks, 4)
        // 22 050 échantillons = 0,5 s exactement = 30 000 ticks (exact).
        XCTAssertEqual(try XCTUnwrap(MediaTime(cmTime: CMTime(value: 22_050, timescale: 44_100))).ticks, 30_000)
        // 44 100 échantillons = 1 s exactement = 60 000 ticks (exact).
        XCTAssertEqual(try XCTUnwrap(MediaTime(cmTime: CMTime(value: 44_100, timescale: 44_100))).ticks, 60_000)
        // Égalité parfaite à mi-chemin : 1/40 000 s = 1,5 tick
        // → règle constante « ,5 arrondi supérieur » → 2 ticks.
        XCTAssertEqual(try XCTUnwrap(MediaTime(cmTime: CMTime(value: 1, timescale: 40_000))).ticks, 2)
    }

    /// Un CMTime non numérique ou débordant n'est jamais converti en zéro
    /// fabriqué : la conversion échoue explicitement (`nil`).
    func testNonNumericOrOverflowingCMTimeFailsConversion() {
        XCTAssertNil(MediaTime(cmTime: .invalid))
        XCTAssertNil(MediaTime(cmTime: .indefinite))
        XCTAssertNil(MediaTime(cmTime: .positiveInfinity))
        XCTAssertNil(MediaTime(cmTime: .negativeInfinity))
        // Débordement Int64 : valeur maximale à timescale première avec 60 000.
        XCTAssertNil(MediaTime(cmTime: CMTime(value: .max, timescale: 7)))
    }
    #endif

    // MARK: - Affichage au centième

    /// Exemple de la spec §9 : 8,431764 s → « 00:08,43 »
    /// (virgule décimale française, arrondi d'affichage seulement).
    func testDisplayStringSpecExample() {
        XCTAssertEqual(MediaTime(seconds: 8.431764).displayString, "00:08,43")
    }

    /// Retenue : l'arrondi au centième le plus proche se propage aux
    /// secondes et aux minutes (59,9999 s → 60,00 s → « 01:00,00 »).
    func testDisplayStringCarryPropagation() {
        XCTAssertEqual(MediaTime(seconds: 59.9999).displayString, "01:00,00")
        // 59,995 s = 3 599 700 ticks : centième à mi-chemin, arrondi supérieur.
        XCTAssertEqual(MediaTime(ticks: 3_599_700).displayString, "01:00,00")
    }

    /// Valeur exacte, aucun artefact d'arrondi : 90 s → « 01:30,00 ».
    func testDisplayStringExactValue() {
        XCTAssertEqual(MediaTime(seconds: 90).displayString, "01:30,00")
        XCTAssertEqual(MediaTime.zero.displayString, "00:00,00")
    }

    /// Heures ajoutées à partir d'une heure : « h:mm:ss,cc ».
    func testDisplayStringWithHours() {
        XCTAssertEqual(MediaTime(seconds: 3_600).displayString, "1:00:00,00")
        XCTAssertEqual(MediaTime(seconds: 3_661.5).displayString, "1:01:01,50")
    }

    // MARK: - Absence de dérive après 1 000 cases

    /// 1 000 frontières consécutives construites par ADDITION de durées en
    /// ticks : la 1 000e frontière est exactement égale à la multiplication
    /// directe. Aucune dérive possible (arithmétique entière).
    func testNoDriftAfterOneThousandSlots() {
        let slotDuration = MediaTime(ticks: 1_001)
        var boundary = MediaTime.zero
        for _ in 0..<1_000 {
            boundary = boundary + slotDuration
        }
        // Égalité EXACTE (ticks entiers), pas une tolérance flottante.
        XCTAssertEqual(boundary.ticks, 1_000 * 1_001)
        XCTAssertEqual(boundary, MediaTime(ticks: 1_001_000))
    }

    /// Contre-exemple documentaire : reconstruire des frontières depuis les
    /// valeurs AFFICHÉES (centièmes) dérive — c'est précisément interdit
    /// par la spec §9. Le pipeline n'utilise jamais ce chemin.
    func testRebuildingBoundariesFromDisplayedCentisecondsWouldDrift() {
        let slotDuration = MediaTime(ticks: 1_001) // 0,01668 s → affiché « 0,02 »
        // Durée arrondie au centième d'affichage, réinjectée (INTERDIT) :
        let displayedCentiseconds = MediaTime.roundedDivision(slotDuration.ticks, dividedBy: 600)
        let driftedTicks = 1_000 * displayedCentiseconds * 600
        // La reconstruction depuis l'affichage ne retombe PAS sur la vraie
        // frontière : 1 200 000 ≠ 1 001 000.
        XCTAssertNotEqual(driftedTicks, 1_000 * slotDuration.ticks)
    }

    // MARK: - Durée calculée par différence

    /// La durée d'une case est `end - start`, jamais une valeur persistée.
    func testDurationIsComputedByDifference() {
        let start = MediaTime(ticks: 505_906)
        let end = MediaTime(ticks: 1_010_812)
        XCTAssertEqual((end - start).ticks, 504_906)
        // Cohérence : start + (end - start) == end, exactement.
        XCTAssertEqual(start + (end - start), end)
    }

    // MARK: - Cadence 29,97 / 59,94

    /// Une image NTSC 29,97 (1001/30000 s) vaut exactement 2002 ticks ;
    /// une image 59,94 (1001/60000 s) vaut exactement 1001 ticks.
    func testNTSCFrameDurationsAreExactInTicks() throws {
        XCTAssertEqual(MediaTime(seconds: 1_001.0 / 30_000.0).ticks, 2_002)
        XCTAssertEqual(MediaTime(seconds: 1_001.0 / 60_000.0).ticks, 1_001)
        #if canImport(CoreMedia)
        // Même exactitude par le chemin entier CMTime (aucun Double).
        XCTAssertEqual(try XCTUnwrap(MediaTime(cmTime: CMTime(value: 1_001, timescale: 30_000))).ticks, 2_002)
        XCTAssertEqual(try XCTUnwrap(MediaTime(cmTime: CMTime(value: 1_001, timescale: 60_000))).ticks, 1_001)
        #endif
    }

    /// 1 000 images à 29,97 = exactement 2 002 000 ticks : 60 000 étant
    /// compatible avec le tick NTSC de 2002, l'accumulation entière est
    /// exacte, aucune erreur d'arrondi.
    func testOneThousandNTSCFramesAccumulateExactly() {
        let frameDuration = MediaTime(ticks: 2_002)
        var total = MediaTime.zero
        for _ in 0..<1_000 {
            total = total + frameDuration
        }
        XCTAssertEqual(total.ticks, 2_002_000)
        XCTAssertEqual(total, MediaTime(ticks: 1_000 * 2_002))
    }

    /// `nearestFrameBoundary` colle une valeur arbitraire sur la grille
    /// 29,97 (2002 ticks) avec la règle constante « ,5 arrondi supérieur ».
    func testNearestFrameBoundaryOnNTSC2997Grid() {
        let frame = MediaTime(ticks: 2_002)
        // 3000/2002 = 1,4985 image → image 1 → 2002 ticks.
        XCTAssertEqual(MediaTime(ticks: 3_000).nearestFrameBoundary(frameDuration: frame).ticks, 2_002)
        // 3003 ticks = exactement 1,5 image → arrondi supérieur → image 2.
        XCTAssertEqual(MediaTime(ticks: 3_003).nearestFrameBoundary(frameDuration: frame).ticks, 4_004)
        // 5000/2002 = 2,4975 image → image 2 → 4004 ticks.
        XCTAssertEqual(MediaTime(ticks: 5_000).nearestFrameBoundary(frameDuration: frame).ticks, 4_004)
        // Une valeur déjà sur la grille reste inchangée.
        XCTAssertEqual(MediaTime(ticks: 4_004).nearestFrameBoundary(frameDuration: frame).ticks, 4_004)
        XCTAssertEqual(MediaTime.zero.nearestFrameBoundary(frameDuration: frame), .zero)
    }

    /// Même collage sur la grille 59,94 (1001 ticks).
    func testNearestFrameBoundaryOnNTSC5994Grid() {
        let frame = MediaTime(ticks: 1_001)
        // 1502/1001 = 1,5005 image → image 2 → 2002 ticks.
        XCTAssertEqual(MediaTime(ticks: 1_502).nearestFrameBoundary(frameDuration: frame).ticks, 2_002)
        // 1400/1001 = 1,3986 image → image 1 → 1001 ticks.
        XCTAssertEqual(MediaTime(ticks: 1_400).nearestFrameBoundary(frameDuration: frame).ticks, 1_001)
    }
}
