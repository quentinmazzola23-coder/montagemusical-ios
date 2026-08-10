//
//  ClipPickerView.swift
//  MontageMusical
//
//  Photothèque de sélection des rushs — Jalon 8, spec §40 (autorisations :
//  demande à l'ouverture de la feuille, refus expliqué + Réglages, accès
//  limité fonctionnel), §41 (albums, dernier album mémorisé PAR projet),
//  §42 (grille 3 colonnes : miniature, durée, badges iCloud/déjà utilisé,
//  état compatible/trop court, préchargement autour de la zone visible),
//  §43 (filtre initial PHAsset.duration puis validation finale AVAsset —
//  un clip trop court ne peut JAMAIS remplir la case §83), §44 (iCloud :
//  progression affichée, l'utilisateur continue à assigner d'autres cases),
//  §45 (réutilisation confirmée, jamais interdite), §46 (avancement
//  automatique, la feuille RESTE ouverte §83, « Montage complet » à la fin),
//  §64 (erreurs photothèque jamais silencieuses).
//
//  Règle du pouce §30 : la grille est du contenu ; toutes les actions
//  essentielles vivent dans le dock bas `[Albums] [Plan X • durée] [Fermer]`
//  (§36 ligne « Photothèque » — le centre est INFORMATIF).
//  Matériaux sobres §37 (aucun verre permanent sur les miniatures),
//  haptique légère à l'association réussie et haptique d'erreur pour un
//  asset invalide, AUCUNE animation décorative — rien à geler pour
//  Réduire les animations (§38), accessibilité §39 (libellés complets,
//  cibles ≥ 44 pt, jamais la seule couleur).
//
//  Présentée en sheet par `AssemblyView` ; `onSlotChanged` recentre le
//  carrousel derrière la feuille à chaque avancement §46.
//
//  Jalon 9 (§49, §50, §42) :
//  - VERROUILLAGE DE GÉOMÉTRIE : après la PREMIÈRE association réellement
//    prête (`completeAssignment`), la géométrie du projet est lue sur le rush
//    (`MediaLibraryActor.videoGeometry` → `GeometryLock`, §49) et verrouillée
//    (`ProjectStore.lockGeometry`, NO-OP si elle existe déjà — verrou
//    définitif §49/§65). Jamais bloquant : un échec laisse l'association
//    valide et la prochaine association réussie retentera le verrouillage ;
//  - badge « recadrage » §42 : les cellules dont la FORME (`max/min` des
//    pixels encodés — indépendante de l'orientation, cf.
//    `ClipPickerCropLogic`) diffère de celle de la géométrie verrouillée
//    portent un indicateur (§50 : ces rushs restent AUTORISÉS —
//    crop-to-fill centré) ;
//  - §50 « aperçu du crop réel » : la miniature de chaque cellule est rendue
//    dans le RAPPORT de la géométrie verrouillée, remplie et centrée comme le
//    crop-to-fill de la composition — aucun décodage supplémentaire, seul le
//    cadre de rendu change (§42 : jamais de décodage 4K pour la grille). Sans
//    géométrie verrouillée, la cellule garde son rendu carré.
//
//  Écarts documentés :
//  - badge « recadrage » §42, limite d'orientation : `PHAsset.pixelWidth/
//    pixelHeight` sont les dimensions ENCODÉES (un rush portrait iPhone est
//    annoncé 1920×1080). La comparaison porte donc sur des FORMES : un
//    paysage 16:9 dans un projet 9:16 a la même forme et NE porte pas le
//    badge, alors qu'il sera recadré — c'est l'aperçu du crop réel de la
//    cellule qui le montre visuellement ;
//  - badge iCloud §42 : le code du badge (`cloudBadge`) est en place mais
//    PhotoKit n'expose AUCUNE API publique « asset non téléchargé
//    localement » — `VideoAssetSummary.isCloudAsset` vaut donc `false` en
//    pratique (limite documentée dans `MediaLibraryActor.videoAssets`) et
//    l'indicateur ne s'affichera que si PhotoKit fournit l'information un
//    jour. L'état iCloud RÉEL est découvert à la RÉSOLUTION : premier
//    callback de progression réseau → statut `downloading` + anneau de
//    progression (§44), sans dépendre de la métadonnée absente.
//

import Photos
// `presentLimitedLibraryPicker` est une extension PhotosUI de PHPhotoLibrary.
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

// MARK: - Haptiques (§38)

// Non defini par la specification — definition minimale V1.
/// Haptiques via UIKit, sans dépendance (§38) : légère pour une association
/// réussie, notification d'erreur pour un asset invalide.
@MainActor
private enum PickerHaptics {
    static func success() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - Progression iCloud observable (§44)

// Non defini par la specification — definition minimale V1.
/// Fractions de téléchargement iCloud par asset (§44 : « afficher la
/// progression ») — classe `@MainActor` (donc `Sendable`) mutée depuis la
/// closure `@Sendable` de `resolveAsset` via un saut explicite MainActor.
///
/// Porte AUSSI les hooks « premier callback réseau » (§44) : la closure
/// `@Sendable` de progression ne peut pas capturer la vue (non `Sendable`) —
/// elle ne capture que ce modèle et déclenche le hook posé par
/// `beginSelection` sur l'acteur principal.
@MainActor
@Observable
private final class ClipPickerProgressModel {
    private(set) var fractionByAssetID: [String: Double] = [:]

    /// §44 : hooks « premier callback réseau » par ASSOCIATION — posés par
    /// `beginSelection` AVANT la résolution, consommés UNE seule fois
    /// (retirés au premier déclenchement) puis désarmés à la complétion.
    /// Closures `@MainActor` : posées, déclenchées et exécutées sur
    /// l'acteur principal uniquement. `@ObservationIgnored` : état interne,
    /// jamais affiché.
    @ObservationIgnored
    private var networkHooksByAssignmentID: [UUID: @MainActor () -> Void] = [:]

    func set(_ fraction: Double, assetID: String) {
        fractionByAssetID[assetID] = fraction
    }

    func clear(assetID: String) {
        fractionByAssetID[assetID] = nil
    }

    /// Arme le hook §44 d'une association (avant `resolveAsset`).
    func setNetworkHook(_ hook: @escaping @MainActor () -> Void, assignmentID: UUID) {
        networkHooksByAssignmentID[assignmentID] = hook
    }

    /// Déclenche PUIS retire le hook — une seule fois ; no-op s'il est déjà
    /// consommé ou désarmé (§44 : « au PREMIER callback avec fraction < 1 »).
    func fireNetworkHook(assignmentID: UUID) {
        networkHooksByAssignmentID.removeValue(forKey: assignmentID)?()
    }

    /// Désarme le hook à la complétion (succès ou échec) : un callback
    /// tardif ne peut plus déclencher d'avancement après coup.
    func clearNetworkHook(assignmentID: UUID) {
        networkHooksByAssignmentID[assignmentID] = nil
    }
}

// Non defini par la specification — definition minimale V1.
/// État partagé d'UNE sélection (§44) : « la feuille a déjà avancé pendant
/// le téléchargement » — écrit par le hook réseau, lu par le chemin de
/// complétion. Tout vit sur l'acteur principal : aucune course.
@MainActor
private final class SelectionAdvanceState {
    var didAdvanceDuringDownload = false
}

// Non defini par la specification — definition minimale V1.
/// Relais MainActor pour un callback système NON isolé (§40 :
/// `presentLimitedLibraryPicker(from:completionHandler:)` peut rappeler sur
/// un thread arbitraire) : le callback ne capture que ce relais (`Sendable`
/// par isolation MainActor) — jamais la vue — et le travail est rejoué sur
/// l'acteur principal (hop propre).
@MainActor
private final class MainActorRelay {
    private let work: @MainActor () async -> Void

    init(_ work: @escaping @MainActor () async -> Void) {
        self.work = work
    }

