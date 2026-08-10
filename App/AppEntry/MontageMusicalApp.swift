import SwiftUI

/// Point d'entrée de l'application (spec §6, §75 Jalon 0).
///
/// L'`AppEnvironment` (conteneur de services) sera injecté dans la hiérarchie
/// de vues lors des jalons suivants (Jalon 2 : projets et persistance).
@main
struct MontageMusicalApp: App {
    var body: some Scene {
        WindowGroup {
            ProjectListView()
        }
    }
}
