//
//  AssemblyViewLogicTests.swift
//  MontageMusicalTests
//
//  Tests de la logique d'écran du Jalon 7 (`AssemblyViewLogic`), extraite
//  en fonctions pures testables SANS UI :
//  - clamp de l'index de case active (§60 : valeur restaurée hors bornes) ;
//  - fenêtre du carrousel §35.3 clampée aux bornes 0 et N-1 ;
//  - dérivation des libellés du dock contextuel §36 (case vide/remplie) ;
//  - Export désactivé quand le préfixe exportable §51 est vide (réutilise
//    `contiguousReadyPrefix` du Domain avec des snapshots `ProjectSlot`).
//

import XCTest
@testable import MontageMusical

final class AssemblyViewLogicTests: XCTestCase {

    // MARK: - Helpers privés (portée classe — aucune collision de module)

    /// Fabrique une case snapshot §51. `status == nil` produit une case
    /// vide (aucune association).
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

    // MARK: - Clamp de l'index actif (§60)

    func testClampNegativeIndexReturnsZero() {
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(-3, slotCount: 5), 0)
    }

    func testClampBeyondLastReturnsLastIndex() {
        // §60 : la valeur restaurée peut dépasser si les cases ont changé
        // (duplication, migration) — jamais d'indexation hors bornes.
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(99, slotCount: 5), 4)
    }

    func testClampInRangeIndexIsUnchanged() {
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(2, slotCount: 5), 2)
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(0, slotCount: 5), 0)
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(4, slotCount: 5), 4)
    }

    func testClampWithoutSlotsReturnsZero() {
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(7, slotCount: 0), 0)
    }

    // MARK: - Fenêtre du carrousel (§35.3)

    func testWindowRangeInMiddleIsPreviousActiveNext() {
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 2, slotCount: 5),
            1...3
        )
    }

    func testWindowRangeAtFirstSlotClampsLowerBoundToZero() {
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 0, slotCount: 5),
            0...1
        )
    }

    func testWindowRangeAtLastSlotClampsUpperBoundToLastIndex() {
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 4, slotCount: 5),
            3...4
        )
    }

    func testWindowRangeWithSingleSlotIsZeroToZero() {
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 0, slotCount: 1),
            0...0
        )
    }

    func testWindowRangeWithoutSlotsIsZeroToZero() {
        // Cas dégénéré : jamais de plage invalide (lowerBound > upperBound
        // ferait planter `ClosedRange`).
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 3, slotCount: 0),
            0...0
        )
    }

    func testWindowRangeClampsOutOfRangeActiveIndex() {
        // Index actif hors bornes (restauration §60) : la fenêtre est
        // celle du dernier index valide.
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 42, slotCount: 3),
            1...2
        )
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: -5, slotCount: 3),
            0...1
        )
    }

    // MARK: - Libellés du dock contextuel (§36)

    func testDockLabelsForEmptySlotShowAddVideoWithRequiredDuration() {
        // 72 000 ticks = 1,2 s → « 1,20 s » (§35.2, `shortDurationString`).
        let labels = AssemblyViewLogic.dockLabels(
            activeState: .empty,
            requiredDuration: MediaTime(ticks: 72_000)
        )

        XCTAssertEqual(labels.left, "Projets")
        XCTAssertEqual(labels.center, "+ Vidéo • 1,20 s")
        XCTAssertEqual(labels.right, "Export")
    }

    func testDockLabelsForReadySlotShowReplace() {
        let labels = AssemblyViewLogic.dockLabels(
            activeState: .ready,
            requiredDuration: MediaTime(ticks: 72_000)
        )

        XCTAssertEqual(labels.left, "Projets")
        XCTAssertEqual(labels.center, "Remplacer")
        XCTAssertEqual(labels.right, "Export")
    }

    func testDockLabelsForEveryAssignedStateShowReplace() {
        // §36 : dès qu'une association existe — même non prête
        // (resolving, downloading §44, unavailable §64, tooShort) — la
        // case est « remplie » : le centre propose « Remplacer ».
        let assignedStates: [AssemblySlotState] = [
            .resolving, .downloading, .unavailable, .tooShort
        ]
        for state in assignedStates {
            let labels = AssemblyViewLogic.dockLabels(
                activeState: state,
                requiredDuration: MediaTime(ticks: 30_000)
            )
            XCTAssertEqual(labels.center, "Remplacer", "état : \(state)")
            XCTAssertEqual(labels.left, "Projets", "état : \(state)")
            XCTAssertEqual(labels.right, "Export", "état : \(state)")
        }
    }

    // MARK: - Export désactivé si le préfixe §51 est vide

    func testExportDisabledWithoutAnySlot() {
        XCTAssertFalse(AssemblyViewLogic.isExportEnabled(slots: []))
    }

    func testExportDisabledWhenFirstSlotIsEmpty() {
        // §51/§66 : « première case vide : export désactivé » — même si
        // des cases ultérieures sont prêtes.
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        XCTAssertFalse(AssemblyViewLogic.isExportEnabled(slots: slots))
    }

    func testExportDisabledWhenFirstSlotIsDownloading() {
        // §51 : une case `downloading` interrompt le préfixe — en première
        // position, le préfixe est vide.
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: .downloading),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000)
        ]

        XCTAssertFalse(AssemblyViewLogic.isExportEnabled(slots: slots))
    }

    func testExportEnabledWhenFirstSlotIsReady() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: nil)
        ]

        XCTAssertTrue(AssemblyViewLogic.isExportEnabled(slots: slots))
    }

    func testExportEnabledDespiteGapAfterReadyPrefix() {
        // §51 : l'export partiel s'arrête au premier trou mais reste
        // POSSIBLE — le préfixe [0, 1] est non vide.
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil),
            makeSlot(index: 3, startTicks: 120_000, endTicks: 165_000)
        ]

        XCTAssertTrue(AssemblyViewLogic.isExportEnabled(slots: slots))
    }
}
