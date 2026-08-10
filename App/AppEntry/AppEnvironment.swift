import Foundation

/// Conteneur de services de l'application (spec §6).
///
/// Jalon 0 : conteneur minimal, expose uniquement le logger.
/// Les services des jalons suivants s'y brancheront :
/// - Jalon 2 : persistance des projets (SwiftData) — volontairement absent ici ;
/// - Jalon 3 : import audio (`AudioImporting`) ;
/// - Jalon 4+ : analyse musicale (`MusicAnalyzing`), génération de scores
///   (`EditScoreGenerating`), photothèque (`MediaLibraryBrowsing`),
///   preview (`PreviewBuilding`), export (`ProjectExporting`).
@MainActor
final class AppEnvironment {
    /// Logger de la catégorie « app » pour le cycle de vie général.
    let logger: AppLogger

    init() {
        self.logger = AppLogger(category: .app)
    }
}
