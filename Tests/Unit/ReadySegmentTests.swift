//
//  ReadySegmentTests.swift
//  MontageMusicalTests
//
//  Segment exportable — CHANGEMENT PRODUIT qui remplace le « préfixe
//  exportable » §51 (contrat complet en tête de `ExportModels.swift`).
//
//  Remplace `ContiguousPrefixTests.swift` : le bloc §70 « Préfixe exportable »
//  est conservé cas par cas (toutes remplies ; première vide ; trou au
//  milieu ; asset downloading ; asset unavailable ; cases remplies après le
//  trou non déplacées), mais l'attendu du cas « première vide » est INVERSÉ —
//  c'est précisément ce que l'utilisateur a demandé :
//
//      AVANT : première case vide → aucun export possible.
//      APRÈS : première case vide → le segment prêt suivant EST le montage.
//
//  S'y ajoutent les cas propres au segment : plusieurs segments (le premier
//  gagne), bornes musicales et durée en TICKS exacts, et le DÉCALAGE
//  `slot.start - musicStart` — la conséquence temporelle critique, testée
//  sans AVFoundation.
//

import XCTest
@testable import MontageMusical

final class ReadySegmentTests: XCTestCase {

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

        let segment = contiguousReadySegment(slots: slots)

        // Égalité complète des structs : les cases retournées conservent
        // leurs temps absolus (aucun recompactage possible).
        XCTAssertEqual(segment.slots, slots)
        XCTAssertFalse(segment.isEmpty)
        XCTAssertEqual(segment.startIndex, 0)
        XCTAssertEqual(segment.endIndex, 2)
        // Montage commençant à l'instant 0 : la durée vaut la fin absolue —
        // c'est l'ancien comportement §51, conservé quand la case 0 est prête.
        XCTAssertEqual(segment.musicStart, MediaTime(ticks: 0))
        XCTAssertEqual(segment.musicEnd, MediaTime(ticks: 150_000))
        XCTAssertEqual(segment.duration, MediaTime(ticks: 150_000))

