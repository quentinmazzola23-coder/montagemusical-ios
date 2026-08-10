//
//  PaceSelectionView.swift
//  MontageMusical
//
//  Écran du choix du rythme — Jalon 6, spec §34 (Fluide | Équilibré |
//  Percutant : nombre de plans, durée moyenne, minimum, maximum, miniature
//  de timeline), §36 (dock « Choix rythme » : Projets | Sélecteur |
//  Valider), §61 (partitions absentes/périmées → recalcul EXPLICITE,
//  jamais silencieux), §65 (rythme verrouillé par des associations →
//  proposer la duplication, jamais de mutation destructive).
//
//  Règle du pouce §30 : la zone haute est purement informative (aperçu du
//  mode sélectionné) ; toutes les actions vivent dans le dock bas.
//  Matériaux translucides sobres §37, aucune animation décorative §38,
//  accessibilité §39 (libellés, cibles ≥ 44 pt, sélection marquée par
//  autre chose que la couleur).
//

import SwiftData
import SwiftUI

// MARK: - Libellés français des modes (§34)

extension PaceMode {
    /// Libellé d'interface français (§34 : `Fluide | Équilibré | Percutant`).
    var displayLabel: String {
        switch self {
        case .fluid: "Fluide"
        case .balanced: "Équilibré"
        case .percussive: "Percutant"
        }
    }
}

// MARK: - Miniature de timeline (§34, §35.3 simplifié)

/// Miniature d'une partition : un segment par case, largeur proportionnelle
/// à la durée (§35.3 simplifié pour l'aperçu §34), séparateurs fins.
///
/// `Canvas` pur, aucune animation (§38). Les positions sont dérivées des
/// ticks CUMULÉS (jamais d'accumulation de largeurs flottantes — l'esprit
/// §9 appliqué au dessin) ; le flottant n'existe qu'à l'affichage.
struct MiniTimelineView: View {
    /// Cases de la partition, dans l'ordre des index.
    let slots: [EditSlotDefinition]

    var body: some View {
        Canvas { context, size in
            guard !slots.isEmpty, size.width > 0, size.height > 0 else { return }
            let totalTicks = slots.reduce(Int64(0)) { $0 + max(0, $1.duration.ticks) }
            guard totalTicks > 0 else { return }

            // Séparateur fin entre segments — pas après le dernier.
            let separatorWidth: CGFloat = 1
            var segments = Path()
            var cumulativeTicks: Int64 = 0
            var previousEdge: CGFloat = 0
            for (position, slot) in slots.enumerated() {
                cumulativeTicks += max(0, slot.duration.ticks)
                let edge = CGFloat(Double(cumulativeTicks) / Double(totalTicks)) * size.width
                let isLast = position == slots.count - 1
                let width = max(0, (isLast ? edge : edge - separatorWidth) - previousEdge)
                if width > 0 {
                    segments.addRect(CGRect(
                        x: previousEdge,
                        y: 0,
                        width: width,
                        height: size.height
                    ))
                }
                previousEdge = edge
            }
            // `.secondary` : le contenu reste sobre, lisible en clair et en
            // sombre (§39) — même convention que `WaveformView`.
            context.fill(segments, with: .color(.secondary))
        }
    }
}

// MARK: - Écran du choix du rythme (§34)

