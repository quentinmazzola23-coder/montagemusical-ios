import SwiftData
import SwiftUI

/// Écran d'accueil (spec §31) — Jalon 2 : liste des projets et création.
///
/// - Liste des projets triée par `updatedAt` décroissant (`@Query`).
/// - Gros bouton `+` centré au-dessus de la safe area : crée un brouillon
///   (titre automatique §10, jamais d'écran de nommage §89) puis ouvre
///   immédiatement la timeline (§31).
/// - Actions secondaires par swipe : renommer, dupliquer, supprimer (§31).
/// - Suppression avec confirmation si le projet a du contenu (musique,
///   associations ou export) ; sinon suppression directe (§31).
/// - Un brouillon sans musique est supprimé au retour à l'accueil (§31),
///   détecté via `.onChange` du chemin de navigation.
/// - Règle du pouce §30 : aucune action obligatoire en haut de l'écran.
/// - Matériaux translucides sobres (§37), aucune animation décorative (§38),
///   libellés accessibles et cibles ≥ 44 pt (§39).
struct ProjectListView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Liste des projets, tri `updatedAt` décroissant (contrat Jalon 2).
    @Query(sort: \ProjectRecord.updatedAt, order: .reverse)
    private var projects: [ProjectRecord]

    /// Chemin de navigation : uniquement des identifiants de projet.
    /// `ProjectRecord` n'est pas `Sendable` et ne traverse jamais une
    /// frontière d'acteur — seuls des `UUID` circulent.
    @State private var path: [UUID] = []

    // Renommage (§31) : alerte avec champ de texte pré-rempli.
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var isRenamePresented = false

    // Suppression (§31) : confirmation seulement si le projet a du contenu.
    @State private var deleteTargetID: UUID?
    @State private var isDeleteConfirmationPresented = false

    /// Anti double-tap sur « + » : une seule création à la fois.
    @State private var isCreatingProject = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .safeAreaInset(edge: .bottom) { createButton }
            .navigationTitle("Projets")
            .navigationDestination(for: UUID.self) { projectID in
                ProjectView(projectID: projectID)
            }
            .alert("Renommer le projet", isPresented: $isRenamePresented) {
                TextField("Titre du projet", text: $renameText)
                Button("Annuler", role: .cancel) {
                    renameTargetID = nil
                }
                Button("Renommer") {
                    confirmRename()
                }
            } message: {
                Text("Laissez le champ vide pour revenir au titre automatique.")
            }
            .confirmationDialog(
                "Supprimer ce projet ?",
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Supprimer le projet", role: .destructive) {
                    confirmDelete()
                }
                Button("Annuler", role: .cancel) {
                    deleteTargetID = nil
                }
            } message: {
                // §31 : la suppression retire métadonnées, analyses, previews
                // et temporaires du sandbox — jamais les rushs de Photos (§69A).
                Text("La musique, les associations et les exports de ce projet seront supprimés. Vos vidéos dans Photos ne seront pas touchées.")
            }
        }
        .onChange(of: path) { oldPath, newPath in
            handleNavigationChange(from: oldPath, to: newPath)
        }
        // §31 : balayage des brouillons vides résiduels à l'apparition —
        // couvre l'app tuée avec un brouillon ouvert, le brouillon dupliqué
        // jamais ouvert et la double création, que le nettoyage au pop ne
        // voit pas. Le projet actuellement ouvert est protégé.
        .task {
            await sweepEmptyDrafts()
        }
    }

    // MARK: - État vide (§31)

    /// État vide conservé du Jalon 0 : « Aucun projet » + sous-texte.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Aucun projet")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Touchez + pour créer votre premier montage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Liste des projets (§31)

    private var projectList: some View {
        List {
            ForEach(projects) { project in
                projectRow(project)
            }
        }
        .listStyle(.plain)
    }

    /// Carte projet : titre affiché, progression textuelle, date relative,
    /// miniature en placeholder neutre (la vraie miniature viendra plus tard).
    private func projectRow(_ project: ProjectRecord) -> some View {
        // Valeurs extraites immédiatement (le record reste sur le MainActor).
        let projectID = project.id
        let title = project.customTitle ?? project.automaticTitle
        let status = statusText(for: project.statusRaw)
        let updatedAt = project.updatedAt

        return Button {
            path.append(projectID)
        } label: {
            HStack(spacing: 12) {
                thumbnailPlaceholder
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(updatedAt, format: updatedAtFormat)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44) // cible tactile ≥ 44 pt (§39)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(status), modifié \(updatedAt.formatted(updatedAtFormat))")
        .accessibilityHint("Ouvre le projet.")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                requestDelete(projectID)
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
            Button {
                beginRename(projectID: projectID, currentTitle: title)
            } label: {
                Label("Renommer", systemImage: "pencil")
            }
            .tint(.blue)
            Button {
                duplicate(projectID)
            } label: {
                Label("Dupliquer", systemImage: "plus.square.on.square")
            }
            .tint(.indigo)
        }
    }

    /// Miniature : placeholder neutre pour le Jalon 2 (§31 « miniature
    /// éventuelle ») — la vraie miniature arrivera avec la photothèque.
    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary)
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }

    /// Progression affichée : libellés français sobres selon `ProjectStatus`.
    private func statusText(for statusRaw: String) -> String {
        guard let status = ProjectStatus(rawValue: statusRaw) else {
            return "Brouillon"
        }
        switch status {
        case .draft: return "Brouillon"
        case .importingAudio: return "Import de la musique"
        case .analyzing: return "Analyse en cours"
        case .awaitingPaceSelection: return "Choix du rythme"
        case .assembling: return "Montage"
        case .partiallyPreviewable: return "Montage partiel"
        case .complete: return "Terminé"
        case .exporting: return "Export en cours"
        case .failed: return "Échec"
        }
    }

    /// Date relative française (« il y a 2 heures ») — l'interface est
    /// 100 % française dans la V1.
    private var updatedAtFormat: Date.RelativeFormatStyle {
        Date.RelativeFormatStyle(presentation: .named, locale: Locale(identifier: "fr_FR"))
    }

    // MARK: - Bouton de création (§31)

    /// Gros bouton `+` circulaire, centré au-dessus de la safe area (§31).
    /// Style translucide conservé (§37), cible ≥ 44 pt (§39).
    private var createButton: some View {
        Button {
            createProject()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 64, height: 64)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isCreatingProject) // anti double-tap : un seul brouillon créé
        .accessibilityLabel("Créer un projet")
        .accessibilityHint("Crée un projet et ouvre immédiatement sa timeline.")
        .padding(.bottom, 16)
    }

    // MARK: - Actions

    /// Action `+` (§31) : créer le projet, générer le titre (fait par le
    /// store), puis ouvrir immédiatement la timeline. Jamais d'écran de
    /// nommage (§89).
    private func createProject() {
        guard !isCreatingProject else { return }
        isCreatingProject = true
        Task {
            defer { isCreatingProject = false }
            do {
                let projectID = try await environment.projectStore.createDraft()
                path.append(projectID)
            } catch {
                environment.logger.error("Création du projet impossible : \(error.localizedDescription)")
            }
        }
    }

    /// §31 : supprime tous les brouillons sans musique, sauf celui
    /// éventuellement ouvert.
    private func sweepEmptyDrafts() async {
        do {
            let deleted = try await environment.projectStore.deleteAllEmptyDrafts(excluding: path.last)
            if deleted > 0 {
                environment.logger.info("Brouillons vides supprimés au balayage : \(deleted)")
            }
        } catch {
            environment.logger.error("Balayage des brouillons vides impossible : \(error.localizedDescription)")
        }
    }

    private func beginRename(projectID: UUID, currentTitle: String) {
        renameTargetID = projectID
        renameText = currentTitle
        isRenamePresented = true
    }

    private func confirmRename() {
        guard let projectID = renameTargetID else { return }
        renameTargetID = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                // Chaîne vide → nil → retour au titre automatique (contrat).
                try await environment.projectStore.rename(
                    projectID: projectID,
                    customTitle: title.isEmpty ? nil : title
                )
            } catch {
                environment.logger.error("Renommage impossible : \(error.localizedDescription)")
            }
        }
    }

    private func duplicate(_ projectID: UUID) {
        Task {
            do {
                _ = try await environment.projectStore.duplicate(projectID: projectID)
            } catch {
                environment.logger.error("Duplication impossible : \(error.localizedDescription)")
            }
        }
    }

    /// Suppression (§31) : confirmation uniquement si le projet contient une
    /// musique, des associations ou un export (`hasContent`).
    private func requestDelete(_ projectID: UUID) {
        Task {
            do {
                let summary = try await environment.projectStore.summary(id: projectID)
                if summary?.hasContent == true {
                    deleteTargetID = projectID
                    isDeleteConfirmationPresented = true
                } else {
                    try await environment.projectStore.delete(projectID: projectID)
                }
            } catch {
                environment.logger.error("Suppression impossible : \(error.localizedDescription)")
            }
        }
    }

    private func confirmDelete() {
        guard let projectID = deleteTargetID else { return }
        deleteTargetID = nil
        Task {
            do {
                try await environment.projectStore.delete(projectID: projectID)
            } catch {
                environment.logger.error("Suppression impossible : \(error.localizedDescription)")
            }
        }
    }

    /// §31 : un brouillon sans musique est supprimé au retour à l'accueil.
    /// Détection par la réduction du chemin de navigation (pop).
    private func handleNavigationChange(from oldPath: [UUID], to newPath: [UUID]) {
        guard oldPath.count > newPath.count, let closedProjectID = oldPath.last else { return }
        Task {
            do {
                let deleted = try await environment.projectStore.deleteIfEmptyDraft(projectID: closedProjectID)
                if deleted {
                    environment.logger.info("Brouillon vide supprimé au retour à l'accueil (§31).")
                }
            } catch {
                environment.logger.error("Nettoyage du brouillon vide impossible : \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Previews

#Preview("Liste vide") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    return ProjectListView()
        .environment(environment)
        .modelContainer(container)
}

#Preview("Avec projets") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    let now = Date.now
    for (offset, status) in [ProjectStatus.draft, .awaitingPaceSelection, .complete].enumerated() {
        let date = now.addingTimeInterval(TimeInterval(-offset) * 3_600)
        let record = ProjectRecord(
            id: UUID(),
            automaticTitle: automaticProjectTitle(date: date),
            customTitle: offset == 2 ? "Descente à ski" : nil,
            createdAt: date,
            updatedAt: date,
            statusRaw: status.rawValue,
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
    }
    return ProjectListView()
        .environment(environment)
        .modelContainer(container)
}
