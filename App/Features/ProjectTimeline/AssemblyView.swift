//
//  AssemblyView.swift
//  MontageMusical
//
//  Écran de la timeline d'assemblage — Jalon 7, spec §35 (zone haute,
//  carrousel trois cases, mini-timeline), §36 (dock contextuel « Case
//  vide » / « Case remplie »), §46 (préparé : la sélection avance par
//  case), §51 (Export désactivé si le préfixe exportable est vide),
//  §59 (debounce très court UNIQUEMENT pour la navigation), §60 (case
//  active restaurée à la réouverture), §65 (« Changer de rythme » →
//  duplication si verrouillé).
//
//  Règle du pouce §30 : toutes les actions ESSENTIELLES (navigation entre
//  cases, ajout de vidéo, export) vivent dans la moitié basse — carrousel,
//  mini-timeline et dock. « Changer de rythme » est une action SECONDAIRE
//  non essentielle au parcours principal : elle vit dans un menu en haut à
//  droite (écart §30 assumé — la règle vise les contrôles obligatoires du
//  parcours principal, pas les options rares).
//
//  Matériaux translucides sobres §37 (aucun verre permanent sur l'aperçu),
//  aucune animation décorative §38, accessibilité §39 complète.
//

import SwiftData
import SwiftUI

// MARK: - Logique pure testable (Jalon 7)

// Non defini par la specification — definitions minimales V1.
/// Logique d'écran extraite en fonctions PURES, testables sans UI
/// (`Tests/Unit/AssemblyViewLogicTests.swift`).
enum AssemblyViewLogic {

    /// Clampe l'index de case active aux bornes `0...(slotCount - 1)`
    /// (§60 : la valeur restaurée peut être hors bornes si les cases ont
    /// changé — jamais de crash d'indexation).
    static func clampedActiveIndex(_ index: Int, slotCount: Int) -> Int {
        guard slotCount > 0 else { return 0 }
        return min(max(index, 0), slotCount - 1)
    }

    /// Fenêtre du carrousel §35.3 : la case active et ses voisines
    /// immédiates (`activeIndex - 1 ... activeIndex + 1`), clampée aux
    /// bornes `0` et `slotCount - 1`.
    static func windowRange(activeIndex: Int, slotCount: Int) -> ClosedRange<Int> {
        guard slotCount > 0 else { return 0...0 }
        let active = clampedActiveIndex(activeIndex, slotCount: slotCount)
        return max(0, active - 1)...min(slotCount - 1, active + 1)
    }

    /// Libellés des trois zones du dock contextuel (§36).
    struct DockLabels: Equatable {
        let left: String
        let center: String
        let right: String
    }

    /// Dérivation §36 : case vide → `[Projets] [+ Vidéo • durée] [Export]` ;
    /// case remplie (tout état d'association, même non prêt) →
    /// `[Projets] [Remplacer] [Export]`.
    static func dockLabels(
        activeState: AssemblySlotState,
        requiredDuration: MediaTime
    ) -> DockLabels {
        switch activeState {
        case .empty:
            DockLabels(
                left: "Projets",
                center: "+ Vidéo • \(requiredDuration.shortDurationString)",
                right: "Export"
            )
        case .resolving, .downloading, .ready, .unavailable, .tooShort:
            DockLabels(left: "Projets", center: "Remplacer", right: "Export")
        }
    }

    /// §51 : « export désactivé si le résultat est vide » — Export actif
    /// seulement si le préfixe continu prêt (`contiguousReadyPrefix`, le
    /// MÊME algorithme que la preview et l'export) contient au moins une
    /// case.
    static func isExportEnabled(slots: [ProjectSlot]) -> Bool {
        !contiguousReadyPrefix(slots: slots).isEmpty
    }

