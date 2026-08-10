import Foundation
import Observation
import SwiftData

/// Conteneur de services de l'application (spec §6).
///
/// Jalon 3 : expose l'import audio (`AudioImporter`), l'accès aux fichiers
/// de projet (`ProjectFileStore`) et l'extraction de forme d'onde
/// (`WaveformExtractor`) en plus de la persistance (Jalon 2) et du logger.
/// Les services des jalons suivants s'y brancheront :
/// - Jalon 4+ : analyse musicale (`MusicAnalyzing`), génération de scores
///   (`EditScoreGenerating`), photothèque (`MediaLibraryBrowsing`),
///   preview (`PreviewBuilding`), export (`ProjectExporting`).
///
/// `@Observable` pour permettre l'injection via `.environment(_:)` et la
/// lecture via `@Environment(AppEnvironment.self)` dans les vues.
@MainActor
@Observable
final class AppEnvironment {
    /// Logger de la catégorie « app » pour le cycle de vie général.
    let logger: AppLogger

    /// Conteneur SwiftData partagé (schéma : `ProjectRecord`,
    /// `ProjectSlotRecord`, `ClipAssignmentRecord`).
    let modelContainer: ModelContainer

    /// Accès acteur à la persistance des projets (création, résumés,
    /// renommage, duplication, suppression — spec §31, §59, §60).
    let projectStore: ProjectStore

    /// Fichiers lourds des projets hors SwiftData (arbre §11) — même racine
    /// par défaut (`Application Support/Projects/`) que celle utilisée en
    /// interne par `ProjectStore`.
    let fileStore: ProjectFileStore

    /// Import audio (Jalon 3, §62, §78) : validation réelle AVFoundation
    /// puis copie dans `audio/original.<extension>` (§11).
    let audioImporter: AudioImporter

    /// Extraction de la forme d'onde (§16.2, §68) : pics normalisés 0...1,
    /// lecture par blocs pour limiter la mémoire.
    let waveformExtractor: WaveformExtractor

    /// Cache d'analyse et checkpoints de phase dans `analysis/` (§11, §69).
    let analysisCache: AnalysisCache

    /// Moteur musical déterministe niveau A (Jalon 4, §15, §79) — protocole
    /// `MusicAnalyzing` §7 ; le moteur avancé Core ML (Jalon 11) se
    /// branchera derrière le même protocole.
    let musicAnalyzer: DeterministicMusicAnalyzer

    /// Acteur d'analyse (§8) : une analyse lourde à la fois par projet,
    /// progression observable, annulation avec checkpoint conservé (§8.1).
    let audioAnalysisActor: AudioAnalysisActor

    /// Lecture des partitions générées (`analysis/scores-v1.json`, §11) et
    /// de leur validité §61 — écran du choix du rythme (Jalon 6, §34).
    let scoreLibrary: ScoreLibrary

    /// Initialiseur de production : ouvre le conteneur persistant partagé
    /// (Application Support).
    convenience init() {
        let container: ModelContainer
        do {
            container = try ModelContainerFactory.makeShared()
        } catch {
            // Échec d'ouverture de la base au démarrage : sans persistance,
            // aucune fonctionnalité n'est possible (tout est autosauvegardé,
            // spec §3.13, §59, §60). Un crash immédiat et explicite au
            // lancement est préférable à une application qui perdrait
            // silencieusement les projets de l'utilisateur.
            fatalError("Impossible d'ouvrir le conteneur SwiftData partagé : \(error)")
        }
        self.init(modelContainer: container)
    }

    /// Initialiseur d'injection — previews SwiftUI et tests
    /// (utiliser `ModelContainerFactory.makeInMemory()`).
    init(modelContainer: ModelContainer) {
        self.logger = AppLogger(category: .app)
        self.modelContainer = modelContainer
        let projectStore = ProjectStore(modelContainer: modelContainer)
        self.projectStore = projectStore
        let fileStore = ProjectFileStore()
        self.fileStore = fileStore
        self.audioImporter = AudioImporter(fileStore: fileStore)
        self.waveformExtractor = WaveformExtractor()
        let analysisCache = AnalysisCache(fileStore: fileStore)
        self.analysisCache = analysisCache
        let musicAnalyzer = DeterministicMusicAnalyzer(cache: analysisCache, fileStore: fileStore)
        self.musicAnalyzer = musicAnalyzer
        self.audioAnalysisActor = AudioAnalysisActor(
            analyzer: musicAnalyzer,
            projectStore: projectStore,
            fileStore: fileStore
        )
        self.scoreLibrary = ScoreLibrary(fileStore: fileStore)
    }

    /// Maintenance au lancement (§69A) : brouillons vides résiduels,
    /// dossiers orphelins, vidage des `temp/`. Les erreurs sont journalisées,
    /// jamais bloquantes pour le démarrage.
    func performStartupMaintenance() async {
        do {
            try await projectStore.performStartupMaintenance()
        } catch {
            logger.error("Maintenance au lancement impossible : \(error.localizedDescription)")
        }
    }
}
