//
//  ExportActor.swift
//  MontageMusical
//
//  Acteur dédié à l'export (§8 : « ExportActor : un export actif à la
//  fois »). Cycle de vie §10/§58/§66 : statut `exporting` pendant l'encodage,
//  retour à `assembling`/`complete` ensuite, fichier temporaire nettoyé,
//  aucun asset Photos créé sans succès complet.
//
//  Non defini par la specification — definition minimale V1.
//

import Foundation

// MARK: - Issue d'une demande de démarrage (§58)

// Non defini par la specification — definition minimale V1.
/// Ce qu'il est advenu d'un appel à `ExportActor.startExport` (§58).
///
/// Sans ce retour, un démarrage refusé (réentrance, export déjà en cours,
/// aucun segment prêt, instantané illisible) était SILENCIEUX : l'appelant croyait
/// avoir lancé un export et lisait ensuite l'issue du run PRÉCÉDENT.
enum ExportStartResult: Sendable, Equatable {

    /// L'encodage a démarré : la progression est publiée
    /// (`currentProgress`), l'issue arrivera dans `lastOutcome`/`lastError`.
    case started

    /// §58 : « empêcher un second export simultané du même projet ». Un
    /// export du MÊME projet occupe déjà l'acteur — l'appelant doit se
    /// contenter d'observer la progression en cours, jamais réinterpréter
    /// l'issue du run précédent comme la sienne.
    case alreadyRunning

    /// Aucun encodage n'a été lancé et le projet est strictement intact :
    /// préfixe vide (§66), instantané illisible, statut non enregistrable.
    /// L'erreur est aussi exposée par `lastError(projectID:)`.
    case refused(ExportError)
}

