import Foundation
import Observation
import SwiftData

/// Conteneur de services de l'application (spec §6).
///
/// Jalon 2 : expose la persistance des projets (SwiftData) en plus du logger.
/// Les services des jalons suivants s'y brancheront :
/// - Jalon 3 : import audio (`AudioImporting`) ;
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
        self.projectStore = ProjectStore(modelContainer: modelContainer)
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
