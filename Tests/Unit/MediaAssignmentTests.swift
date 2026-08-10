//
//  MediaAssignmentTests.swift
//  MontageMusicalTests
//
//  Associations vidéo (Jalon 8) côté règles pures et persistance —
//  AUCUN appel PhotoKit :
//  - `AssignmentRules.isDurationCompatible` (§43 : plus court/égal/plus
//    long §70, et métadonnée arrondie compatible mais durée réelle
//    insuffisante → validation finale refusée) ;
//  - `AssignmentRules.nextEmptySlotIndex` (§46 : strictement après,
//    rebouclage documenté, `nil` si aucune case vide) ;
//  - `ProjectStore` : begin/complete/fail/remove d'association (§13.3,
//    §59 : sauvegarde immédiate ; §64 : la case garde l'association en
//    échec ; Remplacer §36 : une seule association par case §10.1) ;
//  - `markAssignmentDownloading` (§44 : `downloading` UNIQUEMENT depuis
//    `resolving`, sinon no-op silencieux) ;
//  - `removeAssignmentIfCurrent` (courses par ASSOCIATION : le retrait
//    d'une tâche périmée ne touche jamais l'association qui l'a
//    remplacée §36/§64) ;
//  - reprise après kill (§8/§64) : `performStartupMaintenance` bascule
//    `resolving`/`downloading` vers `unavailable`, la case GARDE son
//    association ;
//  - `usedAssetSlotIndexes` (§45 « Déjà utilisé au plan 4 »),
//    `emptySlotIndexes` cohérent avant/après ;
//  - `setLastAlbum`/`lastAlbum` (§41 : mémorisé par projet).
//
//  Conteneur SwiftData en mémoire + racine de fichiers temporaire unique
//  par test (pattern `PaceSelectionStoreTests`) ; helpers privés de classe ;
//  vérifications par instantanés de valeurs (jamais de `PersistentModel`
//  survivant à son `ModelContext`).
//

import XCTest
import SwiftData
@testable import MontageMusical

final class MediaAssignmentTests: XCTestCase {

    private var container: ModelContainer!
    private var rootURL: URL!
    private var fileStore: ProjectFileStore!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "MediaAssignmentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    // MARK: - AssignmentRules.isDurationCompatible (§43, §70)

    func testDurationCompatibilityShorterEqualLonger() {
        // §70 « Durée d'asset » : plus court / égal / plus long.
        XCTAssertFalse(
            AssignmentRules.isDurationCompatible(assetTicks: 119_999, requiredTicks: 120_000),
            "Plus court → incompatible (§43)"
        )
        XCTAssertTrue(
            AssignmentRules.isDurationCompatible(assetTicks: 120_000, requiredTicks: 120_000),
            "Égalité EXACTE → acceptée (§43)"
        )
        XCTAssertTrue(
            AssignmentRules.isDurationCompatible(assetTicks: 120_001, requiredTicks: 120_000),
            "Plus long → compatible (§43)"
        )
    }

    func testRoundedMetadataPassesInitialFilterButFinalValidationFails() {
        // §43 : premier filtre = `PHAsset.duration` (métadonnée Double
        // arrondie par PhotoKit) ; validation finale = durée réelle de
        // l'AVAsset résolu. Ici la métadonnée annonce 2,00 s (compatible)
        // mais la durée réelle mesurée est 1,98 s : la validation finale
        // DOIT refuser — la case ne doit pas être remplie.
        let requiredTicks: Int64 = 120_000 // case de 2 s exactement

        let announcedTicks = MediaTime(seconds: 2.0).ticks // frontière §9
        XCTAssertEqual(announcedTicks, 120_000)
        XCTAssertTrue(
            AssignmentRules.isDurationCompatible(assetTicks: announcedTicks, requiredTicks: requiredTicks),
            "Filtre initial (métadonnée arrondie) : annoncé compatible"
        )

        let realTicks = MediaTime(seconds: 1.98).ticks // durée réelle load(.duration)
        XCTAssertFalse(
            AssignmentRules.isDurationCompatible(assetTicks: realTicks, requiredTicks: requiredTicks),
            "Validation finale (durée réelle) : refusée — erreur claire et case non remplie (§43)"
        )
    }

