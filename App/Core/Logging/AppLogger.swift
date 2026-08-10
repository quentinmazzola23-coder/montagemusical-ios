import Foundation
import OSLog

/// Wrapper OSLog centralisé (spec §5 : OSLog pour les journaux locaux).
///
/// Rappel §69A (confidentialité et protection locale) :
/// - ne pas journaliser les noms complets de fichiers personnels en Release ;
/// - ne jamais enregistrer de waveform ou de miniature dans les logs.
/// Les interpolations dynamiques ci-dessous utilisent la confidentialité par
/// défaut d'OSLog (masquées en Release), ce qui va dans le sens du §69A ;
/// ne pas les marquer `.public` pour des valeurs personnelles.
struct AppLogger: Sendable {
    /// Catégories de journalisation de l'application.
    enum Category: String, Sendable {
        case app
        case analysis
        case media
        case export
    }

    /// Sous-système = identifiant de bundle de l'application.
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.example.montagemusical"

    private let logger: Logger

    init(category: Category) {
        self.logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
    }

    func debug(_ message: String) {
        logger.debug("\(message)")
    }

    func info(_ message: String) {
        logger.info("\(message)")
    }

    func error(_ message: String) {
        logger.error("\(message)")
    }
}