    nonisolated func schedule() {
        Task { @MainActor in
            await self.work()
        }
    }
}

// MARK: - Recadrage potentiel (§42, §50)

// Non defini par la specification — definition minimale V1.
/// Logique PURE de la grille face à la géométrie verrouillée : badge
/// « recadrage » §42 (un rush de cadrage différent sera recadré en
/// crop-to-fill centré §50 — il reste parfaitement AUTORISÉ, l'indicateur est
/// informatif) et cadre d'aperçu du crop réel §50.
///
/// Comparaison sur les métadonnées PhotoKit `pixelWidth`/`pixelHeight`
/// (§42 : jamais de décodage 4K pour afficher la grille) contre
/// `aspectWidth`/`aspectHeight` du projet. Tolérance RELATIVE de 1 % : deux
/// tournages « 16:9 » réels (1920×1080, 3840×2160, 1918×1080…) ne doivent pas
/// déclencher un faux badge à cause d'un pixel d'arrondi.
///
/// **Comparaison de FORMES, pas de rapports orientés.**
/// `PHAsset.pixelWidth/pixelHeight` sont les dimensions ENCODÉES, sans
/// orientation appliquée : un rush filmé en portrait sur iPhone est annoncé
/// 1920×1080 alors qu'il s'affiche 1080×1920. La géométrie du projet §14,
/// elle, porte un rapport ORIENTÉ (`GeometryLock.geometry` applique
/// `preferredTransform`). Comparer les deux directement marquerait
/// « recadrage » TOUS les rushs d'un projet 9:16 — y compris ceux du même
/// cadrage. On compare donc des formes indépendantes de l'orientation :
/// `max/min` de chaque côté (1,777… pour 16:9 comme pour 9:16).
///
/// LIMITE RESTANTE assumée : deux cadrages de même forme mais d'orientation
/// opposée (un paysage 16:9 dans un projet 9:16) ne portent PAS le badge,
/// alors qu'ils seront bel et bien recadrés (§50). Sans l'orientation réelle
/// du rush, l'affirmer serait deviner — et §42 interdit de décoder la vidéo
/// pour afficher la grille. Ce cas est montré VISUELLEMENT par l'aperçu du
/// crop réel de la cellule (`previewSize`, §50) : la miniature y est rendue
/// dans le rapport du projet, bords rognés compris. Le badge reste un
/// indice, jamais une décision : il n'interdit rien et n'entre dans aucun
/// calcul — le recadrage RÉEL est calculé à la composition
/// (`GeometryLock.cropToFillTransform`, §50) sur `naturalSize` +
/// `preferredTransform`.
enum ClipPickerCropLogic {

    /// Tolérance relative sur la forme (1 %).
    static let ratioTolerance = 0.01

    /// Forme d'un cadrage, indépendante de l'orientation : `max/min` — 16:9
    /// et 9:16 partagent la même valeur (1,777…), 1:1 vaut 1.
    static func shape(width: Int, height: Int) -> Double {
        Double(max(width, height)) / Double(min(width, height))
    }

    static func requiresCrop(
        assetPixelWidth: Int,
        assetPixelHeight: Int,
        geometry: ProjectGeometry?
    ) -> Bool {
        // Aucune géométrie (aucune case remplie §49) → aucun badge.
        guard let geometry else { return false }
        guard assetPixelWidth > 0, assetPixelHeight > 0,
              geometry.aspectWidth > 0, geometry.aspectHeight > 0 else {
            return false // métadonnée absente : ne rien affirmer
        }
        let assetShape = shape(width: assetPixelWidth, height: assetPixelHeight)
        let projectShape = shape(width: geometry.aspectWidth, height: geometry.aspectHeight)
        return abs(assetShape - projectShape) > ratioTolerance * projectShape
    }

    /// §50 « Afficher dans la grille un aperçu du crop réel » : taille du
    /// cadre de rendu d'une miniature dans une cellule carrée de côté `side`.
    ///
    /// Le cadre prend le RAPPORT de la géométrie verrouillée (§14/§49) et
    /// s'inscrit dans la cellule (la plus grande dimension occupe tout le
    /// côté). Combiné à `scaledToFill` + `clipped`, il reproduit exactement
    /// le crop-to-fill CENTRÉ de §50 : la miniature déjà chargée est
    /// simplement rognée à l'affichage — aucun décodage supplémentaire, la
    /// grille reste dans le contrat §42/§67.
    ///
    /// Sans géométrie verrouillée (aucune case remplie §49), rien à
    /// simuler : la cellule garde son rendu CARRÉ.
    static func previewSize(side: CGFloat, geometry: ProjectGeometry?) -> CGSize {
        guard let geometry,
              geometry.aspectWidth > 0, geometry.aspectHeight > 0 else {
            return CGSize(width: side, height: side)
        }
        let ratio = CGFloat(geometry.aspectWidth) / CGFloat(geometry.aspectHeight)
        if ratio >= 1 {
            // Paysage ou carré : largeur pleine, hauteur réduite.
            return CGSize(width: side, height: side / ratio)
        }
        // Portrait : hauteur pleine, largeur réduite.
        return CGSize(width: side * ratio, height: side)
    }
}

// MARK: - Badge de durée de la grille (§42)

private extension MediaTime {
    /// Badge court « m:ss » des cellules de la grille §42 (durée d'un asset,
    /// arrondi à la seconde d'AFFICHAGE — jamais réinjecté dans un calcul §9).
    /// Format distinct du `displayString` (centièmes) : la grille n'a pas la
    /// place pour les centièmes. Non defini par la specification — definition
    /// minimale V1.
    var gridBadgeString: String {
        let totalSeconds = max(0, Self.roundedDivision(ticks, dividedBy: Int64(Self.canonicalTimescale)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
    }
}

// MARK: - Photothèque (§40–§46)

/// Feuille de sélection des rushs (Jalon 8). Contrat partagé : présentée par
/// `AssemblyView`, elle pilote l'avancement automatique §46 via
/// `onSlotChanged` et RESTE ouverte pendant tout l'enchaînement (§83).
///
/// La case courante est un état INTERNE (`currentSlotIndex`) initialisé par
/// `slotIndex` : chaque association réussie avance vers la prochaine case
/// vide (`AssignmentRules.nextEmptySlotIndex`) et met à jour le dock
/// (plan courant + durée minimale §46).
struct ClipPickerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL

    // MARK: Contrat d'entrée

    private let projectID: UUID
    private let initialSlotID: UUID
    private let initialSlotIndex: Int
    private let initialRequiredDuration: MediaTime
    private let onSlotChanged: (Int) -> Void

    // MARK: Phases de la feuille

    // Non defini par la specification — definition minimale V1.
    fileprivate enum Phase {
        /// Demande d'autorisation §40 en cours (première apparition).
        case requestingAccess
        /// Accès refusé §40/§64 : explication + Réglages, jamais bloquant.
        case denied
        /// Grille §42 active.
        case browsing
        /// §46 : plus aucune case vide — « Montage complet ».
        case complete
    }

    /// Cases du projet (triées par index) — source de la case courante
    /// (identifiant + durée requise recalculée `end - start` §9).
    @Query private var slotRecords: [ProjectSlotRecord]

    @State private var phase: Phase = .requestingAccess
    @State private var authorization: MediaLibraryAuthorization = .notDetermined

    // MARK: État photothèque

    @State private var albums: [MediaAlbum] = []
    @State private var selectedAlbumID: MediaAlbum.ID?
    @State private var selectedAlbumTitle = ""
    @State private var assets: [VideoAssetSummary] = []
    @State private var isLoadingAssets = false
    @State private var isAlbumSheetPresented = false

    // MARK: État sélection

    /// Index de la case courante (avance automatiquement §46).
    @State private var currentSlotIndex: Int
    /// `asset → index de cases (triés)` pour le badge et le dialogue §45.
    @State private var usedIndexesByAsset: [String: [Int]] = [:]
    @State private var progressModel = ClipPickerProgressModel()
    @State private var reuseContext: ReuseContext?
    @State private var isReusePresented = false
    @State private var activeAlert: PickerAlert?
    @State private var retrySelection: PendingSelection?

    // MARK: État géométrie (Jalon 9, §49, §42)

    /// Géométrie VERROUILLÉE du projet (§49) — `nil` tant qu'aucune case
    /// n'est prête : dans ce cas aucune cellule ne porte le badge
    /// « recadrage » (§42, rien à comparer).
    @State private var lockedGeometry: ProjectGeometry?

    // MARK: État prévisualisation (Jalon 9, §46, §47.2)

    /// §46 : « Montage complet » → Fermer / Prévisualiser — l'aperçu
    /// principal (§47.2) s'ouvre au-dessus de la feuille photothèque.
    @State private var isPreviewPresented = false

    // MARK: Préchargement des miniatures (§42)

    @State private var prefetchedIDs: Set<String> = []
    @State private var prefetchBuffer: [String] = []
    @State private var prefetchTask: Task<Void, Never>?
    /// Cache BORNÉ (§42) : identifiants sortis d'écran en attente d'arrêt de
    /// préchargement — même mécanique par lots que `prefetchBuffer`.
    @State private var stopCachingBuffer: [String] = []
    @State private var stopCachingTask: Task<Void, Never>?
    @State private var lastCellPixelSize = CGSize(width: 240, height: 240)

    // MARK: Previews (aucun PhotoKit en preview)

    private let previewPhase: Phase?
    private let previewAuthorization: MediaLibraryAuthorization
    private let previewAssets: [VideoAssetSummary]
    private let previewUsed: [String: [Int]]
    /// Géométrie synthétique des previews SwiftUI (badge §42 visible sans
    /// PhotoKit ni persistance).
    private let previewGeometry: ProjectGeometry?

    // MARK: - Initialisation (contrat Jalon 8)

    init(
        projectID: UUID,
        slotID: UUID,
        slotIndex: Int,
        requiredDuration: MediaTime,
        onSlotChanged: @escaping (Int) -> Void
    ) {
        self.projectID = projectID
        self.initialSlotID = slotID
        self.initialSlotIndex = slotIndex
        self.initialRequiredDuration = requiredDuration
        self.onSlotChanged = onSlotChanged
        self.previewPhase = nil
        self.previewAuthorization = .full
        self.previewAssets = []
        self.previewUsed = [:]
        self.previewGeometry = nil
        _currentSlotIndex = State(initialValue: slotIndex)
        _slotRecords = Query(
            filter: #Predicate<ProjectSlotRecord> { slot in
                slot.projectID == projectID
            },
            sort: [SortDescriptor(\ProjectSlotRecord.index, order: .forward)]
        )
    }

