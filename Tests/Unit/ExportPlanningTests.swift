//
//  ExportPlanningTests.swift
//  MontageMusicalTests
//
//  Logique d'export testable SANS encodage (Jalon 10) :
//  - plan d'export = TIMELINE CONCATÉNÉE de toutes les zones remplies
//    (changement produit qui remplace le préfixe §51 puis le segment unique —
//    contrat en tête de `ExportModels.swift`) : durée = SOMME des durées des
//    cases prêtes, position = `run + (slot.start - run.musicStart)`, nombre
//    TOTAL de plans, aucune case prête → `emptyPrefix` ;
//  - TRONCATURE §66 quand un rush devient indisponible pendant l'export (la
//    case en cause, la fin de son run et les runs suivants sont abandonnés ;
//    les cases conservées ne bougent pas ; tout premier rush indisponible →
//    `emptyPrefix`) ;
//  - estimation de taille §57 (croissance avec pixels/cadence/durée) et
//    place exigée pour la COPIE Photos ;
//  - refus pour espace insuffisant §57/§66 AVANT tout encodage, avec une
//    capacité INJECTÉE — aucun test ne dépend du disque réel ;
//  - fichiers d'export §11 : « dernier export réussi » restauré (§60) et
//    purge des exports précédents (§11/§57) ;
//  - reprise après kill pendant un export (§8.1/§66).
//
//  Aucun média, aucune session d'encodage, aucune photothèque.
//

import XCTest
import SwiftData
@testable import MontageMusical

final class ExportPlanningTests: XCTestCase {

    // MARK: - Helpers

    /// Case snapshot. `status == nil` produit une case VIDE.
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

    private func makeSnapshot(slots: [ProjectSlot]) -> ProjectSnapshot {
        ProjectSnapshot(
            projectID: UUID(),
            slots: slots,
            geometry: ProjectGeometry(
                aspectWidth: 9,
                aspectHeight: 16,
                orientation: .portrait,
                lockedByAssetIdentifier: "asset-0"
            )
        )
    }

    private func makeProfile(
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Double = 30,
        isHDR: Bool = false
    ) -> MasterProfile {
        MasterProfile(
            renderWidth: width,
            renderHeight: height,
            frameRate: frameRate,
            isHDR: isHDR
        )
    }

    // MARK: - Durée exportée et nombre de plans (timeline concaténée)

    func testPlanDurationIsTheAbsoluteEndWhenNothingIsMissing() {
        // 3 cases prêtes, jointives, à partir de la case 0 : un seul run, le
        // montage commence à l'instant 0 et la durée exportée vaut la fin
        // ABSOLUE de la dernière — comportement identique à l'ancien préfixe
        // §51 quand rien ne manque.
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let plan = try? ExportPlan.make(project: makeSnapshot(slots: slots), scope: .complete)

        XCTAssertEqual(plan?.runs.count, 1)
        XCTAssertEqual(plan?.duration, MediaTime(ticks: 150_000))
        XCTAssertEqual(plan?.slotCount, 3)
        XCTAssertEqual(plan?.slots.map(\.index), [0, 1, 2])
        XCTAssertEqual(plan?.compositionStart(of: slots[2]), MediaTime(ticks: 90_000))
    }

