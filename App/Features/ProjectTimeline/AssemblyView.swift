//
//  AssemblyView.swift
//  MontageMusical
//
//  Écran de la timeline d'assemblage — Jalon 7, spec §35 (zone haute,
//  carrousel trois cases, mini-timeline), §36 (dock contextuel « Case
//  vide » / « Case remplie » ; « + Vidéo »/« Remplacer » présentent la
//  photothèque Jalon 8 §40–§46 en sheet, `onSlotChanged` recentre le
//  carrousel §46), §51 (Export désactivé si le préfixe exportable est vide),
//  §59 (debounce très court UNIQUEMENT pour la navigation), §60 (case
//  active restaurée à la réouverture), §65 (« Changer de rythme » →
//  duplication si verrouillé).
//
//  Jalon 9 : §47.1 (aperçu LOCAL — toucher sur la zone haute quand la case
//  active est prête), §47.2 (aperçu PRINCIPAL du préfixe continu, ZONE
//  DROITE du dock + entrée de menu), §48 (invalidation du cache de preview
//  dès qu'une association change), §35.3 (courbe musicale simplifiée passée à
//  la mini-timeline — écart Jalon 7 résorbé), §49 (rattrapage du verrou de
//  géométrie si aucune géométrie n'a été posée alors qu'une case est prête).
//
//  Règle du pouce §30 / §89 : toutes les actions ESSENTIELLES vivent dans la
//  moitié basse ou sur le contenu lui-même — navigation entre cases
//  (carrousel + mini-timeline), ajout/remplacement de vidéo et APERÇU
//  PRINCIPAL §47.2 (dock §36), APERÇU LOCAL §47.1 (toucher sur la zone
//  haute). Seul « Changer de rythme » (§65), action rare et non essentielle
//  au parcours minimal §88, vit dans le menu ellipsis en haut à droite
//  (écart §30 assumé — la règle vise les contrôles obligatoires).
//
//  DÉCISION Jalon 9 — placement de « Prévisualiser » (§88.11, §89, §36) :
//  « prévisualiser le préfixe rempli » fait partie du parcours MINIMAL
//  (§88.11) et §89 interdit de placer une action essentielle exclusivement
//  en haut ; le menu ellipsis ne pouvait donc pas rester son seul accès. Le
//  dock §36 n'admettant que TROIS zones, la zone DROITE porte
//  « Prévisualiser » dès qu'un préfixe exportable existe (§51) — l'écran
//  d'export n'existe pas avant le Jalon 10 (§85), un bouton « Export » actif
//  ne mènerait nulle part ; sans préfixe, elle garde « Export » DÉSACTIVÉ
//  avec son hint. L'entrée du menu est CONSERVÉE (accès secondaire
//  redondant, jamais l'unique).
//  Au Jalon 10, le dock retrouvera « Export » en zone droite et l'aperçu
//  principal migrera vers la ligne « Prévisualisation » §36 (ou un accès
//  équivalent en zone basse) — jamais vers le seul menu du haut.
//
//  Matériaux translucides sobres §37 (aucun verre permanent sur l'aperçu),
//  aucune animation décorative §38, accessibilité §39 complète.
//