        // La propriété du snapshot délègue au même algorithme.
        let snapshot = ProjectSnapshot(projectID: UUID(), slots: slots, geometry: nil)
        XCTAssertEqual(snapshot.contiguousReadySegment.slots.map(\.id), slots.map(\.id))
    }

    // MARK: - §70 « première vide » — ATTENDU INVERSÉ par le changement produit

    /// LE nouveau comportement : la case 0 est vide, les cases 1 à 3 sont
    /// prêtes → le segment est `1...3`. L'ancien test attendait un résultat
    /// VIDE (export impossible).
    func testFirstSlotEmptyReturnsTheSegmentThatFollows() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000),
            makeSlot(index: 3, startTicks: 150_000, endTicks: 200_000)
        ]

        let segment = contiguousReadySegment(slots: slots)

        XCTAssertFalse(segment.isEmpty, "une première case vide n'interdit plus l'export")
        XCTAssertEqual(segment.slots, [slots[1], slots[2], slots[3]])
        XCTAssertEqual(segment.startIndex, 1)
        XCTAssertEqual(segment.endIndex, 3)
        // Le montage ne commence plus à l'instant 0 de la musique.
        XCTAssertEqual(segment.musicStart, MediaTime(ticks: 45_000))
        XCTAssertEqual(segment.musicEnd, MediaTime(ticks: 200_000))
        XCTAssertEqual(segment.duration, MediaTime(ticks: 155_000))
        // La case 0 n'est PAS exportée, et aucune case n'a été déplacée pour
        // combler son absence.
        XCTAssertFalse(segment.slots.contains { $0.id == slots[0].id })
        XCTAssertEqual(segment.slots.map(\.start.ticks), [45_000, 90_000, 150_000])
    }

    /// Plusieurs cases non prêtes AVANT le segment : elles sont simplement
    /// ignorées, quel que soit leur statut.
    func testAnyNumberOfNonReadySlotsBeforeTheSegmentAreIgnored() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 10_000, status: nil),
            makeSlot(index: 1, startTicks: 10_000, endTicks: 20_000, status: .downloading),
            makeSlot(index: 2, startTicks: 20_000, endTicks: 30_000, status: .unavailable),
            makeSlot(index: 3, startTicks: 30_000, endTicks: 40_000, status: .resolving),
            makeSlot(index: 4, startTicks: 40_000, endTicks: 50_000, status: .tooShort),
            makeSlot(index: 5, startTicks: 50_000, endTicks: 60_000)
        ]

        let segment = contiguousReadySegment(slots: slots)

        XCTAssertEqual(segment.slots.map(\.index), [5])
        XCTAssertEqual(segment.musicStart, MediaTime(ticks: 50_000))
        XCTAssertEqual(segment.musicEnd, MediaTime(ticks: 60_000))
        XCTAssertEqual(segment.duration, MediaTime(ticks: 10_000))
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

        let segment = contiguousReadySegment(slots: slots)

        // Égalité complète : le segment est exactement [case 0, case 1],
        // temps absolus intacts.
        XCTAssertEqual(segment.slots, [slots[0], slots[1]])
        XCTAssertEqual(segment.duration, MediaTime(ticks: 90_000))
    }

    /// Plusieurs segments : c'est le PREMIER qui compte — comportement
    /// prévisible, dont la mini-timeline montre les bornes. Le second segment
    /// (cases 5 et 6), pourtant plus long, est ignoré.
    func testSeveralSegmentsKeepsTheFirstOne() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000),
            makeSlot(index: 3, startTicks: 120_000, endTicks: 165_000, status: .downloading),
            makeSlot(index: 4, startTicks: 165_000, endTicks: 210_000, status: nil),
            makeSlot(index: 5, startTicks: 210_000, endTicks: 300_000),
            makeSlot(index: 6, startTicks: 300_000, endTicks: 400_000)
        ]

        let segment = contiguousReadySegment(slots: slots)

        XCTAssertEqual(segment.slots.map(\.index), [1, 2])
        XCTAssertEqual(segment.startIndex, 1)
        XCTAssertEqual(segment.endIndex, 2)
        XCTAssertEqual(segment.musicStart, MediaTime(ticks: 45_000))
        XCTAssertEqual(segment.musicEnd, MediaTime(ticks: 120_000))
        XCTAssertEqual(segment.duration, MediaTime(ticks: 75_000))
    }

    // MARK: - §70 : asset downloading / unavailable / resolving / tooShort

    func testDownloadingAssetStopsTheSegmentBeforeIt() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .downloading),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        XCTAssertEqual(contiguousReadySegment(slots: slots).slots, [slots[0]])
    }

    func testUnavailableAssetStopsTheSegmentBeforeIt() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .unavailable),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        XCTAssertEqual(contiguousReadySegment(slots: slots).slots, [slots[0]])
    }

    func testResolvingAssetStopsTheSegmentBeforeIt() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .resolving),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        XCTAssertEqual(contiguousReadySegment(slots: slots).slots, [slots[0]])
    }

    func testTooShortAssetStopsTheSegmentBeforeIt() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .tooShort),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        XCTAssertEqual(contiguousReadySegment(slots: slots).slots, [slots[0]])
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

        let segment = contiguousReadySegment(slots: slots)

        // Les cases après le trou ne font pas partie du segment…
        XCTAssertFalse(segment.slots.contains { $0.id == afterGapA.id })
        XCTAssertFalse(segment.slots.contains { $0.id == afterGapB.id })
        // …et elles n'ont pas bougé d'un tick.
        XCTAssertEqual(afterGapA.start, MediaTime(ticks: 120_000))
        XCTAssertEqual(afterGapB.start, MediaTime(ticks: 165_000))

        // Assertion sur la SORTIE : structs d'origine intacts (index et temps
        // absolus préservés — aucun déplacement, aucun avancement, §3.12).
        XCTAssertEqual(segment.slots, [slots[0], slots[1]])
    }

    // MARK: - Aucune case prête → segment vide (export désactivé)

    func testNoReadySlotReturnsAnEmptySegment() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .downloading),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000, status: .unavailable)
        ]

        let segment = contiguousReadySegment(slots: slots)

        XCTAssertTrue(segment.isEmpty)
        XCTAssertEqual(segment.slotCount, 0)
        XCTAssertEqual(segment.musicStart, .zero)
        XCTAssertEqual(segment.musicEnd, .zero)
        XCTAssertEqual(segment.duration, .zero)
        XCTAssertNil(segment.startIndex)
        XCTAssertNil(segment.endIndex)
        XCTAssertEqual(segment, ReadySegment.empty)
    }

    func testProjectWithoutSlotsReturnsAnEmptySegment() {
        XCTAssertEqual(contiguousReadySegment(slots: []), ReadySegment.empty)
        XCTAssertTrue(ReadySegment.empty.isEmpty)
    }

    // MARK: - Cases dans le désordre → triées par index

    func testUnorderedSlotsAreSortedByIndex() {
        // Segment qui ne commence PAS à zéro, donné dans le désordre : le tri
        // par index doit précéder toute décision.
        let empty0 = makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil)
        let slot1 = makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000)
        let slot2 = makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        let slot3 = makeSlot(index: 3, startTicks: 150_000, endTicks: 200_000)

        let segment = contiguousReadySegment(slots: [slot3, slot1, empty0, slot2])

        XCTAssertEqual(segment.slots.map(\.index), [1, 2, 3])
        XCTAssertEqual(segment.slots.map(\.id), [slot1.id, slot2.id, slot3.id])
        XCTAssertEqual(segment.musicStart, MediaTime(ticks: 45_000))
        XCTAssertEqual(segment.musicEnd, MediaTime(ticks: 200_000))
    }

    // MARK: - Exemple CHIFFRÉ de l'utilisateur : cases 28 à 50

    /// Montage de 51 cases de 0,5 s (30 000 ticks) pavant la musique sans trou
    /// (§28.1). Seules les cases 28 à 50 sont prêtes — l'exemple donné par
    /// l'utilisateur : « cases 28 à 50 remplies → l'export contient ces
    /// 23 plans ».
    ///
    /// Valeurs calculées à la main (60 000 ticks/s, §9) :
    /// - case `i` : start = `i × 30 000`, end = `(i + 1) × 30 000` ;
    /// - case 28 : start = 840 000 ticks = 14 s ;
    /// - case 50 : end = 51 × 30 000 = 1 530 000 ticks = 25,5 s ;
    /// - durée du montage = 1 530 000 − 840 000 = 690 000 ticks = 11,5 s,
    ///   soit exactement 23 × 0,5 s.
    private var fiftyOneSlotsReadyFrom28To50: [ProjectSlot] {
        (0...50).map { index in
            makeSlot(
                index: index,
                startTicks: Int64(index) * 30_000,
                endTicks: Int64(index + 1) * 30_000,
                status: (28...50).contains(index) ? ClipAssignmentStatus.ready : nil
            )
        }
    }

    func testUserExampleSlots28To50IsTheExportedSegment() {
        let segment = contiguousReadySegment(slots: fiftyOneSlotsReadyFrom28To50)

        XCTAssertEqual(segment.slotCount, 23, "cases 28 à 50 incluses")
        XCTAssertEqual(segment.startIndex, 28)
        XCTAssertEqual(segment.endIndex, 50)
        XCTAssertEqual(segment.slots.map(\.index), Array(28...50))
    }

    func testUserExampleMusicBoundsAndDurationInTicks() {
        let segment = contiguousReadySegment(slots: fiftyOneSlotsReadyFrom28To50)

        // Bornes ABSOLUES dans le morceau, en ticks entiers (§9).
        XCTAssertEqual(segment.musicStart, MediaTime(ticks: 840_000))    // 14 s
        XCTAssertEqual(segment.musicEnd, MediaTime(ticks: 1_530_000))    // 25,5 s
        // Durée du montage = musicEnd − musicStart, JAMAIS musicEnd.
        XCTAssertEqual(segment.duration, MediaTime(ticks: 690_000))      // 11,5 s
        XCTAssertEqual(segment.duration.ticks, 23 * 30_000)
        XCTAssertNotEqual(
            segment.duration, segment.musicEnd,
            "le montage ne commence plus à l'instant 0 de la musique"
        )
    }

    // MARK: - DÉCALAGE : instant de composition = slot.start − musicStart

    /// La conséquence temporelle critique, testée sans AVFoundation : chaque
    /// case est posée à `slot.start - musicStart` dans la composition.
    func testCompositionStartIsSlotStartMinusMusicStart() {
        let segment = contiguousReadySegment(slots: fiftyOneSlotsReadyFrom28To50)
        let musicStart = segment.musicStart

        for slot in segment.slots {
            XCTAssertEqual(
                segment.compositionStart(of: slot),
                MediaTime(ticks: slot.start.ticks - musicStart.ticks)
            )
        }

        // Valeurs chiffrées à la main sur les bornes du segment.
        XCTAssertEqual(segment.compositionStart(of: segment.slots[0]), .zero)
        XCTAssertEqual(
            segment.compositionStart(of: segment.slots[1]),
            MediaTime(ticks: 30_000),
            "la deuxième case tombe à 0,5 s de composition"
        )
        XCTAssertEqual(
            segment.compositionStart(of: segment.slots[22]),
            MediaTime(ticks: 660_000),
            "case 50 : 1 500 000 − 840 000 ticks"
        )
    }

    /// L'ÉCART entre deux cases consécutives est rigoureusement celui de la
    /// musique : le décalage translate la timeline, il ne l'étire pas (§53).
    func testShiftPreservesTheMusicalSpacingExactly() throws {
        let segment = contiguousReadySegment(slots: fiftyOneSlotsReadyFrom28To50)

        for (previous, current) in zip(segment.slots, segment.slots.dropFirst()) {
            XCTAssertEqual(
                segment.compositionStart(of: current).ticks
                    - segment.compositionStart(of: previous).ticks,
                current.start.ticks - previous.start.ticks
            )
        }

        // Dernière image : fin du dernier plan == durée du montage. Aucune
        // dérive cumulative après 23 cases (§9).
        let lastSlot = try XCTUnwrap(segment.slots.last)
        XCTAssertEqual(
            segment.compositionStart(of: lastSlot) + lastSlot.duration,
            segment.duration
        )
    }

    /// Un segment commençant à la case 0 se comporte EXACTEMENT comme
    /// l'ancien préfixe §51 : décalage nul, durée = fin absolue. La
    /// non-régression du cas nominal est explicite.
    func testSegmentStartingAtZeroBehavesLikeTheFormerPrefix() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000)
        ]

        let segment = contiguousReadySegment(slots: slots)

        XCTAssertEqual(segment.musicStart, .zero)
        XCTAssertEqual(segment.duration, segment.musicEnd)
        XCTAssertEqual(segment.compositionStart(of: slots[0]), slots[0].start)
        XCTAssertEqual(segment.compositionStart(of: slots[1]), slots[1].start)
    }
}
