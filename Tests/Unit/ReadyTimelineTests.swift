//
//  ReadyTimelineTests.swift
//  MontageMusicalTests
//
//  Timeline exportable — CHANGEMENT PRODUIT qui remplace le « segment
//  exportable » (lui-même successeur du « préfixe exportable » §51). Contrat
//  complet en tête de `ExportModels.swift`.
//
//  Remplace `ReadySegmentTests.swift`. Le bloc §70 « Préfixe exportable » est
//  conservé cas par cas (toutes remplies ; première vide ; trou au milieu ;
//  asset downloading ; asset unavailable ; cases remplies après le trou non
//  déplacées), mais DEUX verdicts sont désormais inversés :
//
//      §51    : première case vide → aucun export possible.
//      Étape 1: première case vide → le PREMIER segment prêt EST le montage.
//      Étape 2: première case vide → toutes les zones remplies sont
//               exportées, CONCATÉNÉES ; les cases vides sont supprimées,
//               vidéo ET musique.
//
//  S'y ajoutent les cas propres à la concaténation : plusieurs runs (aucune
//  zone remplie n'est abandonnée), position de composition cumulée, durée =
//  SOMME des durées des cases prêtes, continuité à l'intérieur d'un run et
//  absence de trou aux jonctions — le tout en TICKS exacts, sans AVFoundation.
//

import XCTest
@testable import MontageMusical

final class ReadyTimelineTests: XCTestCase {

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

    /// Montage de `count` cases jointives de 30 000 ticks (0,5 s), pavant la
    /// musique sans trou (§28.1). `readyIndexes` dit lesquelles sont prêtes ;
    /// les autres sont VIDES.
    private func makeMontage(count: Int, ready readyIndexes: Set<Int>) -> [ProjectSlot] {
        (0..<count).map { index in
            makeSlot(
                index: index,
                startTicks: Int64(index) * 30_000,
                endTicks: Int64(index + 1) * 30_000,
                status: readyIndexes.contains(index) ? ClipAssignmentStatus.ready : nil
            )
        }
    }

    // MARK: - Aucune case prête → timeline vide (export désactivé)

