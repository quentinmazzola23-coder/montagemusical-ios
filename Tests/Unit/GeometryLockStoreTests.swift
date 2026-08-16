//
//  GeometryLockStoreTests.swift
//  MontageMusicalTests
//
//  Persistance de la géométrie et instantané de projet (Jalon 9) :
//  - `lockGeometry` verrouille au PREMIER rush et n'écrase JAMAIS ensuite
//    (§14, §49 étape 5, §65 : « premier rush supprimé après verrouillage :
//    conserver la géométrie ») ;
//  - `geometry(projectID:)` : aller-retour JSON complet ;
//  - duplication (§49/§65) : la copie POUR CHANGER DE RYTHME repart sans
//    géométrie (son propre premier rush la fixera), la copie COMPLÈTE la
//    conserve avec ses associations ;
//  - `projectSnapshot` : cases triées par index, statuts exacts, géométrie
//    présente, une case `downloading` qui coupe le préfixe exportable
//    (§47.2, §51), et AUCUNE case tant qu'aucun rythme n'est choisi.
//
//  Conteneur SwiftData en mémoire + racine de fichiers temporaire unique par
//  test (pattern `MediaAssignmentTests`) — aucun accès PhotoKit, aucun
//  AVFoundation.
//

import XCTest
import SwiftData
@testable import MontageMusical