    // MARK: - AssignmentRules.nextEmptySlotIndex (§46)

    func testNextEmptySlotIndexStrictlyAfterThenWrapAround() {
        let empty = [2, 5, 7]
        XCTAssertEqual(AssignmentRules.nextEmptySlotIndex(after: 2, emptySlotIndexes: empty), 5)
        XCTAssertEqual(AssignmentRules.nextEmptySlotIndex(after: 0, emptySlotIndexes: empty), 2)
        XCTAssertEqual(
            AssignmentRules.nextEmptySlotIndex(after: 5, emptySlotIndexes: empty), 7,
            "STRICTEMENT après : jamais la case courante elle-même"
        )
        XCTAssertEqual(
            AssignmentRules.nextEmptySlotIndex(after: 7, emptySlotIndexes: empty), 2,
            "Rebouclage : plus rien après → première case vide avant (choix documenté non-spec)"
        )
    }

    func testNextEmptySlotIndexNilWhenNoEmptySlotRemains() {
        XCTAssertNil(
            AssignmentRules.nextEmptySlotIndex(after: 3, emptySlotIndexes: []),
            "Aucune case vide → nil (§46 : « Montage complet »)"
        )
    }

    func testNextEmptySlotIndexIgnoresInputOrder() {
        XCTAssertEqual(
            AssignmentRules.nextEmptySlotIndex(after: 2, emptySlotIndexes: [7, 2, 5]), 5,
            "L'ordre d'entrée est indifférent (tri interne)"
        )
    }

    // MARK: - beginAssignment / completeAssignment (§13.3, §43, §59)

    func testBeginAssignmentCreatesResolvingRecordAndSetsSlotReference() async throws {
        let projectID = try await makeAssemblingProject()
        let slot = try persistedSlots(projectID: projectID)[0]

        let assignmentID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-A",
            requiredDurationTicks: slot.durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )

