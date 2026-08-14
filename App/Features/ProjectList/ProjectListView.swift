import SwiftData
import SwiftUI

// MARK: - Décision de réouverture (§60) — logique PURE

// Non defini par la specification — definition minimale V1.
/// Ce que l'application doit faire de l'identifiant du dernier projet ouvert
/// au lancement (§60 « Restaurer : projet »).
///
/// Type PUR, sans SwiftUI ni SwiftData : la règle §60 se teste sans écran ni
/// base (`Tests/Unit/ProjectRestoreDecisionTests.swift`).
enum ProjectRestoreDecision: Equatable {
    /// Rouvrir ce projet : il existe encore et a du contenu.
    case open(UUID)
    /// Oublier l'identifiant mémorisé : il ne désigne plus rien
    /// d'ouvrable (illisible, projet supprimé, brouillon vide §31).
    /// Le conserver ferait réessayer indéfiniment au lancement suivant.
    case forget
    /// Ne rien faire : aucun projet n'était mémorisé.
    case none
}

// Non defini par la specification — definition minimale V1.
/// Règle §60 de réouverture, isolée de la vue.
enum ProjectRestore {

    /// Décision de réouverture (§60) à partir de l'identifiant MÉMORISÉ et du
    /// résumé du projet correspondant (`nil` si le `ProjectStore` n'en a
    /// aucun).
    ///
    /// - identifiant vide → `.none` : l'utilisateur a quitté vers la liste,
    ///   il n'y a rien à restaurer et rien à effacer ;
    /// - identifiant illisible (pas un UUID) → `.forget` ;
    /// - projet introuvable (supprimé depuis, base réinitialisée) →
    ///   `.forget` ;
    /// - résumé d'un AUTRE projet → `.forget` : on ne rouvre jamais un projet
    ///   qui n'est pas celui qui était mémorisé ;
    /// - brouillon SANS contenu → `.forget` (§31 : il est de toute façon
    ///   supprimé au retour à l'accueil et par le balayage §69A — le rouvrir
    ///   créerait une course avec ce balayage) ;
    /// - sinon → `.open(identifiant)`.
    static func decision(
        storedIdentifier: String,
        summary: ProjectSummary?
    ) -> ProjectRestoreDecision {
        guard !storedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }
        guard let projectID = parsedProjectID(fromStored: storedIdentifier) else { return .forget }
        guard let summary, summary.id == projectID, summary.hasContent else { return .forget }
        return .open(projectID)
    }

    /// Identifiant à relire, ou `nil` s'il n'y en a pas d'exploitable.
    /// Point de lecture UNIQUE : la vue s'en sert pour savoir s'il vaut la
    /// peine d'interroger le `ProjectStore`, et `decision` pour trancher —
    /// les deux ne peuvent donc pas interpréter la même chaîne autrement.
    static func parsedProjectID(fromStored storedIdentifier: String) -> UUID? {
        UUID(uuidString: storedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Écran d'accueil (spec §31) — Jalon 2 : liste des projets et création.
///
/// - Liste des projets triée par `updatedAt` décroissant (`@Query`).
/// - Gros bouton `+` centré au-dessus de la safe area : crée un brouillon
///   (titre automatique §10, jamais d'écran de nommage §89) puis ouvre
///   immédiatement la timeline (§31).
/// - Actions secondaires par swipe : renommer, dupliquer, supprimer (§31).
/// - Suppression IMMÉDIATE, sans confirmation (écart produit du 13 août 2026
///   demandé par l'utilisateur ; §31 prévoyait une confirmation dès que le
///   projet avait du contenu). Définitive et sans annulation — voir
///   `requestDelete`.
/// - Un brouillon sans musique est supprimé au retour à l'accueil (§31),
///   détecté via `.onChange` du chemin de navigation.
/// - Règle du pouce §30 : aucune action obligatoire en haut de l'écran.
/// - Matériaux translucides sobres (§37), aucune animation décorative (§38),
///   libellés accessibles et cibles ≥ 44 pt (§39).
///
/// Jalon 12 (§60) — RÉOUVERTURE DU DERNIER PROJET. §60 demande de restaurer
/// « projet, case active, position de timeline ». La case active, la
/// progression d'analyse, les associations, la géométrie et le dernier album
/// l'étaient déjà (persistés §59, relus par les écrans concernés) ; il
/// manquait le PROJET lui-même : au lancement à froid, l'application ouvrait
/// toujours la liste. L'identifiant du dernier projet ouvert est désormais
/// mémorisé, écrit à l'ouverture, effacé à la fermeture ; au lancement, s'il
/// existe ENCORE en base, sa `ProjectView` est repoussée dans le
/// `NavigationStack`. Un projet supprimé entre-temps (ou un brouillon vide
/// balayé §31) ramène simplement à la liste : jamais de crash, jamais d'écran
/// vide (voir `restoreLastOpenedProject` et la règle pure `ProjectRestore`).
///
/// Revue finale (§60) — `@SceneStorage` et non `@AppStorage`. `@AppStorage`
/// écrit dans `UserDefaults`, PARTAGÉ par toutes les scènes : sur iPad, deux
/// fenêtres du même projet se seraient écrasées l'une l'autre et la même
/// restauration se serait appliquée à CHAQUE fenêtre rouverte — alors que
/// §60 restaure l'état d'UNE session de travail. `@SceneStorage` range la
/// valeur dans l'état de restauration de la scène : chaque fenêtre retrouve
/// SON dernier projet. Même type (`String`), même code appelant.
///
/// Jalon 12 (§38) — cet écran n'anime rien (choix §38) ; `reduceMotionSafe()`
/// garantit qu'aucune animation implicite ne s'attache au passage
/// « liste vide » ↔ « liste remplie » sous « Réduire les animations ».
struct ProjectListView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Liste des projets, tri `updatedAt` décroissant (contrat Jalon 2).
    @Query(sort: \ProjectRecord.updatedAt, order: .reverse)
    private var projects: [ProjectRecord]

    /// Chemin de navigation : uniquement des identifiants de projet.
    /// `ProjectRecord` n'est pas `Sendable` et ne traverse jamais une
    /// frontière d'acteur — seuls des `UUID` circulent.
    @State private var path: [UUID] = []

    // §60 : réouverture du dernier projet.

    /// Identifiant (UUID textuel) du dernier projet OUVERT, ou chaîne vide
    /// si l'utilisateur a quitté vers la liste. Persisté dans l'état de
    /// restauration de la SCÈNE plutôt qu'en base : c'est un état
    /// d'interface, pas une donnée du projet — le schéma §10 reste verbatim.
    ///
    /// `@SceneStorage` et non `@AppStorage` : `UserDefaults` est partagé par
    /// toutes les scènes, donc sur iPad (multi-fenêtres) la même restauration
    /// §60 se serait appliquée à chaque fenêtre et deux fenêtres ouvertes sur
    /// deux projets se seraient écrasées mutuellement. Ici, chaque fenêtre
    /// retrouve le projet qu'ELLE affichait.
    @SceneStorage("lastOpenedProjectID") private var lastOpenedProjectID = ""
    /// Vrai dès que la restauration §60 a été TENTÉE — une seule fois par
    /// lancement, jamais de repoussée intempestive après un retour manuel à
    /// la liste.
    @State private var hasAttemptedRestore = false

    // Renommage (§31) : alerte avec champ de texte pré-rempli.
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var isRenamePresented = false

    // La suppression est IMMÉDIATE (écart produit — voir `requestDelete`) :
    // plus aucun état de confirmation à porter.

    /// Anti double-tap sur « + » : une seule création à la fois.
    @State private var isCreatingProject = false

    /// Message d'échec d'une action de l'accueil (§62/§64 : expliquer, jamais
    /// un geste sans effet ni explication). Jusqu'au Jalon 12, une création,
    /// un renommage, une duplication ou une suppression en échec n'était que
    /// journalisée : l'utilisateur voyait un bouton sans effet.
    @State private var actionErrorMessage: String?
    @State private var isActionErrorPresented = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            // §38 : le passage « aucun projet » ↔ liste n'est pas animé —
            // choix §38 (aucune animation décorative). La garde neutralise
            // toute animation implicite héritée quand « Réduire les
            // animations » est actif. Elle est posée ICI, sur le contenu, et
            // non sur le `NavigationStack` : les transitions de navigation
            // sont gérées par le système, qui applique déjà le réglage.
            .reduceMotionSafe()
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
            // ÉCART PRODUIT (13 août 2026) : le dialogue de confirmation de
            // suppression §31 a été SUPPRIMÉ sur demande de l'utilisateur —
            // supprimer, c'est supprimer. Voir `requestDelete`.
        }
        // §62/§64 : une action qui échoue est EXPLIQUÉE, avec la suite à
        // donner — jamais un bouton silencieux.
        //
        // Revue finale (§62/§64) — ALERTE ATTACHÉE AU `NavigationStack`, PAS
        // À SON CONTENU. Elle concourait autrefois avec le dialogue de
        // confirmation de suppression posé sur la même vue : la présentation
        // qui se terminait avalait celle qui commençait, et l'échec devenait
        // silencieux. Ce dialogue a disparu (suppression immédiate), mais
        // l'alerte reste portée par le conteneur : elle ne peut alors
        // concourir avec AUCUNE présentation du contenu (renommage, feuilles
        // futures).
        .alert("Action impossible", isPresented: $isActionErrorPresented) {
            Button("OK", role: .cancel) {
                actionErrorMessage = nil
            }
        } message: {
            Text(actionErrorMessage ?? "Une erreur inattendue est survenue. Réessayez.")
        }
        .onChange(of: path) { oldPath, newPath in
            handleNavigationChange(from: oldPath, to: newPath)
        }
        // §60 puis §31, dans cet ordre : le dernier projet ouvert est
        // restauré AVANT le balayage des brouillons vides, qui épargne alors
        // le projet ouvert (`excluding: path.last`). Un brouillon SANS
        // contenu n'est de toute façon jamais restauré — voir
        // `restoreLastOpenedProject`.
        .task {
            await restoreLastOpenedProject()
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
        // Jalon 3 : le moteur d'analyse n'existe pas encore (Jalon 4) —
        // libellé honnête, jamais de fausse activité en cours (§33).
        case .analyzing: return "En attente d'analyse"
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
                // §62/§64 : la cause probable (stockage) et la suite à donner.
                present(
                    error: "Le projet n'a pas pu être créé. Vérifiez l'espace disponible sur l'iPhone, puis réessayez."
                )
            }
        }
    }

    // MARK: - Réouverture du dernier projet (§60)

    /// §60 « Restaurer : projet … » — au lancement à froid, rouvre le dernier
    /// projet ouvert s'il existe ENCORE.
    ///
    /// Déroulé volontairement minimal :
    /// 1. une seule tentative par lancement (`hasAttemptedRestore`) et
    ///    seulement si l'utilisateur n'est pas déjà en train de naviguer
    ///    (`path.isEmpty`) ;
    /// 2. l'existence est vérifiée auprès du `ProjectStore` (source de
    ///    vérité), pas dans la `@Query` du contexte principal, dont la
    ///    propagation peut être en retard au tout premier affichage ;
    /// 3. la DÉCISION elle-même (`ProjectRestore.decision`) est une fonction
    ///    PURE, testée sans écran ni base : projet disparu, identifiant
    ///    illisible ou brouillon vide §31 → identifiant oublié, l'écran reste
    ///    la liste. Jamais de crash, jamais d'écran vide.
    ///
    /// Le reste de l'état §60 (case active, position de timeline, dernier
    /// album, progression d'analyse, associations, géométrie, dernier export
    /// réussi — celui-ci relu par `ExportSummaryView`) est déjà persisté
    /// (§59) et relu par les écrans eux-mêmes : rouvrir le projet suffit à
    /// retrouver le montage tel qu'il était.
    private func restoreLastOpenedProject() async {
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true
        guard path.isEmpty else { return }

        let storedIdentifier = lastOpenedProjectID
        // Identifiant vide ou illisible : la décision se prend SANS aucune
        // lecture (résumé `nil`) — inutile d'interroger le store.
        guard let projectID = ProjectRestore.parsedProjectID(fromStored: storedIdentifier) else {
            apply(ProjectRestore.decision(storedIdentifier: storedIdentifier, summary: nil))
            return
        }

        let summary: ProjectSummary?
        do {
            summary = try await environment.projectStore.summary(id: projectID)
        } catch {
            // Lecture impossible : la liste reste affichée, rien n'est
            // annoncé (l'utilisateur n'a rien demandé), et l'identifiant est
            // oublié pour ne pas réessayer indéfiniment.
            environment.logger.error(
                "Réouverture du dernier projet impossible : \(error.localizedDescription)"
            )
            lastOpenedProjectID = ""
            return
        }
        apply(ProjectRestore.decision(storedIdentifier: storedIdentifier, summary: summary))
    }

    /// Applique la décision §60 — le seul endroit qui TOUCHE à l'état.
    private func apply(_ decision: ProjectRestoreDecision) {
        switch decision {
        case .open(let projectID):
            path = [projectID]
        case .forget:
            lastOpenedProjectID = ""
        case .none:
            break
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
                present(error: "Le projet n'a pas pu être renommé. Réessayez ; son titre actuel est conservé.")
            }
        }
    }

    private func duplicate(_ projectID: UUID) {
        Task {
            do {
                _ = try await environment.projectStore.duplicate(projectID: projectID)
            } catch {
                environment.logger.error("Duplication impossible : \(error.localizedDescription)")
                present(
                    error: "Le projet n'a pas pu être dupliqué. L'original est intact : "
                        + "vérifiez l'espace disponible sur l'iPhone, puis réessayez."
                )
            }
        }
    }

    /// Suppression IMMÉDIATE.
    ///
    /// ÉCART PRODUIT (demande utilisateur, 13 août 2026) : §31 demandait une
    /// confirmation dès que le projet contenait une musique, des associations
    /// ou un export. L'utilisateur a demandé que la suppression soit directe
    /// dans TOUTE l'application. Le geste de swipe reste délibéré (il faut
    /// balayer la carte puis toucher « Supprimer »), et l'action porte le
    /// rôle destructif d'iOS.
    ///
    /// CONSÉQUENCE ASSUMÉE : la suppression est DÉFINITIVE et sans annulation
    /// — musique importée, analyse, partitions, associations et exports du
    /// projet disparaissent (§69A : uniquement les fichiers créés par
    /// l'application ; les rushs de Photos ne sont JAMAIS touchés).
    private func requestDelete(_ projectID: UUID) {
        Task {
            do {
                try await environment.projectStore.delete(projectID: projectID)
                forgetLastOpenedProject(projectID)
            } catch {
                environment.logger.error("Suppression impossible : \(error.localizedDescription)")
                present(error: Self.deleteFailureMessage)
            }
        }
    }

    /// §62/§64 : dit ce qui n'a pas eu lieu ET la suite à donner.
    private static let deleteFailureMessage =
        "Le projet n'a pas pu être supprimé. Il est toujours dans la liste : réessayez."

    /// §60 : un projet supprimé ne doit plus être rouvert au prochain
    /// lancement. Le cas nominal est déjà couvert (l'identifiant est effacé
    /// au retour à la liste, et la restauration vérifie l'existence) : ce
    /// nettoyage est une ceinture de sécurité, sans effet sur les autres
    /// projets.
    private func forgetLastOpenedProject(_ projectID: UUID) {
        guard lastOpenedProjectID == projectID.uuidString else { return }
        lastOpenedProjectID = ""
    }

    /// Affiche une alerte d'échec (§62/§64) — un seul point d'entrée.
    private func present(error message: String) {
        actionErrorMessage = message
        isActionErrorPresented = true
    }

    /// §31 : un brouillon sans musique est supprimé au retour à l'accueil.
    /// Détection par la réduction du chemin de navigation (pop).
    ///
    /// §60 : le MÊME point de passage mémorise le projet ouvert (push, quelle
    /// que soit son origine — création `+`, appui sur une carte, restauration
    /// au lancement) et l'oublie au retour à la liste. Une seule écriture,
    /// aucune duplication de règle.
    private func handleNavigationChange(from oldPath: [UUID], to newPath: [UUID]) {
        lastOpenedProjectID = newPath.last?.uuidString ?? ""
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
            // Retour à l'accueil : re-balayage complet — couvre un brouillon
            // redevenu `draft` APRÈS le premier nettoyage (import échoué en
            // arrière-plan, §62).
            if newPath.isEmpty {
                await sweepEmptyDrafts()
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
