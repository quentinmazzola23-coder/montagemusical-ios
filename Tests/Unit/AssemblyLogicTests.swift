//
//  AssemblyLogicTests.swift
//  MontageMusicalTests
//
//  Tests déterministes de la logique d'assemblage — Jalon 7 :
//  - dérivation unique `AssemblySlotState.from` (statuts §13.3, repli sobre) ;
//  - grille durée-proportionnelle `AssemblyGeometry` (§35.3) : positions par
//    ticks cumulés, bornes, clamp, cohérence aller-retour ;
//  - `AssemblySlotItem.duration` toujours calculée `end - start` (§9).
//

import XCTest
@testable import MontageMusical

final class AssemblyLogicTests: XCTestCase {

    // MARK: - Helpers privés

    /// Cases contiguës aux durées données (ticks), index 0-based, état
    /// `.empty` (la géométrie ne dépend pas de l'état).
    private func makeSlots(durationsTicks: [Int64]) -> [AssemblySlotItem] {
        var items: [AssemblySlotItem] = []
        var start: Int64 = 0
        for (index, duration) in durationsTicks.enumerated() {
            items.append(AssemblySlotItem(
                id: UUID(),
                index: index,
                start: MediaTime(ticks: start),
                end: MediaTime(ticks: start + duration),
                state: .empty
            ))
            start += duration
        }
        return items
    }

    /// Grille de référence des tests §35.3 : durées 1 s / 2 s / 1 s
    /// (60 000 / 120 000 / 60 000 ticks, total 240 000).
    private func makeReferenceSlots() -> [AssemblySlotItem] {
        makeSlots(durationsTicks: [60_000, 120_000, 60_000])
    }

    // MARK: - AssemblySlotState.from : les 5 rawValues réels (§13.3)

    func testFromMapsAllFiveKnownStatuses() {
        // rawValues RÉELS de `ClipAssignmentStatus` — jamais de littéraux
        // dupliqués : si l'enum change, ce test suit.
        let expectations: [(ClipAssignmentStatus, AssemblySlotState)] = [
            (.resolving, .resolving),
            (.downloading, .downloading),
            (.ready, .ready),
            (.unavailable, .unavailable),
            (.tooShort, .tooShort)
        ]
        for (status, expected) in expectations {
            XCTAssertEqual(
                AssemblySlotState.from(assignmentStatusRaw: status.rawValue),
                expected,
                "Statut \(status.rawValue) mal dérivé"
            )
        }
    }

    func testFromNilIsEmpty() {
        // Aucune association → case vide.
        XCTAssertEqual(AssemblySlotState.from(assignmentStatusRaw: nil), .empty)
    }

    func testFromUnknownRawValueFallsBackToUnavailable() {
        // Donnée corrompue ou version future → repli sobre : jamais prête,
        // l'export partiel s'arrête avant elle (§51, §64).
        XCTAssertEqual(AssemblySlotState.from(assignmentStatusRaw: "corrompu"), .unavailable)
    }

    // MARK: - AssemblyGeometry.slotIndex : grille durée-proportionnelle

    func testSlotIndexProportionalGrid() {
        let slots = makeReferenceSlots()
        // Frontières cumulées : 0,25 et 0,75 de la largeur.
        XCTAssertEqual(AssemblyGeometry.slotIndex(atFraction: 0.1, slots: slots), 0)
        XCTAssertEqual(AssemblyGeometry.slotIndex(atFraction: 0.5, slots: slots), 1)
        XCTAssertEqual(AssemblyGeometry.slotIndex(atFraction: 0.9, slots: slots), 2)
    }

    func testSlotIndexAtBounds() {
        let slots = makeReferenceSlots()
        // Borne 0 → première case ; borne 1 → dernière case.
        XCTAssertEqual(AssemblyGeometry.slotIndex(atFraction: 0, slots: slots), 0)
        XCTAssertEqual(AssemblyGeometry.slotIndex(atFraction: 1, slots: slots), 2)
    }

    func testSlotIndexClampsOutOfRangeFractions() {
        let slots = makeReferenceSlots()
        // Fraction négative ou supérieure à 1 : clampée (un glisser qui sort
        // de la vue reste sur la première/dernière case).
        XCTAssertEqual(AssemblyGeometry.slotIndex(atFraction: -0.5, slots: slots), 0)
        XCTAssertEqual(AssemblyGeometry.slotIndex(atFraction: 1.5, slots: slots), 2)
    }

    func testSlotIndexEmptySlotsReturnsNil() {
        XCTAssertNil(AssemblyGeometry.slotIndex(atFraction: 0.5, slots: []))
    }

    // MARK: - AssemblyGeometry.fractionRange : ticks cumulés exacts

    func testFractionRangeUsesExactCumulativeTicks() throws {
        let slots = makeReferenceSlots()
        // Case 1 : ticks cumulés 60 000 / 240 000 → 0,25, et
        // 180 000 / 240 000 → 0,75 — valeurs EXACTES en Double.
        let range = try XCTUnwrap(AssemblyGeometry.fractionRange(of: 1, slots: slots))
        XCTAssertEqual(range.lowerBound, 0.25)
        XCTAssertEqual(range.upperBound, 0.75)
    }

    func testFractionRangeOutOfBoundsReturnsNil() {
        let slots = makeReferenceSlots()
        XCTAssertNil(AssemblyGeometry.fractionRange(of: -1, slots: slots))
        XCTAssertNil(AssemblyGeometry.fractionRange(of: 3, slots: slots))
        XCTAssertNil(AssemblyGeometry.fractionRange(of: 0, slots: []))
    }

    // MARK: - Cohérence aller-retour

    func testRoundTripMidpointOfFractionRangeReturnsSameIndex() throws {
        let slots = makeReferenceSlots()
        for index in slots.indices {
            let range = try XCTUnwrap(AssemblyGeometry.fractionRange(of: index, slots: slots))
            let midpoint = (range.lowerBound + range.upperBound) / 2
            XCTAssertEqual(
                AssemblyGeometry.slotIndex(atFraction: midpoint, slots: slots),
                index,
                "Aller-retour incohérent pour la case \(index)"
            )
        }
    }

    // MARK: - AssemblySlotItem.duration == end - start (§9)

    func testDurationIsAlwaysEndMinusStart() {
        let item = AssemblySlotItem(
            id: UUID(),
            index: 7,
            start: MediaTime(ticks: 45_000),
            end: MediaTime(ticks: 117_000),
            state: .ready
        )
        XCTAssertEqual(item.duration.ticks, 72_000)
        XCTAssertEqual(item.duration, item.end - item.start)
    }
}
