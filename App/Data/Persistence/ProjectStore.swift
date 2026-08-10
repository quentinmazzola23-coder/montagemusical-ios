//
//  ProjectStore.swift
//  MontageMusical
//
//  Acteur de persistance des projets — spec §8 (« ProjectStoreActor :
//  cohérence des écritures projet »), §10, §10.1, §31, §59, §65, §69A.
//

import Foundation
import SwiftData

// Non defini par la specification — definition minimale V1.
/// Erreurs du magasin de projets.
enum ProjectStoreError: Error, Equatable {
    case projectNotFound(UUID)
    /// §10.1 : `endTicks` doit être strictement supérieur à `startTicks`.
    case invalidSlotDuration(index: Int)
    /// §10.1 : unicité logique `(projectID, scoreModeRaw, index)` violée.
    case duplicateSlotKey(scoreModeRaw: String, index: Int)
    /// §10.1 : index strictement croissant au sein d'un lot inséré.
    case nonIncreasingSlotIndex(scoreModeRaw: String, index: Int)
}

/// Acteur dédié à la cohérence des écritures projet (spec §8). Toutes les
/// lectures et écritures SwiftData des projets passent par cet acteur ;
/// les vues et view models restent sur `@MainActor`.
///
/// Autosauvegarde (spec §59, §3.13) : il n'existe aucun bouton
/// « Enregistrer » — chaque mutation met à jour `updatedAt` et se termine
/// par un `save()` explicite.
@ModelActor
actor ProjectStore {

    /// Fichiers lourds hors SwiftData (spec §11).
    ///
    /// Valeur par défaut requise : l'init généré par `@ModelActor`
    /// (`init(modelContainer:)`, utilisé en production par
    /// `AppEnvironment`) n'initialise pas les propriétés ajoutées.
    private var fileStore = ProjectFileStore()

    // Non defini par la specification — definition minimale V1 :
    // init d'injection pour les tests (conteneur en mémoire + racine de
    // fichiers temporaire).
    init(modelContainer: ModelContainer, fileStore: ProjectFileStore) {
        let modelContext = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.modelContainer = modelContainer
        self.fileStore = fileStore
    }

    // MARK: - Création

    /// Crée un projet brouillon (spec §31 : action `+` → créer le projet,
    /// générer le titre) : titre automatique §10, statut `.draft`,
    /// `activeSlotIndex` 0, puis crée l'arbre de dossiers §11.
    func createDraft(now: Date = .now) throws -> UUID {
        let projectID = UUID()
        let record = ProjectRecord(
            id: projectID,
            automaticTitle: automaticProjectTitle(date: now),
            customTitle: nil,
            createdAt: now,
            updatedAt: now,
            statusRaw: ProjectStatus.draft.rawValue,
            selectedPaceRaw: nil,
            activeSlotIndex: 0,
            audioRelativePath: nil,
            analysisRelativePath: nil,
            geometryData: nil,
            lastAlbumIdentifier: nil,
            analysisVersion: 0,
            scoreVersion: 0
        )
        // Arbre §11 AVANT la persistance : un échec disque ne laisse jamais
        // de brouillon fantôme sans dossier dans la liste.
        try fileStore.createDirectories(for: projectID)
        modelContext.insert(record)
        do {
            try modelContext.save() // autosauvegarde après création (§59)
        } catch {
            modelContext.rollback()
            try? fileStore.deleteDirectory(for: projectID)
            throw error
        }
        return projectID
    }

    // MARK: - Lecture

    /// Résumés de tous les projets, triés par `updatedAt` décroissant
    /// (liste de l'écran d'accueil, spec §31).
    func summaries() throws -> [ProjectSummary] {
        let descriptor = FetchDescriptor<ProjectRecord>(
            sortBy: [SortDescriptor(\ProjectRecord.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { try makeSummary($0) }
    }

    /// Résumé d'un projet, ou `nil` s'il n'existe pas.
    func summary(id: UUID) throws -> ProjectSummary? {
        guard let record = try fetchProject(id) else { return nil }
        return try makeSummary(record)
    }

    // MARK: - Renommage

    /// Renomme le projet (spec §31). Le titre est nettoyé des espaces de
    /// bord ; `nil` ou une chaîne vide rétablit le titre automatique
    /// (titre affiché = `customTitle ?? automaticTitle`, spec §10).
    func rename(projectID: UUID, customTitle: String?) throws {
        let record = try requireProject(projectID)
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        record.customTitle = trimmed.isEmpty ? nil : trimmed
        try touchAndSave(record)
    }

    // MARK: - Duplication

    /// Duplique un projet (spec §31 ; §65 : la duplication est l'alternative
    /// non destructive à la mutation ; §10.1 : la duplication est autorisée
    /// à copier les temps des cases).
    ///
    /// Copie l'enregistrement projet (nouvel identifiant, dates = `now`),
    /// toutes les cases et associations (nouveaux identifiants, références
    /// remappées) et le dossier de fichiers §11 s'il existe.
    func duplicate(projectID: UUID, now: Date = .now) throws -> UUID {
        let source = try requireProject(projectID)
        let newProjectID = UUID()

        // Titre de la copie : titre affiché source + « (copie) ».
        // Non defini par la specification — definition minimale V1.
        let sourceDisplayTitle = source.customTitle ?? source.automaticTitle

        let copy = ProjectRecord(
            id: newProjectID,
            automaticTitle: automaticProjectTitle(date: now),
            customTitle: sourceDisplayTitle + " (copie)",
            createdAt: now,
            updatedAt: now,
            // La copie reprend l'état fonctionnel de la source (statut,
            // rythme choisi, case active, dernier album) — cohérent avec
            // §65 : dupliquer pour continuer sans mutation destructive.
            // Non defini par la specification — definition minimale V1.
            statusRaw: source.statusRaw,
            selectedPaceRaw: source.selectedPaceRaw,
            activeSlotIndex: source.activeSlotIndex,
            audioRelativePath: source.audioRelativePath,
            analysisRelativePath: source.analysisRelativePath,
            geometryData: source.geometryData,
            lastAlbumIdentifier: source.lastAlbumIdentifier,
            analysisVersion: source.analysisVersion,
            scoreVersion: source.scoreVersion
        )
        modelContext.insert(copy)

        // Copie des cases et associations avec remappage des identifiants.
        let sourceSlots = try fetchSlots(projectID: projectID)
        let sourceAssignments = try fetchAssignments(projectID: projectID)

        var newSlotIDs: [UUID: UUID] = [:] // ancien id de case → nouveau
        for slot in sourceSlots {
            newSlotIDs[slot.id] = UUID()
        }
        var newAssignmentIDs: [UUID: UUID] = [:] // ancien id d'association → nouveau
        for assignment in sourceAssignments {
            newAssignmentIDs[assignment.id] = UUID()
        }

        for slot in sourceSlots {
            modelContext.insert(ProjectSlotRecord(
                id: newSlotIDs[slot.id] ?? UUID(),
                projectID: newProjectID,
                scoreModeRaw: slot.scoreModeRaw,
                index: slot.index,
                startTicks: slot.startTicks,
                endTicks: slot.endTicks,
                entryAnchorID: slot.entryAnchorID,
                exitAnchorID: slot.exitAnchorID,
                gestureID: slot.gestureID,
                assignmentID: slot.assignmentID.flatMap { newAssignmentIDs[$0] }
            ))
        }
        for assignment in sourceAssignments {
            modelContext.insert(ClipAssignmentRecord(
                id: newAssignmentIDs[assignment.id] ?? UUID(),
                projectID: newProjectID,
                slotID: newSlotIDs[assignment.slotID] ?? assignment.slotID,
                assetLocalIdentifier: assignment.assetLocalIdentifier,
                sourceStartTicks: assignment.sourceStartTicks,
                requiredDurationTicks: assignment.requiredDurationTicks,
                observedAssetDurationTicks: assignment.observedAssetDurationTicks,
                statusRaw: assignment.statusRaw,
                assignedAt: assignment.assignedAt
            ))
        }

        // Copie du dossier de fichiers §11 AVANT la sauvegarde SwiftData :
        // si la copie échoue, aucun enregistrement incohérent (audio pointé
        // mais absent) n'est persisté — §65 : la duplication est l'alternative
        // sûre, jamais d'état corrompu.
        let sourceDirectory = fileStore.directory(for: projectID)
        do {
            if FileManager.default.fileExists(atPath: sourceDirectory.path(percentEncoded: false)) {
                try FileManager.default.copyItem(
                    at: sourceDirectory,
                    to: fileStore.directory(for: newProjectID)
                )
            } else {
                try fileStore.createDirectories(for: newProjectID)
            }
            try modelContext.save() // autosauvegarde (§59)
        } catch {
            modelContext.rollback()
            try? fileStore.deleteDirectory(for: newProjectID)
            throw error
        }
        return newProjectID
    }

    // MARK: - Suppression

    /// Suppression définitive d'un projet, en cascade (spec §10.1 :
    /// suppression en cascade des cases et associations).
    ///
    /// Le schéma §10/§10.1/§13.3 est verbatim, sans relations SwiftData
    /// déclarées : la cascade est donc manuelle — toutes les
    /// `ProjectSlotRecord` et `ClipAssignmentRecord` du projet, puis le
    /// `ProjectRecord`, puis le dossier de fichiers §11.
    ///
    /// §31/§69A : ne supprime que les métadonnées, analyses, previews et
    /// temporaires créés par l'application — jamais les rushs de Photos.
    func delete(projectID: UUID) throws {
        for slot in try fetchSlots(projectID: projectID) {
            modelContext.delete(slot)
        }
        for assignment in try fetchAssignments(projectID: projectID) {
            modelContext.delete(assignment)
        }
        if let record = try fetchProject(projectID) {
            modelContext.delete(record)
        }
        try modelContext.save() // autosauvegarde (§59)
        try fileStore.deleteDirectory(for: projectID)
    }

    /// Supprime le projet seulement s'il s'agit d'un brouillon sans musique
    /// (spec §31 : « Un brouillon sans musique est supprimé au retour à
    /// l'accueil »). Retourne `true` si la suppression a eu lieu.
    @discardableResult
    func deleteIfEmptyDraft(projectID: UUID) throws -> Bool {
        guard let record = try fetchProject(projectID) else { return false }
        guard record.statusRaw == ProjectStatus.draft.rawValue,
              record.audioRelativePath == nil else {
            return false
        }
        try delete(projectID: projectID)
        return true
    }

    /// Supprime TOUS les brouillons sans musique (§31) — couvre les cas que
    /// le nettoyage au retour à l'accueil ne voit pas : app tuée par iOS avec
    /// un brouillon ouvert, brouillon dupliqué jamais ouvert, double création.
    /// `excluding` protège le projet actuellement ouvert.
    @discardableResult
    func deleteAllEmptyDrafts(excluding excludedID: UUID? = nil) throws -> Int {
        let draftRaw = ProjectStatus.draft.rawValue
        let drafts = try modelContext.fetch(FetchDescriptor<ProjectRecord>(
            predicate: #Predicate<ProjectRecord> {
                $0.statusRaw == draftRaw && $0.audioRelativePath == nil
            }
        ))
        var deletedCount = 0
        for record in drafts where record.id != excludedID {
            try delete(projectID: record.id)
            deletedCount += 1
        }
        return deletedCount
    }

    /// Maintenance au lancement (§69A : « supprimer les temporaires au
    /// prochain lancement après un crash ») :
    /// 1. brouillons vides résiduels (§31) ;
    /// 2. dossiers §11 orphelins — suppression interrompue entre la
    ///    sauvegarde SwiftData et la suppression du dossier ;
    /// 3. vidage des `temp/` de chaque projet existant.
    func performStartupMaintenance() throws {
        // §8 : reprise propre après relance — une app tuée pendant l'import
        // laisse un projet bloqué en `importingAudio` sans audio. Retour à
        // `draft` (le balayage §31 ci-dessous le supprime ensuite comme
        // brouillon vide).
        let importingRaw = ProjectStatus.importingAudio.rawValue
        let stuckImports = try modelContext.fetch(FetchDescriptor<ProjectRecord>(
            predicate: #Predicate<ProjectRecord> {
                $0.statusRaw == importingRaw && $0.audioRelativePath == nil
            }
        ))
        if !stuckImports.isEmpty {
            for record in stuckImports {
                record.statusRaw = ProjectStatus.draft.rawValue
            }
            try modelContext.save()
        }
        try deleteAllEmptyDrafts()
        let knownIDs = Set(try modelContext.fetch(FetchDescriptor<ProjectRecord>()).map(\.id))
        for orphanID in fileStore.projectDirectoryIDs() where !knownIDs.contains(orphanID) {
            try? fileStore.deleteDirectory(for: orphanID)
        }
        for projectID in knownIDs {
            fileStore.clearTemporaryFiles(projectID: projectID)
        }
    }

    // MARK: - Mutations d'état

    /// Change le statut du projet (spec §10).
    func setStatus(_ status: ProjectStatus, projectID: UUID) throws {
        let record = try requireProject(projectID)
        record.statusRaw = status.rawValue
        try touchAndSave(record)
    }

    /// Change la case active (spec §59 : sauvegarder après chaque
    /// changement de case active ; §60 : restaurée à la réouverture).
    func setActiveSlot(index: Int, projectID: UUID) throws {
        let record = try requireProject(projectID)
        record.activeSlotIndex = index
        try touchAndSave(record)
    }

    // MARK: - Audio (Jalon 3)

    /// Rattache un audio importé au projet (spec §11, §59 : sauvegarder
    /// après import audio ; annexe A `importMusic`).
    ///
    /// Pose `audioRelativePath` (chemin relatif au dossier du projet,
    /// `audio/original.<ext>` — §11, aucune URL externe conservée §78) et
    /// passe le statut à `.analyzing` : l'analyse réelle démarre au
    /// Jalon 4 ; le statut suit déjà l'annexe A.
    func attachAudio(_ imported: ImportedAudio, projectID: UUID) throws {
        let record = try requireProject(projectID)
        record.audioRelativePath = imported.relativePath
        record.statusRaw = ProjectStatus.analyzing.rawValue
        try touchAndSave(record) // updatedAt + autosauvegarde (§59)
    }

    /// Chemin relatif de l'audio du projet (`audio/original.<ext>`, §11),
    /// ou `nil` si aucune musique n'a encore été importée.
    func audioRelativePath(projectID: UUID) throws -> String? {
        try requireProject(projectID).audioRelativePath
    }

    // MARK: - Cases (point d'insertion Jalon 6)

    /// Point d'insertion unique des cases d'un projet. Les cases sont
    /// produites par le générateur de partition au Jalon 6 ; ce helper
    /// centralise dès maintenant l'écriture et sa validation.
    ///
    /// La signature ne prend que des valeurs `Sendable`
    /// (`EditSlotDefinition`) : les `ProjectSlotRecord` sont construits DANS
    /// l'acteur — aucun `PersistentModel` ne traverse la frontière.
    ///
    /// Contraintes §10.1 vérifiées par des erreurs typées (récupérables,
    /// jamais de crash en production), en plus du `#Unique` déclaré sur
    /// `ProjectSlotRecord` :
    /// - unicité logique `(projectID, scoreModeRaw, index)` — lot inséré
    ///   ET cases déjà persistées ;
    /// - `endTicks > startTicks` ;
    /// - index strictement croissant au sein du lot.
    ///
    /// « Une association maximum par case » et le gel des temps après
    /// verrouillage du rythme relèvent des Jalons 6–8.
    func insertSlots(
        _ definitions: [EditSlotDefinition],
        scoreMode: PaceMode,
        projectID: UUID
    ) throws {
        let record = try requireProject(projectID)

        var keys = Set<SlotKey>()
        for existing in try fetchSlots(projectID: projectID) {
            keys.insert(SlotKey(scoreModeRaw: existing.scoreModeRaw, index: existing.index))
        }
        var previousIndex: Int?
        for definition in definitions {
            guard definition.end.ticks > definition.start.ticks else {
                throw ProjectStoreError.invalidSlotDuration(index: definition.index)
            }
            if let previousIndex, definition.index <= previousIndex {
                throw ProjectStoreError.nonIncreasingSlotIndex(
                    scoreModeRaw: scoreMode.rawValue,
                    index: definition.index
                )
            }
            previousIndex = definition.index
            let inserted = keys.insert(
                SlotKey(scoreModeRaw: scoreMode.rawValue, index: definition.index)
            ).inserted
            guard inserted else {
                throw ProjectStoreError.duplicateSlotKey(
                    scoreModeRaw: scoreMode.rawValue,
                    index: definition.index
                )
            }
            modelContext.insert(ProjectSlotRecord(
                id: definition.id,
                projectID: projectID,
                scoreModeRaw: scoreMode.rawValue,
                index: definition.index,
                startTicks: definition.start.ticks,
                endTicks: definition.end.ticks,
                entryAnchorID: definition.entryAnchorID,
                exitAnchorID: definition.exitAnchorID,
                gestureID: definition.gestureID,
                assignmentID: nil
            ))
        }
        try touchAndSave(record)
    }

    // Non defini par la specification — definition minimale V1 :
    // clé d'unicité logique §10.1 (projectID fixé par l'appel).
    private struct SlotKey: Hashable {
        let scoreModeRaw: String
        let index: Int
    }

    // MARK: - Helpers privés

    /// Toute mutation met à jour `updatedAt` puis sauvegarde explicitement
    /// (autosauvegarde §59, pas de bouton « Enregistrer » §3.13).
    private func touchAndSave(_ record: ProjectRecord) throws {
        record.updatedAt = .now
        try modelContext.save()
    }

    private func makeSummary(_ record: ProjectRecord) throws -> ProjectSummary {
        ProjectSummary(
            id: record.id,
            displayTitle: record.customTitle ?? record.automaticTitle, // §10
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            // Repli `.draft` si statut inconnu (base corrompue) — jamais
            // attendu. Non defini par la specification — choix minimal V1.
            status: ProjectStatus(rawValue: record.statusRaw) ?? .draft,
            hasContent: try hasContent(record)
        )
    }

    /// §31 : la suppression demande confirmation si le projet contient une
    /// musique, des associations ou un export.
    private func hasContent(_ record: ProjectRecord) throws -> Bool {
        if record.audioRelativePath != nil { return true }
        if try assignmentCount(projectID: record.id) > 0 { return true }
        return fileStore.hasExportFiles(projectID: record.id)
    }

    private func fetchProject(_ id: UUID) throws -> ProjectRecord? {
        var descriptor = FetchDescriptor<ProjectRecord>(
            predicate: #Predicate<ProjectRecord> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func requireProject(_ id: UUID) throws -> ProjectRecord {
        guard let record = try fetchProject(id) else {
            throw ProjectStoreError.projectNotFound(id)
        }
        return record
    }

    private func fetchSlots(projectID: UUID) throws -> [ProjectSlotRecord] {
        try modelContext.fetch(FetchDescriptor<ProjectSlotRecord>(
            predicate: #Predicate<ProjectSlotRecord> { $0.projectID == projectID }
        ))
    }

    private func fetchAssignments(projectID: UUID) throws -> [ClipAssignmentRecord] {
        try modelContext.fetch(FetchDescriptor<ClipAssignmentRecord>(
            predicate: #Predicate<ClipAssignmentRecord> { $0.projectID == projectID }
        ))
    }

    private func assignmentCount(projectID: UUID) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<ClipAssignmentRecord>(
            predicate: #Predicate<ClipAssignmentRecord> { $0.projectID == projectID }
        ))
    }
}
