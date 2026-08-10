//
//  PaceSelectionStoreTests.swift
//  MontageMusicalTests
//
//  Choix du rythme (Jalon 6, §34, §81) côté persistance :
//  - `selectPace` matérialise les cases §10.1 du mode choisi (ticks et
//    ancres exacts), statut `assembling`, case active 0, sauvegardé (§59) ;
//  - `revertToPaceSelection` AVANT association : cases effacées, rythme
//    désélectionné, statut `awaitingPaceSelection`, re-sélection possible
//    (§65 : seule la mutation APRÈS association est interdite) ;
//  - APRÈS une association : `selectPace`, `revertToPaceSelection` et
//    `clearSlots` échouent en `paceLockedByAssignments` et les cases
//    restent INTACTES (§65, §89 : jamais de mutation destructive) ;
//  - `ScoreLibrary` : round-trip `analysis/scores-v1.json` + validité §61
//    via `scores-meta-v1.json` (version du générateur + empreinte de
//    configuration partagée `ScoreConfigurationFingerprint`).
//
//  Conteneur SwiftData en mémoire + racine de fichiers dans un dossier
//  temporaire unique par test (pattern `ProjectStoreTests`) ; helpers
//  privés de classe pour éviter les collisions de module. Les vérifications
//  passent par des instantanés de valeurs (jamais de `PersistentModel`
//  survivant à son `ModelContext`).
//

import XCTest
import SwiftData
@testable import MontageMusical

