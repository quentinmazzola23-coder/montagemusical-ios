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
//    configuration partagée `ScoreConfigurationFingerprint` + version de
//    SCHÉMA d'analyse) ;
//  - §69 : la version de MOTEUR d'analyse est tracée dans la méta mais ne
//    périme PAS les partitions — sans quoi la moindre correction de bug du
//    moteur imposerait un recalcul à tous les projets de tous les
//    utilisateurs ;
//  - §61 « version du modèle Core ML » : champ `coreMLModelVersion` tracé,
//    absent du JSON quand il vaut `nil` (aucun modèle embarqué §29A), et
//    décodage TOLÉRANT d'une méta écrite avant l'ajout du champ — un projet
//    existant ne devient pas périmé pour cette seule raison.
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

        try await store.selectPace(.everyTwoBeats, from: family, projectID: projectID)

        // Cases persistées == cases de la partition Équilibré (ticks §9
        // exacts, ancres conservées), UNIQUEMENT le mode choisi (§11 : les
        // trois partitions complètes restent dans scores-v1.json).
        let slots = try persistedSlots(projectID: projectID)
        let expected = family.everyTwoBeats.slots
        XCTAssertEqual(slots.count, expected.count, "Cases du mode choisi uniquement")
        XCTAssertEqual(slots.map(\.index), expected.map(\.index))
        XCTAssertEqual(slots.map(\.startTicks), expected.map(\.start.ticks), "Frontières de début exactes (§9)")
        XCTAssertEqual(slots.map(\.endTicks), expected.map(\.end.ticks), "Frontières de fin exactes (§9)")
        XCTAssertEqual(slots.map(\.entryAnchorID), expected.map(\.entryAnchorID))
        XCTAssertEqual(slots.map(\.exitAnchorID), expected.map(\.exitAnchorID))
        XCTAssertTrue(
            slots.allSatisfy { $0.scoreModeRaw == PaceMode.everyTwoBeats.rawValue },
            "scoreModeRaw == balanced pour toutes les cases"
        )
        XCTAssertTrue(slots.allSatisfy { $0.assignmentID == nil }, "Aucune association à l'insertion")

        // Projet : rythme choisi, statut assembling, case active 0 (§59).
        let project = try projectState(projectID)
        XCTAssertEqual(project.selectedPaceRaw, PaceMode.everyTwoBeats.rawValue)
        XCTAssertEqual(project.statusRaw, ProjectStatus.assembling.rawValue)
        XCTAssertEqual(project.activeSlotIndex, 0)

        let count = try await store.slotCount(projectID: projectID)
        XCTAssertEqual(count, expected.count)
    }

    // MARK: - revertToPaceSelection (sans association, §65)

    func testRevertWithoutAssignmentClearsSlotsAndAllowsReselection() async throws {
        let projectID = try await store.createDraft()
        let family = makeFamily()
        try await store.selectPace(.everyTwoBeats, from: family, projectID: projectID)
        try await store.setActiveSlot(index: 1, projectID: projectID)

        try await store.revertToPaceSelection(projectID: projectID)

        // Cases effacées, rythme désélectionné, retour au choix du rythme.
        let countAfterRevert = try await store.slotCount(projectID: projectID)
        XCTAssertEqual(countAfterRevert, 0, "Cases effacées (§65 : avant association, changer d'avis est libre)")
        var project = try projectState(projectID)
        XCTAssertNil(project.selectedPaceRaw)
        XCTAssertEqual(project.statusRaw, ProjectStatus.awaitingPaceSelection.rawValue)

        // Re-sélection d'un AUTRE mode : fonctionne et repart de zéro.
        try await store.selectPace(.everyFourBeats, from: family, projectID: projectID)
        let slots = try persistedSlots(projectID: projectID)
        XCTAssertEqual(slots.count, family.everyFourBeats.slots.count)
        XCTAssertEqual(slots.map(\.startTicks), family.everyFourBeats.slots.map(\.start.ticks))
        XCTAssertEqual(slots.map(\.endTicks), family.everyFourBeats.slots.map(\.end.ticks))
        XCTAssertTrue(slots.allSatisfy { $0.scoreModeRaw == PaceMode.everyFourBeats.rawValue })
        project = try projectState(projectID)
        XCTAssertEqual(project.selectedPaceRaw, PaceMode.everyFourBeats.rawValue)
        XCTAssertEqual(project.statusRaw, ProjectStatus.assembling.rawValue)
        XCTAssertEqual(project.activeSlotIndex, 0, "Case active remise à 0 à la re-sélection")
    }

    // MARK: - Verrouillage après association (§65, §81, §89)

    func testAssignmentLocksSelectPaceRevertAndClearSlots() async throws {
        let projectID = try await store.createDraft()
        let family = makeFamily()
        try await store.selectPace(.everyTwoBeats, from: family, projectID: projectID)
        try insertAssignment(projectID: projectID)

        let locked = try await store.hasAssignments(projectID: projectID)
        XCTAssertTrue(locked, "Association présente → rythme verrouillé (§81)")
        let before = try persistedSlots(projectID: projectID)

        do {
            try await store.selectPace(.everyFourBeats, from: family, projectID: projectID)
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
        XCTAssertEqual(project.selectedPaceRaw, PaceMode.everyTwoBeats.rawValue, "Rythme choisi inchangé")
        XCTAssertEqual(project.statusRaw, ProjectStatus.assembling.rawValue, "Statut inchangé")
    }

    // MARK: - ScoreLibrary (§61)

    func testScoreLibraryRoundTripLoadsFamilyAndIsCurrent() throws {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        let family = makeFamily()
        try writeScores(family, projectID: projectID)
        try writeMeta(
            generatorVersion: BeatGridEditScoreGenerator.generatorVersion,
            configurationFingerprint: ScoreConfigurationFingerprint.fingerprint(of: .production),
            projectID: projectID
        )

        let library = ScoreLibrary(fileStore: fileStore)
        let loaded = try XCTUnwrap(library.loadScores(projectID: projectID), "scores-v1.json présent → famille décodée")
        XCTAssertEqual(loaded.analysisVersion, family.analysisVersion)
        for (original, redecoded) in [
            (family.everyBeat, loaded.everyBeat),
            (family.everyTwoBeats, loaded.everyTwoBeats),
            (family.everyFourBeats, loaded.everyFourBeats),
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
            generatorVersion: BeatGridEditScoreGenerator.generatorVersion + 1,
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
            generatorVersion: BeatGridEditScoreGenerator.generatorVersion,
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

    func testScoreLibraryAnalysisSchemaVersionMismatchIsStale() throws {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        try writeScores(makeFamily(), projectID: projectID)
        try writeMeta(
            generatorVersion: BeatGridEditScoreGenerator.generatorVersion,
            configurationFingerprint: ScoreConfigurationFingerprint.fingerprint(of: .production),
            analysisVersion: DeterministicMusicAnalyzer.analysisSchemaVersion + 1,
            projectID: projectID
        )

        let library = ScoreLibrary(fileStore: fileStore)
        XCTAssertFalse(
            library.scoresAreCurrent(projectID: projectID),
            "SCHÉMA d'analyse ayant évolué → partitions périmées (§61) : elles ont été tirées d'un document d'une autre forme"
        )
    }

    // MARK: - §61/§69 : la version de MOTEUR ne périme plus les partitions

    /// Remplace l'ancien test « moteur d'analyse ayant évolué → périmé ».
    /// La propriété a changé volontairement, et c'est le cœur du correctif :
    /// tant que `ScoreLibrary` comparait `analysisVersion` à
    /// `engineVersion`, tout incrément du moteur — jusqu'à la plus petite
    /// correction de bug — périmait d'un seul coup le cache d'analyse ET les
    /// partitions de TOUS les projets de TOUS les utilisateurs. La promesse
    /// §69 (« une nouvelle partition ne doit pas obligatoirement redécoder la
    /// musique ») ne couvrait alors que le cas rare (changement de
    /// `ScoreConfiguration`) et tombait exactement dans le cas fréquent.
    ///
    /// Ce test fige la nouvelle règle : ce qui périme une partition, c'est le
    /// SCHÉMA du résultat d'analyse, le générateur ou sa configuration —
    /// jamais la version d'algorithme, qui reste TRACÉE dans la méta.
    func testScoresStayCurrentWhateverTheAnalysisEngineVersionTraced() throws {
        // Garde-fou : les deux axes doivent rester distincts, sinon ce test
        // ne prouverait rien (il coïnciderait avec le précédent).
        XCTAssertNotEqual(
            DeterministicMusicAnalyzer.analysisSchemaVersion,
            DeterministicMusicAnalyzer.engineVersion,
            "Schéma et moteur sont deux axes de version distincts"
        )

        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        try writeScores(makeFamily(), projectID: projectID)

        // Méta produite par un moteur ANCIEN (v2) et par un moteur FUTUR
        // (v+1) : dans les deux cas le schéma est le bon, donc les partitions
        // restent à jour — aucune régénération imposée à un projet terminé.
        for tracedEngineVersion in [2, DeterministicMusicAnalyzer.engineVersion + 1] {
            try writeMeta(
                generatorVersion: BeatGridEditScoreGenerator.generatorVersion,
                configurationFingerprint: ScoreConfigurationFingerprint.fingerprint(of: .production),
                analysisEngineVersion: tracedEngineVersion,
                projectID: projectID
            )
            let library = ScoreLibrary(fileStore: fileStore)
            XCTAssertTrue(
                library.scoresAreCurrent(projectID: projectID),
                "Moteur v\(tracedEngineVersion) : la version d'ALGORITHME est tracée, jamais discriminante (§61, §69)"
            )
        }

        // Et la trace est bien relue telle qu'écrite (explicabilité §29 :
        // « quel moteur a produit ce montage ? »).
        let url = fileStore.directory(for: projectID)
            .appending(path: AudioAnalysisActor.scoresMetaRelativePath)
        let meta = try JSONDecoder().decode(ScoresMeta.self, from: Data(contentsOf: url))
        XCTAssertEqual(meta.analysisEngineVersion, DeterministicMusicAnalyzer.engineVersion + 1)
        XCTAssertEqual(meta.analysisVersion, DeterministicMusicAnalyzer.analysisSchemaVersion)
    }

    /// Migration : les `scores-meta-v1.json` écrits AVANT le découplage ne
    /// portent pas `analysisEngineVersion` — leur décodage doit rester
    /// possible (le champ est optionnel), et leur verdict de validité ne doit
    /// dépendre que des trois clés historiques.
    func testLegacyScoresMetaWithoutEngineVersionStaysReadable() throws {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        try writeScores(makeFamily(), projectID: projectID)
        try writeMeta(
            generatorVersion: BeatGridEditScoreGenerator.generatorVersion,
            configurationFingerprint: ScoreConfigurationFingerprint.fingerprint(of: .production),
            analysisEngineVersion: nil,
            projectID: projectID
        )

        let url = fileStore.directory(for: projectID)
            .appending(path: AudioAnalysisActor.scoresMetaRelativePath)
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(
            raw.contains("analysisEngineVersion"),
            "Version de moteur nulle → clé absente du JSON, forme identique aux métas déjà sur disque"
        )
        let library = ScoreLibrary(fileStore: fileStore)
        XCTAssertTrue(
            library.scoresAreCurrent(projectID: projectID),
            "L'ajout du champ de trace ne périme AUCUN projet existant (§61)"
        )
    }

    // MARK: - §61 : version du modèle Core ML tracée

    func testScoresMetaKeepsCoreMLModelVersionAndStaysReadableWithoutIt() throws {
        // 1. Aujourd'hui, aucun modèle n'est embarqué (§29A/§86) : le registre
        //    rend `nil` et la méta l'écrit tel quel — l'ABSENCE de version est
        //    la trace exigée par §61, jamais une chaîne inventée.
        XCTAssertNil(
            CoreMLModelRegistry.beatActivationModelVersion(),
            "Aucun modèle embarqué → aucune version (§29A)"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let withoutModel = ScoresMeta(
            generatorVersion: BeatGridEditScoreGenerator.generatorVersion,
            configurationFingerprint: "empreinte",
            analysisVersion: DeterministicMusicAnalyzer.analysisSchemaVersion,
            coreMLModelVersion: CoreMLModelRegistry.beatActivationModelVersion()
        )
        let encodedWithoutModel = try encoder.encode(withoutModel)
        // Une version absente n'écrit AUCUNE clé : les métas déjà sur disque
        // gardent exactement la même forme (§61 : rien n'est périmé par cet
        // ajout de champ).
        XCTAssertFalse(
            String(decoding: encodedWithoutModel, as: UTF8.self).contains("coreMLModelVersion"),
            "Version nulle → clé absente du JSON"
        )
        XCTAssertNil(try JSONDecoder().decode(ScoresMeta.self, from: encodedWithoutModel).coreMLModelVersion)

        // 2. Aller-retour d'une version RÉELLE (le jour où un modèle sera livré).
        let withModel = ScoresMeta(
            generatorVersion: 3,
            configurationFingerprint: "empreinte",
            analysisVersion: 2,
            coreMLModelVersion: "beat-activation-1.2.0"
        )
        let redecoded = try JSONDecoder().decode(ScoresMeta.self, from: encoder.encode(withModel))
        XCTAssertEqual(redecoded.coreMLModelVersion, "beat-activation-1.2.0")
        XCTAssertEqual(redecoded.generatorVersion, 3)
        XCTAssertEqual(redecoded.analysisVersion, 2)

        // 3. TOLÉRANCE : une méta écrite AVANT l'ajout du champ (JSON sans la
        //    clé) reste décodable — sinon toutes les partitions existantes
        //    passeraient périmées et seraient proposées au recalcul sans
        //    raison (§61 : jamais de recalcul non justifié).
        let legacyJSON = """
        {"analysisVersion":\(DeterministicMusicAnalyzer.analysisSchemaVersion),\
        "configurationFingerprint":"empreinte",\
        "generatorVersion":\(BeatGridEditScoreGenerator.generatorVersion)}
        """
        let legacy = try JSONDecoder().decode(ScoresMeta.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.coreMLModelVersion, "Champ absent → nil, jamais une erreur de décodage")
        XCTAssertNil(
            legacy.analysisEngineVersion,
            "Version de moteur absente → nil : les trois clés historiques suffisent à décoder (§61)"
        )
        XCTAssertEqual(legacy.generatorVersion, BeatGridEditScoreGenerator.generatorVersion)
    }

    func testScoresAreCurrentIgnoresCoreMLModelVersion() throws {
        // §61 : la version du modèle est CONSERVÉE mais ne tranche pas la
        // validité aujourd'hui (aucun modèle embarqué). Une méta cohérente
        // portant une version reste donc « à jour » : ce test fige ce choix,
        // pour qu'un changement de règle soit délibéré et non subi.
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        try writeScores(makeFamily(), projectID: projectID)
        try writeMeta(
            generatorVersion: BeatGridEditScoreGenerator.generatorVersion,
            configurationFingerprint: ScoreConfigurationFingerprint.fingerprint(of: .production),
            projectID: projectID,
            coreMLModelVersion: "beat-activation-1.2.0"
        )

        let library = ScoreLibrary(fileStore: fileStore)
        XCTAssertTrue(
            library.scoresAreCurrent(projectID: projectID),
            "Version de modèle tracée mais non discriminante (§61)"
        )
    }

    // MARK: - §65 : duplication pour changer de rythme

    func testDuplicateForPaceChangeUnlocksCopyAndKeepsOriginalIntact() async throws {
        let projectID = try await store.createDraft()
        try await store.selectPace(.everyTwoBeats, from: makeFamily(), projectID: projectID)
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
        try await store.selectPace(.everyFourBeats, from: makeFamily(), projectID: copyID)
        XCTAssertEqual(try projectState(copyID).selectedPaceRaw, PaceMode.everyFourBeats.rawValue)

        // L'original est STRICTEMENT intact (cases, association, rythme).
        XCTAssertEqual(try persistedSlots(projectID: projectID), originalSlots)
        let originalHasAssignments = try await store.hasAssignments(projectID: projectID)
        XCTAssertTrue(originalHasAssignments)
        XCTAssertEqual(try projectState(projectID).selectedPaceRaw, PaceMode.everyTwoBeats.rawValue)
    }

    // MARK: - §10.1 : insertion refusée après association

    func testInsertSlotsRefusedAfterAssignment() async throws {
        let projectID = try await store.createDraft()
        try await store.selectPace(.everyBeat, from: makeFamily(), projectID: projectID)
        try insertAssignment(projectID: projectID)
        let before = try persistedSlots(projectID: projectID)

        do {
            try await store.insertSlots(
                [makeSlot(index: 10, startTicks: 240_000, endTicks: 300_000)],
                scoreMode: .everyBeat,
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
    /// générateur réel) : trois familles de frappe sur 4 s — kick 1 case,
    /// snare 2, hat 4.
    ///
    /// Les frontières sont ici emboîtées par simple commodité d'écriture, et
    /// non par contrat : l'imbrication §70 (Fluide ⊆ Équilibré ⊆ Percutant) a
    /// DISPARU avec le pivot du 16 août 2026 — voir `PaceMode`. Aucun test de
    /// ce fichier n'en dépend ; ces cases ne servent qu'à fournir des
    /// frontières valides au `ProjectStore`.
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
        analysisVersion: Int = DeterministicMusicAnalyzer.analysisSchemaVersion,
        analysisEngineVersion: Int? = DeterministicMusicAnalyzer.engineVersion,
        projectID: UUID,
        coreMLModelVersion: String? = nil
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ScoresMeta(
            generatorVersion: generatorVersion,
            configurationFingerprint: configurationFingerprint,
            analysisVersion: analysisVersion,
            analysisEngineVersion: analysisEngineVersion,
            coreMLModelVersion: coreMLModelVersion
        ))
        let url = fileStore.directory(for: projectID)
            .appending(path: AudioAnalysisActor.scoresMetaRelativePath)
        try data.write(to: url)
    }
}
