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
//  - succès    → phase 5 §33 (« Création des rythmes ») publiée par
//    l'acteur, génération des partitions (Jalon 5, HORS acteur — tâche
//    détachée pour ne pas geler le polling ni l'annulation), écriture
//    `analysis/scores-v1.json` + `analysis/scores-meta-v1.json` (§11,
//    §61), puis `saveScores` + `saveAnalysisResult` (statut final
//    `awaitingPaceSelection`) ;
//  - annulation → checkpoint (ou cache §69) conservé, statut INCHANGÉ
//    (`analyzing`) : reprise à la prochaine ouverture du projet ;
//  - échec (analyse OU génération) → statut `failed` + journal ; le bouton
//    « Réessayer » (§63) est offert par l'interface (version complète au
//    Jalon 6).
//

import AVFoundation
import Foundation

// Non defini par la specification — definition minimale V1.
actor AudioAnalysisActor {

    /// Chemin relatif §11 des partitions générées (Jalon 5).
    static let scoresRelativePath = "analysis/scores-v1.json"

    /// Chemin relatif §11 des métadonnées de validité des partitions
    /// (§61) : version du générateur + empreinte de configuration.
    static let scoresMetaRelativePath = "analysis/scores-meta-v1.json"

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
        // IDEMPOTENCE (Jalon 5) : un projet déjà en `awaitingPaceSelection`
        // — analyse ET partitions déjà sauvegardées (`scores-v1.json` écrit
        // avec la version courante du générateur) — est écarté ici :
        // `startAnalysisIfNeeded` ne refait rien. Une régénération après
        // évolution du moteur passe par une action explicite (§61 : jamais
        // de recalcul automatique d'un projet terminé).
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
            let result = try await analyzer.analyze(audio: audio, configuration: .production) { progress in
                Task { await self.update(progress: progress, projectID: projectID) }
            }

            // ========================================================
            // Phase 5 §33 — « Création des rythmes » (Jalon 5)
            // ========================================================
            // Publiée par l'ACTEUR : le moteur d'analyse s'arrête aux 4
            // premières phases §33 ; les 4 sont terminées, la génération
            // des partitions commence.
            update(
                progress: AnalysisProgress(
                    phase: .rhythmCreation,
                    completedPhases: [
                        .audioPreparation, .pulseAndTempo,
                        .phrasesAndStructure, .buildUpsAndImpacts,
                    ]
                ),
                projectID: projectID
            )
            try Task.checkCancellation()

            // Génération HORS acteur : `generateScores` est un calcul pur
            // potentiellement long ; exécuté sur l'executor de l'acteur il
            // gèlerait `currentProgress` (polling de l'interface) et
            // `cancelAnalysis` pendant toute la phase 5. `Task.detached`
            // l'envoie sur le pool global (`result` et la configuration
            // sont `Sendable`, le générateur est un struct `Sendable`).
            // Le calcul lui-même n'est pas annulable, mais l'annulation
            // est honorée ci-dessous AVANT toute écriture : rien n'est
            // modifié sur disque ni en base après un `cancel`.
            let configuration = ScoreConfiguration.production
            let scores = try await Task.detached(priority: .userInitiated) {
                try DeterministicEditScoreGenerator()
                    .generateScores(from: result, configuration: configuration)
            }.value

            // Annulée pendant la génération → aucune écriture (le résultat
            // d'analyse reste en cache §69, les partitions seront
            // régénérées à la reprise).
            try Task.checkCancellation()
            try writeScores(scores, projectID: projectID)
            try writeScoresMeta(
                configuration: configuration,
                analysisVersion: result.version,
                projectID: projectID
            )

            // Les deux sauvegardes, dans cet ordre : `saveScores` (champ
            // `scoreVersion` §61, statut inchangé) PUIS `saveAnalysisResult`
            // (chemin + version d'analyse + statut) — le statut final reste
            // `awaitingPaceSelection` (annexe A).
            try await projectStore.saveScores(
                relativePath: Self.scoresRelativePath,
                scoreVersion: DeterministicEditScoreGenerator.generatorVersion,
                projectID: projectID
            )
            try await projectStore.saveAnalysisResult(
                relativePath: "analysis/analysis-v1.json",
                analysisVersion: DeterministicMusicAnalyzer.engineVersion,
                projectID: projectID
            )
        } catch is CancellationError {
            // §8.1/§63 : statut INCHANGÉ (`analyzing`) — reprise à la
            // prochaine ouverture du projet. Deux fenêtres d'annulation :
            // - pendant l'ANALYSE : le checkpoint du dernier jalon terminé
            //   est conservé, la reprise repart de ce checkpoint ;
            // - pendant la GÉNÉRATION des partitions (Jalon 5) : le
            //   checkpoint d'analyse a déjà été effacé au succès de
            //   l'analyse, mais le résultat complet est en cache (§69) —
            //   la réouverture RELANCE l'analyse via `startAnalysisIfNeeded`
            //   (statut resté `analyzing`), l'analyse sort immédiatement du
            //   cache sans recalcul, puis les partitions sont REGÉNÉRÉES.
            logger.info("Analyse annulée — reprise à la prochaine ouverture (checkpoint ou cache §69).")
        } catch {
            // Échec de l'analyse OU de la génération des partitions : même
            // traitement (§63) — statut `failed` + journal ; le bouton
            // « Réessayer » relance via `setStatus(.analyzing)` +
            // `startAnalysisIfNeeded` (une analyse déjà réussie sortira du
            // cache §69, seules les partitions seront recalculées).
            logger.error("Analyse ou génération des partitions échouée : \(error.localizedDescription)")
            do {
                try await projectStore.setStatus(.failed, projectID: projectID)
            } catch {
                logger.error("Statut d'échec non enregistré : \(error.localizedDescription)")
            }
        }
        finish(projectID: projectID)
    }

    /// Écrit `analysis/scores-v1.json` (§11) — `EditScoreFamily` est
    /// `Codable`. Écriture ATOMIQUE (jamais de JSON partiel lisible),
    /// encodeur à clés triées (déterministe, même convention que
    /// `AnalysisCache`).
    private func writeScores(_ scores: EditScoreFamily, projectID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(scores)
        let url = fileStore.directory(for: projectID).appending(path: Self.scoresRelativePath)
        try data.write(to: url, options: .atomic)
    }

    /// Écrit `analysis/scores-meta-v1.json` À CÔTÉ des partitions (§61 :
    /// les critères de validité — version du générateur + configuration —
    /// sont tracés avec le résultat, même approche que
    /// `analysis-meta-v1.json` pour l'analyse). Exploité au Jalon 6 : des
    /// partitions absentes ou dont la méta ne correspond plus (générateur
    /// ou configuration ayant évolué) sont PÉRIMÉES → l'application
    /// propose une régénération explicite, jamais silencieuse (§61 :
    /// aucun recalcul automatique d'un projet terminé). Écrit APRÈS
    /// `scores-v1.json` : une méta sans partitions validerait un fichier
    /// absent, l'inverse est inoffensif (méta absente → partitions
    /// considérées périmées).
    private func writeScoresMeta(
        configuration: ScoreConfiguration,
        analysisVersion: Int,
        projectID: UUID
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // `ScoresMeta` : schéma unique partagé (défini dans ScoreLibrary.swift).
        let meta = ScoresMeta(
            generatorVersion: DeterministicEditScoreGenerator.generatorVersion,
            configurationFingerprint: try ScoreConfigurationFingerprint.fingerprint(of: configuration),
            analysisVersion: analysisVersion
        )
        let data = try encoder.encode(meta)
        let url = fileStore.directory(for: projectID).appending(path: Self.scoresMetaRelativePath)
        try data.write(to: url, options: .atomic)
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