/// Un export actif au plus **par projet** (§8, §58 : « empêcher un second
/// export simultané du même projet »).
///
/// **Arrière-plan (§8.1) — aucune promesse.** Rien ici ne garantit qu'un
/// export se poursuivra si iOS suspend l'application : la spécification
/// demande explicitement de « demander de garder l'application ouverte
/// pendant l'encodage final » et de « ne jamais annoncer un export réussi
/// avant confirmation effective ». Une tâche interrompue est donc annoncée
/// comme INTERROMPUE (`ExportError.cancelled`, statut du projet restauré,
/// fichier temporaire supprimé) — jamais comme un succès, jamais comme une
/// promesse de reprise.
///
/// **Photos n'est pas appelé ici** (§40, §55, §58) : l'enregistrement dans la
/// photothèque est une action utilisateur distincte
/// (`PhotoLibrarySaver.save`), postérieure au succès complet. Un export
/// annulé ou échoué ne peut donc jamais laisser d'asset Photos incomplet.
actor ExportActor {

    private let exporter: ProjectExporter
    private let projectStore: ProjectStore
    private let fileStore: ProjectFileStore
    private let logger = AppLogger(category: .export)

    /// Un export au plus par projet (§8).
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    /// Garde de réentrance : projets dont le démarrage est en préparation
    /// (les `await` de préparation rendent l'acteur réentrant — sans cette
    /// garde, deux appuis rapprochés lanceraient deux encodages, ce que §58
    /// interdit).
    private var startingProjects: Set<UUID> = []
    /// Dernière progression publiée par projet (0…1), `nil` hors export.
    private var progressByProject: [UUID: Double] = [:]
    /// Dernier export RÉUSSI par projet (§58, §60).
    private var outcomeByProject: [UUID: ExportOutcome] = [:]
    /// Dernière erreur exposée par projet (§58 : l'interruption et l'échec
    /// sont annoncés, jamais avalés).
    private var errorByProject: [UUID: ExportError] = [:]

    init(exporter: ProjectExporter, projectStore: ProjectStore, fileStore: ProjectFileStore) {
        self.exporter = exporter
        self.projectStore = projectStore
        self.fileStore = fileStore
    }

    // MARK: - Démarrage (§8, §58)

    /// Lance l'export du projet et dit CE QUI S'EST PASSÉ
    /// (`ExportStartResult`).
    ///
    /// **Second démarrage REFUSÉ** (§58 : « empêcher un second export
    /// simultané du même projet ») : l'export en cours n'est ni relancé ni
    /// perturbé, et l'appelant reçoit `.alreadyRunning` — il continue
    /// d'observer `currentProgress(projectID:)` au lieu de lire l'issue d'un
    /// run qui n'est pas le sien.
    ///
    /// Aucun segment prêt → aucun export lancé (écart produit : une première
    /// case vide ne bloque plus l'export, contrairement à §66) ;
    /// `.refused(.emptyPrefix)` est rendu ET exposé par
    /// `lastError` pour que le dock puisse l'expliquer plutôt que rester
    /// inerte.
    ///
    /// L'état observable du projet est REMIS À ZÉRO au démarrage d'un export
    /// réel (erreur et dernier résultat effacés) : plus aucune issue
    /// précédente ne peut être confondue avec celle du nouvel export.
    @discardableResult
    func startExport(projectID: UUID) async -> ExportStartResult {
        guard !startingProjects.contains(projectID) else {
            logger.info("Export déjà en préparation pour ce projet (§58) — démarrage refusé.")
            return .alreadyRunning
        }
        if let existing = runningTasks[projectID] {
            guard existing.isCancelled else {
                logger.info("Export déjà en cours pour ce projet (§58) — démarrage refusé.")
                return .alreadyRunning
            }
            // Relance immédiate après une annulation : attendre la fin propre
            // de la tâche annulée (statut restauré, temporaire supprimé) puis
            // RE-VÉRIFIER tous les gardes — l'acteur est réentrant pendant
            // l'await.
            await existing.value
            return await startExport(projectID: projectID)
        }

        startingProjects.insert(projectID)
        defer { startingProjects.remove(projectID) }

        let snapshot: ProjectSnapshot
        do {
            snapshot = try await projectStore.projectSnapshot(projectID: projectID)
        } catch {
            logger.error("Instantané de projet illisible avant export : \(error.localizedDescription)")
            let failure = ExportError.exportFailed(error.localizedDescription)
            errorByProject[projectID] = failure
            return .refused(failure)
        }

        // Rien à exporter → aucun encodage, aucun changement de statut,
        // projet strictement intact.
        //
        // ÉCART PRODUIT (demande utilisateur postérieure à la spec) : le
        // montage exporté est le premier SEGMENT continu de cases prêtes, où
        // qu'il commence — une première case vide ne bloque donc plus
        // l'export, contrairement à §51/§66.
        let segment = snapshot.contiguousReadySegment
        guard !segment.isEmpty else {
            logger.info("Export demandé sans segment exportable — refusé.")
            errorByProject[projectID] = .emptyPrefix
            return .refused(.emptyPrefix)
        }
        // Portée informative : `.complete` quand le segment couvre TOUT le
        // montage, `.contiguousPrefix` sinon (nom de cas conservé — il
        // désigne désormais le segment ; les deux portées encodent le même
        // segment).
        let scope: ExportScope = segment.slotCount == snapshot.slots.count ? .complete : .contiguousPrefix

        // §10 : statut `exporting` pendant l'encodage.
        do {
            try await projectStore.setExporting(true, projectID: projectID)
        } catch {
            logger.error("Statut d'export non enregistré : \(error.localizedDescription)")
            let failure = ExportError.exportFailed(error.localizedDescription)
            errorByProject[projectID] = failure
            return .refused(failure)
        }

        // Purge de l'état observable AVANT de lancer : ni l'erreur ni le
        // résultat d'un export précédent (y compris celui RESTAURÉ depuis
        // `exports/`, §60) ne doivent survivre au démarrage d'un nouvel
        // export — sans cela l'interface lirait l'issue du run précédent.
        errorByProject[projectID] = nil
        outcomeByProject[projectID] = nil
        progressByProject[projectID] = 0
        runningTasks[projectID] = Task {
            await self.runExport(snapshot: snapshot, scope: scope, projectID: projectID)
        }
        return .started
    }

    /// Annule l'export en cours du projet (§58 : « permettre annulation »).
    ///
    /// L'annulation est COOPÉRATIVE : la tâche la propage à
    /// `AVAssetExportSession`, le fichier temporaire est supprimé, le statut
    /// du projet est restauré et aucun asset Photos n'existe — « interruption :
    /// projet intact » (§66).
    func cancelExport(projectID: UUID) {
        runningTasks[projectID]?.cancel()
    }

    // MARK: - État observable (§58, §60)

    /// Progression courante (0…1), ou `nil` si aucun export n'est en cours
    /// pour ce projet. Lue par polling par le dock inférieur (§58).
    func currentProgress(projectID: UUID) -> Double? {
        progressByProject[projectID]
    }

    /// Dernier export RÉUSSI du projet (§58, §60 : « Restaurer : […] dernier
    /// export réussi »).
    ///
    /// Deux origines possibles :
    /// 1. l'export de la session courante (`isRestored == false`) — durée et
    ///    nombre de plans sont ceux qui ont été encodés ;
    /// 2. à défaut, le fichier le plus récent d'`exports/` (§11), RESTAURÉ au
    ///    premier accès après relance (`isRestored == true`). Le schéma §10
    ///    est verbatim : aucune colonne ne décrit un export, le fichier EST la
    ///    trace durable — sa durée et son nombre de plans ne sont donc pas
    ///    connus et valent zéro (jamais affichés comme des mesures).
    ///
    /// La valeur restaurée est mémorisée pour que la lecture reste stable ;
    /// elle est PURGÉE au démarrage d'un nouvel export et n'est JAMAIS
    /// reconstituée tant qu'un export tourne : l'export d'AVANT ne peut donc
    /// pas être pris pour l'issue de celui d'après (§58).
    func lastOutcome(projectID: UUID) -> ExportOutcome? {
        if let outcome = outcomeByProject[projectID] {
            return outcome
        }
        // Export en cours : son issue n'existe pas encore — restaurer le
        // fichier précédent ici le ferait passer pour un succès du run
        // courant (§8.1 : « ne jamais annoncer un export réussi avant
        // confirmation effective »).
        guard runningTasks[projectID] == nil else { return nil }
        guard let url = fileStore.lastExportURL(projectID: projectID) else { return nil }
        let restored = ExportOutcome(
            outputURL: url,
            duration: .zero,
            slotCount: 0,
            isRestored: true
        )
        outcomeByProject[projectID] = restored
        return restored
    }

    /// Dernière erreur d'export exposée (annulation comprise, §8.1 : une
    /// tâche interrompue est ANNONCÉE comme interrompue). `nil` si le dernier
    /// export s'est bien terminé ou si aucun export n'a été tenté.
    func lastError(projectID: UUID) -> ExportError? {
        errorByProject[projectID]
    }

    // MARK: - Exécution

    private func runExport(snapshot: ProjectSnapshot, scope: ExportScope, projectID: UUID) async {
        do {
            let result = try await exporter.export(project: snapshot, scope: scope) { fraction in
                Task { await self.update(progress: fraction, projectID: projectID) }
            }

            outcomeByProject[projectID] = ExportOutcome(
                outputURL: result.outputURL,
                duration: result.duration,
                slotCount: result.slotCount
            )
            errorByProject[projectID] = nil
            // §60 : succès enregistré (statut restauré + `updatedAt`).
            // §8.1 : le succès n'est annoncé qu'ICI, après confirmation
            // effective de l'écriture du fichier final.
            do {
                try await projectStore.markExportSucceeded(projectID: projectID)
            } catch {
                logger.error("Succès d'export non enregistré : \(error.localizedDescription)")
            }
            logger.info("Export réussi : \(result.slotCount) plans.")
        } catch let error as ExportError {
            await handle(error: error, projectID: projectID)
        } catch {
            await handle(error: .exportFailed(error.localizedDescription), projectID: projectID)
        }
        finish(projectID: projectID)
    }

    /// Chemin d'échec ET d'annulation (§58, §66) : statut restauré, fichiers
    /// temporaires nettoyés, erreur exposée. Le montage n'est jamais modifié.
    ///
    /// La restauration du statut est ATTENDUE avant de libérer l'emplacement
    /// d'export (`finish`) : sans cela, un nouvel export lancé aussitôt
    /// poserait `exporting` pendant qu'une restauration tardive le
    /// ramènerait à `assembling` — le dock afficherait un état faux.
    private func handle(error: ExportError, projectID: UUID) async {
        errorByProject[projectID] = error
        if error == .cancelled {
            logger.info("Export annulé (§58) — projet intact, fichier temporaire supprimé.")
        } else {
            logger.error("Export échoué : \(error.localizedDescription)")
        }
        // §57/§58 : ceinture de sécurité — l'exporteur supprime déjà SON
        // temporaire ; ce nettoyage couvre un résidu laissé par une tâche
        // tuée avant son `defer`.
        fileStore.clearTemporaryFiles(projectID: projectID)
        // §10 : retour à `assembling`/`complete`.
        do {
            try await projectStore.setExporting(false, projectID: projectID)
        } catch {
            logger.error("Statut de projet non restauré après export : \(error.localizedDescription)")
        }
    }

    /// Publie la progression (§58), sans jamais régresser : les tâches de
    /// rappel n'ont aucun ordre FIFO garanti, une valeur plus ancienne
    /// arrivée après une plus récente est ignorée.
    private func update(progress: Double, projectID: UUID) {
        guard runningTasks[projectID] != nil else { return } // rappel tardif
        let clamped = min(max(progress, 0), 1)
        if let current = progressByProject[projectID], current > clamped { return }
        progressByProject[projectID] = clamped
    }

    /// Libère l'emplacement d'export du projet. La progression est effacée :
    /// c'est `lastOutcome` (succès) ou `lastError` (échec/annulation) qui
    /// porte le résultat — jamais une barre figée à 100 %.
    private func finish(projectID: UUID) {
        runningTasks[projectID] = nil
        progressByProject[projectID] = nil
    }
}
