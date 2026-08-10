//
//  ExportPlanningTests.swift
//  MontageMusicalTests
//
//  Logique d'export testable SANS encodage (Jalon 10) :
//  - plan d'export §51 (préfixe, durée absolue, nombre de plans, préfixe
//    vide → `emptyPrefix` §66) ;
//  - TRONCATURE §66 quand un rush devient indisponible pendant l'export
//    (plan réduit à n-1, musique recoupée §51 ; n == 0 → `emptyPrefix`) ;
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

    // MARK: - §51 : durée exportée et nombre de plans

    func testPlanDurationIsAbsoluteEndOfLastPrefixSlot() {
        // 3 cases prêtes, jointives : la durée exportée est la fin ABSOLUE de
        // la dernière (§51 : « la musique est coupée à la fin absolue de la
        // dernière case exportée »).
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let plan = try? ExportPlan.make(project: makeSnapshot(slots: slots), scope: .complete)

        XCTAssertEqual(plan?.duration, MediaTime(ticks: 150_000))
        XCTAssertEqual(plan?.slotCount, 3)
        XCTAssertEqual(plan?.slots.map(\.index), [0, 1, 2])
    }

    func testPlanStopsAtFirstHoleAndNeverShiftsLaterClips() {
        // §66 : « trou au milieu : export limité au préfixe ». Les cases 3 et
        // 4 sont prêtes mais situées APRÈS le trou : elles ne sont ni
        // exportées, ni avancées (§51 : « les clips ultérieurs ne sont jamais
        // déplacés »).
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil),
            makeSlot(index: 3, startTicks: 120_000, endTicks: 150_000),
            makeSlot(index: 4, startTicks: 150_000, endTicks: 180_000)
        ]
        let snapshot = makeSnapshot(slots: slots)

        let plan = try? ExportPlan.make(project: snapshot, scope: .contiguousPrefix)

        XCTAssertEqual(plan?.slotCount, 2)
        XCTAssertEqual(plan?.duration, MediaTime(ticks: 90_000))
        XCTAssertEqual(plan?.slots.map(\.start.ticks), [0, 45_000], "temps ABSOLUS conservés")
    }

    func testDownloadingSlotStopsThePrefix() {
        // §66 : « asset en téléchargement : export limité avant lui ».
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .downloading),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let plan = try? ExportPlan.make(project: makeSnapshot(slots: slots), scope: .contiguousPrefix)

        XCTAssertEqual(plan?.slotCount, 1)
        XCTAssertEqual(plan?.duration, MediaTime(ticks: 45_000))
    }

    func testBothScopesExportTheSamePrefix() {
        // §66 : `.complete` ne peut jamais exporter AU-DELÀ du préfixe — les
        // deux portées produisent le même plan (contrairement à la
        // prévisualisation §47.2, qui refuse un montage incomplet).
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

    // MARK: - §66 : première case vide → export désactivé

    func testEmptyFirstSlotThrowsEmptyPrefix() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000)
        ]

        XCTAssertThrowsError(
            try ExportPlan.make(project: makeSnapshot(slots: slots), scope: .contiguousPrefix)
        ) { error in
            XCTAssertEqual(error as? ExportError, .emptyPrefix)
        }
    }

    func testProjectWithoutSlotsThrowsEmptyPrefix() {
        XCTAssertThrowsError(
            try ExportPlan.make(project: makeSnapshot(slots: []), scope: .complete)
        ) { error in
            XCTAssertEqual(error as? ExportError, .emptyPrefix)
        }
    }

    func testUnavailableFirstSlotThrowsEmptyPrefix() {
        let slots = [makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: .unavailable)]

        XCTAssertThrowsError(
            try ExportPlan.make(project: makeSnapshot(slots: slots), scope: .contiguousPrefix)
        ) { error in
            XCTAssertEqual(error as? ExportError, .emptyPrefix)
        }
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
        // §66 : le tout premier rush est indisponible — il ne reste rien à
        // exporter, exactement comme une première case vide.
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

    private func makePlan(seconds: Double) -> ExportPlan {
        let end = MediaTime(seconds: seconds)
        return ExportPlan(
            slots: [makeSlot(index: 0, startTicks: 0, endTicks: end.ticks)],
            duration: end
        )
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

    func testEstimateForProjectUsesTheExportablePrefix() {
        // L'estimation d'un PROJET (§57) porte sur le PRÉFIXE §51, pas sur le
        // montage entier : les cases situées après le trou ne comptent pas.
        // Logique PURE : aucun exporteur, aucun acteur photothèque, aucun
        // disque — `ExportPlan.estimatedBytes(project:profile:)` est la source
        // unique dont `ProjectExporter.estimatedBytes` n'est qu'une façade.
        let profile = makeProfile()
        let truncated = makeSnapshot(slots: [
            makeSlot(index: 0, startTicks: 0, endTicks: 600_000),
            makeSlot(index: 1, startTicks: 600_000, endTicks: 1_200_000, status: nil),
            makeSlot(index: 2, startTicks: 1_200_000, endTicks: 1_800_000)
        ])
        let complete = makeSnapshot(slots: [
            makeSlot(index: 0, startTicks: 0, endTicks: 600_000),
            makeSlot(index: 1, startTicks: 600_000, endTicks: 1_200_000),
            makeSlot(index: 2, startTicks: 1_200_000, endTicks: 1_800_000)
        ])

        let truncatedBytes = ExportPlan.estimatedBytes(project: truncated, profile: profile)
        let completeBytes = ExportPlan.estimatedBytes(project: complete, profile: profile)

        XCTAssertGreaterThan(truncatedBytes, 0)
        XCTAssertLessThan(truncatedBytes, completeBytes)
    }

    func testEstimateForProjectWithoutExportablePrefixIsZero() {
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
