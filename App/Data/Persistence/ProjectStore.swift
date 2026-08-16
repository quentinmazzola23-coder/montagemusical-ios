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
    /// §65 : « changement de rythme après association : proposer duplication,
    /// pas mutation destructive » — dès qu'une association existe, les cases
    /// du projet ne peuvent plus être effacées ni remplacées (§81 :
    /// verrouillage après première association ; §89 : ne jamais perdre les
    /// associations).
    case paceLockedByAssignments(UUID)
    /// Jalon 8 : la case visée n'existe pas ou n'appartient pas au projet.
    /// Non defini par la specification — definition minimale V1.
    case slotNotFound(UUID)
    /// Jalon 8 : l'association visée n'existe pas ou n'appartient pas au
    /// projet. Non defini par la specification — definition minimale V1.
    case assignmentNotFound(UUID)
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

    /// Journal de la maintenance au lancement (§69A). Valeur par défaut
    /// requise pour la même raison que `fileStore` : l'init généré par
    /// `@ModelActor` n'initialise pas les propriétés ajoutées.
    private let logger = AppLogger(category: .app)

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
        try performDuplication(projectID: projectID, now: now, resetPaceInCopy: false)
    }

    /// Duplication POUR CHANGER DE RYTHME (§65 : « changement de rythme
    /// après association : proposer duplication, pas mutation destructive »).
    ///
    /// Même copie que `duplicate` (enregistrement projet, dossier de
    /// fichiers §11 — audio, analyse ET partitions) mais SANS les cases ni
    /// les associations : la copie repart au choix du rythme
    /// (`awaitingPaceSelection`, rythme désélectionné, case active 0)
    /// pendant que l'ORIGINAL reste strictement intact. Sans cette
    /// variante, la copie d'un projet verrouillé serait verrouillée elle
    /// aussi — « dupliquez pour changer de rythme » serait une impasse.
    ///
    /// Les partitions copiées (`analysis/scores-v1.json`, §11) restent
    /// valides : le choix du rythme relit simplement la famille des trois
    /// modes, aucun recalcul (§61).
    ///
    /// La GÉOMÉTRIE n'est PAS copiée (§49) : sans case ni association, la
    /// copie n'a pas de « premier rush » — c'est le sien qui fixera sa
    /// géométrie.
    func duplicateForPaceChange(projectID: UUID, now: Date = .now) throws -> UUID {
        try performDuplication(projectID: projectID, now: now, resetPaceInCopy: true)
    }

    /// Cœur partagé des deux duplications (§65) — un seul chemin de copie,
    /// jamais deux implémentations qui divergent.
    ///
    /// `resetPaceInCopy` :
    /// - `false` : copie complète — statut, rythme, cases et associations ;
    /// - `true`  : copie SANS cases ni associations NI géométrie, rythme
    ///   désélectionné, statut `awaitingPaceSelection`, case active 0 (la
    ///   copie repart au choix du rythme, §65).
    private func performDuplication(
        projectID: UUID,
        now: Date,
        resetPaceInCopy: Bool
    ) throws -> UUID {
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
            // Copie complète : la copie reprend l'état fonctionnel de la
            // source (statut, rythme choisi, case active) — cohérent avec
            // §65 : dupliquer pour continuer sans mutation destructive.
            // Copie pour changement de rythme : retour au choix (§65).
            // Non defini par la specification — definition minimale V1.
            statusRaw: resetPaceInCopy
                ? ProjectStatus.awaitingPaceSelection.rawValue
                : source.statusRaw,
            selectedPaceRaw: resetPaceInCopy ? nil : source.selectedPaceRaw,
            activeSlotIndex: resetPaceInCopy ? 0 : source.activeSlotIndex,
            audioRelativePath: source.audioRelativePath,
            analysisRelativePath: source.analysisRelativePath,
            // §49 « le premier rush valide fixe la géométrie » : une copie
            // POUR CHANGER DE RYTHME repart sans cases ni associations —
            // elle ne peut donc pas hériter d'un verrou posé par un rush
            // qu'elle n'utilise pas (sinon son propre premier rush ne
            // fixerait JAMAIS sa géométrie, et §52.1 « toujours celle du
            // projet » s'appliquerait à un rapport étranger). Copie
            // complète : le verrou suit ses associations (§65 : « toutes
            // les cases retirées : conserver la géométrie »).
            geometryData: resetPaceInCopy ? nil : source.geometryData,
            lastAlbumIdentifier: source.lastAlbumIdentifier,
            analysisVersion: source.analysisVersion,
            scoreVersion: source.scoreVersion
        )
        modelContext.insert(copy)

        // Copie des cases et associations avec remappage des identifiants —
        // OMISE pour un changement de rythme : la copie repart de zéro, ce
        // qui la laisse libre d'un nouveau `selectPace` (§65).
        if !resetPaceInCopy {
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
    /// 1. reprises d'état interrompues (§8, §8.1) : import audio, résolution
    ///    d'association, **export** ;
    /// 2. brouillons vides résiduels (§31) ;
    /// 3. dossiers §11 orphelins — suppression interrompue entre la
    ///    sauvegarde SwiftData et la suppression du dossier ;
    /// 4. vidage des `temp/` de chaque projet existant.
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
        // §8/§64 : reprise après kill — une association restée en `resolving`
        // ou `downloading` (app tuée en pleine résolution ou en plein
        // téléchargement iCloud) ne se terminera jamais : aucune tâche ne la
        // reprendra. Bascule vers `unavailable` : la case GARDE son
        // association (§64 — le dock propose « Remplacer », jamais de perte
        // silencieuse §89), l'utilisateur voit un état honnête et décide.
        let resolvingRaw = ClipAssignmentStatus.resolving.rawValue
        let downloadingRaw = ClipAssignmentStatus.downloading.rawValue
        let stuckAssignments = try modelContext.fetch(FetchDescriptor<ClipAssignmentRecord>(
            predicate: #Predicate<ClipAssignmentRecord> {
                $0.statusRaw == resolvingRaw || $0.statusRaw == downloadingRaw
            }
        ))
        if !stuckAssignments.isEmpty {
            for assignment in stuckAssignments {
                assignment.statusRaw = ClipAssignmentStatus.unavailable.rawValue
            }
            try modelContext.save()
        }
        // §8.1/§66 : reprise après kill PENDANT un export. L'application tuée
        // en plein encodage laisse le projet figé en `exporting` : l'écran
        // d'accueil et le dock afficheraient indéfiniment un export en cours
        // qu'aucune tâche ne poursuit (§8.1 : « ne jamais annoncer un export
        // réussi avant confirmation effective » — et jamais un export en cours
        // qui n'existe plus). Le statut revient à sa valeur RESTAURÉE, avec la
        // règle EXACTE qu'applique `ExportActor` après un export
        // (`restoredStatusRaw` : `complete` si la TIMELINE exportable — toutes
        // les zones remplies concaténées — couvre toutes les cases,
        // `assembling` sinon). Le montage n'est pas touché : §66
        // « interruption : projet intact ». Les fichiers temporaires —
        // encodage partiel, sources matérialisées §52.3 — sont supprimés par
        // le vidage des `temp/` ci-dessous.
        let exportingRaw = ProjectStatus.exporting.rawValue
        let stuckExports = try modelContext.fetch(FetchDescriptor<ProjectRecord>(
            predicate: #Predicate<ProjectRecord> { $0.statusRaw == exportingRaw }
        ))
        if !stuckExports.isEmpty {
            for record in stuckExports {
                record.statusRaw = try restoredStatusRaw(projectID: record.id)
            }
            try modelContext.save()
        }
        try deleteAllEmptyDrafts()
        let knownIDs = Set(try modelContext.fetch(FetchDescriptor<ProjectRecord>()).map(\.id))
        let directoryIDs = fileStore.projectDirectoryIDs()

        // ================================================================
        // FILET DE SÉCURITÉ — base VIDE face à des dossiers PLEINS
        // ================================================================
        // La purge ci-dessous efface le dossier §11 (audio/, analysis/,
        // exports/, temp/) de tout identifiant présent sur disque et absent
        // de la base. Elle suppose donc que la base est la source de vérité,
        // ce qui n'est vrai QUE si la base ouverte est bien celle qui décrit
        // cette racine de fichiers.
        //
        // Or `AppEnvironment(modelContainer: .makeInMemory())` associe un
        // conteneur VIDE à la racine de fichiers de PRODUCTION (correctif
        // jumeau côté `AppEnvironment` : la racine est désormais injectable).
        // Dans cette configuration, `knownIDs` est vide, `directoryIDs`
        // contient tous les vrais projets, et la purge détruirait la musique
        // importée, les analyses en cache et les exports de l'utilisateur
        // alors que ses enregistrements SwiftData, eux, survivraient — perte
        // de données silencieuse et irréversible (§59, §69A, §89).
        //
        // « Aucun projet en base + au moins un dossier sur disque » est la
        // signature exacte d'un conteneur non peuplé, JAMAIS celle d'un
        // utilisateur ayant supprimé tous ses projets : `delete(projectID:)`
        // supprime l'enregistrement ET le dossier dans la même opération, et
        // une interruption entre les deux ne peut laisser qu'un sous-ensemble
        // strict de dossiers orphelins — pas la totalité alors que la base
        // est intégralement vide. Dans le doute, on ne supprime RIEN : un
        // dossier orphelin conservé coûte quelques kilo-octets, une purge à
        // tort coûte le projet. La maintenance est un confort (§69A), jamais
        // une opération dont dépend la correction du système.
        //
        // Cas volontairement NON couvert par cette garde : une base non vide
        // dont TOUS les dossiers seraient étrangers — impossible sans
        // corruption, puisque `createDraft` crée l'arbre §11 avant même
        // d'insérer l'enregistrement.
        let containerLooksUnpopulated = knownIDs.isEmpty && !directoryIDs.isEmpty
        if containerLooksUnpopulated {
            logger.error(
                "Maintenance : purge des dossiers orphelins ANNULÉE — base vide face à "
                + "\(directoryIDs.count) dossier(s) de projet sur disque (conteneur non peuplé ?)."
            )
        } else {
            for orphanID in directoryIDs where !knownIDs.contains(orphanID) {
                try? fileStore.deleteDirectory(for: orphanID)
            }
        }

        // Le vidage des `temp/` reste inconditionnel : il ne porte que sur
        // les projets CONNUS de la base (donc jamais sur un dossier dont on
        // ignore le propriétaire) et ne détruit que des fichiers déjà
        // déclarés jetables (§69A).
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

    // MARK: - Analyse (Jalon 4)

    /// Enregistre le résultat d'analyse du projet (annexe A `analyze`) :
    /// chemin relatif du JSON (`analysis/analysis-v1.json`, §11), version
    /// du moteur (§61) et statut `awaitingPaceSelection` — en une seule
    /// écriture autosauvegardée (§59).
    func saveAnalysisResult(relativePath: String, analysisVersion: Int, projectID: UUID) throws {
        let record = try requireProject(projectID)
        record.analysisRelativePath = relativePath
        record.analysisVersion = analysisVersion
        record.statusRaw = ProjectStatus.awaitingPaceSelection.rawValue
        try touchAndSave(record) // updatedAt + autosauvegarde (§59)
    }

    // MARK: - Partitions (Jalon 5)

    /// Enregistre la génération des partitions du projet (annexe A
    /// `analyze`, Jalon 5) : version du générateur (§61 `scoreVersion`) —
    /// `updatedAt` + autosauvegarde (§59).
    ///
    /// Le statut n'est PAS modifié ici : c'est `saveAnalysisResult` qui pose
    /// `awaitingPaceSelection` — quel que soit l'ordre des deux sauvegardes
    /// dans `AudioAnalysisActor`, le statut final reste identique.
    ///
    /// `relativePath` (contrat Jalon 5 : `analysis/scores-v1.json`, §11) :
    /// le schéma §10 verbatim n'a pas de colonne dédiée au chemin des
    /// partitions — le chemin est FIXE (§11) et re-dérivable ; le paramètre
    /// documente le contrat sans changement de schéma SwiftData.
    /// Non defini par la specification — definition minimale V1.
    func saveScores(relativePath: String, scoreVersion: Int, projectID: UUID) throws {
        let record = try requireProject(projectID)
        record.scoreVersion = scoreVersion
        try touchAndSave(record) // updatedAt + autosauvegarde (§59)
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
    /// « Une association maximum par case » relève des Jalons 7–8 ; le gel
    /// des temps après verrouillage est garanti ici par la garde
    /// `paceLockedByAssignments` (§10.1/§65).
    func insertSlots(
        _ definitions: [EditSlotDefinition],
        scoreMode: PaceMode,
        projectID: UUID
    ) throws {
        // §10.1/§65 : dès la première association, les temps des cases sont
        // gelés — aucune insertion possible sans passer par la duplication.
        guard try !hasAssignments(projectID: projectID) else {
            throw ProjectStoreError.paceLockedByAssignments(projectID)
        }
        let record = try requireProject(projectID)
        do {
            try insertSlotRecords(definitions, scoreMode: scoreMode, projectID: projectID)
            try touchAndSave(record)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Validation §10.1 + insertion SANS sauvegarde — partagé par
    /// `insertSlots` et `selectPace` (la transaction — sauvegarde unique et
    /// rollback — appartient à l'appelant).
    private func insertSlotRecords(
        _ definitions: [EditSlotDefinition],
        scoreMode: PaceMode,
        projectID: UUID
    ) throws {
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

// MARK: - Choix du rythme (Jalon 6)

// Non defini par la specification — definition minimale V1 (contrat Jalon 6).
extension ProjectStore {

    /// Vrai si le projet possède au moins une association vidéo (§13.3).
    /// Dès la première association, le rythme est verrouillé (§65, §81 :
    /// « verrouillage après première association »).
    func hasAssignments(projectID: UUID) throws -> Bool {
        try assignmentCount(projectID: projectID) > 0
    }

    /// Nombre de cases persistées du projet — tous modes confondus (après
    /// `selectPace`, seules les cases du mode choisi existent en base).
    func slotCount(projectID: UUID) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<ProjectSlotRecord>(
            predicate: #Predicate<ProjectSlotRecord> { $0.projectID == projectID }
        ))
    }

    /// Supprime toutes les cases persistées du projet — REFUSÉ si une
    /// association existe (`paceLockedByAssignments`, §65 : jamais de
    /// mutation destructive après association ; §89 : ne jamais perdre les
    /// associations après relance).
    func clearSlots(projectID: UUID) throws {
        guard try !hasAssignments(projectID: projectID) else {
            throw ProjectStoreError.paceLockedByAssignments(projectID)
        }
        let record = try requireProject(projectID)
        for slot in try fetchSlots(projectID: projectID) {
            modelContext.delete(slot)
        }
        try touchAndSave(record) // autosauvegarde (§59)
    }

    /// Choix du rythme (§34, annexe A) : matérialise en cases persistées
    /// §10.1 la partition du mode choisi, passe le statut à `assembling`
    /// et remet la case active à 0 — sauvegardé (§59 : « choix du
    /// rythme »).
    ///
    /// Seules les cases du mode CHOISI sont insérées — les trois partitions
    /// complètes restent dans `analysis/scores-v1.json` (§11) : revenir au
    /// choix du rythme ou changer de mode avant association ne recalcule
    /// rien, la famille est simplement relue.
    ///
    /// §65 : interdit dès qu'une association existe
    /// (`paceLockedByAssignments`) — l'alternative est la duplication.
    func selectPace(_ mode: PaceMode, from family: EditScoreFamily, projectID: UUID) throws {
        guard try !hasAssignments(projectID: projectID) else {
            throw ProjectStoreError.paceLockedByAssignments(projectID)
        }
        let record = try requireProject(projectID)
        let score: EditScore = switch mode {
        case .kick: family.kick
        case .snare: family.snare
        case .hat: family.hat
        }
        // TRANSACTION UNIQUE (tout-ou-rien) : suppression des cases
        // existantes + insertions validées §10.1 + champs du projet, puis
        // UNE seule sauvegarde. Un `scores-v1.json` corrompu (erreur typée
        // en cours de lot) laisse la base STRICTEMENT inchangée (rollback) —
        // jamais d'état intermédiaire persisté.
        do {
            for slot in try fetchSlots(projectID: projectID) {
                modelContext.delete(slot)
            }
            try insertSlotRecords(score.slots, scoreMode: mode, projectID: projectID)
            record.selectedPaceRaw = mode.rawValue
            record.activeSlotIndex = 0
            record.statusRaw = ProjectStatus.assembling.rawValue
            try touchAndSave(record) // autosauvegarde unique (§59)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Retour au choix du rythme AVANT toute association (§65 : seule la
    /// mutation APRÈS association est interdite — avant, changer d'avis est
    /// libre) : cases effacées, rythme désélectionné, statut
    /// `awaitingPaceSelection`. Un nouveau `selectPace` reste possible.
    func revertToPaceSelection(projectID: UUID) throws {
        guard try !hasAssignments(projectID: projectID) else {
            throw ProjectStoreError.paceLockedByAssignments(projectID)
        }
        let record = try requireProject(projectID)
        // Transaction unique, même raison que `selectPace`.
        do {
            for slot in try fetchSlots(projectID: projectID) {
                modelContext.delete(slot)
            }
            record.selectedPaceRaw = nil
            record.statusRaw = ProjectStatus.awaitingPaceSelection.rawValue
            try touchAndSave(record) // autosauvegarde unique (§59)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // `duplicateForPaceChange` (§65) est définie plus haut, à côté de
    // `duplicate` — les deux partagent `performDuplication(resetPaceInCopy:)`.
}

// MARK: - Associations vidéo (Jalon 8)

// Non defini par la specification — definition minimale V1.
/// Résumé `Sendable` d'une association §13.3 — seule forme qui traverse la
/// frontière de l'acteur (jamais de `ClipAssignmentRecord`).
struct AssignmentSummary: Sendable, Equatable {
    let id: UUID
    let slotID: UUID
    let slotIndex: Int
    let assetLocalIdentifier: String
    let statusRaw: String
}

// Non defini par la specification — definition minimale V1 (contrat Jalon 8).
extension ProjectStore {

    /// Toutes les associations du projet (§13.3), triées par index de case.
    ///
    /// Un enregistrement dont la case n'existe plus (jamais attendu — la
    /// cascade §10.1 supprime les deux ensemble) est exposé avec
    /// `slotIndex == -1` plutôt que masqué : aucune association n'est
    /// silencieusement perdue (§89).
    func assignments(projectID: UUID) throws -> [AssignmentSummary] {
        let indexBySlotID = try slotIndexesByID(projectID: projectID)
        return try fetchAssignments(projectID: projectID)
            .map { record in
                AssignmentSummary(
                    id: record.id,
                    slotID: record.slotID,
                    slotIndex: indexBySlotID[record.slotID] ?? -1,
                    assetLocalIdentifier: record.assetLocalIdentifier,
                    statusRaw: record.statusRaw
                )
            }
            .sorted { $0.slotIndex < $1.slotIndex }
    }

    /// §45 « Déjà utilisé au plan 4 » : dictionnaire
    /// `assetLocalIdentifier → [index de case]` (index TRIÉS croissants).
    ///
    /// TOUS les statuts comptent (y compris `unavailable`) : une case en
    /// échec garde son association (§64) et l'indicateur « déjà utilisé »
    /// doit continuer de la signaler.
    func usedAssetSlotIndexes(projectID: UUID) throws -> [String: [Int]] {
        let indexBySlotID = try slotIndexesByID(projectID: projectID)
        var used: [String: [Int]] = [:]
        for record in try fetchAssignments(projectID: projectID) {
            guard let slotIndex = indexBySlotID[record.slotID] else { continue }
            used[record.assetLocalIdentifier, default: []].append(slotIndex)
        }
        return used.mapValues { $0.sorted() }
    }

    /// Engage une association sur une case (§13.3, §43) : crée
    /// l'enregistrement (statut initial `resolving`/`downloading` selon
    /// l'appelant) et pose `slot.assignmentID`.
    ///
    /// Remplacer (§36 : barre inférieure « Remplacer » d'une case remplie) :
    /// si la case possède déjà une association, l'ancienne est supprimée
    /// d'abord — une association maximum par case (§10.1).
    ///
    /// SAUVEGARDE IMMÉDIATE (§59 : « jamais de debounce pour une
    /// association critique »).
    ///
    /// V1 : `sourceStartTicks` vaut toujours 0 (§13.3) ;
    /// `observedAssetDurationTicks` vaut 0 tant que la durée réelle n'est
    /// pas mesurée (`completeAssignment`, §43 validation finale).
    @discardableResult
    func beginAssignment(
        projectID: UUID, slotID: UUID, assetLocalIdentifier: String,
        requiredDurationTicks: Int64, statusRaw: String
    ) throws -> UUID {
        let record = try requireProject(projectID)
        let slot = try requireSlot(slotID, projectID: projectID)
        let assignmentID = UUID()
        do {
            // Remplacer (§36) : suppression de l'association existante
            // d'abord — la boucle couvre aussi un enregistrement orphelin
            // résiduel (état réparé), vide en régime normal §10.1.
            for existing in try fetchAssignments(slotID: slotID) {
                modelContext.delete(existing)
            }
            modelContext.insert(ClipAssignmentRecord(
                id: assignmentID,
                projectID: projectID,
                slotID: slotID,
                assetLocalIdentifier: assetLocalIdentifier,
                sourceStartTicks: 0, // V1 : toujours 0 (§13.3)
                requiredDurationTicks: requiredDurationTicks,
                observedAssetDurationTicks: 0, // mesurée à la résolution (§43)
                statusRaw: statusRaw,
                assignedAt: .now
            ))
            slot.assignmentID = assignmentID
            try touchAndSave(record) // sauvegarde immédiate (§59)
        } catch {
            modelContext.rollback()
            throw error
        }
        return assignmentID
    }

    /// Validation finale réussie (§43) : durée réelle mesurée enregistrée
    /// et statut `ready` — sauvegarde immédiate (§59).
    func completeAssignment(_ id: UUID, observedDurationTicks: Int64, projectID: UUID) throws {
        let record = try requireProject(projectID)
        let assignment = try requireAssignment(id, projectID: projectID)
        assignment.observedAssetDurationTicks = observedDurationTicks
        assignment.statusRaw = ClipAssignmentStatus.ready.rawValue
        try touchAndSave(record) // sauvegarde immédiate (§59)
    }

    /// §44 : découverte iCloud à la RÉSOLUTION — le premier callback de
    /// progression réseau fait passer la case en `downloading` (la grille
    /// affiche l'avancement, l'utilisateur continue à assigner d'autres
    /// cases). UNIQUEMENT depuis `resolving` : si la résolution s'est déjà
    /// terminée entre-temps (`ready`, `unavailable`, `tooShort`), no-op
    /// SILENCIEUX — un callback tardif ne doit jamais écraser un état
    /// final. Sauvegarde immédiate (§59).
    func markAssignmentDownloading(_ id: UUID, projectID: UUID) throws {
        let record = try requireProject(projectID)
        let assignment = try requireAssignment(id, projectID: projectID)
        guard assignment.statusRaw == ClipAssignmentStatus.resolving.rawValue else {
            return // no-op silencieux : statut déjà final (ou déjà en téléchargement)
        }
        assignment.statusRaw = ClipAssignmentStatus.downloading.rawValue
        try touchAndSave(record) // sauvegarde immédiate (§59)
    }

    /// Échec de résolution : la case GARDE son association en état d'échec
    /// (`unavailable` — §64 « asset supprimé : case `unavailable` » — ou
    /// `tooShort`), sauvegarde immédiate (§59).
    ///
    /// EXCEPTION documentée : un `tooShort` détecté à la VALIDATION FINALE
    /// §43 (« ne pas remplir la case ») n'utilise PAS cette méthode —
    /// l'appelant retire l'association (`removeAssignment`) et la case
    /// reste VIDE.
    func failAssignment(_ id: UUID, statusRaw: String, projectID: UUID) throws {
        let record = try requireProject(projectID)
        let assignment = try requireAssignment(id, projectID: projectID)
        assignment.statusRaw = statusRaw
        try touchAndSave(record) // sauvegarde immédiate (§59)
    }

    /// Retire l'association d'une case (§59 : sauvegarder après retrait) :
    /// enregistrement §13.3 supprimé ET `slot.assignmentID` remis à `nil`
    /// — la case redevient vide.
    func removeAssignment(slotID: UUID, projectID: UUID) throws {
        let record = try requireProject(projectID)
        let slot = try requireSlot(slotID, projectID: projectID)
        do {
            for assignment in try fetchAssignments(slotID: slotID) {
                modelContext.delete(assignment)
            }
            slot.assignmentID = nil
            try touchAndSave(record) // sauvegarde immédiate (§59)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Retire une association PAR SON IDENTIFIANT, en ne vidant la case que
    /// si elle référence ENCORE cette association (§59 : sauvegarde après
    /// retrait). Défense contre les courses PAR CASE : pendant une
    /// résolution lente, l'utilisateur peut réassigner la même case
    /// (« Remplacer » §36) — le chemin d'échec de l'ANCIENNE tâche ne doit
    /// JAMAIS retirer la NOUVELLE association (§64 : jamais de perte
    /// silencieuse d'une association valide).
    ///
    /// - `slot.assignmentID == id` : retrait complet — enregistrement §13.3
    ///   supprimé ET `slot.assignmentID` remis à `nil`, la case redevient
    ///   vide (identique à `removeAssignment(slotID:)`) ;
    /// - sinon : seul l'enregistrement orphelin `id` est supprimé s'il
    ///   existe encore — l'association COURANTE de la case reste intacte ;
    /// - ni l'un ni l'autre (tâche périmée déjà nettoyée) : no-op silencieux.
    func removeAssignmentIfCurrent(_ id: UUID, slotID: UUID, projectID: UUID) throws {
        let record = try requireProject(projectID)
        let slot = try requireSlot(slotID, projectID: projectID)
        do {
            if slot.assignmentID == id {
                // La boucle couvre aussi un enregistrement orphelin résiduel
                // (état réparé), vide en régime normal §10.1.
                for assignment in try fetchAssignments(slotID: slotID) {
                    modelContext.delete(assignment)
                }
                slot.assignmentID = nil
                try touchAndSave(record) // sauvegarde immédiate (§59)
            } else if let orphan = try fetchAssignment(id), orphan.projectID == projectID {
                modelContext.delete(orphan)
                try touchAndSave(record) // sauvegarde immédiate (§59)
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Index des cases SANS association (`assignmentID == nil`), triés
    /// croissants — entrée de l'avancement automatique §46
    /// (`AssignmentRules.nextEmptySlotIndex`).
    func emptySlotIndexes(projectID: UUID) throws -> [Int] {
        try fetchSlots(projectID: projectID)
            .filter { $0.assignmentID == nil }
            .map(\.index)
            .sorted()
    }

    /// §41 : « mémoriser le dernier album par projet » (§60 : restauré à la
    /// réouverture). `nil` efface la mémorisation.
    func setLastAlbum(_ albumID: String?, projectID: UUID) throws {
        let record = try requireProject(projectID)
        record.lastAlbumIdentifier = albumID
        try touchAndSave(record)
    }

    /// Dernier album mémorisé du projet (§41), ou `nil`.
    func lastAlbum(projectID: UUID) throws -> String? {
        try requireProject(projectID).lastAlbumIdentifier
    }

    // MARK: - Helpers privés (Jalon 8)

    /// Case par identifiant, avec vérification d'appartenance au projet.
    private func requireSlot(_ slotID: UUID, projectID: UUID) throws -> ProjectSlotRecord {
        var descriptor = FetchDescriptor<ProjectSlotRecord>(
            predicate: #Predicate<ProjectSlotRecord> { $0.id == slotID }
        )
        descriptor.fetchLimit = 1
        guard let slot = try modelContext.fetch(descriptor).first,
              slot.projectID == projectID else {
            throw ProjectStoreError.slotNotFound(slotID)
        }
        return slot
    }

    /// Association par identifiant, ou `nil` si elle n'existe plus
    /// (tâche périmée — `removeAssignmentIfCurrent`).
    private func fetchAssignment(_ id: UUID) throws -> ClipAssignmentRecord? {
        var descriptor = FetchDescriptor<ClipAssignmentRecord>(
            predicate: #Predicate<ClipAssignmentRecord> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Association par identifiant, avec vérification d'appartenance au
    /// projet.
    private func requireAssignment(_ id: UUID, projectID: UUID) throws -> ClipAssignmentRecord {
        guard let assignment = try fetchAssignment(id),
              assignment.projectID == projectID else {
            throw ProjectStoreError.assignmentNotFound(id)
        }
        return assignment
    }

    /// Associations d'une case donnée (au plus une en régime normal §10.1 ;
    /// la boucle de suppression tolère un état réparé).
    private func fetchAssignments(slotID: UUID) throws -> [ClipAssignmentRecord] {
        try modelContext.fetch(FetchDescriptor<ClipAssignmentRecord>(
            predicate: #Predicate<ClipAssignmentRecord> { $0.slotID == slotID }
        ))
    }

    /// Dictionnaire `id de case → index` du projet.
    private func slotIndexesByID(projectID: UUID) throws -> [UUID: Int] {
        var indexes: [UUID: Int] = [:]
        for slot in try fetchSlots(projectID: projectID) {
            indexes[slot.id] = slot.index
        }
        return indexes
    }
}

// MARK: - Géométrie et instantané de projet (Jalon 9)

// Non defini par la specification — definition minimale V1 (contrat Jalon 9).
extension ProjectStore {

    /// Géométrie verrouillée du projet (§14), ou `nil` tant qu'aucun rush
    /// prêt ne l'a fixée (§49).
    ///
    /// La géométrie est persistée en JSON dans `ProjectRecord.geometryData`
    /// (schéma §10 verbatim : une colonne `Data?`, aucune colonne dédiée par
    /// champ). Une donnée illisible n'est PAS masquée par un `nil` : l'erreur
    /// de décodage remonte à l'appelant — un `nil` silencieux ferait croire à
    /// un projet non verrouillé alors que `lockGeometry` refuse d'écrire par
    /// dessus (verrou définitif §49).
    func geometry(projectID: UUID) throws -> ProjectGeometry? {
        guard let data = try requireProject(projectID).geometryData else { return nil }
        return try JSONDecoder().decode(ProjectGeometry.self, from: data)
    }

    /// Verrouille la géométrie du projet au premier rush prêt (§49 étapes 4
    /// et 5 : « enregistrer la géométrie », « ne plus jamais la modifier
    /// automatiquement »).
    ///
    /// **NO-OP si une géométrie existe déjà** — le verrou est DÉFINITIF :
    /// - §14/§49 : « Le premier rush valide fixe la géométrie. Elle ne change
    ///   plus ensuite, même si un rush plus défini est ajouté » ;
    /// - §65 : « premier rush supprimé après verrouillage : conserver la
    ///   géométrie » et « toutes les cases retirées : conserver la géométrie
    ///   pour éviter un basculement inattendu ».
    ///
    /// Le test porte sur `geometryData != nil` (présence de l'octet), jamais
    /// sur le décodage : même illisible, une géométrie enregistrée reste un
    /// verrou — jamais de re-verrouillage silencieux par un rush suivant.
    ///
    /// Un appel sur un projet déjà verrouillé ne touche donc NI la géométrie
    /// NI `updatedAt` : aucun effet de bord observable.
    func lockGeometry(_ geometry: ProjectGeometry, projectID: UUID) throws {
        let record = try requireProject(projectID)
        guard record.geometryData == nil else { return } // verrou définitif (§49, §65)
        record.geometryData = try JSONEncoder().encode(geometry)
        try touchAndSave(record) // autosauvegarde immédiate (§59)
    }

    /// Instantané `Sendable` complet du projet (§51) : cases TRIÉES par
    /// index, association de chaque case, géométrie verrouillée.
    ///
    /// Seule forme du projet qui traverse la frontière de l'acteur (§8) :
    /// aucun `PersistentModel` n'en sort. C'est l'entrée de la timeline
    /// exportable (`readyTimeline` — toutes les zones remplies concaténées,
    /// écart produit qui remplace le préfixe §51), de la
    /// prévisualisation (§47) et de l'export (§7 `ProjectExporting`).
    ///
    /// Cases retenues : celles du rythme CHOISI (après §34, `selectPace`
    /// n'en persiste pas d'autres — le filtre est une simple ceinture de
    /// sécurité).
    ///
    /// AUCUN rythme choisi → instantané SANS cases : aucun montage n'est en
    /// cours, donc aucune timeline exportable (export et aperçu principal
    /// désactivés). Renvoyer toutes les cases mélangerait les cases de
    /// plusieurs modes dans un même instantané (indices en doublon, temps qui
    /// se chevauchent) — un « montage » que l'utilisateur n'a jamais demandé.
    ///
    /// Statut d'association illisible (base corrompue, jamais attendu) →
    /// `unavailable` : le repli ne peut JAMAIS valoir `ready`, donc une
    /// donnée douteuse n'entre jamais dans une zone exportée.
    func projectSnapshot(projectID: UUID) throws -> ProjectSnapshot {
        let project = try requireProject(projectID)

        var slots: [ProjectSlot] = []
        // Aucun rythme choisi (§34 pas encore franchi) → aucune case dans
        // l'instantané : aucun montage en cours, donc aucune zone remplie,
        // donc aucune timeline exportable. La géométrie, elle, reste
        // rapportée : le verrou §49 survit à un retour au choix du rythme.
        if let selectedModeRaw = project.selectedPaceRaw {
            var assignmentsBySlotID: [UUID: ClipAssignmentRecord] = [:]
            for assignment in try fetchAssignments(projectID: projectID) {
                assignmentsBySlotID[assignment.slotID] = assignment
            }

            slots = try fetchSlots(projectID: projectID)
                .filter { $0.scoreModeRaw == selectedModeRaw }
                .sorted { $0.index < $1.index }
                .map { slotRecord in
                    ProjectSlot(
                        id: slotRecord.id,
                        index: slotRecord.index,
                        start: MediaTime(ticks: slotRecord.startTicks),
                        end: MediaTime(ticks: slotRecord.endTicks),
                        assignment: assignmentsBySlotID[slotRecord.id].map { assignment in
                            ClipAssignmentSnapshot(
                                id: assignment.id,
                                assetLocalIdentifier: assignment.assetLocalIdentifier,
                                status: ClipAssignmentStatus(rawValue: assignment.statusRaw) ?? .unavailable
                            )
                        }
                    )
                }
        }

        let geometry = try project.geometryData.map {
            try JSONDecoder().decode(ProjectGeometry.self, from: $0)
        }

        return ProjectSnapshot(projectID: projectID, slots: slots, geometry: geometry)
    }
}

// MARK: - Export (Jalon 10)

// Non defini par la specification — definition minimale V1 (contrat Jalon 10).
extension ProjectStore {

    /// Bascule le statut d'export du projet (§10, §58).
    ///
    /// - `true` : statut `exporting` pendant l'encodage ;
    /// - `false` : retour à `complete` si TOUTES les cases sont prêtes,
    ///   `assembling` sinon (§10) — appelé après une annulation ou un échec
    ///   (§66 : « interruption : projet intact »).
    ///
    /// Les deux sens sont GARDÉS pour ne jamais écraser un statut étranger :
    /// - poser `exporting` alors qu'il l'est déjà est un no-op silencieux
    ///   (`updatedAt` intact) ;
    /// - retirer `exporting` alors que le projet est dans un tout autre état
    ///   (analyse relancée, projet remis au choix du rythme pendant un export
    ///   que l'utilisateur a quitté) ne touche à rien : la restauration
    ///   tardive d'un export mort ne doit jamais réécrire l'état courant.
    func setExporting(_ isExporting: Bool, projectID: UUID) throws {
        let record = try requireProject(projectID)
        let exportingRaw = ProjectStatus.exporting.rawValue
        if isExporting {
            guard record.statusRaw != exportingRaw else { return }
            record.statusRaw = exportingRaw
        } else {
            guard record.statusRaw == exportingRaw else { return }
            record.statusRaw = try restoredStatusRaw(projectID: projectID)
        }
        try touchAndSave(record) // autosauvegarde (§59)
    }

    /// Enregistre un export RÉUSSI (§60 : « dernier export réussi »
    /// restauré à la réouverture).
    ///
    /// Le schéma §10 est VERBATIM : aucune colonne n'y décrit un export. La
    /// trace durable du dernier export réussi est donc le FICHIER lui-même,
    /// dans `exports/` du projet (§11) — écrit seulement après un succès
    /// complet (§55, §58) et nommé de façon horodatée triable
    /// (`ProjectExporter.uniqueOutputURL`). Cette méthode enregistre côté
    /// projet ce que la base peut porter sans changement de schéma :
    /// - le statut revient de `exporting` à `complete`/`assembling` (§10) ;
    /// - `updatedAt` est touché (§59), ce qui remonte le projet en tête de
    ///   l'écran d'accueil (§31).
    ///
    /// C'est aussi le point d'insertion unique le jour où une colonne
    /// `lastExportRelativePath` serait ajoutée au schéma.
    func markExportSucceeded(projectID: UUID) throws {
        let record = try requireProject(projectID)
        if record.statusRaw == ProjectStatus.exporting.rawValue {
            record.statusRaw = try restoredStatusRaw(projectID: projectID)
        }
        try touchAndSave(record) // autosauvegarde (§59)
    }

    /// Statut à restaurer après un export (§10) : `complete` si le montage
    /// est intégralement prêt (la timeline exportable couvre toutes les
    /// cases), `assembling` sinon — un montage partiellement rempli n'est pas
    /// « terminé » parce qu'un export partiel a réussi.
    private func restoredStatusRaw(projectID: UUID) throws -> String {
        let snapshot = try projectSnapshot(projectID: projectID)
        // Écart produit : le montage exporté CONCATÈNE toutes les zones
        // remplies, les cases vides étant supprimées. Le critère de
        // « terminé » est INCHANGÉ : TOUTES les cases doivent être prêtes —
        // un montage troué, même exporté en entier, ne rend pas le projet
        // complet.
        let exportedSlotCount = snapshot.readyTimeline.slotCount
        let isComplete = exportedSlotCount > 0 && exportedSlotCount == snapshot.slots.count
        return isComplete
            ? ProjectStatus.complete.rawValue
            : ProjectStatus.assembling.rawValue
    }
}