/// Écran affiché par `ProjectView` quand le statut du projet est
/// `awaitingPaceSelection` (Jalon 6).
///
/// Trois états :
/// 1. **Chargement** : lecture (hors MainActor) de `analysis/scores-v1.json`
///    via `ScoreLibrary` ;
/// 2. **À recalculer** (§61) : partitions absentes ou périmées (générateur ou
///    configuration ayant évolué) → état sobre + bouton « Recalculer » —
///    JAMAIS de régénération silencieuse ; le cache d'analyse §69 rend le
///    recalcul rapide ;
/// 3. **Prêt** : zone haute = aperçu du mode sélectionné (miniature de
///    timeline + stats §34), dock bas = `[Projets] [Sélecteur] [Valider]`
///    (§36 ligne « Choix rythme »).
///
/// Valider → `ProjectStore.selectPace` (statut `assembling`, le routage de
/// `ProjectView` bascule via sa `@Query`). Rythme verrouillé par des
/// associations (§65) → alerte avec « Dupliquer ».
///
/// La vue ne reçoit qu'un `UUID` : les enregistrements SwiftData ne
/// traversent jamais une frontière d'acteur.
struct PaceSelectionView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private let projectID: UUID
    /// Famille injectée pour les previews SwiftUI UNIQUEMENT (aucune
    /// lecture disque). `nil` en production : lecture via `ScoreLibrary`.
    private let previewFamily: EditScoreFamily?

    /// État de chargement des partitions.
    private enum ScoresState {
        case loading
        /// Partitions absentes ou périmées (§61) → recalcul explicite.
        case needsRecalculation
        case ready(EditScoreFamily)
    }

    @State private var scoresState: ScoresState = .loading
    /// Mode présenté dans l'aperçu. Défaut Équilibré — position centrale
    /// §34. Non defini par la specification — definition minimale V1.
    @State private var selectedMode: PaceMode = .balanced
    /// Vrai pendant `selectPace` — évite la double validation.
    @State private var isValidating = false
    @State private var isLockAlertPresented = false
    @State private var errorMessage: String?
    @State private var isErrorPresented = false

    init(projectID: UUID, previewFamily: EditScoreFamily? = nil) {
        self.projectID = projectID
        self.previewFamily = previewFamily
    }

    var body: some View {
        Group {
            switch scoresState {
            case .loading:
                loadingContent
            case .needsRecalculation:
                staleContent
            case .ready(let family):
                readyContent(family: family)
            }
        }
        .task(id: projectID) {
            await loadScores()
        }
        // §65 : jamais de mutation destructive — proposer la duplication.
        .alert("Rythme verrouillé", isPresented: $isLockAlertPresented) {
            Button("Dupliquer") {
                duplicateProject()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ce rythme est verrouillé par des vidéos déjà associées. Dupliquez le projet pour changer de rythme.")
        }
        .alert("Action impossible", isPresented: $isErrorPresented) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Une erreur inattendue est survenue. Réessayez.")
        }
    }

    // MARK: - État 1 : chargement

    private var loadingContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ProgressView()
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chargement des rythmes")
        .safeAreaInset(edge: .bottom) { projectsOnlyDock }
    }

    // MARK: - État 2 : partitions absentes ou périmées (§61)

    private var staleContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("Les rythmes doivent être recalculés")
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) { staleDock }
    }

    /// Dock de l'état à recalculer : `Projets` | `Recalculer` (≥ 44 pt,
    /// zone basse §30). Le recalcul est EXPLICITE (§61).
    private var staleDock: some View {
        HStack(spacing: 12) {
            dockSecondaryButton(
                title: "Projets",
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }

            Button {
                recalculateScores()
            } label: {
                Label("Recalculer", systemImage: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recalculer les rythmes")
            .accessibilityHint("Relance l'analyse pour recréer les trois rythmes.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - État 3 : partitions prêtes (§34)

    private func readyContent(family: EditScoreFamily) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Zone d'aperçu §34 : les TROIS rythmes comparables d'un coup
            // d'œil — pour CHAQUE mode : miniature de timeline, nombre de
            // plans, durée moyenne, minimum, maximum. Les cartes sont
            // tapables (sélection) mais rien n'est OBLIGATOIRE en haut :
            // sélection et validation restent au dock (§30).
            VStack(spacing: 10) {
                ForEach(PaceMode.allCases, id: \.self) { mode in
                    modeCard(for: mode, in: family)
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) { selectionDock(family: family) }
    }

    /// Carte compacte d'un mode (§34) : miniature + « N plans » + durées
    /// moyenne/min/max (`shortDurationString`, « 1,20 s » §35.2). Tapable
    /// (sélectionne le mode) — la validation reste au dock. Sélection
    /// marquée par coche + trait renforcé, jamais la seule couleur (§39).
    private func modeCard(for mode: PaceMode, in family: EditScoreFamily) -> some View {
        let score = score(for: mode, in: family)
        let isSelected = mode == selectedMode
        return Button {
            // Simple changement d'état — aucune animation (§38).
            selectedMode = mode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                    }
                    Text(mode.displayLabel)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    Spacer(minLength: 0)
                    Text(planCountLabel(score.slots.count))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                MiniTimelineView(slots: score.slots)
                    .frame(height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("moy \(score.averageDuration.shortDurationString) · min \(score.minimumDuration.shortDurationString) · max \(score.maximumDuration.shortDurationString)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    isSelected
                        ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                        : AnyShapeStyle(HierarchicalShapeStyle.quaternary),
                    lineWidth: isSelected ? 2 : 1
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(modeAccessibilityLabel(for: mode, in: family))
        .accessibilityHint("Sélectionne ce rythme.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Dock §36 ligne « Choix rythme » : `[Projets] [Sélecteur] [Valider]`.
    /// Le CTA affiche « Utiliser ce rythme » (§34) si la place le permet,
    /// sinon « Valider » — libellé accessible « Utiliser ce rythme » dans
    /// les deux cas (§39).
    private func selectionDock(family: EditScoreFamily) -> some View {
        HStack(spacing: 8) {
            dockSecondaryButton(
                title: "Projets",
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }

            modeSelector(family: family)

            validateButton(family: family)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Sélecteur des trois modes (§34) en capsules translucides (§37).
    /// L'état sélectionné est marqué par une coche ET un trait renforcé —
    /// jamais par la seule couleur (§39). Chaque segment annonce ses stats
    /// à VoiceOver (« Équilibré, 24 plans, durée moyenne 1 virgule 20
    /// seconde »).
    private func modeSelector(family: EditScoreFamily) -> some View {
        HStack(spacing: 4) {
            ForEach(PaceMode.allCases, id: \.self) { mode in
                let isSelected = mode == selectedMode
                Button {
                    // Simple changement d'état — aucune animation (§38).
                    selectedMode = mode
                } label: {
                    HStack(spacing: 3) {
                        if isSelected {
                            // Coche §39 : la sélection ne dépend pas de la
                            // seule couleur.
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }
                        Text(mode.displayLabel)
                            .font(.footnote.weight(isSelected ? .semibold : .regular))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            isSelected
                                ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                                : AnyShapeStyle(HierarchicalShapeStyle.quaternary),
                            lineWidth: isSelected ? 2 : 1
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(modeAccessibilityLabel(for: mode, in: family))
                .accessibilityHint("Sélectionne ce rythme pour l'aperçu.")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// CTA de validation (§34). `ViewThatFits` : « Utiliser ce rythme »
    /// quand la place le permet, sinon « Valider ».
    private func validateButton(family: EditScoreFamily) -> some View {
        Button {
            validate(family: family)
        } label: {
            ViewThatFits(in: .horizontal) {
                Text("Utiliser ce rythme")
                Text("Valider")
            }
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 52) // ≥ 44 pt (§39)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isValidating)
        .accessibilityLabel("Utiliser ce rythme")
        .accessibilityHint("Verrouille le rythme \(selectedMode.displayLabel) et passe au remplissage des cases.")
    }

    /// Dock minimal : uniquement la sortie « Projets ».
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

    // MARK: - Actions

    /// Charge la famille de partitions HORS MainActor (lecture disque +
    /// décodage JSON — appels légers mais jamais bloquants pour
    /// l'interface). Absentes ou périmées (§61) → état de recalcul.
    private func loadScores() async {
        if let previewFamily {
            scoresState = .ready(previewFamily)
            return
        }
        let library = environment.scoreLibrary
        let id = projectID
        let family: EditScoreFamily? = await Task.detached(priority: .userInitiated) {
            // §61 : la validité (version du générateur + empreinte de
            // configuration) prime — des partitions lisibles mais périmées
            // sont traitées comme absentes.
            guard library.scoresAreCurrent(projectID: id) else { return nil }
            return library.loadScores(projectID: id)
        }.value
        guard !Task.isCancelled else { return }
        if let family {
            scoresState = .ready(family)
        } else {
            scoresState = .needsRecalculation
        }
    }

    /// §61 : recalcul EXPLICITE — statut `analyzing` puis relance de
    /// l'analyse (le cache §69 la rend rapide ; seules les partitions sont
    /// régénérées). Le routage de `ProjectView` bascule vers la
    /// progression d'analyse §33 dès le changement de statut.
    private func recalculateScores() {
        Task {
            do {
                try await environment.projectStore.setStatus(.analyzing, projectID: projectID)
            } catch {
                environment.logger.error("Recalcul des rythmes impossible : \(error.localizedDescription)")
                errorMessage = "Le recalcul n'a pas pu démarrer. Réessayez."
                isErrorPresented = true
                return
            }
            await environment.audioAnalysisActor.startAnalysisIfNeeded(projectID: projectID)
        }
    }

    /// Valider (§34) : verrouille le rythme sélectionné — les cases du mode
    /// sont insérées et le statut passe à `assembling` (contrat Jalon 6).
    /// §65 : si une association existe déjà, aucune mutation — alerte avec
    /// « Dupliquer ».
    private func validate(family: EditScoreFamily) {
        guard !isValidating else { return }
        isValidating = true
        let mode = selectedMode
        Task {
            defer { isValidating = false }
            do {
                try await environment.projectStore.selectPace(mode, from: family, projectID: projectID)
                // Succès : le statut est `assembling` — `ProjectView`
                // bascule automatiquement via sa `@Query`.
            } catch ProjectStoreError.paceLockedByAssignments {
                isLockAlertPresented = true
            } catch {
                environment.logger.error("Validation du rythme impossible : \(error.localizedDescription)")
                errorMessage = "Le rythme n'a pas pu être enregistré. Réessayez."
                isErrorPresented = true
            }
        }
    }

    /// §65 : duplication POUR CHANGER DE RYTHME — la copie repart SANS
    /// associations, au choix du rythme (`duplicateForPaceChange`), sinon
    /// la copie serait verrouillée comme l'original (impasse). Après
    /// duplication, retour à la liste où la copie apparaît (navigation
    /// directe vers la copie : amélioration future).
    /// Non defini par la specification — definition minimale V1.
    private func duplicateProject() {
        Task {
            do {
                _ = try await environment.projectStore.duplicateForPaceChange(projectID: projectID)
                dismiss()
            } catch {
                environment.logger.error("Duplication impossible : \(error.localizedDescription)")
                errorMessage = "La duplication a échoué. Réessayez."
                isErrorPresented = true
            }
        }
    }

    // MARK: - Helpers

    private func score(for mode: PaceMode, in family: EditScoreFamily) -> EditScore {
        switch mode {
        case .fluid: family.fluid
        case .balanced: family.balanced
        case .percussive: family.percussive
        }
    }

    private func planCountLabel(_ count: Int) -> String {
        count == 1 ? "1 plan" : "\(count) plans"
    }

    /// « Équilibré, 24 plans, durée moyenne 1 virgule 20 seconde,
    /// minimum …, maximum … » — les cinq éléments §34 annoncés (§39).
    private func modeAccessibilityLabel(for mode: PaceMode, in family: EditScoreFamily) -> String {
        let score = score(for: mode, in: family)
        return "\(mode.displayLabel), \(planCountLabel(score.slots.count)), "
            + "durée moyenne \(score.averageDuration.spokenString), "
            + "minimum \(score.minimumDuration.spokenString), "
            + "maximum \(score.maximumDuration.spokenString)"
    }

    /// Bouton secondaire de dock — même style que `ProjectView` (§37, §39).
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

// MARK: - Forme parlée VoiceOver (§39)

private extension MediaTime {
    /// Forme parlée d'une durée pour VoiceOver, calquée sur l'exemple §39
    /// (« 1 virgule 20 seconde ») : centièmes d'AFFICHAGE, jamais
    /// réinjectés dans un calcul.
    var spokenString: String {
        let centiseconds = Self.roundedDivision(ticks, dividedBy: 600)
        let total = max(0, centiseconds)
        let seconds = total / 100
        let fraction = total % 100
        // Accord : « 2 secondes » mais « 1 virgule 20 seconde » (§39).
        let secondsLabel = seconds >= 2 ? "secondes" : "seconde"
        guard fraction > 0 else { return "\(seconds) \(secondsLabel)" }
        // « zéro 5 » : sans le zéro explicite, « 1 virgule 05 » serait lu
        // comme « 1 virgule 5 ».
        let spokenFraction = fraction < 10 ? "zéro \(fraction)" : "\(fraction)"
        return "\(seconds) virgule \(spokenFraction) \(secondsLabel)"
    }
}

// MARK: - Previews (famille synthétique en mémoire, aucune lecture disque)

/// Partition synthétique : cases contiguës aux durées données (en ticks,
/// 60 000 ticks = 1 s), stats dérivées.
private func makePreviewScore(mode: PaceMode, durationsTicks: [Int64]) -> EditScore {
    var slots: [EditSlotDefinition] = []
    var start: Int64 = 0
    for (index, duration) in durationsTicks.enumerated() {
        slots.append(EditSlotDefinition(
            id: UUID(),
            index: index,
            start: MediaTime(ticks: start),
            end: MediaTime(ticks: start + duration),
            entryAnchorID: UUID(),
            exitAnchorID: UUID(),
            gestureID: nil
        ))
        start += duration
    }
    let average = MediaTime.roundedDivision(start, dividedBy: Int64(max(1, durationsTicks.count)))
    return EditScore(
        mode: mode,
        slots: slots,
        gestures: [],
        averageDuration: MediaTime(ticks: average),
        minimumDuration: MediaTime(ticks: durationsTicks.min() ?? 0),
        maximumDuration: MediaTime(ticks: durationsTicks.max() ?? 0)
    )
}

private func makePreviewFamily() -> EditScoreFamily {
    // Durées déterministes (previews stables) : motifs contrastés entre
    // modes — Fluide long, Équilibré alterné, Percutant court avec bursts.
    let fluid: [Int64] = [220_000, 160_000, 240_000, 180_000, 200_000, 150_000, 260_000, 190_000]
    let balanced: [Int64] = (0..<18).map { index in
        [72_000, 96_000, 60_000, 120_000, 84_000, 108_000][index % 6]
    }
    let percussive: [Int64] = (0..<36).map { index in
        [30_000, 45_000, 24_000, 60_000, 36_000, 18_000, 48_000, 27_000][index % 8]
    }
    return EditScoreFamily(
        analysisVersion: 1,
        fluid: makePreviewScore(mode: .fluid, durationsTicks: fluid),
        balanced: makePreviewScore(mode: .balanced, durationsTicks: balanced),
        percussive: makePreviewScore(mode: .percussive, durationsTicks: percussive)
    )
}

#Preview("Choix du rythme") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    return NavigationStack {
        PaceSelectionView(projectID: UUID(), previewFamily: makePreviewFamily())
            .navigationTitle("Projet du 10 août 2026 • 11:24")
            .toolbarTitleDisplayMode(.inline)
    }
    .environment(environment)
    .modelContainer(container)
}

#Preview("Rythmes à recalculer") {
    // Aucun fichier de partitions sur disque pour cet identifiant :
    // l'écran bascule sur l'état « Les rythmes doivent être recalculés ».
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    return NavigationStack {
        PaceSelectionView(projectID: UUID())
    }
    .environment(environment)
    .modelContainer(container)
}

#Preview("Miniature de timeline") {
    MiniTimelineView(slots: makePreviewScore(
        mode: .balanced,
        durationsTicks: [72_000, 96_000, 60_000, 120_000, 84_000, 108_000, 66_000, 90_000]
    ).slots)
    .frame(height: 56)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .padding()
}
