//
//  ProjectStoreTests.swift
//  MontageMusicalTests
//
//  Persistance des projets (Jalon 2, spec §77) : création de brouillon,
//  tri des résumés, renommage, suppression de brouillon vide (§31),
//  suppression en cascade (§10.1) et duplication (§65).
//
//  Conteneur SwiftData en mémoire + racine de fichiers dans un dossier
//  temporaire unique par test.
//

import XCTest
import SwiftData
@testable import MontageMusical

final class ProjectStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var rootURL: URL!
    private var fileStore: ProjectFileStore!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ProjectStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileStore = ProjectFileStore(rootURL: rootURL)
        store = ProjectStore(modelContainer: container, fileStore: fileStore)
    }

    override func tearDownWithError() throws {
        store = nil
        fileStore = nil
        container = nil
        if let rootURL, FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    // MARK: - createDraft

    func testCreateDraftCreatesRecordWithAutomaticTitleAndDirectories() async throws {
        let now = Date(timeIntervalSinceNow: -3_600)
        let projectID = try await store.createDraft(now: now)

        let summary = try await requireSummary(projectID)
        XCTAssertEqual(summary.id, projectID)
        XCTAssertEqual(summary.displayTitle, automaticProjectTitle(date: now), "Titre auto §10")
        XCTAssertEqual(summary.status, .draft)
        XCTAssertEqual(summary.createdAt, now)
        XCTAssertEqual(summary.updatedAt, now)
        XCTAssertFalse(summary.hasContent, "Brouillon neuf : ni musique, ni association, ni export")

        // Champs non exposés par le résumé, lus via un contexte frais.
        let context = ModelContext(container)
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<ProjectRecord>(
            predicate: #Predicate<ProjectRecord> { $0.id == projectID }
        )).first)
        XCTAssertNil(record.customTitle)
        XCTAssertEqual(record.activeSlotIndex, 0)

        // Arbre de dossiers §11 : audio/ analysis/ previews/ exports/ temp/.
        for subdirectory in ProjectFileStore.Subdirectory.allCases {
            var isDirectory: ObjCBool = false
            let url = fileStore.subdirectoryURL(subdirectory, for: projectID)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: url.path(percentEncoded: false),
                    isDirectory: &isDirectory
                ),
                "Dossier §11 manquant : \(subdirectory.rawValue)/"
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    // MARK: - summaries

    func testSummariesSortedByUpdatedAtDescending() async throws {
        let older = Date(timeIntervalSinceNow: -2_000)
        let newer = Date(timeIntervalSinceNow: -1_000)
        let first = try await store.createDraft(now: older)
        let second = try await store.createDraft(now: newer)

        var ids = try await store.summaries().map(\.id)
        XCTAssertEqual(ids, [second, first], "Tri updatedAt décroissant")

        // Une mutation touche updatedAt (§59) et fait remonter le projet.
        try await store.rename(projectID: first, customTitle: "Premier")
        ids = try await store.summaries().map(\.id)
        XCTAssertEqual(ids, [first, second])
    }

    // MARK: - rename

    func testRenameTrimsAndEmptyOrNilRestoresAutomaticTitle() async throws {
        let created = Date(timeIntervalSinceNow: -3_600)
        let projectID = try await store.createDraft(now: created)

        // Le titre personnalisé prime et est nettoyé des espaces de bord.
        try await store.rename(projectID: projectID, customTitle: "  Ma vidéo  ")
        var summary = try await requireSummary(projectID)
        XCTAssertEqual(summary.displayTitle, "Ma vidéo")
        XCTAssertGreaterThan(summary.updatedAt, created, "updatedAt touché (§59)")
        let renamedAt = summary.updatedAt

        // Chaîne vide (après trim) → retour au titre automatique (§10).
        try await store.rename(projectID: projectID, customTitle: "   ")
        summary = try await requireSummary(projectID)
        XCTAssertEqual(summary.displayTitle, automaticProjectTitle(date: created))
        XCTAssertGreaterThanOrEqual(summary.updatedAt, renamedAt)

        // nil → retour au titre automatique également.
        try await store.rename(projectID: projectID, customTitle: "Temporaire")
        try await store.rename(projectID: projectID, customTitle: nil)
        summary = try await requireSummary(projectID)
        XCTAssertEqual(summary.displayTitle, automaticProjectTitle(date: created))
    }

    // MARK: - deleteIfEmptyDraft (§31)

    func testDeleteIfEmptyDraftRemovesDraftWithoutMusic() async throws {
        let projectID = try await store.createDraft()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fileStore.directory(for: projectID).path(percentEncoded: false)
        ))

        let deleted = try await store.deleteIfEmptyDraft(projectID: projectID)

        XCTAssertTrue(deleted, "Brouillon sans musique → supprimé (§31)")
        let remaining = try await store.summary(id: projectID)
        XCTAssertNil(remaining)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fileStore.directory(for: projectID).path(percentEncoded: false)
            ),
            "Le dossier §11 du brouillon doit disparaître"
        )
    }

    func testDeleteIfEmptyDraftKeepsDraftWithMusic() async throws {
        // Brouillon AVEC musique, inséré à la main.
        let projectID = UUID()
        let context = ModelContext(container)
        context.insert(makeProjectRecord(id: projectID, audioRelativePath: "audio/original.m4a"))
        try context.save()

        let deleted = try await store.deleteIfEmptyDraft(projectID: projectID)

        XCTAssertFalse(deleted, "Un brouillon avec musique n'est pas un brouillon vide (§31)")
        let summary = try await requireSummary(projectID)
        XCTAssertTrue(summary.hasContent, "Musique présente → confirmation avant suppression (§31)")
    }

    func testDeleteIfEmptyDraftKeepsNonDraftProject() async throws {
        let projectID = UUID()
        let context = ModelContext(container)
        context.insert(makeProjectRecord(id: projectID, statusRaw: ProjectStatus.complete.rawValue))
        try context.save()

        let deleted = try await store.deleteIfEmptyDraft(projectID: projectID)

        XCTAssertFalse(deleted, "Seul un brouillon (statut draft) peut être supprimé automatiquement")
        let remaining = try await store.summary(id: projectID)
        XCTAssertNotNil(remaining)
    }

    // MARK: - delete (cascade §10.1)

    func testDeleteCascadesSlotsAssignmentsAndFiles() async throws {
        let projectID = UUID()
        let slotA = UUID()
        let slotB = UUID()
        let assignmentID = UUID()

        let context = ModelContext(container)
        context.insert(makeProjectRecord(id: projectID))
        context.insert(makeSlotRecord(
            id: slotA, projectID: projectID, index: 0,
            startTicks: 0, endTicks: 60_000, assignmentID: assignmentID
        ))
        context.insert(makeSlotRecord(
            id: slotB, projectID: projectID, index: 1,
            startTicks: 60_000, endTicks: 120_000
        ))
        context.insert(makeAssignmentRecord(id: assignmentID, projectID: projectID, slotID: slotA))

        // Témoin : un autre projet et sa case ne doivent pas être touchés.
        let otherProjectID = UUID()
        context.insert(makeProjectRecord(id: otherProjectID))
        context.insert(makeSlotRecord(
            id: UUID(), projectID: otherProjectID, index: 0,
            startTicks: 0, endTicks: 60_000
        ))
        try context.save()

        try fileStore.createDirectories(for: projectID)

        try await store.delete(projectID: projectID)

        let checkContext = ModelContext(container)
        XCTAssertEqual(try checkContext.fetchCount(FetchDescriptor<ProjectRecord>(
            predicate: #Predicate<ProjectRecord> { $0.id == projectID }
        )), 0, "ProjectRecord supprimé")
        XCTAssertEqual(try checkContext.fetchCount(FetchDescriptor<ProjectSlotRecord>(
            predicate: #Predicate<ProjectSlotRecord> { $0.projectID == projectID }
        )), 0, "Cascade §10.1 : cases supprimées")
        XCTAssertEqual(try checkContext.fetchCount(FetchDescriptor<ClipAssignmentRecord>(
            predicate: #Predicate<ClipAssignmentRecord> { $0.projectID == projectID }
        )), 0, "Cascade §10.1 : associations supprimées")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fileStore.directory(for: projectID).path(percentEncoded: false)
            ),
            "Dossier de fichiers §11 supprimé"
        )

        // La cascade est limitée au projet supprimé.
        XCTAssertEqual(try checkContext.fetchCount(FetchDescriptor<ProjectSlotRecord>(
            predicate: #Predicate<ProjectSlotRecord> { $0.projectID == otherProjectID }
        )), 1)
        let otherSummary = try await store.summary(id: otherProjectID)
        XCTAssertNotNil(otherSummary)
    }

    // MARK: - duplicate (§65)

    func testDuplicateCopiesRecordsWithRemappedIdentifiersAndKeepsSourceIntact() async throws {
        let sourceID = UUID()
        let slotA = UUID()
        let slotB = UUID()
        let assignmentID = UUID()

        let context = ModelContext(container)
        context.insert(makeProjectRecord(
            id: sourceID,
            statusRaw: ProjectStatus.complete.rawValue,
            audioRelativePath: "audio/original.m4a"
        ))
        context.insert(makeSlotRecord(
            id: slotA, projectID: sourceID, index: 0,
            startTicks: 0, endTicks: 45_000, assignmentID: assignmentID
        ))
        context.insert(makeSlotRecord(
            id: slotB, projectID: sourceID, index: 1,
            startTicks: 45_000, endTicks: 120_000
        ))
        context.insert(makeAssignmentRecord(id: assignmentID, projectID: sourceID, slotID: slotA))
        try context.save()

        // Fichier audio présent → le dossier §11 doit être copié.
        try fileStore.createDirectories(for: sourceID)
        let sourceAudioURL = fileStore.subdirectoryURL(.audio, for: sourceID)
            .appending(path: "original.m4a")
        try Data("audio-temoin".utf8).write(to: sourceAudioURL)

        let now = Date()
        let copyID = try await store.duplicate(projectID: sourceID, now: now)
        XCTAssertNotEqual(copyID, sourceID, "Nouvel identifiant de projet")

        let checkContext = ModelContext(container)

        // Enregistrement projet copié.
        let copy = try XCTUnwrap(try checkContext.fetch(FetchDescriptor<ProjectRecord>(
            predicate: #Predicate<ProjectRecord> { $0.id == copyID }
        )).first)
        XCTAssertEqual(copy.automaticTitle, automaticProjectTitle(date: now))
        XCTAssertEqual(copy.customTitle, "Projet du 1 janvier 2026 • 00:00 (copie)")
        XCTAssertEqual(copy.statusRaw, ProjectStatus.complete.rawValue)
        XCTAssertEqual(copy.audioRelativePath, "audio/original.m4a")
        XCTAssertEqual(copy.createdAt, now)
        XCTAssertEqual(copy.updatedAt, now)

        // Cases copiées : nouveaux identifiants, mêmes bornes et index.
        let copiedSlots = try checkContext.fetch(FetchDescriptor<ProjectSlotRecord>(
            predicate: #Predicate<ProjectSlotRecord> { $0.projectID == copyID },
            sortBy: [SortDescriptor(\ProjectSlotRecord.index)]
        ))
        guard copiedSlots.count == 2 else {
            return XCTFail("Deux cases copiées attendues, obtenu \(copiedSlots.count)")
        }
        XCTAssertEqual(copiedSlots.map(\.index), [0, 1])
        XCTAssertEqual(copiedSlots.map(\.startTicks), [0, 45_000])
        XCTAssertEqual(copiedSlots.map(\.endTicks), [45_000, 120_000])
        XCTAssertFalse(copiedSlots.map(\.id).contains(slotA), "Nouvel id de case")
        XCTAssertFalse(copiedSlots.map(\.id).contains(slotB), "Nouvel id de case")

        // Association copiée : nouvel id, slotID remappé vers la nouvelle
        // case d'index 0, référence croisée cohérente.
        let copiedAssignments = try checkContext.fetch(FetchDescriptor<ClipAssignmentRecord>(
            predicate: #Predicate<ClipAssignmentRecord> { $0.projectID == copyID }
        ))
        XCTAssertEqual(copiedAssignments.count, 1)
        let copiedAssignment = try XCTUnwrap(copiedAssignments.first)
        XCTAssertNotEqual(copiedAssignment.id, assignmentID, "Nouvel id d'association")
        XCTAssertEqual(copiedAssignment.slotID, copiedSlots[0].id, "slotID remappé")
        XCTAssertEqual(copiedSlots[0].assignmentID, copiedAssignment.id, "assignmentID remappé")
        XCTAssertNil(copiedSlots[1].assignmentID)
        XCTAssertEqual(copiedAssignment.assetLocalIdentifier, "asset-temoin")

        // Fichiers §11 copiés.
        XCTAssertTrue(fileStore.hasAudioFile(projectID: copyID))

        // Source intacte (§65 : duplication, jamais de mutation destructive).
        let sourceSlots = try checkContext.fetch(FetchDescriptor<ProjectSlotRecord>(
            predicate: #Predicate<ProjectSlotRecord> { $0.projectID == sourceID },
            sortBy: [SortDescriptor(\ProjectSlotRecord.index)]
        ))
        XCTAssertEqual(sourceSlots.map(\.id), [slotA, slotB])
        XCTAssertEqual(sourceSlots.first?.assignmentID, assignmentID)
        let sourceAssignments = try checkContext.fetch(FetchDescriptor<ClipAssignmentRecord>(
            predicate: #Predicate<ClipAssignmentRecord> { $0.projectID == sourceID }
        ))
        XCTAssertEqual(sourceAssignments.map(\.id), [assignmentID])
        XCTAssertTrue(fileStore.hasAudioFile(projectID: sourceID))
    }

    // MARK: - Helpers

    /// `store.summary(id:)` déballé — `XCTUnwrap` n'accepte pas
    /// d'expression `await` dans son autoclosure.
    private func requireSummary(_ id: UUID) async throws -> ProjectSummary {
        let summary = try await store.summary(id: id)
        return try XCTUnwrap(summary)
    }

    // MARK: - Fabriques d'enregistrements (insertion « à la main »)

    private func makeProjectRecord(
        id: UUID,
        statusRaw: String = ProjectStatus.draft.rawValue,
        audioRelativePath: String? = nil,
        automaticTitle: String = "Projet du 1 janvier 2026 • 00:00",
        date: Date = Date(timeIntervalSinceNow: -7_200)
    ) -> ProjectRecord {
        ProjectRecord(
            id: id,
            automaticTitle: automaticTitle,
            customTitle: nil,
            createdAt: date,
            updatedAt: date,
            statusRaw: statusRaw,
            selectedPaceRaw: nil,
            activeSlotIndex: 0,
            audioRelativePath: audioRelativePath,
            analysisRelativePath: nil,
            geometryData: nil,
            lastAlbumIdentifier: nil,
            analysisVersion: 0,
            scoreVersion: 0
        )
    }

    // MARK: - deleteAllEmptyDrafts / maintenance au lancement

    func testDeleteAllEmptyDraftsSparesExcludedAndNonDraftProjects() async throws {
        let emptyDraft = try await store.createDraft()
        let openDraft = try await store.createDraft()
        let analyzingProject = try await store.createDraft()
        try await store.setStatus(.analyzing, projectID: analyzingProject)

        let deleted = try await store.deleteAllEmptyDrafts(excluding: openDraft)

        XCTAssertEqual(deleted, 1, "Seul le brouillon vide non ouvert est supprimé (§31)")
        let remaining = try await store.summaries().map(\.id)
        XCTAssertFalse(remaining.contains(emptyDraft))
        XCTAssertTrue(remaining.contains(openDraft), "Le projet ouvert est protégé")
        XCTAssertTrue(remaining.contains(analyzingProject), "Un projet non-brouillon survit")
    }

    func testStartupMaintenanceRemovesOrphanDirectoriesAndClearsTemp() async throws {
        // Projet réel (protégé du balayage des brouillons) + fichier temporaire.
        let projectID = try await store.createDraft()
        try await store.setStatus(.analyzing, projectID: projectID)
        let tempFile = fileStore.subdirectoryURL(.temp, for: projectID)
            .appending(path: "reste-de-crash.tmp")
        try Data("x".utf8).write(to: tempFile)

        // Dossier orphelin : arbre §11 sans enregistrement SwiftData
        // (suppression interrompue entre save et suppression du dossier).
        let orphanID = UUID()
        try fileStore.createDirectories(for: orphanID)

        try await store.performStartupMaintenance()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fileStore.directory(for: orphanID).path(percentEncoded: false)
            ),
            "Dossier orphelin supprimé à la maintenance"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempFile.path(percentEncoded: false)),
            "temp/ vidé au lancement (§69A)"
        )
        // Le projet réel et son arbre §11 survivent.
        let remaining = try await store.summaries().map(\.id)
        XCTAssertTrue(remaining.contains(projectID))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fileStore.directory(for: projectID).path(percentEncoded: false)
            )
        )
    }

    // MARK: - Fabriques

    private func makeSlotRecord(
        id: UUID,
        projectID: UUID,
        index: Int,
        startTicks: Int64,
        endTicks: Int64,
        assignmentID: UUID? = nil
    ) -> ProjectSlotRecord {
        ProjectSlotRecord(
            id: id,
            projectID: projectID,
            scoreModeRaw: PaceMode.balanced.rawValue,
            index: index,
            startTicks: startTicks,
            endTicks: endTicks,
            entryAnchorID: UUID(),
            exitAnchorID: UUID(),
            gestureID: nil,
            assignmentID: assignmentID
        )
    }

    private func makeAssignmentRecord(
        id: UUID,
        projectID: UUID,
        slotID: UUID
    ) -> ClipAssignmentRecord {
        ClipAssignmentRecord(
            id: id,
            projectID: projectID,
            slotID: slotID,
            assetLocalIdentifier: "asset-temoin",
            sourceStartTicks: 0, // V1 : toujours 0 (§13.3)
            requiredDurationTicks: 45_000,
            observedAssetDurationTicks: 300_000,
            statusRaw: ClipAssignmentStatus.ready.rawValue,
            assignedAt: Date(timeIntervalSinceNow: -1_800)
        )
    }
}