    func testNoReadySlotReturnsAnEmptyTimeline() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .downloading),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000, status: .unavailable)
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertTrue(timeline.isEmpty)
        XCTAssertTrue(timeline.runs.isEmpty)
        XCTAssertEqual(timeline.slotCount, 0)
        XCTAssertEqual(timeline.duration, .zero)
        XCTAssertTrue(timeline.allSlots.isEmpty)
        XCTAssertEqual(timeline, ReadyTimeline.empty)
    }

    func testProjectWithoutSlotsReturnsAnEmptyTimeline() {
        XCTAssertEqual(readyTimeline(slots: []), ReadyTimeline.empty)
        XCTAssertTrue(ReadyTimeline.empty.isEmpty)
        XCTAssertEqual(ReadyTimeline.empty.duration, .zero)
    }

    /// Un run VIDE est impossible par construction : c'est ce qui rend
    /// `musicStart` / `startIndex` non optionnels.
    func testAnEmptyRunCannotBeBuilt() {
        XCTAssertNil(ReadyRun(slots: []))
    }

    // MARK: - §70 : toutes remplies → UN SEUL run

    func testAllSlotsReadyProduceASingleRun() throws {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertEqual(timeline.runs.count, 1, "aucun trou → une seule zone remplie")
        let run = try XCTUnwrap(timeline.runs.first)
        // Égalité complète des structs : les cases retournées conservent
        // leurs temps absolus (aucun recompactage possible).
        XCTAssertEqual(run.slots, slots)
        XCTAssertEqual(run.startIndex, 0)
        XCTAssertEqual(run.endIndex, 2)
        XCTAssertEqual(run.musicStart, MediaTime(ticks: 0))
        XCTAssertEqual(run.musicEnd, MediaTime(ticks: 150_000))
        // Montage sans trou : la durée vaut la fin absolue — c'est l'ancien
        // comportement §51, conservé quand TOUTES les cases sont prêtes.
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 150_000))
        XCTAssertEqual(timeline.slotCount, 3)
        XCTAssertEqual(timeline.allSlots, slots)

        // La propriété du snapshot délègue au même algorithme.
        let snapshot = ProjectSnapshot(projectID: UUID(), slots: slots, geometry: nil)
        XCTAssertEqual(snapshot.readyTimeline.allSlots.map(\.id), slots.map(\.id))
    }

    // MARK: - §70 « première vide » — la timeline commence au PREMIER RUN

    /// LE comportement du premier écart produit, CONSERVÉ : la case 0 est
    /// vide, les cases 1 à 3 sont prêtes → le montage commence à la case 1 et
    /// tombe à l'instant `.zero` de la composition.
    func testFirstSlotEmptyMakesTheTimelineStartAtTheFirstRun() throws {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000),
            makeSlot(index: 3, startTicks: 150_000, endTicks: 200_000)
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertFalse(timeline.isEmpty, "une première case vide n'interdit plus l'export")
        XCTAssertEqual(timeline.runs.count, 1)
        let run = try XCTUnwrap(timeline.runs.first)
        XCTAssertEqual(run.slots, [slots[1], slots[2], slots[3]])
        XCTAssertEqual(run.startIndex, 1)
        XCTAssertEqual(run.musicStart, MediaTime(ticks: 45_000), "le montage ne commence plus à 0")
        // La case 0 n'est PAS exportée, et aucune case n'a été déplacée pour
        // combler son absence : temps ABSOLUS intacts.
        XCTAssertFalse(timeline.allSlots.contains { $0.id == slots[0].id })
        XCTAssertEqual(timeline.allSlots.map(\.start.ticks), [45_000, 90_000, 150_000])
        // Le premier plan ouvre le montage.
        XCTAssertEqual(timeline.compositionStart(of: slots[1]), MediaTime.zero)
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 155_000))
    }

    // MARK: - EXEMPLE CHIFFRÉ DE L'UTILISATEUR : cases 28…35 + 40…50

    /// 51 cases de 0,5 s (30 000 ticks), cases 28 à 35 et 40 à 50 prêtes,
    /// cases 36 à 39 VIDES. Valeurs calculées à la main (60 000 ticks/s, §9) :
    /// - run 1 : cases 28…35, soit 8 plans, `musicStart` = 840 000 ticks ;
    /// - run 2 : cases 40…50, soit 11 plans, `musicStart` = 1 200 000 ticks ;
    /// - montage = 8 + 11 = 19 plans, durée = 19 × 30 000 = 570 000 ticks ;
    /// - la portion de musique des cases 36…39 (120 000 ticks) N'EXISTE PAS
    ///   dans le fichier exporté.
    private var montageWithTwoRuns: [ProjectSlot] {
        makeMontage(count: 51, ready: Set(28...35).union(Set(40...50)))
    }

    func testTwoRunsAreBothExportedAndConcatenated() throws {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        XCTAssertEqual(timeline.runs.count, 2, "les DEUX zones remplies sont exportées")
        XCTAssertEqual(timeline.runs[0].slots.map(\.index), Array(28...35))
        XCTAssertEqual(timeline.runs[1].slots.map(\.index), Array(40...50))
        XCTAssertEqual(timeline.runs[0].slotCount, 8)
        XCTAssertEqual(timeline.runs[1].slotCount, 11)
        // Nombre TOTAL de plans exportés — l'exemple de l'utilisateur.
        XCTAssertEqual(timeline.slotCount, 19)
        XCTAssertEqual(timeline.allSlots.map(\.index), Array(28...35) + Array(40...50))
    }

    func testTwoRunsDurationIsTheSumOfTheReadySlotDurations() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        // Durée = SOMME des durées des cases prêtes, et NON
        // `dernière.end - première.start` (= 1 530 000 − 840 000 = 690 000).
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 570_000))
        XCTAssertEqual(timeline.duration.ticks, 19 * 30_000)
        XCTAssertNotEqual(
            timeline.duration,
            MediaTime(ticks: 1_530_000 - 840_000),
            "les 4 cases vides (120 000 ticks) sont SUPPRIMÉES, musique comprise"
        )
        // Contrôle direct : la somme des durées de chaque case exportée.
        let summedTicks = timeline.allSlots.reduce(Int64(0)) { $0 + $1.duration.ticks }
        XCTAssertEqual(timeline.duration.ticks, summedTicks)
    }

    func testSecondRunStartsRightAfterTheFirstOne() throws {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        // Position du run 2 = somme des durées des cases du run 1.
        XCTAssertEqual(timeline.compositionStart(ofRun: 0), .zero)
        XCTAssertEqual(timeline.compositionStart(ofRun: 1), MediaTime(ticks: 240_000))
        XCTAssertEqual(timeline.compositionStart(ofRun: 1).ticks, 8 * 30_000)
        // `runStarts` fait le même calcul en un parcours : c'est lui qu'utilise
        // l'assemblage, il ne doit jamais diverger.
        XCTAssertEqual(timeline.runStarts, [MediaTime(ticks: 0), MediaTime(ticks: 240_000)])

        // Bornes hors plage : jamais de valeur inventée.
        XCTAssertEqual(timeline.compositionStart(ofRun: -1), .zero)
        XCTAssertEqual(timeline.compositionStart(ofRun: 2), timeline.duration)
    }

    func testCompositionStartOfTheUserExampleSlots() throws {
        let slots = montageWithTwoRuns
        let timeline = readyTimeline(slots: slots)

        // Première case du montage : instant zéro.
        XCTAssertEqual(timeline.compositionStart(of: slots[28]), MediaTime.zero)
        // Dernière case du run 1 : 7 × 30 000.
        XCTAssertEqual(timeline.compositionStart(of: slots[35]), MediaTime(ticks: 210_000))
        // Première case du run 2 : elle suit IMMÉDIATEMENT la case 35.
        XCTAssertEqual(timeline.compositionStart(of: slots[40]), MediaTime(ticks: 240_000))
        // Dernière case : 240 000 + 10 × 30 000.
        XCTAssertEqual(timeline.compositionStart(of: slots[50]), MediaTime(ticks: 540_000))

        // Fin du dernier plan == durée du montage : aucune dérive cumulative
        // après 19 cases et une jonction (§9, ticks entiers).
        let lastStart = try XCTUnwrap(timeline.compositionStart(of: slots[50]))
        XCTAssertEqual(lastStart + slots[50].duration, timeline.duration)
    }

    /// Une case NON exportée n'a aucun instant de composition — l'appelant ne
    /// doit pas pouvoir en inventer un.
    func testCompositionStartOfANonExportedSlotIsNil() {
        let slots = montageWithTwoRuns
        let timeline = readyTimeline(slots: slots)

        XCTAssertNil(timeline.compositionStart(of: slots[0]), "case vide avant le montage")
        XCTAssertNil(timeline.compositionStart(of: slots[37]), "case vide entre deux runs")
        XCTAssertNil(
            timeline.compositionStart(
                of: makeSlot(index: 28, startTicks: 840_000, endTicks: 870_000)
            ),
            "case d'un autre montage : identité différente"
        )
    }

    // MARK: - Continuité : écarts d'origine DANS un run, aucun trou ENTRE runs

    /// À l'intérieur d'un run, l'écart entre deux cases consécutives est
    /// rigoureusement celui de la musique : la concaténation translate les
    /// runs, elle n'étire rien (§53).
    func testPositionsInsideARunKeepTheOriginalSpacing() throws {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        for (index, run) in timeline.runs.enumerated() {
            let base = timeline.compositionStart(ofRun: index)
            XCTAssertEqual(
                timeline.compositionStart(of: run.slots[0]), base,
                "chaque run ouvre à sa position de composition"
            )
            for (previous, current) in zip(run.slots, run.slots.dropFirst()) {
                let previousStart = try XCTUnwrap(timeline.compositionStart(of: previous))
                let currentStart = try XCTUnwrap(timeline.compositionStart(of: current))
                XCTAssertEqual(
                    currentStart.ticks - previousStart.ticks,
                    current.start.ticks - previous.start.ticks,
                    "écart musical d'origine conservé"
                )
            }
        }
    }

    /// Entre deux runs, AUCUN trou : le run suivant commence exactement là où
    /// le précédent finit — c'est ce qui garantit qu'aucun écran noir n'est
    /// ajouté et que les instructions de rendu couvrent `[0, durée]`.
    func testRunsAreJoinedWithoutAnyGap() throws {
        let timeline = readyTimeline(slots: makeMontage(
            count: 20,
            ready: Set([1, 2, 3]).union(Set([7, 8])).union(Set([15]))
        ))

        var expectedNextStart = MediaTime.zero
        for slot in timeline.allSlots {
            let start = try XCTUnwrap(timeline.compositionStart(of: slot))
            XCTAssertEqual(start, expectedNextStart, "plan \(slot.index) jointif au précédent")
            expectedNextStart = start + slot.duration
        }
        // Le dernier plan finit EXACTEMENT à la durée du montage.
        XCTAssertEqual(expectedNextStart, timeline.duration)
    }

    // MARK: - Trois runs, runs d'une seule case

    func testThreeRunsIncludingSingleSlotRuns() throws {
        // Cases prêtes : 1-2 / 5 / 9-10-11 → trois zones, dont une d'UNE case.
        let timeline = readyTimeline(slots: makeMontage(
            count: 13,
            ready: Set([1, 2]).union(Set([5])).union(Set([9, 10, 11]))
        ))

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[1, 2], [5], [9, 10, 11]])
        XCTAssertEqual(timeline.slotCount, 6)
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 6 * 30_000))
        XCTAssertEqual(timeline.runStarts.map(\.ticks), [0, 60_000, 90_000])

        // Un run d'UNE case a des bornes cohérentes.
        let single = timeline.runs[1]
        XCTAssertEqual(single.slotCount, 1)
        XCTAssertEqual(single.startIndex, 5)
        XCTAssertEqual(single.endIndex, 5)
        XCTAssertEqual(single.musicStart, MediaTime(ticks: 150_000))
        XCTAssertEqual(single.musicEnd, MediaTime(ticks: 180_000))
        XCTAssertEqual(single.duration, MediaTime(ticks: 30_000))
        XCTAssertEqual(single.offset(of: single.slots[0]), .zero)
    }

    /// DERNIÈRE case prête : le run est clos par la fin du montage, jamais
    /// perdu (c'est le cas que l'oubli d'un `flush` final ferait sauter).
    func testRunEndingOnTheLastSlotIsKept() {
        let timeline = readyTimeline(slots: makeMontage(count: 4, ready: [3]))

        XCTAssertEqual(timeline.runs.count, 1)
        XCTAssertEqual(timeline.allSlots.map(\.index), [3])
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 30_000))
    }

    // MARK: - §70 : trou au milieu / cases après le trou

    /// §66 « trou au milieu » : la zone suivante n'est plus ABANDONNÉE, elle
    /// est CONCATÉNÉE — et ses cases ne sont pas déplacées d'un tick dans le
    /// montage (leurs temps musicaux restent absolus).
    func testGapInMiddleKeepsBothSidesWithoutMovingAnySlot() throws {
        let afterGapA = makeSlot(index: 3, startTicks: 120_000, endTicks: 165_000)
        let afterGapB = makeSlot(index: 4, startTicks: 165_000, endTicks: 210_000)
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil),
            afterGapA,
            afterGapB
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[0, 1], [3, 4]])
        XCTAssertEqual(timeline.slotCount, 4)
        // Durée = 45 000 + 45 000 + 45 000 + 45 000 : la case 2 (30 000 ticks)
        // est supprimée du montage, musique comprise.
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 180_000))
        // Structs d'origine intacts (index et temps absolus préservés, §3.12).
        XCTAssertEqual(timeline.runs[1].slots, [afterGapA, afterGapB])
        XCTAssertEqual(afterGapA.start, MediaTime(ticks: 120_000))
        // …mais leur POSITION dans le montage suit immédiatement la case 1.
        XCTAssertEqual(timeline.compositionStart(of: afterGapA), MediaTime(ticks: 90_000))
        XCTAssertEqual(timeline.compositionStart(of: afterGapB), MediaTime(ticks: 135_000))
    }

    // MARK: - §70 : statuts non prêts — TOUS exclus, aucun n'ouvre un run

    /// `resolving`, `downloading`, `unavailable` et `tooShort` ne sont jamais
    /// exportés : chacun FERME le run en cours, exactement comme une case vide.
    func testEveryNonReadyStatusIsExcludedAndSplitsTheTimeline() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 10_000),
            makeSlot(index: 1, startTicks: 10_000, endTicks: 20_000, status: .resolving),
            makeSlot(index: 2, startTicks: 20_000, endTicks: 30_000),
            makeSlot(index: 3, startTicks: 30_000, endTicks: 40_000, status: .downloading),
            makeSlot(index: 4, startTicks: 40_000, endTicks: 50_000),
            makeSlot(index: 5, startTicks: 50_000, endTicks: 60_000, status: .unavailable),
            makeSlot(index: 6, startTicks: 60_000, endTicks: 70_000),
            makeSlot(index: 7, startTicks: 70_000, endTicks: 80_000, status: .tooShort),
            makeSlot(index: 8, startTicks: 80_000, endTicks: 90_000)
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[0], [2], [4], [6], [8]])
        XCTAssertEqual(timeline.slotCount, 5)
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 50_000))
        XCTAssertFalse(
            timeline.allSlots.contains { $0.assignment?.status != .ready },
            "aucune case non prête n'entre dans le montage"
        )
    }

    // MARK: - Cases dans le désordre → triées par index

    func testUnorderedSlotsAreSortedByIndexBeforeAnyDecision() {
        let slot1 = makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000)
        let empty2 = makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil)
        let slot3 = makeSlot(index: 3, startTicks: 120_000, endTicks: 150_000)
        let slot4 = makeSlot(index: 4, startTicks: 150_000, endTicks: 200_000)
        let empty0 = makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil)

        // Collection donnée dans un ordre arbitraire : le tri par index doit
        // précéder le découpage en runs, sinon les zones seraient fausses.
        let timeline = readyTimeline(slots: [slot4, empty2, slot1, slot3, empty0])

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[1], [3, 4]])
        XCTAssertEqual(timeline.allSlots.map(\.id), [slot1.id, slot3.id, slot4.id])
        XCTAssertEqual(timeline.compositionStart(of: slot1), MediaTime.zero)
        XCTAssertEqual(timeline.compositionStart(of: slot3), MediaTime(ticks: 45_000))
        XCTAssertEqual(timeline.compositionStart(of: slot4), MediaTime(ticks: 75_000))
    }

    // MARK: - Troncature §66 (utilisée par l'export)

    /// La troncature garde les `n` premières cases DU MONTAGE : le run coupé
    /// est raccourci et les runs suivants sont ABANDONNÉS (décision
    /// documentée — le montage livré doit rester celui qui a été annoncé).
    func testTruncationCutsInsideARunAndDropsTheFollowingRuns() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        // 10 cases conservées : les 8 du run 1, puis 2 du run 2.
        let truncated = timeline.truncated(toFirst: 10)

        XCTAssertEqual(truncated.runs.count, 2)
        XCTAssertEqual(truncated.runs[0].slots.map(\.index), Array(28...35))
        XCTAssertEqual(truncated.runs[1].slots.map(\.index), [40, 41])
        XCTAssertEqual(truncated.slotCount, 10)
        XCTAssertEqual(truncated.duration, MediaTime(ticks: 300_000))
        // Les cases conservées n'ont pas bougé : même position qu'avant.
        XCTAssertEqual(
            truncated.compositionStart(of: truncated.allSlots[9]),
            timeline.compositionStart(of: timeline.allSlots[9])
        )
    }

    func testTruncationOnARunBoundaryDropsTheFollowingRunsEntirely() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        let truncated = timeline.truncated(toFirst: 8)

        XCTAssertEqual(truncated.runs.count, 1, "le second run est abandonné")
        XCTAssertEqual(truncated.slotCount, 8)
        XCTAssertEqual(truncated.duration, MediaTime(ticks: 240_000))
    }

    func testTruncationBoundsAreSafe() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        XCTAssertEqual(timeline.truncated(toFirst: 0), .empty)
        XCTAssertEqual(timeline.truncated(toFirst: -3), .empty)
        XCTAssertEqual(timeline.truncated(toFirst: 19), timeline)
        XCTAssertEqual(timeline.truncated(toFirst: 999), timeline)
    }
}
