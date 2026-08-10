import SwiftData
import SwiftUI

/// Point d'entrée de l'application (spec §6, §77 Jalon 2).
///
/// Construit l'`AppEnvironment` une seule fois au lancement, puis l'injecte
/// dans la hiérarchie de vues :
/// - `.environment(_:)` pour les services (`projectStore`, `logger`) ;
/// - `.modelContainer(_:)` pour les `@Query` SwiftData des vues.
@main
struct MontageMusicalApp: App {
    /// Conteneur de services de l'application, construit au lancement.
    /// `AppEnvironment.init()` échoue volontairement (fatalError) si la base
    /// SwiftData partagée ne peut pas être ouverte — voir AppEnvironment.swift.
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .environment(environment)
                .modelContainer(environment.modelContainer)
                // Maintenance au lancement (§69A) : temporaires après crash,
                // dossiers orphelins, brouillons vides résiduels.
                .task {
                    await environment.performStartupMaintenance()
                }
        }
    }
}
