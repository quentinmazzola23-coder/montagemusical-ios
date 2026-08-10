//
//  AudioAnalysisActor.swift
//  MontageMusical
//
//  Acteur dédié à l'analyse musicale (§8 : « AudioAnalysisActor : une
//  analyse lourde à la fois par projet »). Idempotent : une analyse déjà en
//  cours est rejointe ; un cache complet retourne immédiatement (via
//  `DeterministicMusicAnalyzer`).
//
//  Cycle de vie (annexe A `analyze`, §8.1, §63) :
//  - succès    → `saveAnalysisResult` (statut `awaitingPaceSelection`) ;
//  - annulation → checkpoint conservé, statut INCHANGÉ (`analyzing`) :
//    reprise à la prochaine ouverture du projet ;
//  - échec     → statut `failed` + journal ; le bouton « Réessayer » (§63)
//    est offert par l'interface (version complète au Jalon 6).
//

import AVFoundation
import Foundation

// Non defini par la specification — definition minimale V1.
actor AudioAnalysisActor {

    private let analyzer: DeterministicMusicAnalyzer
    private let projectStore: ProjectStore
    private let fileStore: ProjectFileStore
    private let logger = AppLogger(category: .analysis)

    /// Une analyse au plus par projet (§8).
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    /// Garde de réentrance : projets dont le démarrage est en préparation
    /// (les `await` de préparation rendent l'acteur réentrant).
    private var startingProjects: Set<UUID> = []
    /// Dernière progression publiée par projet — état observable par
    /// l'interface (§33 : phase courante + étapes terminées, sans
    /// pourcentage).
    private var progressByProject: [UUID: AnalysisProgress] = [:]

    init(
        analyzer: DeterministicMusicAnalyzer,
        projectStore: ProjectStore,
        fileStore: ProjectFileStore
    ) {
        self.analyzer = analyzer
        self.projectStore = projectStore
        self.fileStore = fileStore
    }

    // MARK: - Démarrage idempotent (§8)

    /// Lance l'analyse du projet si nécessaire. Déjà en cours → rejoint
    /// (retour immédiat, l'interface observe `currentProgress`). Cache
    /// complet → l'analyseur retourne immédiatement et le statut passe à
    /// `awaitingPaceSelection`.
    func startAnalysisIfNeeded(projectID: UUID) async {
        guard !startingProjects.contains(projectID) else { return }
        if let existing = runningTasks[projectID] {
            guard existing.isCancelled else {
                return // déjà en cours → rejoint
            }
            // Réouverture immédiate après une annulation (§8.1) : attendre
            // la fin propre de la tâche annulée puis RE-VÉRIFIER tous les
            // gardes (l'acteur est réentrant pendant l'await) — sans quoi
            // la reprise serait silencieusement perdue.
            await existing.value
            return await startAnalysisIfNeeded(projectID: projectID)
        }
        startingProjects.insert(projectID)
        defer { startingProjects.remove(projectID) }

        // Ne démarrer que pour un projet réellement en attente d'analyse.
        do {
            guard let summary = try await projectStore.summary(id: projectID),
                  summary.status == .analyzing else {
                return
            }
        } catch {
            logger.error("Statut du projet illisible avant analyse : \(error.localizedDescription)")
            return
        }

        // Musique du projet (§11 : chemin relatif, jamais d'URL externe).
        let relativePath: String?
        do {
            relativePath = try await projectStore.audioRelativePath(projectID: projectID)
        } catch {
            logger.error("Chemin audio illisible avant analyse : \(error.localizedDescription)")
            return
        }
        guard let relativePath else {
            logger.error("Analyse demandée sans musique importée — ignorée.")
            return
        }
        let url = fileStore.directory(for: projectID).appending(path: relativePath)

        // Durée RÉELLE lue du fichier (frontière AVFoundation → MediaTime,
        // §9). Fichier illisible → l'analyse échouera proprement plus loin
        // avec une durée nulle plutôt qu'une valeur inventée.
        var duration = MediaTime.zero
        if let cmDuration = try? await AVURLAsset(url: url).load(.duration),
           let mediaDuration = MediaTime(cmTime: cmDuration) {
            duration = mediaDuration
        }

        let audio = ImportedAudio(
            projectID: projectID,
            relativePath: relativePath,
            originalFilename: url.lastPathComponent,
            duration: duration,
            fileExtension: url.pathExtension
        )

        runningTasks[projectID] = Task {
            await self.runAnalysis(audio: audio, projectID: projectID)
        }
    }

    /// Annule l'analyse en cours du projet (le checkpoint du dernier jalon
    /// terminé est conservé — §8.1, §63 ; reprise via
    /// `startAnalysisIfNeeded` à la prochaine ouverture).
    func cancelAnalysis(projectID: UUID) {
        runningTasks[projectID]?.cancel()
    }

    /// Dernière progression publiée, ou `nil` si aucune analyse n'est en
    /// cours pour ce projet. L'interface la lit par polling (Jalon 4) ;
    /// un `AsyncStream` pourra s'y greffer sans changer l'acteur.
    func currentProgress(projectID: UUID) -> AnalysisProgress? {
        progressByProject[projectID]
    }

    // MARK: - Exécution

    private func runAnalysis(audio: ImportedAudio, projectID: UUID) async {
        do {
            _ = try await analyzer.analyze(audio: audio, configuration: .production) { progress in
                Task { await self.update(progress: progress, projectID: projectID) }
            }
            // Succès : chemin du résultat + version + statut
            // `awaitingPaceSelection` en une seule écriture (annexe A).
            try await projectStore.saveAnalysisResult(
                relativePath: "analysis/analysis-v1.json",
                analysisVersion: DeterministicMusicAnalyzer.engineVersion,
                projectID: projectID
            )
        } catch is CancellationError {
            // §8.1/§63 : checkpoint conservé, statut INCHANGÉ (`analyzing`)
            // — l'analyse reprend à la prochaine ouverture du projet.
            logger.info("Analyse annulée — checkpoint conservé pour reprise.")
        } catch {
            logger.error("Analyse échouée : \(error.localizedDescription)")
            do {
                // §63 : échec → statut `failed` ; le bouton « Réessayer »
                // relance via `setStatus(.analyzing)` + `startAnalysisIfNeeded`.
                try await projectStore.setStatus(.failed, projectID: projectID)
            } catch {
                logger.error("Statut d'échec non enregistré : \(error.localizedDescription)")
            }
        }
        finish(projectID: projectID)
    }

    private func update(progress: AnalysisProgress, projectID: UUID) {
        // Une mise à jour tardive (Task non structurée du callback) ne doit
        // jamais repeupler l'état d'un projet dont l'analyse est terminée.
        guard runningTasks[projectID] != nil else { return }
        // Les Task du callback n'ont AUCUN ordre FIFO garanti : une mise à
        // jour dont la phase est ANTÉRIEURE à la phase courante (ordre de
        // déclaration dans `AnalysisPhase.allCases`, qui est l'ordre §33)
        // est ignorée — la progression affichée ne régresse jamais. Une
        // phase égale reste acceptée (`completedPhases` peut grossir).
        if let current = progressByProject[projectID],
           let currentIndex = AnalysisPhase.allCases.firstIndex(of: current.phase),
           let incomingIndex = AnalysisPhase.allCases.firstIndex(of: progress.phase),
           incomingIndex < currentIndex {
            return
        }
        progressByProject[projectID] = progress
    }

    private func finish(projectID: UUID) {
        runningTasks[projectID] = nil
        progressByProject[projectID] = nil
    }
}