import SwiftData
import SwiftUI
import UIKit

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

    /// Dérivation §36 : case vide → `[Projets] [+ Vidéo • durée] [droite]` ;
    /// case remplie (tout état d'association, même non prêt) →
    /// `[Projets] [Remplacer] [droite]`.
    ///
    /// ZONE DROITE — décision Jalon 9 (§88.11/§89) : dès qu'un préfixe
    /// exportable existe (`isExportEnabled`, §51), elle porte
    /// « Prévisualiser » — l'aperçu principal §47.2 fait partie du parcours
    /// MINIMAL (§88.11) et §89 interdit qu'une action essentielle vive
    /// exclusivement en haut ; l'écran d'export, lui, n'existe pas avant le
    /// Jalon 10 (§85), donc un bouton « Export » actif ne mènerait nulle
    /// part. Sans préfixe exportable, la zone garde « Export » DÉSACTIVÉ avec
    /// son hint (§51 : « export désactivé si le résultat est vide ») : rien
    /// à prévisualiser non plus, et l'utilisateur voit quelle action attend
    /// la première case remplie. Le dock reste donc à TROIS zones (§36).
    ///
    /// Jalon 10 : le dock retrouvera « Export » en zone droite et l'aperçu
    /// principal migrera vers la ligne « Prévisualisation » §36 (ou un accès
    /// équivalent en zone basse) — jamais vers le seul menu du haut (§89).
    static func dockLabels(
        activeState: AssemblySlotState,
        requiredDuration: MediaTime,
        isExportEnabled: Bool
    ) -> DockLabels {
        let right = isExportEnabled ? "Prévisualiser" : "Export"
        switch activeState {
        case .empty:
            return DockLabels(
                left: "Projets",
                center: "+ Vidéo • \(requiredDuration.shortDurationString)",
                right: right
            )
        case .resolving, .downloading, .ready, .unavailable, .tooShort:
            return DockLabels(left: "Projets", center: "Remplacer", right: right)
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

// MARK: - Feuilles de l'écran (Jalons 8 et 9)

// Non defini par la specification — definition minimale V1.
/// Paramètres de la feuille photothèque (§40–§46) : la case visée au moment
/// de l'appui. « Remplacer » (§36) rouvre le sélecteur sur la MÊME case —
/// le nouveau choix remplace l'association via `beginAssignment`.
private struct ClipPickerContext: Identifiable {
    /// Identifiant de la case (`ProjectSlotRecord.id`).
    let id: UUID
    let slotIndex: Int
    let requiredDuration: MediaTime
}

// Non defini par la specification — definition minimale V1.
/// Paramètres de la feuille de prévisualisation (§47) : portée + titre
/// affiché au-dessus du dock « Prévisualisation » (§36).
private struct PreviewSheetContext {
    /// Identité STABLE de la feuille (portée) — sert d'`id` à `sheet(item:)`.
    let id: String
    let scope: PreviewScope
    let title: String
}

// Non defini par la specification — definition minimale V1.
/// UNE seule feuille à la fois (photothèque §40–§46 OU prévisualisation
/// §47) : un `sheet(item:)` unique évite les conflits de présentations
/// concurrentes attachées à la même vue.
private enum AssemblySheet: Identifiable {
    case clipPicker(ClipPickerContext)
    case preview(PreviewSheetContext)

    var id: String {
        switch self {
        case .clipPicker(let context): "picker-\(context.id.uuidString)"
        case .preview(let context): "preview-\(context.id)"
        }
    }
}

// MARK: - Déclencheur d'invalidation du cache (§48, §82)

// Non defini par la specification — definition minimale V1.
/// Valeur comparée par le `.onChange` d'invalidation du cache de preview
/// (§48) : nombre d'associations + condensé entier de leur contenu. Deux
/// entiers, aucune allocation — calculable à chaque passe de `body` sans
/// coût (§82 : « projet long navigable sans perte de fluidité »).
private struct AssemblyChangeToken: Equatable {
    let assignmentCount: Int
    let digest: UInt64
}

// MARK: - Écran d'assemblage (§35)

/// Écran affiché par `ProjectView` quand le statut du projet est
/// `assembling` (Jalon 7 — remplace le placeholder du Jalon 6).
///
/// Structure verticale (§35) :
/// 1. **Zone haute §35.1** : aperçu (miniature RÉELLE du rush pour une case
///    prête — placeholder neutre 16:9 sinon), « Plan X sur N », timestamps
///    début → fin, durée requise. Toucher : APERÇU LOCAL §47.1 sur une case
///    prête, sinon lecture du PASSAGE MUSICAL de la case ;
/// 2. **Carrousel §35.2** : trois cases visibles (précédente, active,
///    suivante), cartes à largeur tactile stable, scroll = sélection ;
/// 3. **Mini-timeline §35.3** : vue d'ensemble proportionnelle aux durées
///    avec courbe musicale simplifiée en fond, toucher/glisser = navigation
///    rapide ;
/// 4. **Dock contextuel §36** : `[Projets] [+ Vidéo • durée | Remplacer]
///    [Prévisualiser | Export]` — la zone droite porte l'aperçu principal
///    §47.2 dès qu'un préfixe exportable existe (§51, §88.11), sinon
///    « Export » désactivé.
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
    @Environment(\.displayScale) private var displayScale

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

    /// Lecture du fichier audio ORIGINAL (§16.1) — passage musical d'une
    /// case NON prête par toucher sur l'aperçu (§35.1). Une case prête ouvre
    /// l'aperçu complet §47.1 (vidéo + musique) dans `PreviewPlayerView` ;
    /// ce lecteur est alors arrêté (jamais deux sons simultanés).
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

    // MARK: État des feuilles (Jalon 8 photothèque, Jalon 9 preview)

    /// Feuille présentée — `nil` : aucune (§40–§46 / §47).
    @State private var activeSheet: AssemblySheet?

    // MARK: État rattrapage de géométrie (Jalon 9, §49)

    /// Vrai dès qu'un rattrapage du verrou §49 a été TENTÉ sur cet écran —
    /// une seule tentative par ouverture : ni boucle de réessai, ni
    /// aller-retour PhotoKit répété (l'échec reste journalisé, jamais
    /// bloquant).
    @State private var hasAttemptedGeometryLock = false

    // MARK: État courbe musicale (§35.3, écart Jalon 7 résorbé)

    /// Pics normalisés `0...1` du morceau (200 bins, `WaveformExtractor`
    /// §16.2/§68) — fond de la mini-timeline §35.3. Vide tant que
    /// l'extraction n'a pas abouti : la mini-timeline se dessine sans fond.
    @State private var musicCurve: [Float] = []

    // MARK: État miniatures (Jalon 8, §35.1/§35.2)

    /// Cache LOCAL des miniatures réelles des cases remplies, par
    /// identifiant d'asset (§35.2) — chargé FENÊTRÉ autour de la case
    /// active (± 2), jamais tout le projet ; libéré avec l'écran (@State).
    @State private var thumbnailsByAssetID: [String: UIImage] = [:]

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
        // Menu ellipsis : « Changer de rythme » (§65, action rare) et un
        // accès REDONDANT à l'aperçu principal §47.2 — l'accès de référence
        // est la zone droite du dock (§88.11/§89, décision en tête de
        // fichier) ; aucune action essentielle ne vit ici seulement.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let items = slotItems
                // §51/§47.2 : sans préfixe continu prêt, l'aperçu principal
                // n'a rien à lire — entrée présente mais désactivée (l'état
                // est annoncé par VoiceOver, jamais deviné par la couleur).
                let canPreview = AssemblyViewLogic.isExportEnabled(items: items)
                Menu {
                    Button("Prévisualiser") {
                        requestPrefixPreview()
                    }
                    .disabled(!canPreview)
                    .accessibilityHint(
                        canPreview
                            ? "Lit le montage jusqu'au premier plan non prêt."
                            : "Remplissez la première case pour prévisualiser."
                    )

                    Button("Changer de rythme") {
                        changePace()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Options du projet")
                .accessibilityHint("Contient les actions Prévisualiser et Changer de rythme.")
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
        // Photothèque (Jalon 8, §40–§46) : la feuille RESTE ouverte pendant
        // l'enchaînement §46/§83 — `onSlotChanged` recentre le carrousel
        // DERRIÈRE la feuille à chaque avancement automatique. Les états
        // resolving/downloading/ready/unavailable des cartes se mettent à
        // jour automatiquement via les @Query (associations §13.3).
        // La feuille de prévisualisation (§47) partage le MÊME point de
        // présentation : une seule feuille à la fois.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .clipPicker(let context):
                ClipPickerView(
                    projectID: projectID,
                    slotID: context.id,
                    slotIndex: context.slotIndex,
                    requiredDuration: context.requiredDuration,
                    onSlotChanged: { index in
                        select(index, in: slotItems)
                    }
                )
            case .preview(let context):
                PreviewPlayerView(
                    projectID: projectID,
                    scope: context.scope,
                    title: context.title
                )
            }
        }
        .task(id: projectID) {
            loadAudio()
            await loadMusicCurve()
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
        // §48 : « invalider le cache si une association change ». L'écran
        // d'assemblage est le SEUL endroit toujours vivant pendant qu'une
        // association bouge (il reste monté derrière la photothèque §83) :
        // il porte donc l'invalidation pour tout le projet. Le verrouillage
        // de géométrie (§48, second cas) invalide de son côté depuis
        // `ClipPickerView` et depuis le rattrapage §49 ci-dessous.
        // Déclencheur BON MARCHÉ (§82) — voir `assemblyChangeToken`.
        .onChange(of: assemblyChangeToken) { _, _ in
            environment.previewCache.invalidateAll(projectID: projectID)
        }
        // §49 (rattrapage) : une case peut être PRÊTE sans que la géométrie
        // ait été posée (échec transitoire de `videoGeometry` au moment de
        // l'association). Sans rattrapage, aucun chemin ne la reposerait et
        // les aperçus retomberaient sur un repli DIFFÉRENT selon la portée,
        // alors que §52.1 impose « toujours celle du projet ». Tenté à
        // l'ouverture de l'écran et dès qu'une première case devient prête.
        .task(id: hasReadyAssignment) {
            await lockGeometryIfMissing()
        }
        // Miniatures réelles (Jalon 8, §35.1/§35.2) : chargées FENÊTRÉES —
        // les cases prêtes autour de la case active (± 2) uniquement, la
        // clé change avec la navigation et les associations.
        .task(id: thumbnailWindowAssetIDs) {
            await loadThumbnails(for: thumbnailWindowAssetIDs)
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
    /// dictionnaire `assignmentID → record`. Recalculé par SwiftUI à
    /// chaque changement des deux `@Query`, O(N). L'identifiant d'asset de
    /// l'association alimente les miniatures réelles (§35.1/§35.2).
    private var slotItems: [AssemblySlotItem] {
        let assignmentsByID = Dictionary(
            assignmentRecords.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return slotRecords.map { record in
            // `assignmentID` orphelin (association supprimée) → raw `nil`
            // → `.empty` : la case redevient remplissable.
            let assignment = record.assignmentID.flatMap { assignmentsByID[$0] }
            return AssemblySlotItem(
                id: record.id,
                index: record.index,
                start: MediaTime(ticks: record.startTicks),
                end: MediaTime(ticks: record.endTicks),
                state: AssemblySlotState.from(
                    assignmentStatusRaw: assignment?.statusRaw
                ),
                assetLocalIdentifier: assignment?.assetLocalIdentifier
            )
        }
    }

    // Non defini par la specification — definition minimale V1.
    /// Déclencheur BON MARCHÉ d'invalidation du cache de preview (§48, §82).
    ///
    /// Une propriété calculée alimentant un `.onChange` est évaluée à CHAQUE
    /// passe de `body` : elle doit rester O(N) en opérations ENTIÈRES, sans
    /// allocation. Ce condensé ne construit donc aucune chaîne et ne
    /// matérialise aucun instantané — contrairement à
    /// `PreviewCacheKey.fingerprint`, qui compose ~120 caractères par case
    /// (~35 Ko à 300 cases) et reste réservé à la CLÉ de cache, calculée une
    /// fois par ouverture d'aperçu dans `PreviewPlayerView`.
    ///
    /// Couverture §48 — « invalider si une association change » :
    /// - `count` attrape toute création ou suppression d'association
    ///   (`beginAssignment`, `removeAssignment(IfCurrent)`) ;
    /// - `digest` combine, pour chaque association, son identifiant, sa case
    ///   et son statut : un REMPLACEMENT (§36 — même case, nouvel
    ///   identifiant) et tout changement de statut (`resolving` →
    ///   `downloading` §44 → `ready`, ou → `unavailable` §64 « un asset
    ///   devient indisponible ») changent la valeur.
    ///   La combinaison est un OU-exclusif — donc INDÉPENDANTE de l'ordre de
    ///   la `@Query` (aucun `sort` sur les associations) : seul un vrai
    ///   changement de contenu déclenche, jamais un simple réordonnancement.
    ///
    /// Les deux autres causes §48 sont couvertes AILLEURS, sans coût ici :
    /// la géométrie du premier rush invalide depuis `ClipPickerView` et
    /// depuis le rattrapage §49 de cet écran ; « le rythme change avant
    /// verrouillage » détruit cet écran (retour au choix du rythme §34) ou
    /// crée un autre projet (duplication §65).
    ///
    /// `updatedAt` du projet n'est volontairement PAS utilisé : le store le
    /// touche à CHAQUE mutation (§59), y compris `setActiveSlot` — une simple
    /// navigation dans le carrousel jetterait alors les compositions en
    /// cache, exactement ce que §48 demande de conserver.
    private var assemblyChangeToken: AssemblyChangeToken {
        var digest: UInt64 = 0
        for assignment in assignmentRecords {
            // Mélange par association (entiers uniquement, aucune
            // allocation) ; XOR final = indépendant de l'ordre.
            var mixed = UInt64(bitPattern: Int64(assignment.id.hashValue))
            mixed = mixed &* 0x0000_0100_0000_01B3
            mixed ^= UInt64(bitPattern: Int64(assignment.slotID.hashValue))
            mixed = mixed &* 0x0000_0100_0000_01B3
            mixed ^= UInt64(bitPattern: Int64(assignment.statusRaw.hashValue))
            digest ^= mixed
        }
        return AssemblyChangeToken(assignmentCount: assignmentRecords.count, digest: digest)
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
                // §35.3 : courbe musicale simplifiée en fond (écart Jalon 7
                // résorbé) — vide tant que l'extraction n'a pas abouti.
                musicCurve: musicCurve,
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
    /// L'aperçu affiche la miniature RÉELLE du rush pour une case PRÊTE
    /// (Jalon 8, §35.1 — même image que sa carte du carrousel), un
    /// placeholder neutre 16:9 sinon.
    ///
    /// Toucher (§35.1 « lecture par toucher sur l'aperçu ») :
    /// - case PRÊTE → APERÇU LOCAL §47.1 (vidéo de la case + passage musical
    ///   correspondant, uniquement la plage de la case) en feuille ;
    /// - case non prête (vide, en cours, indisponible) → lecture du PASSAGE
    ///   MUSICAL seul, comme au Jalon 7 (fichier original §16.1, pause
    ///   automatique à la fin de la case) : il n'y a pas encore de vidéo à
    ///   montrer, mais l'utilisateur doit pouvoir entendre ce qu'il remplit.
    private func topZone(item: AssemblySlotItem, count: Int) -> some View {
        VStack(spacing: 8) {
            Button {
                topZoneTapped(item: item, count: count)
            } label: {
                // Case prête : le toucher OUVRE l'aperçu §47.1 — l'icône est
                // donc toujours « lecture », jamais l'état du lecteur audio.
                let opensPreview = item.state == .ready
                let playIconName = (opensPreview || !playerController.isPlaying)
                    ? "play.fill"
                    : "pause.fill"
                ZStack {
                    if let image = thumbnail(for: item) {
                        // Jalon 8 (§35.1) : miniature RÉELLE du rush de la
                        // case active prête — MÊME image que sa carte du
                        // carrousel ; remplace le placeholder neutre 16:9.
                        // Posée en overlay d'un gabarit fixe puis rognée : sa
                        // taille intrinsèque n'influence pas la mise en page.
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.quaternary)
                            .overlay(
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        // Commande de lecture lisible sur la photo : icône
                        // blanche sur pastille sombre (même recette que les
                        // badges de la photothèque §42) — contraste garanti,
                        // l'état est AUSSI porté par `accessibilityValue`
                        // (§39, jamais la seule apparence).
                        Image(systemName: playIconName)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.55), in: Circle())
                    } else {
                        // Fond neutre — pas de verre permanent sur la zone
                        // vidéo (§37 : le contenu reste prioritaire).
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.quaternary)
                        VStack(spacing: 6) {
                            Image(systemName: playIconName)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(opensPreview ? "Aperçu du plan" : "Passage musical")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
            }
            .buttonStyle(.plain)
            // §64 : seule la lecture du PASSAGE MUSICAL dépend du fichier
            // audio — une case PRÊTE garde son aperçu §47.1 accessible même
            // sans musique lisible (le lecteur expliquera l'échec, §64 :
            // jamais un toucher sans effet).
            .disabled(isMediaUnavailable && item.state != .ready)
            .padding(.horizontal, 24)
            .accessibilityLabel(
                "Plan \(item.index + 1) sur \(count), "
                    + "durée requise \(item.duration.spokenString), "
                    + spokenState(item.state)
            )
            // §39 : l'état de lecture n'a de sens que pour le passage
            // musical — une case prête ouvre un aperçu vidéo (§47.1).
            .accessibilityValue(
                item.state == .ready
                    ? ""
                    : (playerController.isPlaying ? "Lecture en cours" : "En pause")
            )
            .accessibilityHint(
                previewHint(for: item)
            )

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
                        SlotCardView(
                            item: item,
                            isActive: position == activeIndex,
                            // Miniature réelle (§35.2) — `nil` tant qu'elle
                            // n'est pas chargée (fenêtre active ± 2).
                            thumbnail: thumbnail(for: item)
                        )
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

    /// `[Projets] [+ Vidéo • durée] [Prévisualiser | Export]` (case vide) ou
    /// `[Projets] [Remplacer] [Prévisualiser | Export]` (case remplie).
    /// Libellés dérivés par la logique pure `AssemblyViewLogic.dockLabels`
    /// (testée).
    ///
    /// Zone droite (§88.11/§89, décision Jalon 9 documentée sur
    /// `dockLabels`) :
    /// - préfixe exportable §51 NON vide → « Prévisualiser », qui ouvre
    ///   l'aperçu principal §47.2 — action du parcours minimal §88.11, donc
    ///   accessible en ZONE BASSE et pas seulement dans le menu du haut
    ///   (§89) ;
    /// - préfixe vide → « Export » DÉSACTIVÉ avec son hint (§51 : « export
    ///   désactivé si le résultat est vide ») — état RÉEL calculé par
    ///   `contiguousReadyPrefix`, pas un stub.
    private func contextualDock(activeItem: AssemblySlotItem, items: [AssemblySlotItem]) -> some View {
        // O(1) sur les items déjà matérialisés (§82 : rien de recalculé
        // pendant un glisser sur la mini-timeline) — équivalent §51 strict.
        let isExportEnabled = AssemblyViewLogic.isExportEnabled(items: items)
        let labels = AssemblyViewLogic.dockLabels(
            activeState: activeItem.state,
            requiredDuration: activeItem.duration,
            isExportEnabled: isExportEnabled
        )
        return HStack(spacing: 8) {
            dockSecondaryButton(
                title: labels.left,
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }

            // Centre : « + Vidéo • durée » / « Remplacer » — ouvre la
            // photothèque (Jalon 8, §40–§46) sur la case active.
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
            .accessibilityHint("Ouvre la photothèque pour choisir une vidéo.")

            // Droite : « Prévisualiser » (aperçu principal §47.2, parcours
            // minimal §88.11) dès qu'un préfixe exportable existe ; sinon
            // « Export » désactivé (§51). L'écran d'export arrive au
            // Jalon 10 — le bouton ne promet donc jamais une action qui
            // n'existe pas.
            Button {
                if isExportEnabled {
                    requestPrefixPreview()
                } else {
                    requestExport()
                }
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
            .accessibilityLabel(labels.right)
            .accessibilityHint(
                isExportEnabled
                    ? "Lit le montage jusqu'au premier plan non prêt."
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

    /// Toucher sur la zone haute (§35.1) — aiguillage Jalon 9 :
    /// - case PRÊTE → APERÇU LOCAL §47.1 (feuille `PreviewPlayerView`,
    ///   portée `.slot`) : « disponible pour toute case remplie, même après
    ///   un trou » ;
    /// - sinon → passage musical seul (comportement Jalon 7).
    private func topZoneTapped(item: AssemblySlotItem, count: Int) {
        guard item.state == .ready else {
            // Seule la LECTURE DU PASSAGE MUSICAL exige le fichier audio :
            // sans lui, le bouton est déjà désactivé pour une case non prête
            // (§39 : état annoncé) — garde de défense en profondeur.
            guard !isMediaUnavailable else { return }
            togglePassagePlayback(item: item)
            return
        }
        // §64 : une case PRÊTE ouvre son aperçu MÊME si la musique du projet
        // est introuvable — jamais d'échec muet. Le constructeur lèvera
        // `missingAudio` et `PreviewPlayerView` affichera le message français
        // prévu, ce qui explique le problème au lieu de ne rien faire.
        // La musique de l'écran s'arrête : le lecteur de l'aperçu prend le
        // relais (jamais deux sons simultanés).
        playerController.stopSegment()
        activeSheet = .preview(PreviewSheetContext(
            id: "slot-\(item.id.uuidString)",
            scope: .slot(item.id),
            title: "Plan \(item.index + 1) sur \(count)"
        ))
    }

    /// Lecture du passage musical de la case (`start → end`, pause
    /// automatique à `end`), ou arrêt s'il est déjà en cours.
    private func togglePassagePlayback(item: AssemblySlotItem) {
        guard !isMediaUnavailable else { return }
        if playerController.isPlaying {
            playerController.stopSegment()
        } else {
            playerController.playSegment(from: item.start, to: item.end)
        }
    }

    /// §47.2 « Aperçu principal » : commence au début et s'arrête avant la
    /// première case non prête (`contiguousPrefix`). DEUX déclencheurs — la
    /// zone droite du dock (accès de référence, zone basse §88.11/§89) et
    /// l'entrée redondante du menu ; les deux sont inactifs quand le préfixe
    /// est vide (§51), ce chemin n'est donc atteint qu'avec au moins une case
    /// prête.
    private func requestPrefixPreview() {
        playerController.stopSegment()
        activeSheet = .preview(PreviewSheetContext(
            id: "prefix",
            scope: .contiguousPrefix,
            title: "Montage jusqu'au premier plan non prêt"
        ))
    }

    // MARK: - Rattrapage du verrou de géométrie (§49, §52.1)

    /// Vrai si au moins une association est PRÊTE — clé du `.task` de
    /// rattrapage. Comparaisons de chaînes courtes sans allocation :
    /// évaluable à chaque passe de `body` (§82).
    private var hasReadyAssignment: Bool {
        assignmentRecords.contains { $0.statusRaw == ClipAssignmentStatus.ready.rawValue }
    }

    /// §49 « Au premier rush prêt … enregistrer la géométrie » — RATTRAPAGE.
    ///
    /// Le chemin nominal verrouille depuis `ClipPickerView` juste après
    /// `completeAssignment`. Si `videoGeometry` y a échoué (asset repassé sur
    /// iCloud, lecture momentanément impossible) et que l'utilisateur ne
    /// refait aucune association, le projet resterait SANS géométrie avec des
    /// cases prêtes : chaque aperçu retomberait alors sur un repli propre à sa
    /// portée, en contradiction avec §52.1 (« la géométrie est TOUJOURS celle
    /// du projet »).
    ///
    /// Même méthode que le picker : `MediaLibraryActor.videoGeometry` puis
    /// `ProjectStore.lockGeometry` — déjà NO-OP si une géométrie existe
    /// (verrou définitif §49/§65), la lecture préalable évite simplement un
    /// aller-retour PhotoKit inutile. Le rush retenu est celui de la
    /// PREMIÈRE case prête (ordre des cases), au plus près de « premier rush »
    /// §49. Erreur → journal seulement, JAMAIS bloquant (aucune alerte : rien
    /// n'est cassé du point de vue de l'utilisateur).
    private func lockGeometryIfMissing() async {
        guard !hasAttemptedGeometryLock else { return }
        guard let firstReady = slotItems.first(where: { $0.state == .ready }),
              let assetID = firstReady.assetLocalIdentifier else {
            return // aucune case prête : rien à verrouiller (§49)
        }
        hasAttemptedGeometryLock = true
        let store = environment.projectStore
        do {
            let existing = try await store.geometry(projectID: projectID)
            guard existing == nil else {
                return // déjà verrouillée : rien à faire (§49)
            }
            let geometry = try await environment.mediaLibrary.videoGeometry(id: assetID)
            try await store.lockGeometry(geometry, projectID: projectID)
            environment.previewCache.invalidateAll(projectID: projectID) // §48
        } catch {
            environment.logger.error(
                "Rattrapage du verrouillage de géométrie impossible : \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Courbe musicale de la mini-timeline (§35.3)

    /// Extrait 200 bins du fichier audio ORIGINAL (§16.1) — même service et
    /// même résolution que la forme d'onde de `ProjectView` (§16.2, lecture
    /// par blocs §68). Échec ou annulation : la courbe reste vide, la
    /// mini-timeline se dessine sans fond (jamais bloquant).
    private func loadMusicCurve() async {
        guard musicCurve.isEmpty,
              let url = environment.fileStore.audioFileURL(projectID: projectID) else { return }
        do {
            musicCurve = try await environment.waveformExtractor.waveform(for: url, binCount: 200)
        } catch is CancellationError {
            return // écran quitté pendant l'extraction : nouvelle tentative au retour
        } catch {
            environment.logger.error("Courbe musicale indisponible : \(error.localizedDescription)")
        }
    }

    // MARK: - Miniatures réelles (Jalon 8, §35.1/§35.2)

    /// Miniature d'une case si elle est PRÊTE et déjà chargée — `nil`
    /// sinon (placeholder). Source unique pour la carte ET la zone haute
    /// (« même image », §35.1).
    private func thumbnail(for item: AssemblySlotItem) -> UIImage? {
        guard item.state == .ready, let assetID = item.assetLocalIdentifier else {
            return nil
        }
        return thumbnailsByAssetID[assetID]
    }

    /// Fenêtre de chargement des miniatures : identifiants d'asset des
    /// cases PRÊTES autour de la case active (± 2 — les trois cartes
    /// visibles du carrousel et leurs voisines immédiates §35.2). Sert de
    /// clé au `.task(id:)` : navigation ou nouvelle association → la
    /// fenêtre change → chargement des manquantes.
    private var thumbnailWindowAssetIDs: [String] {
        let items = slotItems
        guard !items.isEmpty else { return [] }
        let active = AssemblyViewLogic.clampedActiveIndex(activeIndex, slotCount: items.count)
        let window = max(0, active - 2)...min(items.count - 1, active + 2)
        return window.compactMap { position in
            let item = items[position]
            guard item.state == .ready else { return nil }
            return item.assetLocalIdentifier
        }
    }

    /// Taille de carte en PIXELS pour les miniatures (§35.2) : largeur de
    /// carte ~55 % d'un grand iPhone (~215 pt) × hauteur de carte 132 pt, à
    /// l'échelle de l'écran — approximation STABLE documentée (la largeur
    /// réelle dépend du conteneur), jamais de décodage 4K (§42/§67). La
    /// zone haute réutilise la même image (§35.1 « même image »), quitte à
    /// l'agrandir légèrement.
    private var cardThumbnailPixelSize: CGSize {
        CGSize(width: 215 * displayScale, height: 132 * displayScale)
    }

    /// Charge les miniatures MANQUANTES de la fenêtre (§35.2) via
    /// `ThumbnailProvider` — séquentiel (au plus 5 assets), chaque image
    /// mise en cache local par identifiant d'asset.
    private func loadThumbnails(for assetIDs: [String]) async {
        for assetID in assetIDs where thumbnailsByAssetID[assetID] == nil {
            guard !Task.isCancelled else { return }
            guard let image = await environment.thumbnailProvider.thumbnail(
                for: assetID,
                targetSize: cardThumbnailPixelSize
            ) else { continue } // asset disparu (§64) → placeholder
            thumbnailsByAssetID[assetID] = image
        }
    }

    // MARK: - Photothèque (Jalon 8) et export (Jalon 10)

    /// Ouvre la photothèque (Jalon 8, §40–§46) sur la case active. Le dock
    /// « + Vidéo » (case vide) et « Remplacer » (case remplie §36) mènent au
    /// MÊME sélecteur : sur une case remplie, le nouveau choix remplace
    /// l'association existante via `beginAssignment`. Le passage musical en
    /// cours est arrêté (§35.1).
    private func requestVideoSelection(for item: AssemblySlotItem) {
        playerController.stopSegment()
        activeSheet = .clipPicker(ClipPickerContext(
            id: item.id,
            slotIndex: item.index,
            requiredDuration: item.duration
        ))
    }

    /// // Jalon 10 : export — le bouton n'est actif que si le préfixe §51
    /// est non vide (première association prête du Jalon 8) ; l'écran
    /// d'export arrive au Jalon 10.
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

    /// Indication vocale de la zone haute (§39) — trois cas seulement :
    /// aperçu du plan (case prête §47.1), passage musical (case non prête),
    /// musique introuvable (§64 : la raison est DITE, jamais un bouton muet).
    private func previewHint(for item: AssemblySlotItem) -> String {
        if item.state == .ready {
            return "Touchez pour voir l'aperçu de ce plan."
        }
        if isMediaUnavailable {
            return "La musique du projet est introuvable : lecture impossible."
        }
        return "Touchez pour écouter le passage musical de ce plan."
    }

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