final class PaceSelectionStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var rootURL: URL!
    private var fileStore: ProjectFileStore!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "PaceSelectionStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    // MARK: - selectPace

    func testSelectPaceBalancedInsertsSlotsAndUpdatesProject() async throws {
        let projectID = try await store.createDraft()
        let family = makeFamily()

        try await store.selectPace(.balanced, from: family, projectID: projectID)

        // Cases persistées == cases de la partition Équilibré (ticks §9
        // exacts, ancres conservées), UNIQUEMENT le mode choisi (§11 : les
        // trois partitions complètes restent dans scores-v1.json).
        let slots = try persistedSlots(projectID: projectID)
        let expected = family.balanced.slots
        XCTAssertEqual(slots.count, expected.count, "Cases du mode choisi uniquement")
        XCTAssertEqual(slots.map(\.index), expected.map(\.index))
        XCTAssertEqual(slots.map(\.startTicks), expected.map(\.start.ticks), "Frontières de début exactes (§9)")
        XCTAssertEqual(slots.map(\.endTicks), expected.map(\.end.ticks), "Frontières de fin exactes (§9)")
        XCTAssertEqual(slots.map(\.entryAnchorID), expected.map(\.entryAnchorID))
        XCTAssertEqual(slots.map(\.exitAnchorID), expected.map(\.exitAnchorID))
        XCTAssertTrue(
            slots.allSatisfy { $0.scoreModeRaw == PaceMode.balanced.rawValue },
            "scoreModeRaw == balanced pour toutes les cases"
        )
        XCTAssertTrue(slots.allSatisfy { $0.assignmentID == nil }, "Aucune association à l'insertion")

        // Projet : rythme choisi, statut assembling, case active 0 (§59).
        let project = try projectState(projectID)
        XCTAssertEqual(project.selectedPaceRaw, PaceMode.balanced.rawValue)
        XCTAssertEqual(project.statusRaw, ProjectStatus.assembling.rawValue)
        XCTAssertEqual(project.activeSlotIndex, 0)

        let count = try await store.slotCount(projectID: projectID)
        XCTAssertEqual(count, expected.count)
    }

    // MARK: - revertToPaceSelection (sans association, §65)

    func testRevertWithoutAssignmentClearsSlotsAndAllowsReselection() async throws {
        let projectID = try await store.createDraft()
        let family = makeFamily()
        try await store.selectPace(.balanced, from: family, projectID: projectID)
        try await store.setActiveSlot(index: 1, projectID: projectID)

        try await store.revertToPaceSelection(projectID: projectID)

        // Cases effacées, rythme désélectionné, retour au choix du rythme.
        let countAfterRevert = try await store.slotCount(projectID: projectID)
        XCTAssertEqual(countAfterRevert, 0, "Cases effacées (§65 : avant association, changer d'avis est libre)")
        var project = try projectState(projectID)
        XCTAssertNil(project.selectedPaceRaw)
        XCTAssertEqual(project.statusRaw, ProjectStatus.awaitingPaceSelection.rawValue)

        // Re-sélection d'un AUTRE mode : fonctionne et repart de zéro.
        try await store.selectPace(.percussive, from: family, projectID: projectID)
        let slots = try persistedSlots(projectID: projectID)
        XCTAssertEqual(slots.count, family.percussive.slots.count)
        XCTAssertEqual(slots.map(\.startTicks), family.percussive.slots.map(\.start.ticks))
        XCTAssertEqual(slots.map(\.endTicks), family.percussive.slots.map(\.end.ticks))
        XCTAssertTrue(slots.allSatisfy { $0.scoreModeRaw == PaceMode.percussive.rawValue })
        project = try projectState(projectID)
        XCTAssertEqual(project.selectedPaceRaw, PaceMode.percussive.rawValue)
        XCTAssertEqual(project.statusRaw, ProjectStatus.assembling.rawValue)
        XCTAssertEqual(project.activeSlotIndex, 0, "Case active remise à 0 à la re-sélection")
    }

    // MARK: - Verrouillage après association (§65, §81, §89)

    func testAssignmentLocksSelectPaceRevertAndClearSlots() async throws {
        let projectID = try await store.createDraft()
        let family = makeFamily()
        try await store.selectPace(.balanced, from: family, projectID: projectID)
        try insertAssignment(projectID: projectID)

        let locked = try await store.hasAssignments(projectID: projectID)
        XCTAssertTrue(locked, "Association présente → rythme verrouillé (§81)")
        let before = try persistedSlots(projectID: projectID)

        do {
            try await store.selectPace(.percussive, from: family, projectID: projectID)
            XCTFail("selectPace doit échouer après association (§65)")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .paceLockedByAssignments(projectID))
        }
        do {
            try await store.revertToPaceSelection(projectID: projectID)
            XCTFail("revertToPaceSelection doit échouer après association (§65)")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .paceLockedByAssignments(projectID))
        }
        do {
            try await store.clearSlots(projectID: projectID)
            XCTFail("clearSlots doit échouer après association (§65)")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .paceLockedByAssignments(projectID))
        }

        // Cases INTACTES : mêmes identifiants, mêmes ticks, même association
        // (§65 : proposer duplication, pas mutation destructive ; §89 :
        // jamais de perte d'association).
        let after = try persistedSlots(projectID: projectID)
        XCTAssertEqual(after, before, "Cases strictement intactes (§65, §89)")
        XCTAssertEqual(after.compactMap(\.assignmentID).count, 1, "Association conservée")
        let project = try projectState(projectID)
        XCTAssertEqual(project.selectedPaceRaw, PaceMode.balanced.rawValue, "Rythme choisi inchangé")
        XCTAssertEqual(project.statusRaw, ProjectStatus.assembling.rawValue, "Statut inchangé")
    }

    // MARK: - ScoreLibrary (§61)

    func testScoreLibraryRoundTripLoadsFamilyAndIsCurrent() throws {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        let family = makeFamily()
        try writeScores(family, projectID: projectID)
        try writeMeta(
            generatorVersion: DeterministicEditScoreGenerator.generatorVersion,
            configurationFingerprint: ScoreConfigurationFingerprint.fingerprint(of: .production),
            projectID: projectID
        )

        let library = ScoreLibrary(fileStore: fileStore)
        let loaded = try XCTUnwrap(library.loadScores(projectID: projectID), "scores-v1.json présent → famille décodée")
        XCTAssertEqual(loaded.analysisVersion, family.analysisVersion)
        for (original, redecoded) in [
            (family.fluid, loaded.fluid),
            (family.balanced, loaded.balanced),
            (family.percussive, loaded.percussive),
        ] {
            XCTAssertEqual(redecoded.mode, original.mode)
            XCTAssertEqual(redecoded.slots.map(\.id), original.slots.map(\.id))
            XCTAssertEqual(redecoded.slots.map(\.start.ticks), original.slots.map(\.start.ticks))
            XCTAssertEqual(redecoded.slots.map(\.end.ticks), original.slots.map(\.end.ticks))
        }
        XCTAssertTrue(library.scoresAreCurrent(projectID: projectID), "Méta cohérente → partitions à jour (§61)")

        // Déterminisme de l'empreinte partagée : deux configurations égales
        // → même empreinte (écriture et vérification comparables).
        XCTAssertEqual(
            try ScoreConfigurationFingerprint.fingerprint(of: .production),
            try ScoreConfigurationFingerprint.fingerprint(of: ScoreConfiguration())
        )
    }

    func testScoreLibraryMissingMetaIsStale() throws {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        try writeScores(makeFamily(), projectID: projectID)

        let library = ScoreLibrary(fileStore: fileStore)
        XCTAssertNotNil(library.loadScores(projectID: projectID))
        XCTAssertFalse(
            library.scoresAreCurrent(projectID: projectID),
            "Méta absente → partitions périmées (§61)"
        )
    }

    func testScoreLibraryGeneratorVersionMismatchIsStale() throws {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        try writeScores(makeFamily(), projectID: projectID)
        try writeMeta(
            generatorVersion: DeterministicEditScoreGenerator.generatorVersion + 1,
            configurationFingerprint: ScoreConfigurationFingerprint.fingerprint(of: .production),
            projectID: projectID
        )

        let library = ScoreLibrary(fileStore: fileStore)
        XCTAssertFalse(
            library.scoresAreCurrent(projectID: projectID),
            "Générateur ayant évolué → partitions périmées (§61 : régénération explicite, jamais silencieuse)"
        )
    }

    func testScoreLibraryConfigurationFingerprintMismatchIsStale() throws {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        try writeScores(makeFamily(), projectID: projectID)
        // Empreinte d'une configuration DIFFÉRENTE de la production.
        var otherConfiguration = ScoreConfiguration()
        otherConfiguration.rhythmicStrength += 1.0
        try writeMeta(
            generatorVersion: DeterministicEditScoreGenerator.generatorVersion,
            configurationFingerprint: ScoreConfigurationFingerprint.fingerprint(of: otherConfiguration),
            projectID: projectID
        )

        let library = ScoreLibrary(fileStore: fileStore)
        XCTAssertFalse(
            library.scoresAreCurrent(projectID: projectID),
            "Configuration ayant évolué → partitions périmées (§61)"
        )
    }

    func testScoreLibraryLoadScoresNilWhenAbsentOrUnreadable() throws {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        let library = ScoreLibrary(fileStore: fileStore)

        XCTAssertNil(library.loadScores(projectID: projectID), "Fichier absent → nil")

        // Fichier illisible (JSON corrompu) → nil, jamais de crash.
        let url = fileStore.directory(for: projectID)
            .appending(path: AudioAnalysisActor.scoresRelativePath)
        try Data("{ pas du JSON".utf8).write(to: url)
        XCTAssertNil(library.loadScores(projectID: projectID), "Fichier illisible → nil")
    }

    func testScoreLibraryAnalysisVersionMismatchIsStale() throws {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        try writeScores(makeFamily(), projectID: projectID)
        try writeMeta(
            generatorVersion: DeterministicEditScoreGenerator.generatorVersion,
            configurationFingerprint: ScoreConfigurationFingerprint.fingerprint(of: .production),
            analysisVersion: DeterministicMusicAnalyzer.engineVersion + 1,
            projectID: projectID
        )

        let library = ScoreLibrary(fileStore: fileStore)
        XCTAssertFalse(
            library.scoresAreCurrent(projectID: projectID),
            "Moteur d'analyse ayant évolué → partitions périmées (§61)"
        )
    }

    // MARK: - §65 : duplication pour changer de rythme

    func testDuplicateForPaceChangeUnlocksCopyAndKeepsOriginalIntact() async throws {
        let projectID = try await store.createDraft()
        try await store.selectPace(.balanced, from: makeFamily(), projectID: projectID)
        try insertAssignment(projectID: projectID)
        let originalSlots = try persistedSlots(projectID: projectID)

        let copyID = try await store.duplicateForPaceChange(projectID: projectID)

        // La copie repart au choix du rythme, SANS cases ni associations.
        let copyState = try projectState(copyID)
        XCTAssertNil(copyState.selectedPaceRaw)
        XCTAssertEqual(copyState.statusRaw, ProjectStatus.awaitingPaceSelection.rawValue)
        XCTAssertEqual(copyState.activeSlotIndex, 0)
        XCTAssertTrue(try persistedSlots(projectID: copyID).isEmpty)
        let copyHasAssignments = try await store.hasAssignments(projectID: copyID)
        XCTAssertFalse(copyHasAssignments)

        // `selectPace` RÉUSSIT sur la copie (§65 : une issue réelle, pas une
        // boucle de duplications toutes verrouillées).
        try await store.selectPace(.percussive, from: makeFamily(), projectID: copyID)
        XCTAssertEqual(try projectState(copyID).selectedPaceRaw, PaceMode.percussive.rawValue)

        // L'original est STRICTEMENT intact (cases, association, rythme).
        XCTAssertEqual(try persistedSlots(projectID: projectID), originalSlots)
        let originalHasAssignments = try await store.hasAssignments(projectID: projectID)
        XCTAssertTrue(originalHasAssignments)
        XCTAssertEqual(try projectState(projectID).selectedPaceRaw, PaceMode.balanced.rawValue)
    }

    // MARK: - §10.1 : insertion refusée après association

    func testInsertSlotsRefusedAfterAssignment() async throws {
        let projectID = try await store.createDraft()
        try await store.selectPace(.fluid, from: makeFamily(), projectID: projectID)
        try insertAssignment(projectID: projectID)
        let before = try persistedSlots(projectID: projectID)

        do {
            try await store.insertSlots(
                [makeSlot(index: 10, startTicks: 240_000, endTicks: 300_000)],
                scoreMode: .fluid,
                projectID: projectID
            )
            XCTFail("insertSlots doit être refusé après association (§10.1/§65)")
        } catch ProjectStoreError.paceLockedByAssignments {
            // Attendu : les temps des cases sont gelés.
        }
        XCTAssertEqual(try persistedSlots(projectID: projectID), before, "Cases inchangées")
    }

    // MARK: - Instantanés de vérification (valeurs pures, jamais de
    // `PersistentModel` hors de son contexte)

    private struct SlotSnapshot: Equatable {
        let id: UUID
        let index: Int
        let scoreModeRaw: String
        let startTicks: Int64
        let endTicks: Int64
        let entryAnchorID: UUID
        let exitAnchorID: UUID
        let assignmentID: UUID?
    }

    private struct ProjectSnapshot {
        let selectedPaceRaw: String?
        let statusRaw: String
        let activeSlotIndex: Int
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
                scoreModeRaw: $0.scoreModeRaw,
                startTicks: $0.startTicks,
                endTicks: $0.endTicks,
                entryAnchorID: $0.entryAnchorID,
                exitAnchorID: $0.exitAnchorID,
                assignmentID: $0.assignmentID
            )
        }
    }

    private func projectState(_ id: UUID) throws -> ProjectSnapshot {
        let context = ModelContext(container)
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<ProjectRecord>(
            predicate: #Predicate<ProjectRecord> { $0.id == id }
        )).first)
        return ProjectSnapshot(
            selectedPaceRaw: record.selectedPaceRaw,
            statusRaw: record.statusRaw,
            activeSlotIndex: record.activeSlotIndex
        )
    }

    // MARK: - Fabriques (insertion « à la main »)

    /// Insère « à la main » une association sur la première case du projet
    /// (pattern du test cascade de `ProjectStoreTests`) : enregistrement
    /// §13.3 + référence croisée `assignmentID` sur la case.
    private func insertAssignment(projectID: UUID) throws {
        let context = ModelContext(container)
        let slot = try XCTUnwrap(try context.fetch(FetchDescriptor<ProjectSlotRecord>(
            predicate: #Predicate<ProjectSlotRecord> { $0.projectID == projectID },
            sortBy: [SortDescriptor(\ProjectSlotRecord.index)]
        )).first, "Une case est requise pour poser une association")
        let assignmentID = UUID()
        slot.assignmentID = assignmentID
        context.insert(ClipAssignmentRecord(
            id: assignmentID,
            projectID: projectID,
            slotID: slot.id,
            assetLocalIdentifier: "asset-temoin",
            sourceStartTicks: 0, // V1 : toujours 0 (§13.3)
            requiredDurationTicks: slot.durationTicks,
            observedAssetDurationTicks: 600_000,
            statusRaw: ClipAssignmentStatus.ready.rawValue,
            assignedAt: Date(timeIntervalSinceNow: -60)
        ))
        try context.save()
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

    /// Partition synthétique contiguë (§28.1 : frontières triées, sans
    /// trous) construite depuis une liste de frontières en ticks.
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

    /// Famille synthétique directe (plus simple et suffisant que le
    /// générateur réel) : trois modes imbriqués sur 4 s — Fluide 1 case,
    /// Équilibré 2, Percutant 4 (densité croissante, mêmes frontières
    /// majeures — §2).
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

    // MARK: - Fichiers §11 (écriture comme l'acteur)

    /// Écrit `analysis/scores-v1.json` comme l'acteur (clés triées).
    private func writeScores(_ family: EditScoreFamily, projectID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(family)
        let url = fileStore.directory(for: projectID)
            .appending(path: AudioAnalysisActor.scoresRelativePath)
        try data.write(to: url)
    }

    /// Écrit `analysis/scores-meta-v1.json` (§61) avec le schéma UNIQUE
    /// `ScoresMeta` (partagé avec l'acteur et `ScoreLibrary`) — un renommage
    /// de champ casse la compilation ici aussi, jamais de dérive silencieuse.
    private func writeMeta(
        generatorVersion: Int,
        configurationFingerprint: String,
        analysisVersion: Int = DeterministicMusicAnalyzer.engineVersion,
        projectID: UUID
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ScoresMeta(
            generatorVersion: generatorVersion,
            configurationFingerprint: configurationFingerprint,
            analysisVersion: analysisVersion
        ))
        let url = fileStore.directory(for: projectID)
            .appending(path: AudioAnalysisActor.scoresMetaRelativePath)
        try data.write(to: url)
    }
}