        let records = try assignmentRecords(projectID: projectID)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, assignmentID)
        XCTAssertEqual(record.slotID, slot.id)
        XCTAssertEqual(record.assetLocalIdentifier, "asset-A")
        XCTAssertEqual(record.statusRaw, ClipAssignmentStatus.resolving.rawValue)
        XCTAssertEqual(record.sourceStartTicks, 0, "V1 : sourceStartTicks toujours 0 (§13.3)")
        XCTAssertEqual(record.requiredDurationTicks, slot.durationTicks)
        XCTAssertEqual(record.observedAssetDurationTicks, 0, "Durée réelle inconnue avant résolution (§43)")

        // Référence croisée posée et PERSISTÉE (relecture par un contexte
        // frais → la sauvegarde immédiate §59 est effective).
        XCTAssertEqual(
            try persistedSlots(projectID: projectID)[0].assignmentID, assignmentID,
            "slot.assignmentID posé et sauvegardé immédiatement (§59)"
        )
    }

    func testCompleteAssignmentSetsReadyAndObservedDuration() async throws {
        let projectID = try await makeAssemblingProject()
        let slot = try persistedSlots(projectID: projectID)[0]
        let assignmentID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-A",
            requiredDurationTicks: slot.durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )

        try await store.completeAssignment(
            assignmentID,
            observedDurationTicks: 600_000,
            projectID: projectID
        )

        let record = try XCTUnwrap(try assignmentRecords(projectID: projectID).first)
        XCTAssertEqual(record.statusRaw, ClipAssignmentStatus.ready.rawValue)
        XCTAssertEqual(record.observedAssetDurationTicks, 600_000, "Durée RÉELLE mesurée (§43)")
    }

    // MARK: - Remplacer (§36 : une seule association par case §10.1)

    func testBeginAssignmentOnAssignedSlotReplacesExistingRecord() async throws {
        let projectID = try await makeAssemblingProject()
        let slot = try persistedSlots(projectID: projectID)[0]
        let firstID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-A",
            requiredDurationTicks: slot.durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )
        try await store.completeAssignment(firstID, observedDurationTicks: 600_000, projectID: projectID)

        let secondID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-B",
            requiredDurationTicks: slot.durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )

        // Un SEUL enregistrement pour la case : l'ancien est supprimé,
        // le nouveau est en place (§10.1 : une association maximum par case).
        let records = try assignmentRecords(projectID: projectID)
        XCTAssertEqual(records.count, 1, "Ancien enregistrement supprimé (Remplacer §36)")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, secondID)
        XCTAssertNotEqual(record.id, firstID)
        XCTAssertEqual(record.assetLocalIdentifier, "asset-B")
        XCTAssertEqual(record.statusRaw, ClipAssignmentStatus.resolving.rawValue)
        XCTAssertEqual(
            try persistedSlots(projectID: projectID)[0].assignmentID, secondID,
            "La case référence la NOUVELLE association"
        )
    }

    // MARK: - failAssignment / removeAssignment (§64)

    func testFailAssignmentKeepsRecordInUnavailableState() async throws {
        let projectID = try await makeAssemblingProject()
        let slot = try persistedSlots(projectID: projectID)[0]
        let assignmentID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-A",
            requiredDurationTicks: slot.durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )

        try await store.failAssignment(
            assignmentID,
            statusRaw: ClipAssignmentStatus.unavailable.rawValue,
            projectID: projectID
        )

        // §64 « asset supprimé : case unavailable » : l'enregistrement est
        // GARDÉ en état d'échec, la case garde sa référence.
        let record = try XCTUnwrap(try assignmentRecords(projectID: projectID).first)
        XCTAssertEqual(record.id, assignmentID, "Enregistrement conservé")
        XCTAssertEqual(record.statusRaw, ClipAssignmentStatus.unavailable.rawValue)
        XCTAssertEqual(
            try persistedSlots(projectID: projectID)[0].assignmentID, assignmentID,
            "La case garde l'association en état d'échec (§64)"
        )
    }

    func testRemoveAssignmentDeletesRecordAndClearsSlotReference() async throws {
        let projectID = try await makeAssemblingProject()
        let slot = try persistedSlots(projectID: projectID)[0]
        _ = try await store.beginAssignment(
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-A",
            requiredDurationTicks: slot.durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )

        try await store.removeAssignment(slotID: slot.id, projectID: projectID)

        // Cas d'usage §43 validation finale : `tooShort` détecté à la
        // résolution → l'appelant RETIRE l'association, la case reste VIDE.
        XCTAssertTrue(try assignmentRecords(projectID: projectID).isEmpty, "Enregistrement supprimé")
        XCTAssertNil(
            try persistedSlots(projectID: projectID)[0].assignmentID,
            "slot.assignmentID retiré — la case est vide"
        )
        let emptyIndexes = try await store.emptySlotIndexes(projectID: projectID)
        XCTAssertEqual(emptyIndexes, [0, 1, 2, 3], "La case retirée redevient vide")
    }

    // MARK: - markAssignmentDownloading (§44)

    func testMarkAssignmentDownloadingOnlyFromResolvingState() async throws {
        let projectID = try await makeAssemblingProject()
        let slot = try persistedSlots(projectID: projectID)[0]
        let assignmentID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-A",
            requiredDurationTicks: slot.durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )

        // `resolving` → `downloading` : le premier callback réseau (§44).
        try await store.markAssignmentDownloading(assignmentID, projectID: projectID)
        var record = try XCTUnwrap(try assignmentRecords(projectID: projectID).first)
        XCTAssertEqual(record.statusRaw, ClipAssignmentStatus.downloading.rawValue)

        // Statut FINAL posé (résolution terminée) : un callback tardif est
        // un no-op SILENCIEUX — jamais d'écrasement d'un état final.
        try await store.completeAssignment(assignmentID, observedDurationTicks: 600_000, projectID: projectID)
        try await store.markAssignmentDownloading(assignmentID, projectID: projectID)
        record = try XCTUnwrap(try assignmentRecords(projectID: projectID).first)
        XCTAssertEqual(
            record.statusRaw, ClipAssignmentStatus.ready.rawValue,
            "no-op silencieux : `ready` n'est jamais écrasé par `downloading` (§44)"
        )

        // Association inconnue (tâche périmée remplacée) : erreur typée que
        // l'appelant avale silencieusement (§64).
        let unknownID = UUID()
        do {
            try await store.markAssignmentDownloading(unknownID, projectID: projectID)
            XCTFail("Une association inconnue doit être refusée")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .assignmentNotFound(unknownID))
        }
    }

    // MARK: - removeAssignmentIfCurrent (courses par ASSOCIATION, §36/§64)

    func testRemoveAssignmentIfCurrentSparesReplacementAssignment() async throws {
        let projectID = try await makeAssemblingProject()
        let slot = try persistedSlots(projectID: projectID)[0]

        // A en résolution (lente), puis B REMPLACE la même case (§36).
        let firstID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-A",
            requiredDurationTicks: slot.durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )
        let secondID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-B",
            requiredDurationTicks: slot.durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )

        // Le chemin d'échec de la tâche A (périmée) retire « son »
        // association : B doit rester STRICTEMENT intacte.
        try await store.removeAssignmentIfCurrent(firstID, slotID: slot.id, projectID: projectID)

        let records = try assignmentRecords(projectID: projectID)
        XCTAssertEqual(records.count, 1, "L'association B n'est pas touchée par le retrait de A")
        XCTAssertEqual(records.first?.id, secondID)
        XCTAssertEqual(records.first?.assetLocalIdentifier, "asset-B")
        XCTAssertEqual(
            try persistedSlots(projectID: projectID)[0].assignmentID, secondID,
            "La case référence toujours B (§64 : jamais de perte silencieuse)"
        )

        // Retrait de l'association COURANTE : comportement normal — la case
        // redevient vide.
        try await store.removeAssignmentIfCurrent(secondID, slotID: slot.id, projectID: projectID)
        XCTAssertTrue(try assignmentRecords(projectID: projectID).isEmpty)
        XCTAssertNil(try persistedSlots(projectID: projectID)[0].assignmentID)

        // Rejouer le retrait périmé : no-op silencieux, aucune erreur.
        try await store.removeAssignmentIfCurrent(firstID, slotID: slot.id, projectID: projectID)
    }

    // MARK: - Reprise après kill (§8/§64)

    func testStartupMaintenanceSwitchesPendingAssignmentsToUnavailable() async throws {
        let projectID = try await makeAssemblingProject()
        let slots = try persistedSlots(projectID: projectID)

        // Trois associations : resolving (kill en pleine résolution),
        // downloading (kill en plein téléchargement iCloud), ready (saine).
        let resolvingID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slots[0].id,
            assetLocalIdentifier: "asset-resolving",
            requiredDurationTicks: slots[0].durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )
        let downloadingID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slots[1].id,
            assetLocalIdentifier: "asset-downloading",
            requiredDurationTicks: slots[1].durationTicks,
            statusRaw: ClipAssignmentStatus.downloading.rawValue
        )
        let readyID = try await store.beginAssignment(
            projectID: projectID,
            slotID: slots[2].id,
            assetLocalIdentifier: "asset-ready",
            requiredDurationTicks: slots[2].durationTicks,
            statusRaw: ClipAssignmentStatus.resolving.rawValue
        )
        try await store.completeAssignment(readyID, observedDurationTicks: 600_000, projectID: projectID)

        try await store.performStartupMaintenance()

        // §64 : les états en cours deviennent `unavailable` — la case GARDE
        // son association (le dock propose « Remplacer »), `ready` intact.
        let statusByID = Dictionary(
            uniqueKeysWithValues: try assignmentRecords(projectID: projectID).map { ($0.id, $0.statusRaw) }
        )
        XCTAssertEqual(statusByID[resolvingID], ClipAssignmentStatus.unavailable.rawValue)
        XCTAssertEqual(statusByID[downloadingID], ClipAssignmentStatus.unavailable.rawValue)
        XCTAssertEqual(statusByID[readyID], ClipAssignmentStatus.ready.rawValue)
        let persistedSlotRecords = try persistedSlots(projectID: projectID)
        XCTAssertEqual(persistedSlotRecords[0].assignmentID, resolvingID, "La case garde son association (§64)")
        XCTAssertEqual(persistedSlotRecords[1].assignmentID, downloadingID, "La case garde son association (§64)")
        XCTAssertEqual(persistedSlotRecords[2].assignmentID, readyID)
    }

    // MARK: - Appartenance au projet

    func testBeginAssignmentRejectsSlotOfAnotherProject() async throws {
        let projectA = try await makeAssemblingProject()
        let projectB = try await makeAssemblingProject()
        let slotOfA = try persistedSlots(projectID: projectA)[0]

        do {
            _ = try await store.beginAssignment(
                projectID: projectB,
                slotID: slotOfA.id,
                assetLocalIdentifier: "asset-A",
                requiredDurationTicks: slotOfA.durationTicks,
                statusRaw: ClipAssignmentStatus.resolving.rawValue
            )
            XCTFail("Une case d'un AUTRE projet doit être refusée")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .slotNotFound(slotOfA.id))
        }
        XCTAssertTrue(try assignmentRecords(projectID: projectB).isEmpty, "Aucune association créée")
    }

    // MARK: - usedAssetSlotIndexes (§45) et emptySlotIndexes

    func testUsedAssetSlotIndexesSortedAndEmptySlotIndexesCoherent() async throws {
        let projectID = try await makeAssemblingProject()
        let slots = try persistedSlots(projectID: projectID)
        XCTAssertEqual(slots.map(\.index), [0, 1, 2, 3])

        // AVANT toute association : toutes les cases sont vides.
        var emptyIndexes = try await store.emptySlotIndexes(projectID: projectID)
        XCTAssertEqual(emptyIndexes, [0, 1, 2, 3])
        var used = try await store.usedAssetSlotIndexes(projectID: projectID)
        XCTAssertTrue(used.isEmpty)

        // Même asset sur DEUX cases (0 et 3), assignées dans le DÉSORDRE
        // (3 puis 0) : les index retournés doivent être TRIÉS (§45
        // « Déjà utilisé au plan 4 » — réutilisation volontaire permise).
        for slotIndex in [3, 0] {
            let slot = slots[slotIndex]
            let id = try await store.beginAssignment(
                projectID: projectID,
                slotID: slot.id,
                assetLocalIdentifier: "asset-X",
                requiredDurationTicks: slot.durationTicks,
                statusRaw: ClipAssignmentStatus.resolving.rawValue
            )
            try await store.completeAssignment(id, observedDurationTicks: 600_000, projectID: projectID)
        }

        used = try await store.usedAssetSlotIndexes(projectID: projectID)
        XCTAssertEqual(used, ["asset-X": [0, 3]], "Index TRIÉS par asset (§45)")

        // APRÈS : seules les cases 1 et 2 restent vides — entrée directe de
        // l'avancement automatique §46.
        emptyIndexes = try await store.emptySlotIndexes(projectID: projectID)
        XCTAssertEqual(emptyIndexes, [1, 2])
        XCTAssertEqual(AssignmentRules.nextEmptySlotIndex(after: 0, emptySlotIndexes: emptyIndexes), 1)

        // Résumés : triés par index de case, champs exacts.
        let summaries = try await store.assignments(projectID: projectID)
        XCTAssertEqual(summaries.map(\.slotIndex), [0, 3])
        XCTAssertEqual(summaries.map(\.assetLocalIdentifier), ["asset-X", "asset-X"])
        XCTAssertEqual(summaries.map(\.slotID), [slots[0].id, slots[3].id])
        XCTAssertTrue(summaries.allSatisfy { $0.statusRaw == ClipAssignmentStatus.ready.rawValue })
    }

    // MARK: - setLastAlbum / lastAlbum (§41)

    func testLastAlbumRoundTripPerProject() async throws {
        let projectA = try await makeAssemblingProject()
        let projectB = try await makeAssemblingProject()

        var lastA = try await store.lastAlbum(projectID: projectA)
        XCTAssertNil(lastA, "Aucun album mémorisé initialement")

        try await store.setLastAlbum("album-recents", projectID: projectA)
        try await store.setLastAlbum("album-favoris", projectID: projectB)

        lastA = try await store.lastAlbum(projectID: projectA)
        let lastB = try await store.lastAlbum(projectID: projectB)
        XCTAssertEqual(lastA, "album-recents", "Mémorisé PAR PROJET (§41)")
        XCTAssertEqual(lastB, "album-favoris")

        try await store.setLastAlbum(nil, projectID: projectA)
        lastA = try await store.lastAlbum(projectID: projectA)
        XCTAssertNil(lastA, "nil efface la mémorisation")
    }

    // MARK: - Fabriques

    /// Projet en assemblage avec 4 cases percutantes de 1 s chacune
    /// ([0, 1, 2, 3] — indexes utilisés par les tests §45/§46).
    private func makeAssemblingProject() async throws -> UUID {
        let projectID = try await store.createDraft()
        try await store.selectPace(.percussive, from: makeFamily(), projectID: projectID)
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

    /// Partition synthétique contiguë (§28.1) depuis des frontières en ticks.
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

    /// Famille synthétique (pattern `PaceSelectionStoreTests`) : le mode
    /// percutant offre 4 cases (indexes 0...3) sur 4 s.
    private func makeFamily() -> EditScoreFamily {
        EditScoreFamily(
            analysisVersion: 1,
            fluid: makeScore(mode: .fluid, boundaries: [0, 240_000]),
            balanced: makeScore(mode: .balanced, boundaries: [0, 120_000, 240_000]),
            percussive: makeScore(
                mode: .percussive,
                boundaries: [0, 60_000, 120_000, 180_000, 240_000]
            )
        )
    }

    // MARK: - Instantanés de vérification (valeurs pures, contexte frais —
    // la relecture prouve la sauvegarde immédiate §59)

    private struct SlotSnapshot: Equatable {
        let id: UUID
        let index: Int
        let startTicks: Int64
        let endTicks: Int64
        let assignmentID: UUID?

        var durationTicks: Int64 { endTicks - startTicks } // §9 : end - start
    }

    private struct AssignmentSnapshot: Equatable {
        let id: UUID
        let slotID: UUID
        let assetLocalIdentifier: String
        let sourceStartTicks: Int64
        let requiredDurationTicks: Int64
        let observedAssetDurationTicks: Int64
        let statusRaw: String
    }

    private func persistedSlots(projectID: UUID) throws -> [SlotSnapshot] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<ProjectSlotRecord>(
            predicate: #Predicate<ProjectSlotRecord> { $0.projectID == projectID },
            sortBy: [SortDescriptor(\ProjectSlotRecord.index)]
        )).map {
            SlotSnapshot(
                id: $0.id,
                index: $0.index,
                startTicks: $0.startTicks,
                endTicks: $0.endTicks,
                assignmentID: $0.assignmentID
            )
        }
    }

    private func assignmentRecords(projectID: UUID) throws -> [AssignmentSnapshot] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<ClipAssignmentRecord>(
            predicate: #Predicate<ClipAssignmentRecord> { $0.projectID == projectID },
            sortBy: [SortDescriptor(\ClipAssignmentRecord.assignedAt)]
        )).map {
            AssignmentSnapshot(
                id: $0.id,
                slotID: $0.slotID,
                assetLocalIdentifier: $0.assetLocalIdentifier,
                sourceStartTicks: $0.sourceStartTicks,
                requiredDurationTicks: $0.requiredDurationTicks,
                observedAssetDurationTicks: $0.observedAssetDurationTicks,
                statusRaw: $0.statusRaw
            )
        }
    }
}