    /// CHANGEMENT PRODUIT : « trou au milieu » ne limite plus l'export — les
    /// cases 3 et 4, situées APRÈS le trou, sont EXPORTÉES et concaténées à la
    /// suite de la case 1. Elles ne sont pas déplacées pour autant : leurs
    /// temps musicaux restent absolus, seule leur POSITION dans le fichier
    /// change.
    func testHoleInTheMiddleIsRemovedAndBothZonesAreExported() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil),
            makeSlot(index: 3, startTicks: 120_000, endTicks: 150_000),
            makeSlot(index: 4, startTicks: 150_000, endTicks: 180_000)
        ]
        let snapshot = makeSnapshot(slots: slots)

        let plan = try? ExportPlan.make(project: snapshot, scope: .contiguousPrefix)

        XCTAssertEqual(plan?.slotCount, 4, "les 4 cases prêtes, pas seulement les 2 premières")
        XCTAssertEqual(plan?.runs.count, 2)
        // Durée = 45 000 + 45 000 + 30 000 + 30 000 : la case 2 (30 000 ticks)
        // est SUPPRIMÉE du fichier, musique comprise.
        XCTAssertEqual(plan?.duration, MediaTime(ticks: 150_000))
        XCTAssertEqual(
            plan?.slots.map(\.start.ticks), [0, 45_000, 120_000, 150_000],
            "temps ABSOLUS conservés"
        )
        // La case 3 suit IMMÉDIATEMENT la case 1 dans le fichier.
        XCTAssertEqual(plan?.compositionStart(of: slots[3]), MediaTime(ticks: 90_000))
    }

    func testDownloadingSlotIsExcludedButTheRestIsExported() {
        // §66 : « asset en téléchargement : export limité avant lui » — lu
        // désormais comme « la case en téléchargement est retirée du
        // montage », le reste étant concaténé.
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .downloading),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let plan = try? ExportPlan.make(project: makeSnapshot(slots: slots), scope: .contiguousPrefix)

        XCTAssertEqual(plan?.slotCount, 2)
        XCTAssertEqual(plan?.slots.map(\.index), [0, 2])
        XCTAssertEqual(plan?.duration, MediaTime(ticks: 105_000), "45 000 + 60 000")
        XCTAssertNil(plan?.compositionStart(of: slots[1]), "la case exclue n'a aucune position")
    }

    func testBothScopesExportTheSameTimeline() {
        // §66 : `.complete` ne peut jamais exporter autre chose que la
        // timeline — les deux portées produisent le même plan (contrairement à
        // la prévisualisation §47.2, qui refuse un montage incomplet).
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: nil)
        ]
        let snapshot = makeSnapshot(slots: slots)

        let prefixPlan = try? ExportPlan.make(project: snapshot, scope: .contiguousPrefix)
        let completePlan = try? ExportPlan.make(project: snapshot, scope: .complete)

        XCTAssertEqual(prefixPlan, completePlan)
        XCTAssertEqual(prefixPlan?.slotCount, 1)
    }

    // MARK: - CHANGEMENT PRODUIT : première case vide → export POSSIBLE

    /// L'attendu de l'ancien test §66 est INVERSÉ : une première case vide ne
    /// désactive plus l'export, elle est simplement supprimée du montage.
    func testEmptyFirstSlotNowExportsTheZonesThatFollow() throws {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000)
        ]

        let plan = try ExportPlan.make(project: makeSnapshot(slots: slots), scope: .contiguousPrefix)

        XCTAssertEqual(plan.slotCount, 1)
        XCTAssertEqual(plan.slots.map(\.index), [1])
        // Durée du fichier = durée de la case exportée ; la case 0 n'y est pas.
        XCTAssertEqual(plan.duration, MediaTime(ticks: 45_000))
        XCTAssertEqual(plan.compositionStart(of: slots[1]), MediaTime.zero)
    }

    // MARK: - Aucune case prête → export désactivé

    func testProjectWithoutSlotsThrowsEmptyPrefix() {
        XCTAssertThrowsError(
            try ExportPlan.make(project: makeSnapshot(slots: []), scope: .complete)
        ) { error in
            XCTAssertEqual(error as? ExportError, .emptyPrefix)
        }
    }

    func testOnlySlotUnavailableThrowsEmptyPrefix() {
        let slots = [makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: .unavailable)]

        XCTAssertThrowsError(
            try ExportPlan.make(project: makeSnapshot(slots: slots), scope: .contiguousPrefix)
        ) { error in
            XCTAssertEqual(error as? ExportError, .emptyPrefix)
        }
    }

    func testNoReadySlotAtAllThrowsEmptyPrefix() {
        // Aucune case prête, où que ce soit dans le morceau → rien à exporter
        // (bouton désactivé).
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .downloading),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000, status: .unavailable)
        ]

        XCTAssertThrowsError(
            try ExportPlan.make(project: makeSnapshot(slots: slots), scope: .complete)
        ) { error in
            XCTAssertEqual(error as? ExportError, .emptyPrefix)
        }
    }

    // MARK: - Exemple CHIFFRÉ de l'utilisateur : cases 28…35 + 40…50

    /// 51 cases de 0,5 s (30 000 ticks) pavant la musique sans trou (§28.1) :
    /// cases 28 à 35 et 40 à 50 prêtes, cases 36 à 39 VIDES. Valeurs calculées
    /// à la main (60 000 ticks/s, §9) :
    /// - run 1 : 8 plans (cases 28…35), `musicStart` = 840 000 ticks (14 s) ;
    /// - run 2 : 11 plans (cases 40…50), `musicStart` = 1 200 000 ticks ;
    /// - montage = 19 plans, durée = 19 × 30 000 = 570 000 ticks (9,5 s) ;
    /// - la portion de musique des cases 36…39 n'existe PAS dans le fichier.
    private var snapshotWithTwoZones: ProjectSnapshot {
        makeSnapshot(slots: (0...50).map { index in
            makeSlot(
                index: index,
                startTicks: Int64(index) * 30_000,
                endTicks: Int64(index + 1) * 30_000,
                status: (28...35).contains(index) || (40...50).contains(index)
                    ? ClipAssignmentStatus.ready
                    : nil
            )
        })
    }

    func testExportedDurationIsTheSumOfTheExportedSlotDurations() throws {
        let plan = try ExportPlan.make(project: snapshotWithTwoZones, scope: .contiguousPrefix)

        XCTAssertEqual(plan.duration, MediaTime(ticks: 570_000))
        XCTAssertEqual(plan.duration.ticks, 19 * 30_000)
        XCTAssertEqual(
            plan.duration.ticks,
            plan.slots.reduce(Int64(0)) { $0 + $1.duration.ticks }
        )
        // Et NON `dernière.end - première.start` (1 530 000 − 840 000) : les
        // 4 cases vides du milieu sont supprimées du fichier, musique comprise.
        XCTAssertNotEqual(plan.duration, MediaTime(ticks: 690_000))
    }

    func testExportedShotCountCoversEveryFilledZone() throws {
        let plan = try ExportPlan.make(project: snapshotWithTwoZones, scope: .contiguousPrefix)

        XCTAssertEqual(plan.slotCount, 19, "8 plans + 11 plans")
        XCTAssertEqual(plan.slots.map(\.index), Array(28...35) + Array(40...50))
        XCTAssertEqual(plan.runs.count, 2)
        XCTAssertEqual(plan.runs[0].startIndex, 28)
        XCTAssertEqual(plan.runs[0].endIndex, 35)
        XCTAssertEqual(plan.runs[1].startIndex, 40)
        XCTAssertEqual(plan.runs[1].endIndex, 50)
    }

    /// Concaténation §53 : chaque case est posée à
    /// `(position de son run) + (slot.start - run.musicStart)`. Fonction PURE
    /// — testée sans AVFoundation, exactement comme `ProjectExporter.assemble`
    /// l'appelle.
    func testCompositionStartFollowsTheConcatenation() throws {
        let plan = try ExportPlan.make(project: snapshotWithTwoZones, scope: .contiguousPrefix)

        // Aucun trou : chaque plan commence là où le précédent finit.
        var expectedNextStart = MediaTime.zero
        for slot in plan.slots {
            let start = try XCTUnwrap(plan.compositionStart(of: slot))
            XCTAssertEqual(start, expectedNextStart)
            expectedNextStart = start + slot.duration
        }

        // Bornes chiffrées à la main.
        let first = try XCTUnwrap(plan.slots.first)
        let last = try XCTUnwrap(plan.slots.last)
        XCTAssertEqual(
            plan.compositionStart(of: first), MediaTime.zero, "la case 28 ouvre le montage"
        )
        XCTAssertEqual(
            plan.timeline.compositionStart(ofRun: 1),
            MediaTime(ticks: 240_000),
            "le run 2 démarre après les 8 plans du run 1"
        )
        XCTAssertEqual(
            plan.compositionStart(of: plan.slots[8]),
            MediaTime(ticks: 240_000),
            "case 40 : première du second run"
        )
        XCTAssertEqual(
            plan.compositionStart(of: last),
            MediaTime(ticks: 540_000),
            "case 50 : 240 000 + 10 × 30 000"
        )
        // Fin du dernier plan == durée du fichier : aucune dérive cumulative.
        XCTAssertEqual(expectedNextStart, plan.duration)
    }

    /// §57 : l'estimation porte sur la durée RÉELLE du fichier (9,5 s), ni sur
    /// la fin absolue du morceau (25,5 s), ni sur l'écart entre la première et
    /// la dernière case (11,5 s) — sinon l'export serait refusé pour un manque
    /// de place inventé.
    func testStorageEstimateUsesTheConcatenatedDuration() {
        let profile = makeProfile()

        let exportedBytes = ExportPlan.estimatedBytes(
            project: snapshotWithTwoZones, profile: profile
        )

        XCTAssertEqual(exportedBytes, makePlan(seconds: 9.5).estimatedBytes(profile: profile))
        XCTAssertLessThan(exportedBytes, makePlan(seconds: 11.5).estimatedBytes(profile: profile))
        XCTAssertLessThan(exportedBytes, makePlan(seconds: 25.5).estimatedBytes(profile: profile))
    }

    /// La troncature §66 coupe DANS le run atteint et ABANDONNE les runs
    /// suivants : le montage livré reste un préfixe de celui qui a été annoncé
    /// (§56), jamais un montage différent.
    func testTruncationCutsInsideTheReachedRunAndDropsTheFollowingOnes() throws {
        let plan = try ExportPlan.make(project: snapshotWithTwoZones, scope: .contiguousPrefix)

        // Le rush du 11e plan du montage (case 42) est reparti dans iCloud.
        let truncated = try plan.truncated(before: 10)

        XCTAssertEqual(truncated.slots.map(\.index), Array(28...35) + [40, 41])
        XCTAssertEqual(truncated.slotCount, 10)
        XCTAssertEqual(truncated.duration, MediaTime(ticks: 300_000), "10 × 30 000 ticks")
        // Les cases conservées ne bougent pas d'un tick.
        XCTAssertEqual(truncated.compositionStart(of: truncated.slots[0]), MediaTime.zero)
        XCTAssertEqual(
            truncated.compositionStart(of: truncated.slots[9]),
            plan.compositionStart(of: plan.slots[9])
        )
    }

    /// Troncature sur la frontière d'un run : le run suivant disparaît
    /// ENTIÈREMENT.
    func testTruncationOnARunBoundaryDropsTheFollowingRun() throws {
        let plan = try ExportPlan.make(project: snapshotWithTwoZones, scope: .contiguousPrefix)

        let truncated = try plan.truncated(before: 8)

        XCTAssertEqual(truncated.runs.count, 1)
        XCTAssertEqual(truncated.slots.map(\.index), Array(28...35))
        XCTAssertEqual(truncated.duration, MediaTime(ticks: 240_000))
    }

    // MARK: - §66 : rush devenu indisponible PENDANT l'export → troncature

    private var threeReadySlots: [ProjectSlot] {
        [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]
    }

    func testTruncationKeepsTheSlotsBeforeTheUnavailableOne() throws {
        // §66 : « asset en téléchargement : export limité avant lui ». Le rush
        // de la case 2 est reparti dans iCloud pendant l'assemblage : l'export
        // livre les cases 0 et 1, il n'échoue PAS.
        let plan = try ExportPlan.make(project: makeSnapshot(slots: threeReadySlots), scope: .complete)

        let truncated = try plan.truncated(before: 2)

        XCTAssertEqual(truncated.slotCount, 2)
        XCTAssertEqual(truncated.slots.map(\.index), [0, 1])
    }

    func testTruncationCutsTheMusicAtTheLastKeptSlotEnd() throws {
        // §51 : « la musique est coupée à la fin absolue de la dernière case
        // exportée » — la fin absolue de la case 1, pas celle du plan initial.
        // La durée du fichier suit : elle vaut la somme des cases conservées.
        let plan = try ExportPlan.make(project: makeSnapshot(slots: threeReadySlots), scope: .complete)

        let truncated = try plan.truncated(before: 2)

        XCTAssertEqual(plan.duration, MediaTime(ticks: 150_000))
        XCTAssertEqual(truncated.duration, MediaTime(ticks: 90_000))
    }

    func testTruncationNeverShiftsTheKeptSlots() throws {
        // §51 : « les clips ultérieurs ne sont jamais déplacés » — et les
        // clips conservés gardent leurs temps ABSOLUS.
        let plan = try ExportPlan.make(project: makeSnapshot(slots: threeReadySlots), scope: .complete)

        let truncated = try plan.truncated(before: 1)

        XCTAssertEqual(truncated.slots.map(\.start.ticks), [0])
        XCTAssertEqual(truncated.slots.map(\.end.ticks), [45_000])
        XCTAssertEqual(truncated.duration, MediaTime(ticks: 45_000))
    }

    func testTruncationOnTheFirstSlotThrowsEmptyPrefix() throws {
        // §66 : le tout premier rush du montage est indisponible — il ne reste
        // rien à exporter, exactement comme un montage sans aucune case prête.
        let plan = try ExportPlan.make(project: makeSnapshot(slots: threeReadySlots), scope: .complete)

        XCTAssertThrowsError(try plan.truncated(before: 0)) { error in
            XCTAssertEqual(error as? ExportError, .emptyPrefix)
        }
    }

    func testTruncationBeyondThePlanKeepsItUnchanged() throws {
        // Garde-fou : un index au-delà du dernier plan ne peut rien retirer.
        let plan = try ExportPlan.make(project: makeSnapshot(slots: threeReadySlots), scope: .complete)

        XCTAssertEqual(try plan.truncated(before: 3), plan)
        XCTAssertEqual(try plan.truncated(before: 99), plan)
    }

    // MARK: - §57 : estimation de taille

    /// Plan d'UNE case couvrant `seconds`, à partir de l'instant 0 : la durée
    /// du montage vaut alors exactement `seconds`.
    private func makePlan(seconds: Double) -> ExportPlan {
        let end = MediaTime(seconds: seconds)
        let slot = makeSlot(index: 0, startTicks: 0, endTicks: end.ticks)
        guard let run = ReadyRun(slots: [slot]) else {
            XCTFail("Un run d'une case ne peut pas être vide")
            return .empty
        }
        return ExportPlan(timeline: ReadyTimeline(runs: [run]))
    }

    func testEstimatedBytesIsStrictlyPositive() {
        let bytes = makePlan(seconds: 18.43).estimatedBytes(profile: makeProfile())

        XCTAssertGreaterThan(bytes, 0)
    }

    func testEstimatedBytesGrowsWithPixelCount() {
        let plan = makePlan(seconds: 20)

        let fullHD = plan.estimatedBytes(profile: makeProfile(width: 1920, height: 1080))
        let ultraHD = plan.estimatedBytes(profile: makeProfile(width: 3840, height: 2160))

        XCTAssertGreaterThan(ultraHD, fullHD)
    }

    func testEstimatedBytesGrowsWithFrameRate() {
        let plan = makePlan(seconds: 20)

        let thirty = plan.estimatedBytes(profile: makeProfile(frameRate: 30))
        let sixty = plan.estimatedBytes(profile: makeProfile(frameRate: 60))

        XCTAssertGreaterThan(sixty, thirty)
    }

    func testEstimatedBytesGrowsWithDuration() {
        let profile = makeProfile()

        let short = makePlan(seconds: 10).estimatedBytes(profile: profile)
        let long = makePlan(seconds: 60).estimatedBytes(profile: profile)

        XCTAssertGreaterThan(long, short)
    }

    func testEmptyPlanEstimatesNothing() {
        XCTAssertEqual(ExportPlan.empty.estimatedBytes(profile: makeProfile()), 0)
    }

    func testEstimateForProjectUsesTheExportedTimeline() {
        // L'estimation d'un PROJET (§57) porte sur la TIMELINE exportée, pas
        // sur le montage entier : la case vide du milieu ne compte pas, mais
        // celle qui la suit, si — elle est concaténée.
        // Logique PURE : aucun exporteur, aucun acteur photothèque, aucun
        // disque — `ExportPlan.estimatedBytes(project:profile:)` est la source
        // unique dont `ProjectExporter.estimatedBytes` n'est qu'une façade.
        let profile = makeProfile()
        let withHole = makeSnapshot(slots: [
            makeSlot(index: 0, startTicks: 0, endTicks: 600_000),
            makeSlot(index: 1, startTicks: 600_000, endTicks: 1_200_000, status: nil),
            makeSlot(index: 2, startTicks: 1_200_000, endTicks: 1_800_000)
        ])
        let complete = makeSnapshot(slots: [
            makeSlot(index: 0, startTicks: 0, endTicks: 600_000),
            makeSlot(index: 1, startTicks: 600_000, endTicks: 1_200_000),
            makeSlot(index: 2, startTicks: 1_200_000, endTicks: 1_800_000)
        ])

        let withHoleBytes = ExportPlan.estimatedBytes(project: withHole, profile: profile)
        let completeBytes = ExportPlan.estimatedBytes(project: complete, profile: profile)

        XCTAssertGreaterThan(withHoleBytes, 0)
        // 2 cases sur 3 : l'estimation vaut celle de 20 s, pas de 30 s.
        XCTAssertEqual(withHoleBytes, makePlan(seconds: 20).estimatedBytes(profile: profile))
        XCTAssertEqual(completeBytes, makePlan(seconds: 30).estimatedBytes(profile: profile))
        XCTAssertLessThan(withHoleBytes, completeBytes)
    }

    func testEstimateForProjectWithoutAnyReadySlotIsZero() {
        let profile = makeProfile()
        let snapshot = makeSnapshot(slots: [
            makeSlot(index: 0, startTicks: 0, endTicks: 600_000, status: nil)
        ])

        XCTAssertEqual(ExportPlan.estimatedBytes(project: snapshot, profile: profile), 0)
    }

    // MARK: - §57/§66 : espace insuffisant → refus AVANT encodage

    func testInsufficientStorageIsRefusedBeforeEncoding() {
        // Capacité INJECTÉE : aucun encodage n'est possible dans ce test —
        // la vérification §57 précède, par construction, toute session.
        XCTAssertThrowsError(
            try ProjectExporter.requireSufficientStorage(
                requiredBytes: 900_000_000,
                availableBytes: 120_000_000
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportError,
                .insufficientStorage(requiredBytes: 900_000_000, availableBytes: 120_000_000)
            )
        }
    }

    func testSufficientStorageIsAccepted() {
        XCTAssertNoThrow(
            try ProjectExporter.requireSufficientStorage(
                requiredBytes: 120_000_000,
                availableBytes: 900_000_000
            )
        )
    }

    func testExactlyEnoughStorageIsAccepted() {
        XCTAssertNoThrow(
            try ProjectExporter.requireSufficientStorage(
                requiredBytes: 500_000_000,
                availableBytes: 500_000_000
            )
        )
    }

    func testUnknownCapacityNeverBlocksTheExport() {
        // Le volume ne rapporte pas sa capacité : refuser serait inventer une
        // panne. L'export est tenté ; un vrai manque de place sera signalé
        // par l'encodeur.
        XCTAssertNoThrow(
            try ProjectExporter.requireSufficientStorage(
                requiredBytes: 900_000_000,
                availableBytes: nil
            )
        )
    }

    // MARK: - §57 : place exigée pour la COPIE Photos

    func testRequiredBytesCoversThePhotosCopy() {
        // `PHAssetCreationRequest` COPIE le fichier (l'export reste dans
        // `exports/`, §60) : au moment de l'ajout, le montage occupe deux fois
        // sa taille. §57 exige cette place AVANT d'encoder.
        let estimated: Int64 = 500_000_000

        XCTAssertEqual(
            ProjectExporter.requiredBytesIncludingPhotosCopy(estimated),
            estimated * ProjectExporter.photosCopyFactor
        )
    }

    func testRequiredBytesOfAnEmptyExportIsZero() {
        XCTAssertEqual(ProjectExporter.requiredBytesIncludingPhotosCopy(0), 0)
    }

    func testRequiredBytesSaturatesInsteadOfOverflowing() {
        // Estimation dégénérée déjà à la borne : la multiplication sature au
        // lieu de déborder (aucun piège arithmétique en production).
        XCTAssertEqual(
            ProjectExporter.requiredBytesIncludingPhotosCopy(Int64.max),
            Int64.max
        )
    }

    func testStorageIsRefusedWhenOnlyTheEncodingWouldFit() {
        // Assez de place pour le fichier encodé, PAS pour sa copie dans
        // Photos : §57 refuse AVANT l'encodage plutôt que d'échouer après.
        let estimated: Int64 = 400_000_000
        let required = ProjectExporter.requiredBytesIncludingPhotosCopy(estimated)

        XCTAssertThrowsError(
            try ProjectExporter.requireSufficientStorage(
                requiredBytes: required,
                availableBytes: estimated + 1_000_000
            )
        ) { error in
            guard let exportError = error as? ExportError else {
                return XCTFail("Erreur inattendue : \(error)")
            }
            guard case .insufficientStorage(let requiredBytes, _) = exportError else {
                return XCTFail("Erreur inattendue : \(exportError)")
            }
            XCTAssertEqual(requiredBytes, required)
        }
    }

    // MARK: - §11/§57/§60 : fichiers d'`exports/`

    /// Magasin de fichiers §11 dans un dossier temporaire unique, nettoyé en
    /// fin de test.
    private func makeTemporaryFileStore() throws -> (ProjectFileStore, UUID) {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ExportPlanningTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileStore = ProjectFileStore(rootURL: rootURL)
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return (fileStore, projectID)
    }

    @discardableResult
    private func writeExportFile(
        named name: String,
        in fileStore: ProjectFileStore,
        projectID: UUID
    ) throws -> URL {
        let url = fileStore.subdirectoryURL(.exports, for: projectID).appending(path: name)
        try Data("montage".utf8).write(to: url)
        return url
    }

    func testLastExportURLIsTheMostRecentTimestampedFile() throws {
        // §60 : « dernier export réussi » restauré. Le nommage horodaté est
        // TRIABLE (`ProjectExporter.uniqueOutputURL`) : le maximum
        // lexicographique est le plus récent, sans lire aucune date système.
        let (fileStore, projectID) = try makeTemporaryFileStore()
        try writeExportFile(named: "Montage-20260810-090000.mov", in: fileStore, projectID: projectID)
        let latest = try writeExportFile(
            named: "Montage-20260810-231500.mov", in: fileStore, projectID: projectID
        )
        try writeExportFile(named: "Montage-20260809-235959.mov", in: fileStore, projectID: projectID)

        XCTAssertEqual(
            fileStore.lastExportURL(projectID: projectID)?.lastPathComponent,
            latest.lastPathComponent
        )
    }

    func testLastExportURLIsNilWithoutAnyExport() throws {
        let (fileStore, projectID) = try makeTemporaryFileStore()

        XCTAssertNil(fileStore.lastExportURL(projectID: projectID))
        // Projet sans arbre §11 : aucune erreur, aucun export.
        XCTAssertNil(fileStore.lastExportURL(projectID: UUID()))
    }

    func testPruneExportsKeepsOnlyTheLastExport() throws {
        // §11/§57 : un fichier complet par relance saturerait le stockage —
        // seul le dernier export réussi est conservé (et c'est lui que §60
        // restaure).
        let (fileStore, projectID) = try makeTemporaryFileStore()
        try writeExportFile(named: "Montage-20260810-090000.mov", in: fileStore, projectID: projectID)
        try writeExportFile(named: "Montage-20260810-120000.mov", in: fileStore, projectID: projectID)
        let kept = try writeExportFile(
            named: "Montage-20260810-231500.mov", in: fileStore, projectID: projectID
        )

        let removed = fileStore.pruneExports(projectID: projectID, keeping: kept)

        XCTAssertEqual(removed, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path(percentEncoded: false)))
        // Comparaison par NOM : `contentsOfDirectory` peut normaliser le
        // chemin (`/private/var` ↔ `/var`), jamais le nom du fichier.
        XCTAssertEqual(
            fileStore.lastExportURL(projectID: projectID)?.lastPathComponent,
            kept.lastPathComponent
        )
        XCTAssertTrue(fileStore.hasExportFiles(projectID: projectID), "§31 : l'export reste un contenu")
    }

    // MARK: - §8.1/§66 : reprise après kill pendant un export

    func testStartupMaintenanceRestoresProjectStuckInExporting() async throws {
        // App tuée en plein encodage : le projet reste figé en `exporting` et
        // le dock annoncerait indéfiniment un export qu'aucune tâche ne
        // poursuit (§8.1). La maintenance le ramène au statut restauré —
        // `assembling` ici (aucune case prête) — et vide `temp/` (§69A).
        let (fileStore, _) = try makeTemporaryFileStore()
        let store = ProjectStore(
            modelContainer: try ModelContainerFactory.makeInMemory(),
            fileStore: fileStore
        )
        let projectID = try await store.createDraft()
        try await store.setStatus(.exporting, projectID: projectID)
        let partialFile = fileStore.subdirectoryURL(.temp, for: projectID)
            .appending(path: "export-interrompu.mov")
        try Data("partiel".utf8).write(to: partialFile)

        try await store.performStartupMaintenance()

        let summary = try await store.summary(id: projectID)
        XCTAssertEqual(summary?.status, .assembling, "§10 : statut restauré après un export mort")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: partialFile.path(percentEncoded: false)),
            "§57/§69A : temporaire d'encodage supprimé au lancement"
        )
    }

    // MARK: - Estimation cohérente avec la vérification d'espace

    func testEstimateFeedsTheStorageCheck() {
        // Chaînage réel : le plan estime, la vérification refuse — c'est
        // exactement l'ordre suivi par `export(project:scope:progress:)`
        // avant toute création de session.
        let plan = makePlan(seconds: 120)
        let profile = makeProfile(width: 3840, height: 2160, frameRate: 60)
        let required = plan.estimatedBytes(profile: profile)

        XCTAssertThrowsError(
            try ProjectExporter.requireSufficientStorage(
                requiredBytes: required,
                availableBytes: required - 1
            )
        ) { error in
            guard let exportError = error as? ExportError else {
                return XCTFail("Erreur inattendue : \(error)")
            }
            guard case .insufficientStorage(let requiredBytes, let availableBytes) = exportError else {
                return XCTFail("Erreur inattendue : \(exportError)")
            }
            XCTAssertEqual(requiredBytes, required)
            XCTAssertEqual(availableBytes, required - 1)
        }
    }
}