final class GeometryLockStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var rootURL: URL!
    private var fileStore: ProjectFileStore!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "GeometryLockStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    // MARK: - §49/§65 Verrou définitif

    func testGeometryIsNilBeforeFirstRush() async throws {
        let projectID = try await makeAssemblingProject()

        let geometry = try await store.geometry(projectID: projectID)

        XCTAssertNil(geometry, "Aucune géométrie tant qu'aucun rush prêt ne l'a fixée (§49)")
    }

    func testLockGeometryIsDefinitiveAndIgnoresLaterRushes() async throws {
        let projectID = try await makeAssemblingProject()

        // Premier rush prêt : portrait 9:16 (§49).
        let first = ProjectGeometry(
            aspectWidth: 9,
            aspectHeight: 16,
            orientation: .portrait,
            lockedByAssetIdentifier: "asset-premier"
        )
        try await store.lockGeometry(first, projectID: projectID)

        // `await` extrait de chaque assertion : XCTest n'offre pas
        // d'`@autoclosure` asynchrone (`XCTUnwrap`/`XCTAssertEqual`).
        let storedGeometry = try await store.geometry(projectID: projectID)
        let locked = try XCTUnwrap(storedGeometry)
        XCTAssertEqual(locked.aspectWidth, 9)
        XCTAssertEqual(locked.aspectHeight, 16)
        XCTAssertEqual(locked.orientation, .portrait)
        XCTAssertEqual(locked.lockedByAssetIdentifier, "asset-premier")

        let summaryAfterLock = try await store.summary(id: projectID)
        let updatedAtAfterLock = try XCTUnwrap(summaryAfterLock).updatedAt

        // §14/§49 : « Elle ne change plus ensuite, même si un rush plus défini
        // est ajouté » — un second rush 4K paysage NE DOIT RIEN changer.
        let second = ProjectGeometry(
            aspectWidth: 16,
            aspectHeight: 9,
            orientation: .landscape,
            lockedByAssetIdentifier: "asset-4k-paysage"
        )
        try await store.lockGeometry(second, projectID: projectID)

        let geometryAfterSecondLock = try await store.geometry(projectID: projectID)
        let unchanged = try XCTUnwrap(geometryAfterSecondLock)
        XCTAssertEqual(unchanged.aspectWidth, 9, "Rapport INCHANGÉ (§49 étape 5)")
        XCTAssertEqual(unchanged.aspectHeight, 16)
        XCTAssertEqual(unchanged.orientation, .portrait)
        XCTAssertEqual(
            unchanged.lockedByAssetIdentifier, "asset-premier",
            "§65 : la géométrie reste celle du PREMIER rush, même supprimé depuis"
        )

        let summaryAfterSecondLock = try await store.summary(id: projectID)
        XCTAssertEqual(
            try XCTUnwrap(summaryAfterSecondLock).updatedAt, updatedAtAfterLock,
            "Verrou déjà posé : aucun effet de bord, pas même une date de modification"
        )
    }

    func testLockGeometrySurvivesRemovalOfEveryAssignment() async throws {
        // §65 : « toutes les cases retirées : conserver la géométrie pour
        // éviter un basculement inattendu ».
        let projectID = try await makeAssemblingProject()
        let slots = try await store.projectSnapshot(projectID: projectID).slots
        let assignmentID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slots[0].id,
            assetLocalIdentifier: "asset-premier",
            requiredDurationTicks: slots[0].duration.ticks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )
        try await store.completeAssignment(assignmentID, observedDurationTicks: 600_000, projectID: projectID)
        try await store.lockGeometry(
            ProjectGeometry(
                aspectWidth: 9,
                aspectHeight: 16,
                orientation: .portrait,
                lockedByAssetIdentifier: "asset-premier"
            ),
            projectID: projectID
        )

        try await store.removeAssignment(slotID: slots[0].id, projectID: projectID)

        let storedGeometry = try await store.geometry(projectID: projectID)
        let geometry = try XCTUnwrap(storedGeometry)
        XCTAssertEqual(geometry.aspectWidth, 9, "Géométrie conservée sans aucune association (§65)")
        XCTAssertEqual(geometry.aspectHeight, 16)
        XCTAssertEqual(geometry.lockedByAssetIdentifier, "asset-premier")
    }

    // MARK: - §49/§65 Duplication et géométrie

    func testDuplicateForPaceChangeDropsGeometry() async throws {
        // §65 : la copie POUR CHANGER DE RYTHME repart sans cases ni
        // associations. Hériter du verrou §49 la laisserait figée dans le
        // cadrage d'un rush qu'elle n'utilise PAS — et son propre premier
        // rush ne fixerait jamais sa géométrie (§49 : « le premier rush
        // valide fixe la géométrie »).
        let projectID = try await makeAssemblingProject()
        try await store.lockGeometry(
            ProjectGeometry(
                aspectWidth: 9,
                aspectHeight: 16,
                orientation: .portrait,
                lockedByAssetIdentifier: "asset-premier"
            ),
            projectID: projectID
        )

        let copyID = try await store.duplicateForPaceChange(projectID: projectID)

        let copyGeometry = try await store.geometry(projectID: copyID)
        XCTAssertNil(copyGeometry, "La copie repart SANS géométrie (§49)")
        let copySnapshot = try await store.projectSnapshot(projectID: copyID)
        XCTAssertTrue(copySnapshot.slots.isEmpty, "Ni cases ni associations dans la copie (§65)")

        // L'ORIGINAL reste strictement intact.
        let sourceGeometry = try await store.geometry(projectID: projectID)
        let source = try XCTUnwrap(sourceGeometry)
        XCTAssertEqual(source.aspectWidth, 9)
        XCTAssertEqual(source.aspectHeight, 16)
        XCTAssertEqual(source.lockedByAssetIdentifier, "asset-premier")
    }

    func testFullDuplicateKeepsGeometry() async throws {
        // Duplication COMPLÈTE (§31) : la copie garde cases, associations et
        // donc le verrou §49 qui leur correspond.
        let projectID = try await makeAssemblingProject()
        let slots = try await store.projectSnapshot(projectID: projectID).slots
        let assignmentID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slots[0].id,
            assetLocalIdentifier: "asset-premier",
            requiredDurationTicks: slots[0].duration.ticks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )
        try await store.completeAssignment(assignmentID, observedDurationTicks: 600_000, projectID: projectID)
        try await store.lockGeometry(
            ProjectGeometry(
                aspectWidth: 16,
                aspectHeight: 9,
                orientation: .landscape,
                lockedByAssetIdentifier: "asset-premier"
            ),
            projectID: projectID
        )

        let copyID = try await store.duplicate(projectID: projectID)

        let copyGeometry = try await store.geometry(projectID: copyID)
        let geometry = try XCTUnwrap(copyGeometry)
        XCTAssertEqual(geometry.aspectWidth, 16, "Le verrou suit les associations copiées")
        XCTAssertEqual(geometry.aspectHeight, 9)
        XCTAssertEqual(geometry.lockedByAssetIdentifier, "asset-premier")
        let copySnapshot = try await store.projectSnapshot(projectID: copyID)
        XCTAssertEqual(copySnapshot.slots.count, 4)
        XCTAssertEqual(copySnapshot.slots.first?.assignment?.status, .ready)
    }

    // MARK: - Aller-retour JSON

    func testGeometryRoundTripEncodesEveryField() async throws {
        // Chaque orientation §14 traverse l'encodage/décodage sans perte.
        for orientation in [ProjectOrientation.portrait, .landscape, .square] {
            let projectID = try await store.createDraft()
            let original = ProjectGeometry(
                aspectWidth: 1440,
                aspectHeight: 1080,
                orientation: orientation,
                lockedByAssetIdentifier: "asset-\(orientation.rawValue)"
            )

            try await store.lockGeometry(original, projectID: projectID)
            let stored = try await store.geometry(projectID: projectID)
            let decoded = try XCTUnwrap(stored)

            XCTAssertEqual(decoded.aspectWidth, original.aspectWidth)
            XCTAssertEqual(decoded.aspectHeight, original.aspectHeight)
            XCTAssertEqual(decoded.orientation, original.orientation)
            XCTAssertEqual(decoded.lockedByAssetIdentifier, original.lockedByAssetIdentifier)
        }
    }

    func testGeometryIsPerProject() async throws {
        let projectA = try await store.createDraft()
        let projectB = try await store.createDraft()

        try await store.lockGeometry(
            ProjectGeometry(aspectWidth: 9, aspectHeight: 16, orientation: .portrait, lockedByAssetIdentifier: "a"),
            projectID: projectA
        )

        let geometryA = try await store.geometry(projectID: projectA)
        let geometryB = try await store.geometry(projectID: projectB)
        XCTAssertEqual(geometryA?.aspectWidth, 9)
        XCTAssertNil(
            geometryB,
            "Le verrouillage d'un projet n'affecte jamais un autre projet"
        )
    }

    // MARK: - §51 Instantané de projet

    func testProjectSnapshotSortsSlotsAndReportsExactStatuses() async throws {
        let projectID = try await makeAssemblingProject()
        let slots = try await store.projectSnapshot(projectID: projectID).slots
        XCTAssertEqual(slots.map(\.index), [0, 1, 2, 3], "Cases TRIÉES par index (§51)")

        // Associations posées dans le DÉSORDRE (2, 0, 1) : l'instantané doit
        // rester trié et refléter le statut EXACT de chacune.
        let readyOnSlotTwo = try await store.beginAssignment(
            projectID: projectID,
            slotID: slots[2].id,
            assetLocalIdentifier: "asset-C",
            requiredDurationTicks: slots[2].duration.ticks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )
        try await store.completeAssignment(readyOnSlotTwo, observedDurationTicks: 600_000, projectID: projectID)

        let readyOnSlotZero = try await store.beginAssignment(
            projectID: projectID,
            slotID: slots[0].id,
            assetLocalIdentifier: "asset-A",
            requiredDurationTicks: slots[0].duration.ticks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )
        try await store.completeAssignment(readyOnSlotZero, observedDurationTicks: 600_000, projectID: projectID)

        // Case 1 : téléchargement iCloud en cours (§44).
        _ = try await store.beginAssignment(
            projectID: projectID,
            slotID: slots[1].id,
            assetLocalIdentifier: "asset-B",
            requiredDurationTicks: slots[1].duration.ticks,
            statusRaw: ClipAssignmentStatus.downloading.rawValue
        )
        // Case 3 : laissée VIDE.

        try await store.lockGeometry(
            ProjectGeometry(
                aspectWidth: 9,
                aspectHeight: 16,
                orientation: .portrait,
                lockedByAssetIdentifier: "asset-A"
            ),
            projectID: projectID
        )

        let snapshot = try await store.projectSnapshot(projectID: projectID)

        XCTAssertEqual(snapshot.projectID, projectID)
        XCTAssertEqual(snapshot.slots.map(\.index), [0, 1, 2, 3], "Tri par index conservé")
        XCTAssertEqual(
            snapshot.slots.map(\.start.ticks), [0, 60_000, 120_000, 180_000],
            "Temps ABSOLUS intacts (§9, §51)"
        )
        XCTAssertEqual(snapshot.slots.map(\.end.ticks), [60_000, 120_000, 180_000, 240_000])
        XCTAssertEqual(
            snapshot.slots.map { $0.assignment?.status },
            [.ready, .downloading, .ready, nil],
            "Statut EXACT de chaque case, case vide comprise"
        )
        XCTAssertEqual(
            snapshot.slots.map { $0.assignment?.assetLocalIdentifier },
            ["asset-A", "asset-B", "asset-C", nil]
        )

        // Géométrie verrouillée transportée par l'instantané.
        let geometry = try XCTUnwrap(snapshot.geometry)
        XCTAssertEqual(geometry.aspectWidth, 9)
        XCTAssertEqual(geometry.aspectHeight, 16)
        XCTAssertEqual(geometry.orientation, .portrait)

        // La case `downloading` SÉPARE deux zones remplies : elle n'est pas
        // exportée, mais la case 2 l'est — CONCATÉNÉE juste après la case 0
        // (changement produit). Aucune case n'est réécrite : la case 2 garde
        // son temps musical absolu (120 000 ticks) tout en tombant à 60 000
        // dans le fichier.
        let timeline = snapshot.readyTimeline
        XCTAssertEqual(
            timeline.runs.map { $0.slots.map(\.index) }, [[0], [2]],
            "Une case downloading sépare deux zones, elle n'en supprime aucune"
        )
        XCTAssertEqual(timeline.slotCount, 2)
        XCTAssertEqual(timeline.duration.ticks, 120_000, "60 000 + 60 000")
        XCTAssertEqual(timeline.runs[0].musicStart.ticks, 0)
        XCTAssertEqual(timeline.runs[1].musicStart.ticks, 120_000)
        XCTAssertEqual(timeline.compositionStart(of: snapshot.slots[2])?.ticks, 60_000)
    }

    func testProjectSnapshotWithoutGeometryOrAssignments() async throws {
        let projectID = try await makeAssemblingProject()

        let snapshot = try await store.projectSnapshot(projectID: projectID)

        XCTAssertNil(snapshot.geometry, "Aucune géométrie avant le premier rush (§49)")
        XCTAssertEqual(snapshot.slots.count, 4)
        XCTAssertTrue(snapshot.slots.allSatisfy { $0.assignment == nil })
        XCTAssertTrue(
            snapshot.readyTimeline.isEmpty,
            "Aucune case prête → timeline exportable vide → export/aperçu désactivés"
        )
    }

    func testProjectSnapshotWithoutSelectedPaceHasNoSlots() async throws {
        // Aucun rythme choisi (§34 pas encore franchi) : l'instantané ne
        // contient AUCUNE case — sinon les cases de plusieurs modes se
        // chevaucheraient dans un même « montage » jamais demandé, et la
        // timeline exportable serait calculée sur elles.
        let projectID = try await makeAssemblingProject()
        let slotsBefore = try await store.projectSnapshot(projectID: projectID).slots
        XCTAssertEqual(slotsBefore.count, 4, "Rythme choisi : les 4 cases du mode")

        // Retour au choix du rythme (§65 : autorisé avant toute association).
        try await store.revertToPaceSelection(projectID: projectID)

        let snapshot = try await store.projectSnapshot(projectID: projectID)
        XCTAssertTrue(
            snapshot.slots.isEmpty,
            "Aucun rythme sélectionné → aucune case dans l'instantané"
        )
        XCTAssertTrue(
            snapshot.readyTimeline.isEmpty,
            "Aucun montage en cours → timeline exportable vide"
        )
        XCTAssertEqual(snapshot.projectID, projectID)
    }

    func testProjectSnapshotOfUnknownProjectThrows() async throws {
        let unknownID = UUID()
        do {
            _ = try await store.projectSnapshot(projectID: unknownID)
            XCTFail("Un projet inconnu doit être refusé")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .projectNotFound(unknownID))
        }
    }

    // MARK: - Fabriques (pattern `MediaAssignmentTests`)

    /// Projet en assemblage avec 4 cases percutantes de 1 s chacune.
    private func makeAssemblingProject() async throws -> UUID {
        let projectID = try await store.createDraft()
        try await store.selectPace(.everyFourBeats, from: makeFamily(), projectID: projectID)
        return projectID
    }

    private func makeSlot(index: Int, startTicks: Int64, endTicks: Int64) -> EditSlotDefinition {
        EditSlotDefinition(
            id: UUID(),
            index: index,
            start: MediaTime(ticks: startTicks),
            end: MediaTime(ticks: endTicks),
            entryAnchorID: UUID(),
            exitAnchorID: UUID(),
            gestureID: nil
        )
    }

    private func makeScore(mode: PaceMode, boundaries: [Int64]) -> EditScore {
        var slots: [EditSlotDefinition] = []
        for i in 0..<(boundaries.count - 1) {
            slots.append(makeSlot(index: i, startTicks: boundaries[i], endTicks: boundaries[i + 1]))
        }
        let durations = slots.map { $0.end.ticks - $0.start.ticks }
        return EditScore(
            mode: mode,
            slots: slots,
            gestures: [],
            averageDuration: MediaTime(ticks: durations.reduce(0, +) / Int64(max(durations.count, 1))),
            minimumDuration: MediaTime(ticks: durations.min() ?? 0),
            maximumDuration: MediaTime(ticks: durations.max() ?? 0)
        )
    }

    private func makeFamily() -> EditScoreFamily {
        EditScoreFamily(
            analysisVersion: 1,
            everyBeat: makeScore(mode: .everyBeat, boundaries: [0, 240_000]),
            everyTwoBeats: makeScore(mode: .everyTwoBeats, boundaries: [0, 120_000, 240_000]),
            everyFourBeats: makeScore(
                mode: .everyFourBeats,
                boundaries: [0, 60_000, 120_000, 180_000, 240_000]
            )
        )
    }
}
