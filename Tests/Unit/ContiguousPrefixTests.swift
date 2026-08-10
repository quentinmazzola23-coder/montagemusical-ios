//
//  ContiguousPrefixTests.swift
//  MontageMusicalTests
//
//  Tests unitaires obligatoires — spécification §70, bloc « Préfixe
//  exportable » : toutes remplies ; première vide ; trou au milieu ;
//  asset downloading ; asset unavailable ; cases remplies après le trou
//  non déplacées. Ajout : slots donnés dans le désordre → tri par index.
//

import XCTest
@testable import MontageMusical

final class ContiguousPrefixTests: XCTestCase {

    // MARK: - Helper

    /// Fabrique une case snapshot. `status == nil` produit une case vide
    /// (aucune association).
    private func makeSlot(
        index: Int,
        startTicks: Int64,
        endTicks: Int64,
        status: ClipAssignmentStatus? = .ready
    ) -> ProjectSlot {
        let assignment: ClipAssignmentSnapshot? = status.map { status in
            ClipAssignmentSnapshot(
                id: UUID(),
                assetLocalIdentifier: "asset-\(index)",
                status: status
            )
        }
        return ProjectSlot(
            id: UUID(),
            index: index,
            start: MediaTime(ticks: startTicks),
            end: MediaTime(ticks: endTicks),
            assignment: assignment
        )
    }

    // MARK: - §70 : toutes remplies

    func testAllSlotsReadyReturnsAllSlots() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let prefix = contiguousReadyPrefix(slots: slots)

        // Égalité complète des structs : les cases retournées conservent
        // leurs temps absolus (aucun recompactage possible).
        XCTAssertEqual(prefix, slots)

        // La propriété du snapshot délègue au même algorithme (spec §51).
        let snapshot = ProjectSnapshot(projectID: UUID(), slots: slots, geometry: nil)
        XCTAssertEqual(snapshot.contiguousReadyPrefix.map(\.id), slots.map(\.id))
    }

    // MARK: - §70 : première vide

    func testFirstSlotEmptyReturnsEmptyPrefix() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let prefix = contiguousReadyPrefix(slots: slots)

        XCTAssertTrue(prefix.isEmpty)
    }

    // MARK: - §70 : trou au milieu

    func testGapInMiddleStopsBeforeGap() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil),
            makeSlot(index: 3, startTicks: 120_000, endTicks: 165_000),
            makeSlot(index: 4, startTicks: 165_000, endTicks: 210_000)
        ]

        let prefix = contiguousReadyPrefix(slots: slots)

        // Égalité complète : le préfixe est exactement [slot 0, slot 1],
        // temps absolus intacts.
        XCTAssertEqual(prefix, [slots[0], slots[1]])
    }

    // MARK: - §70 : asset downloading

    func testDownloadingAssetStopsPrefixBeforeIt() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .downloading),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let prefix = contiguousReadyPrefix(slots: slots)

        XCTAssertEqual(prefix.map(\.index), [0])
    }

    // MARK: - §70 : asset unavailable

    func testUnavailableAssetStopsPrefixBeforeIt() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .unavailable),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let prefix = contiguousReadyPrefix(slots: slots)

        XCTAssertEqual(prefix.map(\.index), [0])
    }

    // MARK: - §70 : cases remplies après le trou non déplacées

    func testSlotsAfterGapAreNeverMoved() {
        let afterGapA = makeSlot(index: 3, startTicks: 120_000, endTicks: 165_000)
        let afterGapB = makeSlot(index: 4, startTicks: 165_000, endTicks: 210_000)
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil),
            afterGapA,
            afterGapB
        ]

        let prefix = contiguousReadyPrefix(slots: slots)

        // Les cases après le trou ne font pas partie du préfixe.
        XCTAssertFalse(prefix.contains { $0.id == afterGapA.id })
        XCTAssertFalse(prefix.contains { $0.id == afterGapB.id })

        // Assertion sur la SORTIE : le préfixe retourné est exactement
        // [slot 0, slot 1], structs d'origine intacts (index et temps
        // absolus préservés — aucun déplacement, aucun avancement,
        // spec §51, principe §3.12).
        XCTAssertEqual(prefix, [slots[0], slots[1]])
    }

    // MARK: - Ajout : tout statut non-ready interrompt le préfixe

    func testResolvingAssetStopsPrefixBeforeIt() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .resolving),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        XCTAssertEqual(contiguousReadyPrefix(slots: slots), [slots[0]])
    }

    func testTooShortAssetStopsPrefixBeforeIt() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .tooShort),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        XCTAssertEqual(contiguousReadyPrefix(slots: slots), [slots[0]])
    }

    // MARK: - Ajout : slots donnés dans le désordre

    func testUnorderedSlotsAreSortedByIndex() {
        let slot0 = makeSlot(index: 0, startTicks: 0, endTicks: 45_000)
        let slot1 = makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000)
        let slot2 = makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)

        // Ordre d'entrée volontairement mélangé.
        let prefix = contiguousReadyPrefix(slots: [slot2, slot0, slot1])

        XCTAssertEqual(prefix.map(\.index), [0, 1, 2])
        XCTAssertEqual(prefix.map(\.id), [slot0.id, slot1.id, slot2.id])
    }
}
