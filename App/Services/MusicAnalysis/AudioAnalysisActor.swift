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

    /// Moteur d'analyse derrière le protocole §7 (existentiel `Sendable` :
    /// l'analyse est consommée hors `@MainActor` et le moteur avancé Jalon 11
    /// se branche au même endroit).
    private let analyzer: any MusicAnalyzing & Sendable
    /// Générateur de partitions derrière le protocole §7 — injecté pour que
    /// la phase 5 soit substituable en test sans toucher à l'acteur.
    private let scoreGenerator: any EditScoreGenerating & Sendable
    private let projectStore: ProjectStore
    private let fileStore: ProjectFileStore
    private let logger = AppLogger(category: .analysis)

    /// Une analyse au plus par projet (§8).
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    /// Garde de réentrance : projets dont le démarrage est en préparation
    /// (les `await` de préparation rendent l'acteur réentrant).
    private var startingProjects: Set<UUID> = []
    /// Projets dont une analyse ANNULÉE doit être relancée dès qu'elle se
    /// sera terminée (§8.1 : reprise à la réouverture). Voir l'invariant
    /// détaillé dans `startAnalysisIfNeeded` / `finish`.
    private var restartRequests: Set<UUID> = []
    /// Dernière progression publiée par projet — état observable par
    /// l'interface (§33 : phase courante + étapes terminées, sans
    /// pourcentage).
    private var progressByProject: [UUID: AnalysisProgress] = [:]

    init(
        analyzer: any MusicAnalyzing & Sendable,
        scoreGenerator: any EditScoreGenerating & Sendable = DeterministicEditScoreGenerator(),
        projectStore: ProjectStore,
        fileStore: ProjectFileStore
    ) {
        self.analyzer = analyzer
        self.scoreGenerator = scoreGenerator
        self.projectStore = projectStore
        self.fileStore = fileStore
    }

    // MARK: - Démarrage idempotent (§8)

    /// Lance l'analyse du projet si nécessaire. Déjà en cours → rejoint
    /// (retour immédiat, l'interface observe `currentProgress`). Cache
    /// complet → l'analyseur retourne immédiatement et le statut passe à
    /// `awaitingPaceSelection`.
    ///
    /// **Toujours NON BLOQUANT.** Aucun chemin de cette méthode n'attend la
    /// fin d'une analyse : elle démarre, enregistre une intention, ou sort.
    /// C'est une exigence d'INTERFACE, pas une optimisation — l'appelant
    /// (`ProjectView.task(id: status)`) ne démarre sa boucle de polling
    /// qu'APRÈS le retour de cet appel. La version précédente faisait
    /// `await existing.value` sur la tâche annulée : tant que la génération
    /// détachée orpheline n'avait pas fini (jusqu'à ~30 s), la vue restait
    /// figée sur son état initial et affichait « Préparation audio —
    /// Phase 1 sur 5 » alors que le moteur était ailleurs. Un état affiché
    /// FACTUELLEMENT FAUX (§33 : la progression doit décrire ce qui se passe).
    func startAnalysisIfNeeded(projectID: UUID) async {
        guard !startingProjects.contains(projectID) else { return }
        if let existing = runningTasks[projectID] {
            guard existing.isCancelled else {
                return // déjà en cours → rejoint
            }
            // Réouverture immédiate après une annulation (§8.1). La tâche
            // annulée est encore en train de se terminer proprement ; on
            // enregistre une INTENTION DE RELANCE et on sort tout de suite.
            // C'est `finish` — appelé sur l'acteur à la toute fin de cette
            // même tâche — qui rappellera `startAnalysisIfNeeded`, lequel
            // re-vérifiera alors TOUS les gardes (statut, chemin audio…).
            //
            // INVARIANT (démonstration, c'est le point délicat) :
            // 1. `restartRequests.insert` n'a lieu QUE si
            //    `runningTasks[projectID] != nil`. Or `finish` met cette
            //    entrée à `nil` puis consomme la demande, le tout SANS
            //    `await` intercalé : sur un acteur, cette séquence est
            //    atomique. Une demande ne peut donc pas être insérée après
            //    que `finish` l'a consultée → aucune relance perdue.
            // 2. `remove` rend l'intention à usage unique, et la relance
            //    elle-même n'insère jamais de nouvelle demande (au moment
            //    où elle s'exécute, `runningTasks[projectID]` est `nil`) →
            //    aucune boucle infinie. Une nouvelle demande exige une
            //    nouvelle annulation, donc une nouvelle action utilisateur.
            // 3. Double lancement impossible : si un autre appelant démarre
            //    une analyse entre `finish` et l'exécution de la relance, la
            //    relance retombe soit sur `startingProjects.contains` soit
            //    sur une tâche vivante non annulée, et sort dans les deux cas.
            restartRequests.insert(projectID)
            return
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
            // sont `Sendable`, le générateur est un existentiel `Sendable`).
            //
            // ANNULATION — `Task.detached` n'hérite JAMAIS de l'annulation de
            // la tâche qui le crée : sans le pont ci-dessous, un
            // `cancelAnalysis` laissait la génération brûler un cœur jusqu'au
            // bout (1 à 6 s pour 5 min, ~30 s pour ~10 min avec un champ
            // dense) puis JETAIT tout le travail au `checkCancellation`
            // suivant. `withTaskCancellationHandler` propage l'annulation à
            // la tâche détachée, où le générateur la voit par
            // `Task.checkCancellation()` dans sa boucle de raffinement. Si
            // l'annulation arrive avant même l'entrée dans le handler,
            // `onCancel` est exécuté immédiatement — aucune fenêtre aveugle.
            //
            // Le contrat de non-écriture est INCHANGÉ : annulée ici, la
            // génération lève `CancellationError`, donc rien n'est écrit sur
            // disque ni en base (le `checkCancellation` explicite qui suit
            // reste le filet pour une génération qui aurait ignoré la
            // demande).
            let configuration = ScoreConfiguration.production
            let generator = scoreGenerator
            let generation = Task.detached(priority: .userInitiated) {
                try generator.generateScores(from: result, configuration: configuration)
            }
            let scores = try await withTaskCancellationHandler {
                try await generation.value
            } onCancel: {
                generation.cancel()
            }

            // Annulée pendant la génération → aucune écriture (le résultat
            // d'analyse reste en cache §69, les partitions seront
            // régénérées à la reprise).
            try Task.checkCancellation()
            try writeScores(scores, projectID: projectID)
            // `result.version` est la version de SCHÉMA du résultat d'analyse
            // (`DeterministicMusicAnalyzer.analysisSchemaVersion`), pas celle
            // du moteur : c'est elle qui décide de la validité §61 des
            // partitions. La version de MOTEUR est écrite à côté, comme
            // trace non discriminante (voir `ScoresMeta`).
            try writeScoresMeta(
                configuration: configuration,
                analysisVersion: result.version,
                analysisEngineVersion: DeterministicMusicAnalyzer.engineVersion,
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
            // `ProjectRecord.analysisVersion` est une TRACE §61 (« conserver
            // la version du moteur d'analyse »), jamais une clé de validité :
            // la péremption des partitions passe par `scores-meta-v1.json`,
            // celle du cache par `analysis-meta-v1.json`. On y écrit donc la
            // version de MOTEUR — la seule qui dise quel algorithme a produit
            // ce résultat.
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
    ///
    /// Deux versions d'analyse y sont écrites, et une seule tranche :
    /// `analysisVersion` porte la version de SCHÉMA du résultat (clé de
    /// validité §61 des partitions) ; `analysisEngineVersion` porte la
    /// version d'ALGORITHME (trace §61 seulement). Sans cette séparation, la
    /// moindre correction de bug du moteur périmait les partitions de tous
    /// les projets en même temps que le cache d'analyse — voir la note de
    /// `DeterministicMusicAnalyzer.analysisSchemaVersion`.
    ///
    /// §61 « Conserver : […] version du modèle Core ML » : la version est
    /// demandée au registre (`CoreMLModelRegistry`, source unique) et écrite
    /// telle quelle dans la méta — `nil` tant qu'aucun modèle n'est embarqué
    /// (§29A/§86). Une méta écrite AVANT l'ajout de ce champ reste valide
    /// (décodage tolérant, `ScoresMeta.init(from:)`) : aucun projet existant
    /// n'est périmé par ce seul ajout.
    private func writeScoresMeta(
        configuration: ScoreConfiguration,
        analysisVersion: Int,
        analysisEngineVersion: Int,
        projectID: UUID
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // `ScoresMeta` : schéma unique partagé (défini dans ScoreLibrary.swift).
        let meta = ScoresMeta(
            generatorVersion: DeterministicEditScoreGenerator.generatorVersion,
            configurationFingerprint: try ScoreConfigurationFingerprint.fingerprint(of: configuration),
            analysisVersion: analysisVersion,
            analysisEngineVersion: analysisEngineVersion,
            // §61 « version du modèle Core ML » — source UNIQUE : le registre.
            // `nil` aujourd'hui (aucun modèle embarqué, §29A/§86), et c'est
            // exactement la trace exigée : ces partitions viennent du moteur
            // déterministe seul. Cet acteur n'invente aucune version.
            coreMLModelVersion: CoreMLModelRegistry.beatActivationModelVersion()
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

    /// Fin de vie d'une analyse : libère l'emplacement du projet puis honore
    /// une éventuelle demande de relance (§8.1).
    ///
    /// Exécuté sur l'acteur SANS aucun `await` : le retrait de la tâche et la
    /// consommation de la demande forment une section atomique — c'est ce qui
    /// rend l'invariant démontré dans `startAnalysisIfNeeded` vrai.
    ///
    /// La relance passe par une `Task` non structurée : appeler
    /// `startAnalysisIfNeeded` directement ici imposerait un `await` au
    /// milieu de cette section (l'appel est asynchrone) et rouvrirait
    /// exactement la fenêtre de réentrance que l'on ferme.
    private func finish(projectID: UUID) {
        runningTasks[projectID] = nil
        progressByProject[projectID] = nil
        guard restartRequests.remove(projectID) != nil else { return }
        logger.info("Reprise de l'analyse demandée pendant une annulation — relance.")
        Task { await self.startAnalysisIfNeeded(projectID: projectID) }
    }
}