    /// Initialiseur de PREVIEW uniquement : états synthétiques, aucun appel
    /// PhotoKit ni persistance (contrat Jalon 8, previews).
    fileprivate init(
        projectID: UUID,
        slotID: UUID,
        slotIndex: Int,
        requiredDuration: MediaTime,
        previewPhase: Phase,
        previewAuthorization: MediaLibraryAuthorization = .full,
        previewAssets: [VideoAssetSummary] = [],
        previewUsed: [String: [Int]] = [:],
        previewGeometry: ProjectGeometry? = nil
    ) {
        self.projectID = projectID
        self.initialSlotID = slotID
        self.initialSlotIndex = slotIndex
        self.initialRequiredDuration = requiredDuration
        self.onSlotChanged = { _ in }
        self.previewPhase = previewPhase
        self.previewAuthorization = previewAuthorization
        self.previewAssets = previewAssets
        self.previewUsed = previewUsed
        self.previewGeometry = previewGeometry
        _currentSlotIndex = State(initialValue: slotIndex)
        _slotRecords = Query(
            filter: #Predicate<ProjectSlotRecord> { slot in
                slot.projectID == projectID
            },
            sort: [SortDescriptor(\ProjectSlotRecord.index, order: .forward)]
        )
    }

    // MARK: - Case courante

    // Non defini par la specification — definition minimale V1.
    /// Instantané `Sendable` de la case courante, capturé au moment de la
    /// sélection : les résolutions tournent en tâches indépendantes par case
    /// (§44) pendant que `currentSlotIndex` continue d'avancer.
    private struct CurrentSlot: Sendable {
        let id: UUID
        let index: Int
        let requiredDuration: MediaTime
    }

    /// Case courante dérivée des records (durée `end - start` §9), avec
    /// repli sur les paramètres d'ouverture tant que la `@Query` n'a pas
    /// livré (ou en preview sans records).
    private var currentSlot: CurrentSlot {
        if let record = slotRecords.first(where: { $0.index == currentSlotIndex }) {
            return CurrentSlot(
                id: record.id,
                index: record.index,
                requiredDuration: MediaTime(ticks: record.endTicks - record.startTicks)
            )
        }
        return CurrentSlot(
            id: initialSlotID,
            index: initialSlotIndex,
            requiredDuration: initialRequiredDuration
        )
    }

    // MARK: - Contextes de dialogue

    // Non defini par la specification — definitions minimales V1.
    private struct ReuseContext {
        let summary: VideoAssetSummary
        let slot: CurrentSlot
        /// Index HUMAIN (1-based) du premier plan qui utilise déjà l'asset.
        let firstUsedDisplayIndex: Int
    }

    private struct PendingSelection {
        let summary: VideoAssetSummary
        let slot: CurrentSlot
    }

    /// Alertes §43/§64 — jamais silencieuses.
    private enum PickerAlert: Identifiable {
        /// §43 : validation finale échouée — la case reste VIDE.
        case finallyTooShort(required: MediaTime)
        /// §64 : asset supprimé — cellule retirée au refresh.
        case assetNotFound
        /// §64 : iCloud hors réseau — permettre le réessai.
        case icloudUnavailable
        /// §64 : piste vidéo absente — refuser.
        case noVideoTrack
        case generic(message: String)

        var id: String {
            switch self {
            case .finallyTooShort: "finallyTooShort"
            case .assetNotFound: "assetNotFound"
            case .icloudUnavailable: "icloudUnavailable"
            case .noVideoTrack: "noVideoTrack"
            case .generic: "generic"
            }
        }

        var title: String {
            switch self {
            case .finallyTooShort: "Vidéo trop courte"
            case .assetNotFound: "Vidéo introuvable"
            case .icloudUnavailable: "iCloud indisponible"
            case .noVideoTrack: "Vidéo illisible"
            case .generic: "Action impossible"
            }
        }

        var message: String {
            switch self {
            case .finallyTooShort(let required):
                // §43 : « erreur claire et ne pas remplir la case ».
                "Cette vidéo est finalement trop courte pour la case (\(required.shortDurationString) requis)."
            case .assetNotFound:
                "Cette vidéo n'existe plus dans votre photothèque. La case reste indisponible : remplacez-la."
            case .icloudUnavailable:
                "Cette vidéo est sur iCloud et le réseau est indisponible. Réessayez quand la connexion revient."
            case .noVideoTrack:
                "Ce fichier ne contient aucune piste vidéo : il ne peut pas remplir une case."
            case .generic(let message):
                message
            }
        }
    }

    // MARK: - Corps