    /// Variante O(1) sur les items déjà matérialisés (triés par index) :
    /// le préfixe §51 est non vide SI ET SEULEMENT SI la première case est
    /// prête — strictement équivalent à `contiguousReadyPrefix.isEmpty`
    /// (référence unique, testée via la variante snapshots ci-dessus).
    static func isExportEnabled(items: [AssemblySlotItem]) -> Bool {
        items.first?.state == .ready
    }
}

// MARK: - Écran d'assemblage (§35)

/// Écran affiché par `ProjectView` quand le statut du projet est
/// `assembling` (Jalon 7 — remplace le placeholder du Jalon 6).
///
/// Structure verticale (§35) :
/// 1. **Zone haute §35.1** : aperçu (placeholder neutre 16:9 — la vraie
///    miniature arrive au Jalon 8, la preview vidéo au Jalon 9) avec
///    lecture par toucher du PASSAGE MUSICAL de la case, « Plan X sur N »,
///    timestamps début → fin, durée requise ;
/// 2. **Carrousel §35.2** : trois cases visibles (précédente, active,
///    suivante), cartes à largeur tactile stable, scroll = sélection ;
/// 3. **Mini-timeline §35.3** : vue d'ensemble proportionnelle aux durées,
///    toucher/glisser = navigation rapide ;
/// 4. **Dock contextuel §36** : `[Projets] [+ Vidéo • durée] [Export]` ou
///    `[Projets] [Remplacer] [Export]`.
///
/// La case active est persistée avec un debounce ~300 ms (§59 : « debounce
/// très court uniquement pour les changements fréquents de navigation,
/// jamais pour une association critique ») et restaurée à la réouverture
/// (§60).
///
/// La vue ne reçoit qu'un `UUID` : les enregistrements SwiftData ne
/// traversent jamais une frontière d'acteur.
struct AssemblyView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private let projectID: UUID

    /// Projet (case active persistée §60, rythme choisi).
    @Query private var projects: [ProjectRecord]
    /// Cases du projet, triées par index. Après `selectPace`, seules les
    /// cases du mode choisi existent en base (Jalon 6) — aucun filtre de
    /// mode nécessaire.
    @Query private var slotRecords: [ProjectSlotRecord]
    /// Associations du projet — leur statut §13.3 pilote l'état visuel des
    /// cases (mapping recalculé par SwiftUI à chaque changement, O(N)).
    @Query private var assignmentRecords: [ClipAssignmentRecord]

    // MARK: État de navigation

    /// Index de la case active (position dans le tableau trié — égal à
    /// `ProjectSlotRecord.index`, contigu depuis 0 par construction §10.1).
    @State private var activeIndex = 0
    /// Position du carrousel (liaison `scrollPosition`) — synchronisée
    /// bidirectionnellement avec `activeIndex`.
    @State private var carouselPosition: Int?
    /// Vrai après la restauration §60 de la case active (une seule fois).
    @State private var hasRestoredActiveIndex = false
    /// Tâche de persistance débouncée de la case active (§59) — annulable,
    /// la dernière valeur gagne.
    @State private var persistTask: Task<Void, Never>?

    // MARK: État lecture (§35.1)

    /// Lecture du fichier audio ORIGINAL (§16.1) — passage musical de la
    /// case par toucher sur l'aperçu (§35.1). Le §47.1 complet
    /// (vidéo + musique) arrive avec la preview du Jalon 9.
    @State private var playerController = AudioPlayerController()
    /// Vrai si `audio/` ne contient aucun fichier lisible (incohérence
    /// disque/base) — la lecture est désactivée, jamais de crash.
    @State private var isMediaUnavailable = false

    // MARK: État changement de rythme (§65)

    /// Alerte §65 : rythme verrouillé par des associations — proposer la
    /// duplication, jamais de mutation destructive.
    @State private var isPaceLockAlertPresented = false
    /// Alerte générique d'échec (jamais silencieux).
    @State private var isPaceChangeErrorPresented = false

    init(projectID: UUID) {
        self.projectID = projectID
        _projects = Query(filter: #Predicate<ProjectRecord> { record in
            record.id == projectID
        })
        _slotRecords = Query(
            filter: #Predicate<ProjectSlotRecord> { slot in
                slot.projectID == projectID
            },
            sort: [SortDescriptor(\ProjectSlotRecord.index, order: .forward)]
        )
        _assignmentRecords = Query(filter: #Predicate<ClipAssignmentRecord> { assignment in
            assignment.projectID == projectID
        })
    }

    // MARK: - Corps

    var body: some View {
        Group {
            let items = slotItems
            if items.isEmpty {
                // Cases pas encore propagées au contexte principal (les
                // écritures viennent de l'acteur `ProjectStore`) — état
                // transitoire sobre, le dock de sortie reste disponible.
                loadingContent
            } else {
                assemblyContent(items: items)
            }
        }
        // « Changer de rythme » (§65) : action SECONDAIRE non essentielle —
        // menu ellipsis en haut à droite (écart §30 documenté en tête de
        // fichier : la règle du pouce vise les actions essentielles).
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Changer de rythme") {
                        changePace()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Options du projet")
                .accessibilityHint("Contient l'action Changer de rythme.")
            }
        }
        // §65 : jamais de mutation destructive — proposer la duplication.
        .alert("Rythme verrouillé", isPresented: $isPaceLockAlertPresented) {
            Button("Dupliquer") {
                duplicateForPaceChange()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ce rythme est verrouillé par des vidéos déjà associées. Dupliquez le projet pour changer de rythme.")
        }
        .alert("Action impossible", isPresented: $isPaceChangeErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Le changement de rythme a échoué. Réessayez.")
        }
        .task(id: projectID) {
            loadAudio()
        }
        // §60 : restauration de la case active dès que les cases sont
        // visibles — une seule fois, valeur CLAMPÉE aux bornes.
        .task(id: slotItems.isEmpty) {
            guard !hasRestoredActiveIndex, !slotItems.isEmpty else { return }
            hasRestoredActiveIndex = true
            let restored = AssemblyViewLogic.clampedActiveIndex(
                projects.first?.activeSlotIndex ?? 0,
                slotCount: slotItems.count
            )
            activeIndex = restored
            carouselPosition = restored
        }
        // Le scroll du carrousel change la sélection (§35.2).
        .onChange(of: carouselPosition) { _, newValue in
            guard let newValue, newValue != activeIndex else { return }
            selectionDidChange(to: newValue)
        }
        .onDisappear {
            // Lecture arrêtée et observateurs retirés (§35.1). La tâche de
            // persistance débouncée N'EST PAS annulée : la dernière case
            // active est toujours sauvegardée (§59, §60).
            playerController.invalidate()
        }
    }

    // MARK: - Mapping records → items (contrat Jalon 7)

    /// `[AssemblySlotItem]` dérivés des records — dérivation UNIQUE de
    /// l'état par `AssemblySlotState.from(assignmentStatusRaw:)` via un
    /// dictionnaire `assignmentID → statusRaw`. Recalculé par SwiftUI à
    /// chaque changement des deux `@Query`, O(N).
    private var slotItems: [AssemblySlotItem] {
        let statusByAssignmentID = Dictionary(
            assignmentRecords.map { ($0.id, $0.statusRaw) },
            uniquingKeysWith: { first, _ in first }
        )
        return slotRecords.map { record in
            AssemblySlotItem(
                id: record.id,
                index: record.index,
                start: MediaTime(ticks: record.startTicks),
                end: MediaTime(ticks: record.endTicks),
                // `assignmentID` orphelin (association supprimée) → raw
                // `nil` → `.empty` : la case redevient remplissable.
                state: AssemblySlotState.from(
                    assignmentStatusRaw: record.assignmentID
                        .flatMap { statusByAssignmentID[$0] }
                )
            )
        }
    }

    /// Snapshots `ProjectSlot` pour le préfixe exportable §51 — le MÊME
    /// type et le MÊME algorithme (`contiguousReadyPrefix`) que la preview
    /// (Jalon 9) et l'export (Jalon 10).
    private var exportSnapshots: [ProjectSlot] {
        let assignmentsByID = Dictionary(
            assignmentRecords.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return slotRecords.map { record in
            let snapshot: ClipAssignmentSnapshot? = record.assignmentID
                .flatMap { assignmentsByID[$0] }
                .flatMap { assignment in
                    ClipAssignmentStatus(rawValue: assignment.statusRaw).map { status in
                        ClipAssignmentSnapshot(
                            id: assignment.id,
                            assetLocalIdentifier: assignment.assetLocalIdentifier,
                            status: status
                        )
                    }
                }
            return ProjectSlot(
                id: record.id,
                index: record.index,
                start: MediaTime(ticks: record.startTicks),
                end: MediaTime(ticks: record.endTicks),
                assignment: snapshot
            )
        }
    }

    // MARK: - État transitoire sans cases

    private var loadingContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ProgressView()
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chargement des plans")
        .safeAreaInset(edge: .bottom) { projectsOnlyDock }
    }

    private var projectsOnlyDock: some View {
        HStack {
            dockSecondaryButton(
                title: "Projets",
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Écran complet (§35)

    private func assemblyContent(items: [AssemblySlotItem]) -> some View {
        // Clamp défensif : si le nombre de cases changeait sous la vue
        // (duplication, migration), jamais d'indexation hors bornes.
        let active = AssemblyViewLogic.clampedActiveIndex(activeIndex, slotCount: items.count)
        let activeItem = items[active]
        return VStack(spacing: 14) {
            topZone(item: activeItem, count: items.count)

            Spacer(minLength: 0)

            carousel(items: items, activeIndex: active)

            // Mini-timeline §35.3 : toucher/glisser déplace la sélection.
            AssemblyMiniTimelineView(
                slots: items,
                activeIndex: active,
                windowRange: AssemblyViewLogic.windowRange(
                    activeIndex: active,
                    slotCount: items.count
                ),
                onSelect: { index in
                    select(index, in: items)
                }
            )
            .frame(height: 44)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) {
            contextualDock(activeItem: activeItem, items: items)
        }
    }

    // MARK: - Zone haute (§35.1)

    /// Aperçu + « Plan X sur N » + timestamps début → fin + durée requise.
    ///
    /// L'aperçu est un placeholder neutre 16:9 : la vraie miniature du rush
    /// arrive au Jalon 8, la preview vidéo au Jalon 9 (§47.1). Le toucher
    /// lit dès maintenant le PASSAGE MUSICAL de la case (§35.1 « lecture
    /// par toucher sur l'aperçu ») — fichier original §16.1, pause
    /// automatique à la fin de la case.
    private func topZone(item: AssemblySlotItem, count: Int) -> some View {
        VStack(spacing: 8) {
            Button {
                togglePassagePlayback(item: item)
            } label: {
                ZStack {
                    // Fond neutre — pas de verre permanent sur la zone
                    // vidéo (§37 : le contenu reste prioritaire).
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                    VStack(spacing: 6) {
                        Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Passage musical")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .disabled(isMediaUnavailable)
            .padding(.horizontal, 24)
            .accessibilityLabel(
                "Plan \(item.index + 1) sur \(count), "
                    + "durée requise \(item.duration.spokenString), "
                    + spokenState(item.state)
            )
            .accessibilityValue(playerController.isPlaying ? "Lecture en cours" : "En pause")
            .accessibilityHint("Touchez pour écouter le passage musical de ce plan.")

            // « Plan X sur N » (§35.1) — index HUMAIN (1-based).
            Text("Plan \(item.index + 1) sur \(count)")
                .font(.headline.monospacedDigit())

            // Timestamps absolus début → fin, centième d'AFFICHAGE (§9).
            Text("\(item.start.displayString) → \(item.end.displayString)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("De \(item.start.displayString) à \(item.end.displayString)")

            // Durée requise (§35.1) — toujours calculée end - start (§9).
            Text("Durée requise : \(item.duration.shortDurationString)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Durée requise : \(item.duration.spokenString)")
        }
        .padding(.top, 8)
    }

    // MARK: - Carrousel (§35.2)

    /// Trois cases visibles : précédente, active, suivante. Cartes à
    /// largeur tactile STABLE (~62 % du conteneur — les voisines dépassent
    /// de chaque côté), case active centrée (`viewAligned` + ancre
    /// centrale). Le scroll change la sélection via `carouselPosition`.
    private func carousel(items: [AssemblySlotItem], activeIndex: Int) -> some View {
        GeometryReader { proxy in
            // Marges latérales = (100 % − 62 %) / 2 : la première et la
            // dernière carte peuvent elles aussi se centrer.
            // Cartes à 55 % : les voisines montrent leur numéro et leur
            // état (identifiables, pas de simples tranches — §35.2).
            let sideMargin = proxy.size.width * 0.225
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    // Identité = POSITION (Int) : c'est elle que
                    // `scrollPosition(id:)` lit/écrit — les cases ne se
                    // réordonnent jamais (§10.1, index gelés).
                    ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                        SlotCardView(item: item, isActive: position == activeIndex)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                // Largeur tactile stable §35.2.
                                length * 0.55
                            }
                            // §82 « navigation par tap » : toucher une
                            // voisine la sélectionne (le scroll reste).
                            .onTapGesture {
                                select(position, in: items)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, sideMargin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $carouselPosition, anchor: .center)
            .scrollIndicators(.hidden)
        }
        .frame(height: 132)
    }

    // MARK: - Dock contextuel (§36)

    /// `[Projets] [+ Vidéo • durée] [Export]` (case vide) ou
    /// `[Projets] [Remplacer] [Export]` (case remplie). Libellés dérivés
    /// par la logique pure `AssemblyViewLogic.dockLabels` (testée).
    ///
    /// Export : DÉSACTIVÉ tant que le préfixe exportable §51 est vide —
    /// état RÉEL calculé par `contiguousReadyPrefix`, pas un stub. Sans
    /// association (Jalon 7), le préfixe est toujours vide : le bouton
    /// s'activera dès la première case remplie prête (Jalon 8).
    private func contextualDock(activeItem: AssemblySlotItem, items: [AssemblySlotItem]) -> some View {
        let labels = AssemblyViewLogic.dockLabels(
            activeState: activeItem.state,
            requiredDuration: activeItem.duration
        )
        // O(1) sur les items déjà matérialisés (§82 : rien de recalculé
        // pendant un glisser sur la mini-timeline) — équivalent §51 strict.
        let isExportEnabled = AssemblyViewLogic.isExportEnabled(items: items)
        return HStack(spacing: 8) {
            dockSecondaryButton(
                title: labels.left,
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }

            // Centre : « + Vidéo • durée » / « Remplacer » — la photothèque
            // arrive au Jalon 8 (§40–§46) : action stub journalisée.
            Button {
                requestVideoSelection(for: activeItem)
            } label: {
                Text(labels.center)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                activeItem.state == .empty
                    ? "Ajouter une vidéo, durée requise \(activeItem.duration.spokenString)"
                    : "Remplacer la vidéo"
            )
            .accessibilityHint("La photothèque arrive dans une prochaine version.")

            // Droite : Export (§51) — l'écran d'export est le Jalon 10 ;
            // l'état actif/inactif est déjà le vrai (§51).
            Button {
                requestExport()
            } label: {
                Text(labels.right)
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!isExportEnabled)
            // État désactivé marqué par l'opacité ET annoncé par VoiceOver
            // (trait « estompé » automatique + hint) — jamais par la seule
            // couleur (§39).
            .opacity(isExportEnabled ? 1 : 0.4)
            .accessibilityLabel("Export")
            .accessibilityHint(
                isExportEnabled
                    ? "Exporte le montage jusqu'au premier plan vide."
                    : "Remplissez la première case pour exporter."
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Navigation entre cases (§35.3, §59)

    /// Sélection par la mini-timeline (tap/drag §35.3) : met à jour la
    /// case active ET recentre le carrousel.
    private func select(_ index: Int, in items: [AssemblySlotItem]) {
        let clamped = AssemblyViewLogic.clampedActiveIndex(index, slotCount: items.count)
        guard clamped != activeIndex else { return }
        carouselPosition = clamped
        selectionDidChange(to: clamped)
    }

    /// Changement de sélection (scroll du carrousel OU mini-timeline) :
    /// arrêt du passage musical en cours, mise à jour de l'état, puis
    /// persistance DÉBOUNCÉE (§59 : navigation uniquement).
    private func selectionDidChange(to index: Int) {
        playerController.stopSegment()
        activeIndex = index
        schedulePersistActiveIndex(index)
    }

    /// §59 : « debounce très court uniquement pour les changements
    /// fréquents de navigation » — ~300 ms, tâche annulable, la dernière
    /// valeur gagne. Une association (Jalon 8) sera sauvegardée SANS
    /// debounce par `ProjectStore` (§59 : jamais pour une association
    /// critique).
    private func schedulePersistActiveIndex(_ index: Int) {
        persistTask?.cancel()
        let store = environment.projectStore
        let logger = environment.logger
        let id = projectID
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try await store.setActiveSlot(index: index, projectID: id)
            } catch {
                // Échec non bloquant : la navigation reste fluide, la
                // prochaine sauvegarde rattrapera la valeur (§59).
                logger.error("Sauvegarde de la case active impossible : \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lecture du passage musical (§35.1)

    /// Charge le lecteur sur le fichier audio ORIGINAL (§16.1).
    private func loadAudio() {
        guard let url = environment.fileStore.audioFileURL(projectID: projectID) else {
            isMediaUnavailable = true
            environment.logger.error("Aucun fichier dans audio/ alors que le projet est en assemblage.")
            return
        }
        isMediaUnavailable = false
        playerController.load(url: url)
    }

    /// Toucher sur l'aperçu (§35.1) : lit le passage musical de la case
    /// (`start → end`, pause automatique à `end`), ou l'arrête s'il est
    /// déjà en cours. §47.1 complet (vidéo + musique) : Jalon 9.
    private func togglePassagePlayback(item: AssemblySlotItem) {
        guard !isMediaUnavailable else { return }
        if playerController.isPlaying {
            playerController.stopSegment()
        } else {
            playerController.playSegment(from: item.start, to: item.end)
        }
    }

    // MARK: - Actions stub (Jalons 8 et 10)

    /// // Jalon 8 : photothèque — ouverture du navigateur de rushs
    /// (§40–§46) avec avancement automatique après association.
    private func requestVideoSelection(for item: AssemblySlotItem) {
        environment.logger.info(
            "Sélection vidéo demandée pour le plan \(item.index + 1) — la photothèque arrive au Jalon 8."
        )
    }

    /// // Jalon 10 : export — inatteignable au Jalon 7 (le bouton n'est
    /// actif que si le préfixe §51 est non vide, ce qui exige une
    /// association prête du Jalon 8).
    private func requestExport() {
        environment.logger.info("Export demandé — l'écran d'export arrive au Jalon 10.")
    }

    // MARK: - Changement de rythme (§65 — venant du placeholder Jalon 6)

    /// Changement de rythme AVANT association (§65) :
    /// `revertToPaceSelection` efface les cases et ramène le statut à
    /// `awaitingPaceSelection` — le routage de `ProjectView` affiche alors
    /// `PaceSelectionView`. Si une association existe : alerte §65 avec
    /// « Dupliquer », aucune mutation.
    private func changePace() {
        playerController.stopSegment()
        Task {
            do {
                try await environment.projectStore.revertToPaceSelection(projectID: projectID)
            } catch ProjectStoreError.paceLockedByAssignments {
                isPaceLockAlertPresented = true
            } catch {
                environment.logger.error("Changement de rythme impossible : \(error.localizedDescription)")
                isPaceChangeErrorPresented = true
            }
        }
    }

    /// §65 : duplication POUR CHANGER DE RYTHME — la copie repart SANS
    /// associations, au choix du rythme (`duplicateForPaceChange`), sinon
    /// la copie serait verrouillée comme l'original (impasse). Après
    /// duplication, retour à la liste où la copie apparaît.
    /// Non defini par la specification — definition minimale V1.
    private func duplicateForPaceChange() {
        Task {
            do {
                _ = try await environment.projectStore.duplicateForPaceChange(projectID: projectID)
                dismiss()
            } catch {
                environment.logger.error("Duplication impossible : \(error.localizedDescription)")
                isPaceChangeErrorPresented = true
            }
        }
    }

    // MARK: - Helpers accessibilité (§39)

    /// Forme parlée de l'état d'une case — source UNIQUE partagée avec
    /// `SlotCardView` (§39 : même vocabulaire partout sur l'écran).
    private func spokenState(_ state: AssemblySlotState) -> String {
        state.spokenLabel
    }

    // MARK: - Composants de dock partagés (§37, §39)

    /// Bouton secondaire de dock — même style que `ProjectView` et
    /// `PaceSelectionView` (capsule translucide, cible ≥ 44 pt).
    private func dockSecondaryButton(
        title: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 52) // cible ≥ 44 pt (§39)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }
}

// La forme parlée `MediaTime.spokenString` (§39) est définie UNE seule fois
// dans App/Core/Time/MediaTimeFormatting.swift (extension interne partagée).

// MARK: - Previews (conteneur en mémoire, cases synthétiques)

@MainActor
private func makeAssemblyPreviewContainer(
    durationsTicks: [Int64],
    activeSlotIndex: Int
) -> (container: ModelContainer, projectID: UUID) {
    let container = try! ModelContainerFactory.makeInMemory()
    let projectID = UUID()
    let now = Date.now
    container.mainContext.insert(ProjectRecord(
        id: projectID,
        automaticTitle: automaticProjectTitle(date: now),
        customTitle: nil,
        createdAt: now,
        updatedAt: now,
        statusRaw: ProjectStatus.assembling.rawValue,
        selectedPaceRaw: PaceMode.balanced.rawValue,
        activeSlotIndex: activeSlotIndex,
        audioRelativePath: nil,
        analysisRelativePath: nil,
        geometryData: nil,
        lastAlbumIdentifier: nil,
        analysisVersion: 1,
        scoreVersion: 1
    ))
    var start: Int64 = 0
    for (index, duration) in durationsTicks.enumerated() {
        container.mainContext.insert(ProjectSlotRecord(
            id: UUID(),
            projectID: projectID,
            scoreModeRaw: PaceMode.balanced.rawValue,
            index: index,
            startTicks: start,
            endTicks: start + duration,
            entryAnchorID: UUID(),
            exitAnchorID: UUID(),
            gestureID: nil,
            assignmentID: nil
        ))
        start += duration
    }
    return (container, projectID)
}

#Preview("Assemblage — cases vides") {
    let (container, projectID) = makeAssemblyPreviewContainer(
        durationsTicks: [72_000, 96_000, 60_000, 120_000, 84_000, 108_000, 66_000, 90_000],
        activeSlotIndex: 2
    )
    let environment = AppEnvironment(modelContainer: container)
    return NavigationStack {
        AssemblyView(projectID: projectID)
            .navigationTitle("Projet du 10 août 2026 • 11:24")
            .toolbarTitleDisplayMode(.inline)
    }
    .environment(environment)
    .modelContainer(container)
}
