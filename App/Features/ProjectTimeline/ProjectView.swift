import SwiftData
import SwiftUI

/// Écran projet vide (spec §32) — Jalon 2.
///
/// - Partie haute : texte centré « Ajoutez une musique pour commencer ».
/// - Dock bas contextuel, ligne « Projet vide » du §36 :
///   gauche `Projets` (retour accueil), centre `+ Importer une musique`
///   en matériau translucide (§37). L'import réel arrive au Jalon 3.
/// - Titre du projet affiché sobrement dans la barre — aucune action
///   obligatoire en haut (§30) ; le retour passe par le dock, donc le
///   bouton retour système est masqué (cohérence pouce).
/// - Aucune animation décorative (§38), libellés accessibles et cibles
///   ≥ 44 pt (§39).
///
/// La vue reçoit uniquement un `UUID` : `ProjectRecord` n'est pas `Sendable`
/// et ne traverse jamais une frontière d'acteur.
struct ProjectView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private let projectID: UUID

    /// Le projet est chargé par une `@Query` filtrée sur son identifiant :
    /// la vue se met à jour automatiquement (renommage, statut…).
    @Query private var projects: [ProjectRecord]

    init(projectID: UUID) {
        self.projectID = projectID
        _projects = Query(filter: #Predicate<ProjectRecord> { record in
            record.id == projectID
        })
    }

    var body: some View {
        Group {
            if let project = projects.first {
                content(displayTitle: project.customTitle ?? project.automaticTitle)
            } else {
                notFoundFallback
            }
        }
        // Le dock fournit le retour (« Projets ») en zone basse (§30) :
        // le bouton retour système du haut est masqué.
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Contenu (§32)

    private func content(displayTitle: String) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // Partie haute §32 : simple invite, aucune action obligatoire
            // au-dessus de ~65 % de la hauteur (§30).
            Text("Ajoutez une musique pour commencer")
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) { dock }
        .navigationTitle(displayTitle)
        .toolbarTitleDisplayMode(.inline)
    }

    /// Projet introuvable dans le contexte principal : soit la création vient
    /// d'être sauvegardée par le `ProjectStore` et n'est pas encore propagée,
    /// soit le projet a réellement été supprimé. On vérifie auprès du store
    /// avant de revenir à l'accueil — jamais de retour intempestif juste
    /// après « ouvrir immédiatement la timeline » (§31).
    private var notFoundFallback: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ProgressView()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        // Jamais de spinner sans issue : le dock « Projets » reste disponible
        // même si la propagation inter-contextes SwiftData tarde (§30).
        .safeAreaInset(edge: .bottom) { fallbackDock }
        .task {
            do {
                if try await environment.projectStore.summary(id: projectID) == nil {
                    dismiss()
                    return
                }
                // Le projet existe côté store mais la @Query du mainContext ne
                // le voit pas encore : on laisse 2 s à la propagation
                // inter-contextes, puis on re-vérifie avant de revenir.
                try? await Task.sleep(for: .seconds(2))
                if try await environment.projectStore.summary(id: projectID) == nil {
                    dismiss()
                }
            } catch {
                environment.logger.error("Chargement du projet impossible : \(error.localizedDescription)")
                dismiss()
            }
        }
    }

    /// Dock minimal du fallback : uniquement la sortie « Projets ».
    private var fallbackDock: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text("Projets")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52) // cible ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Projets")
            .accessibilityHint("Revient à la liste des projets.")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Dock bas (§32, §36 ligne « Projet vide », §37)

    private var dock: some View {
        HStack(spacing: 12) {
            // Gauche : retour à la liste des projets.
            Button {
                dismiss()
            } label: {
                Text("Projets")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52) // cible ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Projets")
            .accessibilityHint("Revient à la liste des projets.")

            // Centre : action principale « + Importer une musique ».
            Button {
                // Jalon 3 : fileImporter audio (validation UTI, copie dans
                // Application Support, lecture, analyse automatique §32).
                environment.logger.info("Import de musique demandé — sera branché au Jalon 3.")
            } label: {
                Label("Importer une musique", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52) // cible ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Importer une musique")
            .accessibilityHint("L'import de musique arrive dans une prochaine version.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - Preview

#Preview {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    let now = Date.now
    let record = ProjectRecord(
        id: UUID(),
        automaticTitle: automaticProjectTitle(date: now),
        customTitle: nil,
        createdAt: now,
        updatedAt: now,
        statusRaw: ProjectStatus.draft.rawValue,
        selectedPaceRaw: nil,
        activeSlotIndex: 0,
        audioRelativePath: nil,
        analysisRelativePath: nil,
        geometryData: nil,
        lastAlbumIdentifier: nil,
        analysisVersion: 1,
        scoreVersion: 1
    )
    container.mainContext.insert(record)
    return NavigationStack {
        ProjectView(projectID: record.id)
    }
    .environment(environment)
    .modelContainer(container)
}