    var body: some View {
        Group {
            switch phase {
            case .requestingAccess:
                requestingContent
            case .denied:
                deniedContent
            case .browsing:
                browsingContent
            case .complete:
                completeContent
            }
        }
        // §38 : les changements de phase de la feuille (autorisation →
        // grille → « Montage complet ») ne sont pas animés — choix §38, au
        // même titre que l'avancement automatique §46, qui recentre la case
        // sans transition. La garde neutralise toute animation implicite
        // héritée quand « Réduire les animations » est actif ; l'haptique
        // §38 ci-dessus, elle, reste active (ce n'est pas une animation).
        .reduceMotionSafe()
        .task { await start() }
        .onDisappear {
            // §42 : cache de miniatures relâché à la fermeture.
            prefetchTask?.cancel()
            stopCachingTask?.cancel()
            environment.thumbnailProvider.stopCachingAll()
        }
        // §45 : réutilisation signalée, jamais interdite — confirmation simple.
        .confirmationDialog(
            Text("Déjà utilisé au plan \(reuseContext?.firstUsedDisplayIndex ?? 0)"),
            isPresented: $isReusePresented,
            titleVisibility: .visible,
            presenting: reuseContext
        ) { context in
            Button("Réutiliser") {
                beginSelection(context.summary, slot: context.slot)
            }
            Button("Annuler", role: .cancel) {}
        } message: { context in
            Text("Cette vidéo remplit déjà le plan \(context.firstUsedDisplayIndex). Vous pouvez la réutiliser volontairement.")
        }
        // Erreurs §43/§64 — jamais silencieuses.
        .alert(
            activeAlert?.title ?? "",
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { activeAlert = nil } }
            ),
            presenting: activeAlert
        ) { alert in
            switch alert {
            case .icloudUnavailable:
                // §64 : permettre le réessai — relance la sélection complète
                // (nouvelle association qui remplace l'état d'échec).
                Button("Réessayer") {
                    if let pending = retrySelection {
                        retrySelection = nil
                        beginSelection(pending.summary, slot: pending.slot)
                    }
                }
                Button("Annuler", role: .cancel) {
                    retrySelection = nil
                }
            default:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }
        // §41 : liste des albums (bouton du dock, zone basse).
        .sheet(isPresented: $isAlbumSheetPresented) {
            albumList
        }
    }

    // MARK: - Phase 1 : demande d'autorisation (§40)

    private var requestingContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ProgressView()
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ouverture de la photothèque")
        .safeAreaInset(edge: .bottom) { closeOnlyDock }
    }

    // MARK: - Phase 2 : accès refusé (§40, §64)

    /// Refus expliqué, jamais bloquant pour l'application : `Ouvrir
    /// Réglages` + `Fermer` restent en zone basse (§30).
    private var deniedContent: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Accès à la photothèque refusé")
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
            Text("Autorisez l'accès aux photos dans Réglages pour choisir les vidéos qui rempliront les cases du montage. Le reste de l'application reste utilisable sans cet accès.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                dockSecondaryButton(
                    title: "Fermer",
                    accessibilityHint: "Ferme la photothèque et revient au montage."
                ) {
                    dismiss()
                }
                Button {
                    openSettings()
                } label: {
                    Text("Ouvrir Réglages")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ouvrir Réglages")
                .accessibilityHint("Ouvre les réglages de l'application pour autoriser l'accès aux photos.")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Phase 3 : grille (§42)

    private var browsingContent: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let side = max(44, (proxy.size.width - 2 * spacing) / 3) // cibles ≥ 44 pt (§39)
            ScrollView {
                VStack(spacing: 8) {
                    Text(selectedAlbumTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                        .accessibilityLabel("Album \(selectedAlbumTitle)")

                    if authorization == .limited {
                        limitedBanner
                    }

                    if isLoadingAssets {
                        ProgressView()
                            .padding(.top, 48)
                            .accessibilityLabel("Chargement des vidéos")
                    } else if assets.isEmpty {
                        Text("Aucune vidéo dans cet album.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 48)
                    } else {
                        grid(side: side, spacing: spacing)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { browsingDock }
    }

    /// Bandeau discret §40 : accès limité — action système d'ajout d'assets
    /// autorisés.
    private var limitedBanner: some View {
        HStack(spacing: 8) {
            Text("Accès limité aux photos sélectionnées")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Gérer la sélection") {
                presentLimitedLibraryPicker()
            }
            .font(.footnote.weight(.medium))
            .frame(minHeight: 44) // cible ≥ 44 pt (§39)
            .accessibilityHint("Ouvre le sélecteur système pour autoriser d'autres vidéos.")
        }
        .padding(.horizontal, 16)
    }

    private func grid(side: CGFloat, spacing: CGFloat) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: spacing),
            count: 3
        )
        let slot = currentSlot
        let requiredTicks = slot.requiredDuration.ticks
        // Miniature demandée au format CARRÉ de la cellule (§42, jamais de
        // décodage 4K) : le cadre d'aperçu §50 ne dépasse jamais `side` dans
        // l'une ou l'autre dimension — l'image reste donc assez définie sans
        // décodage supplémentaire.
        let pixelSize = CGSize(width: side * displayScale, height: side * displayScale)
        // §50 « aperçu du crop réel » : cadre au rapport de la géométrie
        // verrouillée (§49), carré tant qu'aucune case n'est remplie.
        let previewSize = ClipPickerCropLogic.previewSize(side: side, geometry: lockedGeometry)
        return LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(assets, id: \.localIdentifier) { summary in
                ClipPickerCellView(
                    summary: summary,
                    side: side,
                    previewSize: previewSize,
                    pixelSize: pixelSize,
                    // §43 : premier filtre sur PHAsset.duration — une cellule
                    // trop courte est grisée et INTERDITE à la sélection.
                    isCompatible: AssignmentRules.isDurationCompatible(
                        assetTicks: summary.duration.ticks,
                        requiredTicks: requiredTicks
                    ),
                    usedIndexes: usedIndexesByAsset[summary.localIdentifier] ?? [],
                    downloadFraction: progressModel.fractionByAssetID[summary.localIdentifier],
                    // §42 « recadrage potentiel » (Jalon 9) : FORME
                    // différente de celle de la géométrie verrouillée §49 —
                    // informatif, le rush reste autorisé (§50 crop-to-fill
                    // centré).
                    requiresCrop: ClipPickerCropLogic.requiresCrop(
                        assetPixelWidth: summary.pixelWidth,
                        assetPixelHeight: summary.pixelHeight,
                        geometry: lockedGeometry
                    ),
                    isPreview: previewPhase != nil,
                    onTap: {
                        assetTapped(summary)
                    },
                    onAppeared: {
                        markCellAppeared(summary.localIdentifier, pixelSize: pixelSize)
                    },
                    onDisappeared: {
                        markCellDisappeared(summary.localIdentifier)
                    }
                )
            }
        }
    }

    /// Dock §36 ligne « Photothèque » : `[Albums] [Plan X • durée] [Fermer]`.
    /// Le centre est INFORMATIF (plan courant + durée requise §46), mis à
    /// jour à chaque avancement.
    private var browsingDock: some View {
        let slot = currentSlot
        return HStack(spacing: 8) {
            dockSecondaryButton(
                title: "Albums",
                accessibilityHint: "Ouvre la liste des albums."
            ) {
                isAlbumSheetPresented = true
            }

            Text("Plan \(slot.index + 1) • \(slot.requiredDuration.shortDurationString)")
                .font(.body.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                .accessibilityLabel(
                    "Plan \(slot.index + 1), durée requise \(slot.requiredDuration.spokenString)"
                )

            dockSecondaryButton(
                title: "Fermer",
                accessibilityHint: "Ferme la photothèque et revient au montage."
            ) {
                dismiss()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Phase 4 : montage complet (§46)

    private var completeContent: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Montage complet")
                .font(.title3.weight(.medium))
            Text("Toutes les cases sont remplies.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Montage complet. Toutes les cases sont remplies.")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                dockSecondaryButton(
                    title: "Fermer",
                    accessibilityHint: "Ferme la photothèque et revient au montage."
                ) {
                    dismiss()
                }
                // §46 : « proposer Fermer/Prévisualiser » — l'aperçu
                // principal §47.2 s'ouvre AU-DESSUS de la photothèque
                // (Jalon 9) ; la feuille reste donc en place derrière et
                // « Fermer » ramène toujours au montage.
                Button {
                    isPreviewPresented = true
                } label: {
                    Text("Prévisualiser")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Prévisualiser")
                .accessibilityHint("Lit le montage depuis le début.")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        // Feuille attachée à la SEULE phase « Montage complet » : aucun
        // conflit avec la feuille des albums §41 présentée par le corps.
        .sheet(isPresented: $isPreviewPresented) {
            PreviewPlayerView(
                projectID: projectID,
                scope: .contiguousPrefix, // §47.2 : préfixe continu prêt
                title: "Montage complet"
            )
        }
    }

    // MARK: - Liste des albums (§41)

    /// Ordre §41 garanti par `MediaLibraryActor.albums()` : Récents, Toutes
    /// les vidéos, albums utilisateur, albums intelligents utiles.
    private var albumList: some View {
        NavigationStack {
            List(albums) { album in
                Button {
                    isAlbumSheetPresented = false
                    Task { await selectAlbum(album, persist: true) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title)
                            if let count = album.estimatedVideoCount {
                                Text(count == 1 ? "1 vidéo" : "\(count) vidéos")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if album.id == selectedAlbumID {
                            // Coche §39 : sélection jamais marquée par la
                            // seule couleur.
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .frame(minHeight: 44) // cible ≥ 44 pt (§39)
                }
                .accessibilityLabel(albumAccessibilityLabel(album))
                .accessibilityAddTraits(album.id == selectedAlbumID ? .isSelected : [])
            }
            .navigationTitle("Albums")
            .toolbarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func albumAccessibilityLabel(_ album: MediaAlbum) -> String {
        var label = album.title
        if let count = album.estimatedVideoCount {
            label += count == 1 ? ", 1 vidéo" : ", \(count) vidéos"
        }
        return label
    }

    // MARK: - Dock minimal

    private var closeOnlyDock: some View {
        HStack {
            Spacer(minLength: 0)
            dockSecondaryButton(
                title: "Fermer",
                accessibilityHint: "Ferme la photothèque et revient au montage."
            ) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Démarrage (§40, §41)

    /// Première apparition de la feuille = premier appui sur « + Vidéo » :
    /// c'est ICI que l'accès en LECTURE est demandé (§40 — jamais au
    /// lancement de l'application).
    private func start() async {
        if let previewPhase {
            authorization = previewAuthorization
            albums = [MediaAlbum(id: "preview-recents", title: "Récents", estimatedVideoCount: previewAssets.count)]
            selectedAlbumID = "preview-recents"
            selectedAlbumTitle = "Récents"
            assets = previewAssets
            usedIndexesByAsset = previewUsed
            lockedGeometry = previewGeometry
            phase = previewPhase
            return
        }

        let auth = await environment.mediaLibrary.requestAccess()
        authorization = auth
        switch auth {
        case .full, .limited:
            phase = .browsing
            // §42/§49 : la géométrie verrouillée pilote le badge
            // « recadrage » des cellules — chargée AVANT la grille pour que
            // les badges soient corrects dès le premier affichage.
            await loadGeometry()
            await loadLibrary()
        case .denied, .notDetermined:
            // `notDetermined` après une demande est anormal : traité comme
            // un refus expliqué (§40 — jamais bloquant, jamais silencieux).
            phase = .denied
        }
    }

    /// Charge les albums §41 (dernier album mémorisé PAR projet) et les
    /// réutilisations §45.
    private func loadLibrary() async {
        do {
            let savedAlbumID = try await environment.projectStore.lastAlbum(projectID: projectID)
            let loadedAlbums = try await environment.mediaLibrary.albums()
            albums = loadedAlbums
            usedIndexesByAsset = try await environment.projectStore.usedAssetSlotIndexes(projectID: projectID)
            let album = loadedAlbums.first(where: { $0.id == savedAlbumID }) ?? loadedAlbums.first
            if let album {
                // `persist: false` : la restauration ne réécrit pas la
                // mémorisation §41 — seul un CHOIX la met à jour.
                await selectAlbum(album, persist: false)
            }
        } catch let error as MediaLibraryError {
            handleBrowsingError(error)
        } catch {
            environment.logger.error("Chargement de la photothèque impossible : \(error.localizedDescription)")
            activeAlert = .generic(message: "La photothèque n'a pas pu être chargée. Réessayez.")
        }
    }

    /// Sélection d'un album (§41) : assets vidéo + mémorisation par projet.
    private func selectAlbum(_ album: MediaAlbum, persist: Bool) async {
        selectedAlbumID = album.id
        selectedAlbumTitle = album.title
        isLoadingAssets = true
        // Changement d'album : le préchargement repart de zéro (§42) —
        // lots d'arrêt compris (le `stopCachingAll` couvre tout).
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchBuffer.removeAll()
        prefetchedIDs.removeAll()
        stopCachingTask?.cancel()
        stopCachingTask = nil
        stopCachingBuffer.removeAll()
        environment.thumbnailProvider.stopCachingAll()
        defer { isLoadingAssets = false }
        do {
            assets = try await environment.mediaLibrary.videoAssets(in: album.id)
            if persist {
                try await environment.projectStore.setLastAlbum(album.id, projectID: projectID)
            }
        } catch let error as MediaLibraryError {
            handleBrowsingError(error)
        } catch {
            environment.logger.error("Chargement de l'album impossible : \(error.localizedDescription)")
            activeAlert = .generic(message: "Cet album n'a pas pu être chargé. Réessayez.")
        }
    }

    /// Recharge la grille (§64 : la cellule d'un asset supprimé est retirée
    /// au refresh).
    private func reloadAssets() async {
        guard let albumID = selectedAlbumID,
              let album = albums.first(where: { $0.id == albumID }) else { return }
        await selectAlbum(album, persist: false)
    }

    private func handleBrowsingError(_ error: MediaLibraryError) {
        switch error {
        case .accessDenied:
            phase = .denied
        case .albumNotFound:
            activeAlert = .generic(message: "Cet album n'existe plus. Choisissez un autre album.")
        default:
            activeAlert = .generic(message: error.localizedDescription)
        }
    }

    // MARK: - Sélection d'un asset (§43, §44, §45, §46)

    private func assetTapped(_ summary: VideoAssetSummary) {
        let slot = currentSlot

        // b. Filtre initial §43 sur `PHAsset.duration` — normalement
        // inatteignable (cellule désactivée), défense en profondeur : refus
        // avec haptique d'erreur (§38), JAMAIS de remplissage (§83).
        guard AssignmentRules.isDurationCompatible(
            assetTicks: summary.duration.ticks,
            requiredTicks: slot.requiredDuration.ticks
        ) else {
            PickerHaptics.error()
            return
        }

        // a. §45 : asset déjà utilisé AILLEURS → confirmation simple.
        // La case courante est exclue : remplacer une case par sa propre
        // vidéo n'est pas un doublon. Non defini par la specification —
        // definition minimale V1.
        let usedElsewhere = (usedIndexesByAsset[summary.localIdentifier] ?? [])
            .filter { $0 != slot.index }
        if let firstIndex = usedElsewhere.first {
            reuseContext = ReuseContext(
                summary: summary,
                slot: slot,
                firstUsedDisplayIndex: firstIndex + 1 // index humain §45
            )
            isReusePresented = true
            return
        }

        beginSelection(summary, slot: slot)
    }

    /// c./d./e. Association §43/§44/§46 : `beginAssignment` (sauvegarde
    /// IMMÉDIATE §59), résolution AVAsset réelle, validation finale, puis
    /// avancement automatique.
    ///
    /// §44 — statut `downloading` DYNAMIQUE à la progression : le statut
    /// initial est TOUJOURS `resolving` (la découverte iCloud se fait à la
    /// RÉSOLUTION — `isCloudAsset` n'est pas fiable, limite PhotoKit
    /// documentée dans `MediaLibraryActor.videoAssets`). Au PREMIER callback
    /// de progression avec fraction < 1 (téléchargement réseau avéré), le
    /// hook armé sur `progressModel` — une seule fois — passe la case en
    /// `downloading` ET fait avancer la feuille : la case affiche son
    /// téléchargement pendant que l'utilisateur continue à assigner d'autres
    /// cases (§44). Un asset LOCAL (aucun callback réseau, résolution
    /// immédiate) suit le chemin normal : complete puis avance.
    ///
    /// Courses par ASSOCIATION (§36/§64) : chaque tâche complète/échoue par
    /// l'identifiant de SA propre association — jamais par la case — et une
    /// `assignmentNotFound` (tâche périmée : l'association a été REMPLACÉE
    /// pendant la résolution) est avalée SILENCIEUSEMENT.
    private func beginSelection(_ summary: VideoAssetSummary, slot: CurrentSlot) {
        let store = environment.projectStore
        let library = environment.mediaLibrary
        let logger = environment.logger
        let model = progressModel
        let projectID = projectID
        let assetID = summary.localIdentifier

        Task {
            // c. Sauvegarde immédiate (§59 : jamais de debounce pour une
            // association critique) — la case passe « vérification »
            // derrière la feuille via les @Query ; « téléchargement »
            // arrivera du hook §44 si le réseau entre en jeu.
            let assignmentID: UUID
            do {
                assignmentID = try await store.beginAssignment(
                    projectID: projectID,
                    slotID: slot.id,
                    assetLocalIdentifier: assetID,
                    requiredDurationTicks: slot.requiredDuration.ticks,
                    statusRaw: ClipAssignmentStatus.resolving.rawValue
                )
            } catch {
                logger.error("Début d'association impossible : \(error.localizedDescription)")
                PickerHaptics.error()
                activeAlert = .generic(message: "L'association n'a pas pu démarrer. Réessayez.")
                return
            }

            // §44 : hook « premier callback réseau », consommé UNE seule
            // fois par le modèle (`fireNetworkHook` retire avant d'appeler).
            let advanceState = SelectionAdvanceState()
            model.setNetworkHook({
                // Posé SYNCHRONEMENT (MainActor) : le chemin de complétion
                // saura que la feuille a déjà avancé — jamais deux avances.
                advanceState.didAdvanceDuringDownload = true
                Task { @MainActor in
                    do {
                        try await store.markAssignmentDownloading(assignmentID, projectID: projectID)
                    } catch ProjectStoreError.assignmentNotFound {
                        // §64 : tâche périmée — l'association a été remplacée
                        // pendant le téléchargement : silencieux (ni alerte
                        // ni haptique), et pas d'avancement pour un fantôme.
                        return
                    } catch {
                        logger.error("Statut téléchargement impossible : \(error.localizedDescription)")
                    }
                    // §44 : la case est en téléchargement — l'utilisateur
                    // continue à assigner d'autres cases.
                    await advance(after: slot.index)
                }
            }, assignmentID: assignmentID)

            do {
                // §43/§44 : AVAsset réel, réseau autorisé, progression
                // affichée dans la cellule via le modèle observable.
                let resolved = try await library.resolveAsset(
                    id: assetID,
                    allowNetwork: true,
                    progress: { fraction in
                        Task { @MainActor in
                            model.set(fraction, assetID: assetID)
                            // §44 : fraction < 1 = téléchargement réseau
                            // avéré → hook (une seule fois). La closure
                            // `@Sendable` ne capture que le modèle.
                            if fraction < 1.0 {
                                model.fireNetworkHook(assignmentID: assignmentID)
                            }
                        }
                    }
                )
                model.clear(assetID: assetID)
                // Hook désarmé : un callback tardif ne peut plus déclencher
                // d'avancement après la complétion (§44).
                model.clearNetworkHook(assignmentID: assignmentID)

                // d. Validation finale §43 : durée RÉELLE ≥ requise
                // (égalité exacte acceptée).
                if AssignmentRules.isDurationCompatible(
                    assetTicks: resolved.duration.ticks,
                    requiredTicks: slot.requiredDuration.ticks
                ) {
                    try await store.completeAssignment(
                        assignmentID,
                        observedDurationTicks: resolved.duration.ticks,
                        projectID: projectID
                    )
                    // §49 (Jalon 9) : la case vient de devenir PRÊTE — si le
                    // projet n'a pas encore de géométrie, ce rush la
                    // verrouille définitivement. Jamais bloquant (§46
                    // continue quoi qu'il arrive), no-op côté store si une
                    // géométrie existe déjà.
                    await lockGeometryIfNeeded(assetLocalIdentifier: assetID)
                    // e. §46 : haptique LÉGÈRE puis avancement automatique
                    // — sauf si la feuille a DÉJÀ avancé au premier callback
                    // réseau (§44 : jamais deux avances pour une sélection).
                    PickerHaptics.success()
                    await refreshUsedIndexes()
                    if !advanceState.didAdvanceDuringDownload {
                        await advance(after: slot.index)
                    }
                } else {
                    // §43 : le filtre initial annonçait compatible mais la
                    // validation finale échoue — l'association est RETIRÉE
                    // PAR SON IDENTIFIANT (jamais la case entière : une
                    // association de remplacement §36 reste intacte), la
                    // case reste VIDE, erreur claire + haptique d'erreur.
                    try await store.removeAssignmentIfCurrent(
                        assignmentID,
                        slotID: slot.id,
                        projectID: projectID
                    )
                    PickerHaptics.error()
                    activeAlert = .finallyTooShort(required: slot.requiredDuration)
                    reopenSlotIfMontageWasComplete(slot)
                }
            } catch ProjectStoreError.assignmentNotFound {
                // §64 : tâche périmée — l'association a été REMPLACÉE pendant
                // la résolution (« Remplacer » §36 sur la même case) :
                // silencieux, ni alerte ni haptique d'erreur — la nouvelle
                // tâche pilote désormais la case.
                model.clear(assetID: assetID)
                model.clearNetworkHook(assignmentID: assignmentID)
            } catch let error as MediaLibraryError {
                model.clear(assetID: assetID)
                model.clearNetworkHook(assignmentID: assignmentID)
                await handleResolutionError(
                    error,
                    assignmentID: assignmentID,
                    summary: summary,
                    slot: slot
                )
            } catch {
                model.clear(assetID: assetID)
                model.clearNetworkHook(assignmentID: assignmentID)
                logger.error("Résolution impossible : \(error.localizedDescription)")
                do {
                    try await store.failAssignment(
                        assignmentID,
                        statusRaw: ClipAssignmentStatus.unavailable.rawValue,
                        projectID: projectID
                    )
                } catch ProjectStoreError.assignmentNotFound {
                    // §64 : tâche périmée remplacée — silencieux.
                    return
                } catch {
                    logger.error("Échec d'association impossible à persister : \(error.localizedDescription)")
                }
                // §45 : l'association conservée en échec compte comme
                // « déjà utilisée » — badge rafraîchi.
                await refreshUsedIndexes()
                PickerHaptics.error()
                activeAlert = .generic(message: "Cette vidéo n'a pas pu être vérifiée. Réessayez.")
            }
        }
    }

    /// Erreurs de résolution §64 — jamais silencieuses… SAUF pour une tâche
    /// périmée : `assignmentNotFound` signifie que l'association a été
    /// REMPLACÉE pendant la résolution (« Remplacer » §36 sur la même case) ;
    /// dans ce cas, ni alerte ni haptique d'erreur — la nouvelle tâche
    /// pilote la case (§64 : l'erreur appartient à une association qui
    /// n'existe plus, pas à l'état courant).
    ///
    /// Tous les chemins agissent PAR L'IDENTIFIANT de l'association de la
    /// tâche (`failAssignment(assignmentID:)`,
    /// `removeAssignmentIfCurrent(assignmentID:)`) — jamais par la case.
    private func handleResolutionError(
        _ error: MediaLibraryError,
        assignmentID: UUID,
        summary: VideoAssetSummary,
        slot: CurrentSlot
    ) async {
        let store = environment.projectStore
        switch error {
        case .assetNotFound:
            // §64 : asset supprimé → la case GARDE l'association en état
            // `unavailable` ; alerte + cellule retirée au refresh.
            do {
                try await store.failAssignment(
                    assignmentID,
                    statusRaw: ClipAssignmentStatus.unavailable.rawValue,
                    projectID: projectID
                )
            } catch ProjectStoreError.assignmentNotFound {
                return // §64 : tâche périmée remplacée — silencieux.
            } catch {
                environment.logger.error("Échec d'association impossible à persister : \(error.localizedDescription)")
            }
            // §45 : l'association conservée en échec compte comme « déjà
            // utilisée » — badge rafraîchi.
            await refreshUsedIndexes()
            PickerHaptics.error()
            activeAlert = .assetNotFound
            await reloadAssets()

        case .icloudUnavailable:
            // §64 : iCloud hors réseau → état d'échec + réessai proposé
            // (le réessai relance la sélection : nouvelle association qui
            // remplace l'état d'échec via `beginAssignment`).
            do {
                try await store.failAssignment(
                    assignmentID,
                    statusRaw: ClipAssignmentStatus.unavailable.rawValue,
                    projectID: projectID
                )
            } catch ProjectStoreError.assignmentNotFound {
                return // §64 : tâche périmée remplacée — silencieux.
            } catch {
                environment.logger.error("Échec d'association impossible à persister : \(error.localizedDescription)")
            }
            await refreshUsedIndexes() // §45 : l'échec conservé compte.
            PickerHaptics.error()
            retrySelection = PendingSelection(summary: summary, slot: slot)
            activeAlert = .icloudUnavailable

        case .noVideoTrack:
            // §64 : piste vidéo absente → REFUSER — décision documentée :
            // l'association est retirée PAR SON IDENTIFIANT (une association
            // de remplacement §36 reste intacte), la case reste VIDE
            // (comme §43).
            try? await store.removeAssignmentIfCurrent(
                assignmentID,
                slotID: slot.id,
                projectID: projectID
            )
            PickerHaptics.error()
            activeAlert = .noVideoTrack
            reopenSlotIfMontageWasComplete(slot)

        case .assetTooShort(let requiredTicks, _):
            // §43 signalé par l'acteur : même traitement que la validation
            // finale — retrait par identifiant, case VIDE, erreur claire.
            try? await store.removeAssignmentIfCurrent(
                assignmentID,
                slotID: slot.id,
                projectID: projectID
            )
            PickerHaptics.error()
            activeAlert = .finallyTooShort(required: MediaTime(ticks: requiredTicks))
            reopenSlotIfMontageWasComplete(slot)

        case .accessDenied:
            do {
                try await store.failAssignment(
                    assignmentID,
                    statusRaw: ClipAssignmentStatus.unavailable.rawValue,
                    projectID: projectID
                )
            } catch ProjectStoreError.assignmentNotFound {
                // §64 : tâche périmée remplacée — silencieux : la nouvelle
                // tâche rencontrera elle-même le refus et posera l'écran.
                return
            } catch {
                environment.logger.error("Échec d'association impossible à persister : \(error.localizedDescription)")
            }
            await refreshUsedIndexes() // §45 : l'échec conservé compte.
            PickerHaptics.error()
            phase = .denied

        case .albumNotFound:
            PickerHaptics.error()
            activeAlert = .generic(message: error.localizedDescription)
        }
    }

    /// Un échec qui VIDE une case après l'écran « Montage complet » (asset
    /// iCloud trop court résolu tardivement, piste absente…) rouvre la
    /// grille sur cette case — l'écran complet serait mensonger. Non defini
    /// par la specification — definition minimale V1.
    private func reopenSlotIfMontageWasComplete(_ slot: CurrentSlot) {
        guard phase == .complete else { return }
        currentSlotIndex = slot.index
        phase = .browsing
        onSlotChanged(slot.index)
    }

    // MARK: - Avancement automatique (§46)

    /// Prochaine case vide via `AssignmentRules.nextEmptySlotIndex`
    /// (strictement après l'index, sinon rebouclage). La feuille RESTE
    /// ouverte (§83) ; `onSlotChanged` recentre le carrousel derrière et le
    /// dock met à jour plan + durée minimale (§46). Plus aucune case vide →
    /// « Montage complet ».
    private func advance(after index: Int) async {
        do {
            let emptyIndexes = try await environment.projectStore.emptySlotIndexes(projectID: projectID)
            if let next = AssignmentRules.nextEmptySlotIndex(
                after: index,
                emptySlotIndexes: emptyIndexes
            ) {
                currentSlotIndex = next
                onSlotChanged(next)
            } else {
                phase = .complete
            }
        } catch {
            // Échec non bloquant : la case courante reste inchangée, la
            // prochaine association retentera l'avancement.
            environment.logger.error("Avancement automatique impossible : \(error.localizedDescription)")
        }
    }

    /// Rafraîchit `asset → cases` (§45) après chaque mutation réussie.
    private func refreshUsedIndexes() async {
        do {
            usedIndexesByAsset = try await environment.projectStore.usedAssetSlotIndexes(projectID: projectID)
        } catch {
            environment.logger.error("Rafraîchissement des réutilisations impossible : \(error.localizedDescription)")
        }
    }

    // MARK: - Géométrie verrouillée (Jalon 9, §49, §42, §48)

    /// Lit la géométrie déjà verrouillée du projet (§49) pour alimenter le
    /// badge « recadrage » §42. Échec non bloquant : sans géométrie, aucune
    /// cellule n'est badgée — jamais de badge faux.
    private func loadGeometry() async {
        do {
            lockedGeometry = try await environment.projectStore.geometry(projectID: projectID)
        } catch {
            environment.logger.error("Lecture de la géométrie impossible : \(error.localizedDescription)")
        }
    }

    /// §49 « Géométrie verrouillée par le premier rush ».
    ///
    /// Appelée après CHAQUE association devenue prête. Décisions :
    /// 1. **Lecture d'abord** : si une géométrie existe déjà, on sort
    ///    immédiatement — `lockGeometry` serait de toute façon un NO-OP
    ///    (verrou définitif §49, conservé même si le premier rush est
    ///    supprimé §65), mais on évite un aller-retour PhotoKit inutile ;
    /// 2. **Mesure sur le rush** : `MediaLibraryActor.videoGeometry(id:)` lit
    ///    `naturalSize` + `preferredTransform` DANS le rappel PhotoKit et ne
    ///    renvoie qu'un `ProjectGeometry` `Sendable` (`GeometryLock`, §49) ;
    /// 3. **Jamais bloquant** : un échec (asset repassé sur iCloud, lecture
    ///    impossible) est journalisé sans alerte — l'association reste
    ///    valide, l'avancement §46 se poursuit et la prochaine association
    ///    prête retentera le verrouillage ;
    /// 4. **Invalidation §48** : « la géométrie change lors du premier
    ///    rush » → tout item de prévisualisation en cache pour ce projet est
    ///    jeté.
    private func lockGeometryIfNeeded(assetLocalIdentifier: String) async {
        let store = environment.projectStore
        do {
            if let existing = try await store.geometry(projectID: projectID) {
                lockedGeometry = existing
                return
            }
            let geometry = try await environment.mediaLibrary.videoGeometry(id: assetLocalIdentifier)
            try await store.lockGeometry(geometry, projectID: projectID)
            // Relecture : la source de vérité reste le store — si un autre
            // chemin avait verrouillé entre-temps, c'est SA géométrie qui
            // compte (le verrou est définitif §49).
            let stored = try await store.geometry(projectID: projectID)
            lockedGeometry = stored ?? geometry
            environment.previewCache.invalidateAll(projectID: projectID) // §48
        } catch {
            environment.logger.error("Verrouillage de la géométrie impossible : \(error.localizedDescription)")
        }
    }

    // MARK: - Préchargement des miniatures (§42)

    /// Apparition d'une cellule : préchargement PAR LOTS autour de la zone
    /// visible (buffer vidé à 12 identifiants ou après ~120 ms) — jamais de
    /// décodage 4K (`ThumbnailProvider`, taille de cellule en pixels).
    private func markCellAppeared(_ assetID: String, pixelSize: CGSize) {
        guard previewPhase == nil else { return }
        lastCellPixelSize = pixelSize
        guard prefetchedIDs.insert(assetID).inserted else { return }
        prefetchBuffer.append(assetID)
        if prefetchBuffer.count >= 12 {
            flushPrefetch()
        } else if prefetchTask == nil {
            prefetchTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                flushPrefetch()
            }
        }
    }

    private func flushPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        guard !prefetchBuffer.isEmpty else { return }
        environment.thumbnailProvider.startCaching(
            assetIDs: prefetchBuffer,
            targetSize: lastCellPixelSize
        )
        prefetchBuffer.removeAll()
    }

    /// Disparition d'une cellule : l'identifiant sort de la fenêtre de
    /// préchargement — arrêt PAR LOTS (§42, cache BORNÉ : sans cet arrêt,
    /// un long défilement accumulerait les miniatures de TOUT l'album dans
    /// le `PHCachingImageManager`). Même mécanique que `markCellAppeared`
    /// (lot vidé à 12 identifiants ou après ~120 ms) ; une réapparition
    /// relance simplement le préchargement.
    private func markCellDisappeared(_ assetID: String) {
        guard previewPhase == nil else { return }
        guard prefetchedIDs.remove(assetID) != nil else { return }
        // Encore en attente dans le lot de préchargement : jamais parti —
        // rien à arrêter, il suffit de le retirer du lot.
        if let waitingIndex = prefetchBuffer.firstIndex(of: assetID) {
            prefetchBuffer.remove(at: waitingIndex)
            return
        }
        stopCachingBuffer.append(assetID)
        if stopCachingBuffer.count >= 12 {
            flushStopCaching()
        } else if stopCachingTask == nil {
            stopCachingTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                flushStopCaching()
            }
        }
    }

    private func flushStopCaching() {
        stopCachingTask?.cancel()
        stopCachingTask = nil
        guard !stopCachingBuffer.isEmpty else { return }
        environment.thumbnailProvider.stopCaching(
            assetIDs: stopCachingBuffer,
            targetSize: lastCellPixelSize
        )
        stopCachingBuffer.removeAll()
    }

    // MARK: - Actions système (§40)

    /// §40 : accès limité — présente le sélecteur système d'assets
    /// autorisés au-dessus de la feuille, PUIS recharge albums et grille à
    /// sa fermeture (`completionHandler`) : la sélection autorisée a pu
    /// changer, la grille et les comptes d'albums doivent la refléter.
    private func presentLimitedLibraryPicker() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.keyWindow?.rootViewController else {
            environment.logger.error("Aucune fenêtre pour présenter le sélecteur d'accès limité.")
            return
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        // Hop MainActor propre : le `completionHandler` PhotoKit n'est pas
        // isolé — il ne capture que le relais (Sendable par isolation
        // MainActor, jamais la vue) et le rechargement est rejoué sur
        // l'acteur principal.
        let relay = MainActorRelay {
            await reloadAfterLimitedSelection()
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { _ in
            relay.schedule()
        }
    }

    /// §40 : après la fermeture du sélecteur d'accès limité — recharge la
    /// liste des albums (les comptes de vidéos changent avec la sélection)
    /// ET la grille de l'album courant (`loadLibrary` re-sélectionne
    /// l'album mémorisé §41 sans réécrire la mémorisation).
    private func reloadAfterLimitedSelection() async {
        await loadLibrary()
    }

    /// §40 : refus → proposer d'ouvrir Réglages, jamais bloquer.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    // MARK: - Composants de dock partagés (§37, §39)

    /// Bouton secondaire de dock — même style que `AssemblyView` et
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

// MARK: - Cellule de la grille (§42)

/// Cellule carrée (gabarit de grille STABLE) contenant l'APERÇU DU CROP RÉEL
/// §50 : la miniature (jamais de décodage 4K — `ThumbnailProvider`) est rendue
/// dans un cadre au rapport de la géométrie verrouillée §49, remplie et
/// centrée — exactement le crop-to-fill de §50. Sans géométrie, le cadre
/// reste carré. Autour : badge de durée, badge iCloud, badge « déjà utilisé »,
/// badge « recadrage » §42, progression de téléchargement (§44).
/// Incompatible §43 : grisée à 0,35 et DÉSACTIVÉE — « incompatible, trop
/// courte » annoncé à VoiceOver (§39).
private struct ClipPickerCellView: View {
    @Environment(AppEnvironment.self) private var environment

    let summary: VideoAssetSummary
    /// Côté de la cellule carrée — gabarit de grille et cible tactile (§39).
    let side: CGFloat
    /// §50 : taille du cadre d'aperçu (rapport de la géométrie §49), inscrite
    /// dans la cellule. Égale à `side × side` sans géométrie verrouillée.
    let previewSize: CGSize
    let pixelSize: CGSize
    let isCompatible: Bool
    let usedIndexes: [Int]
    let downloadFraction: Double?
    /// §42 « recadrage potentiel » : FORME différente de celle de la
    /// géométrie verrouillée §49 — le rush reste autorisé (§50).
    let requiresCrop: Bool
    let isPreview: Bool
    let onTap: () -> Void
    let onAppeared: () -> Void
    /// §42 cache borné : la cellule sortie d'écran quitte la fenêtre de
    /// préchargement (arrêt par lots côté parent).
    let onDisappeared: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            // Gabarit CARRÉ conservé (largeur de colonne stable, cible
            // tactile ≥ 44 pt §39) ; l'aperçu §50 s'inscrit dedans.
            ZStack {
                cropPreview
            }
            .frame(width: side, height: side)
            // §43 : cellule trop courte grisée — l'état est AUSSI porté par
            // le libellé VoiceOver et la désactivation, jamais la seule
            // apparence (§39).
            .opacity(isCompatible ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isCompatible)
        .onAppear(perform: onAppeared)
        .onDisappear(perform: onDisappeared)
        .task(id: summary.localIdentifier) {
            guard !isPreview, thumbnail == nil else { return }
            thumbnail = await environment.thumbnailProvider.thumbnail(
                for: summary.localIdentifier,
                targetSize: pixelSize
            )
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isCompatible ? "Associe cette vidéo au plan courant." : "")
    }

    // MARK: Aperçu du crop réel (§50)

    /// §50 « Afficher dans la grille un aperçu du crop réel » : la miniature
    /// est rendue dans le RAPPORT de la géométrie verrouillée (§49) avec le
    /// MÊME centrage que le crop-to-fill de la composition — `scaledToFill`
    /// remplit le cadre, `clipped` rogne les bords qui débordent, le contenu
    /// reste centré. Aucun décodage supplémentaire : c'est la miniature déjà
    /// chargée, seul le cadre de rendu change (§42/§67).
    ///
    /// Les badges suivent le cadre d'aperçu (et non la cellule) : ils restent
    /// posés sur l'image montrée, jamais dans les marges vides.
    private var cropPreview: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .clipped()
        .overlay(alignment: .bottomLeading) { durationBadge }
        .overlay(alignment: .topTrailing) {
            if summary.isCloudAsset { cloudBadge }
        }
        .overlay(alignment: .topLeading) {
            if !usedIndexes.isEmpty { usedBadge }
        }
        .overlay(alignment: .bottomTrailing) {
            if requiresCrop { cropBadge }
        }
        .overlay {
            if let downloadFraction { progressOverlay(downloadFraction) }
        }
    }

    // MARK: Badges

    /// Badge « m:ss » (§42) — fond sombre constant pour rester lisible sur
    /// toute miniature, en clair comme en sombre (§39).
    private var durationBadge: some View {
        Text(summary.duration.gridBadgeString)
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(4)
            .accessibilityHidden(true) // durée déjà dans le libellé global
    }

    private var cloudBadge: some View {
        Image(systemName: "icloud")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.55), in: Circle())
            .padding(4)
            .accessibilityHidden(true)
    }

    /// Badge « recadrage potentiel » (§42) — icône, jamais la seule couleur
    /// (§39) ; l'information est AUSSI dans le libellé VoiceOver. Le rush
    /// reste sélectionnable : V1 recadre en crop-to-fill centré (§50).
    private var cropBadge: some View {
        Image(systemName: "crop")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.55), in: Circle())
            .padding(4)
            .accessibilityHidden(true)
    }

    /// Badge « déjà utilisé » (§42/§45) — icône, jamais la seule couleur (§39).
    private var usedBadge: some View {
        Image(systemName: "repeat")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.55), in: Circle())
            .padding(4)
            .accessibilityHidden(true)
    }

    /// §44 : anneau de progression déterminé (fraction 0…1) — dessin direct
    /// (`ProgressView` circulaire est indéterminée sur iOS), AUCUNE
    /// animation (§38).
    private func progressOverlay(_ fraction: Double) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.35), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 30, height: 30)
        }
        .accessibilityHidden(true) // progression déjà dans le libellé global
    }

    // MARK: Accessibilité (§39, §42, §43)

    private var accessibilityLabel: String {
        var label = "Vidéo, durée \(summary.duration.spokenString)"
        if summary.isCloudAsset {
            label += ", sur iCloud"
        }
        if let first = usedIndexes.first {
            label += ", déjà utilisée au plan \(first + 1)"
        }
        if requiresCrop {
            // §42 « recadrage potentiel » : informatif, la vidéo reste
            // sélectionnable (§50 : crop-to-fill centré).
            label += ", format différent, sera recadrée"
        }
        if let downloadFraction {
            label += ", téléchargement \(Int((min(max(downloadFraction, 0), 1) * 100).rounded())) pour cent"
        }
        if !isCompatible {
            // §42/§43 : « incompatible, trop courte ».
            label += ", incompatible, trop courte"
        }
        return label
    }
}

// MARK: - Previews (états synthétiques, aucun PhotoKit)

private func makePreviewSummaries() -> [VideoAssetSummary] {
    let durations: [Int64] = [
        45_000, 500_000, 90_000, 30_000, 240_000, 1_260_000,
        75_000, 60_000, 660_000, 48_000, 180_000, 96_000
    ]
    return durations.enumerated().map { index, ticks in
        // Trois formes mélangées face à un projet verrouillé en 16:9 (§49) :
        // - 16:9 encodé paysage (forme 1,78) → aucun badge ;
        // - 16:9 encodé portrait (forme 1,78 elle aussi) → aucun badge non
        //   plus : c'est la LIMITE documentée du badge §42, que l'aperçu du
        //   crop réel (§50) montre visuellement ;
        // - 4:3 (forme 1,33) → badge « recadrage » §42.
        let pixels: (width: Int, height: Int) = switch index % 3 {
        case 1: (width: 1080, height: 1920) // portrait 9:16 (métadonnée encodée)
        case 2: (width: 1440, height: 1080) // 4:3 — forme réellement différente
        default: (width: 1920, height: 1080) // 16:9 paysage
        }
        return VideoAssetSummary(
            localIdentifier: "preview-\(index)",
            duration: MediaTime(ticks: ticks),
            isCloudAsset: index % 4 == 2,
            pixelWidth: pixels.width,
            pixelHeight: pixels.height
        )
    }
}

#Preview("Photothèque — grille") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    // Durée requise 1,20 s : les assets de 0,75 s et 0,50 s apparaissent
    // grisés (§43), « preview-1 » porte le badge déjà utilisé (§45), les
    // rushs 4:3 portent le badge « recadrage » (§42) face à une géométrie
    // verrouillée en 16:9 (§49) et toutes les cellules montrent l'aperçu du
    // crop réel en 16:9 (§50).
    return ClipPickerView(
        projectID: UUID(),
        slotID: UUID(),
        slotIndex: 2,
        requiredDuration: MediaTime(ticks: 72_000),
        previewPhase: .browsing,
        previewAssets: makePreviewSummaries(),
        previewUsed: ["preview-1": [0, 4]],
        previewGeometry: ProjectGeometry(
            aspectWidth: 16,
            aspectHeight: 9,
            orientation: .landscape,
            lockedByAssetIdentifier: "preview-0"
        )
    )
    .environment(environment)
    .modelContainer(container)
}

#Preview("Photothèque — accès limité") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    return ClipPickerView(
        projectID: UUID(),
        slotID: UUID(),
        slotIndex: 0,
        requiredDuration: MediaTime(ticks: 72_000),
        previewPhase: .browsing,
        previewAuthorization: .limited,
        previewAssets: makePreviewSummaries()
    )
    .environment(environment)
    .modelContainer(container)
}

#Preview("Photothèque — accès refusé") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    return ClipPickerView(
        projectID: UUID(),
        slotID: UUID(),
        slotIndex: 0,
        requiredDuration: MediaTime(ticks: 72_000),
        previewPhase: .denied,
        previewAuthorization: .denied
    )
    .environment(environment)
    .modelContainer(container)
}

#Preview("Photothèque — montage complet") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    return ClipPickerView(
        projectID: UUID(),
        slotID: UUID(),
        slotIndex: 7,
        requiredDuration: MediaTime(ticks: 72_000),
        previewPhase: .complete
    )
    .environment(environment)
    .modelContainer(container)
}
