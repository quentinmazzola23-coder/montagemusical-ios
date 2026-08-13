//
//  PreviewPlayerView.swift
//  MontageMusical
//
//  Lecteur de prévisualisation — Jalon 9, spec §47 (portées : aperçu local
//  d'une case §47.1, aperçu principal des zones exportées §47.2), §48 (composition
//  mise en cache tant que les associations ne changent pas), §36 (dock
//  contextuel ligne « Prévisualisation » : `[Retour] [Lecture/Pause]
//  [Export]`), §64 (erreurs jamais silencieuses, états sobres français).
//
//  Règle du pouce §30 : les trois contrôles vivent dans le dock bas ; la
//  vidéo au-dessus n'est que du contenu. Matériaux translucides sobres §37
//  (aucun verre permanent sur la vidéo — le contenu reste prioritaire),
//  AUCUNE animation décorative §38, accessibilité §39 (libellés complets,
//  cibles ≥ 44 pt, état annoncé sans dépendre de la couleur).
//
//  Jalon 10 : la zone droite « Export » devient ACTIVE (§85) — elle présente
//  le résumé avant export §56 (`ExportSummaryView`) quand la portée
//  prévisualisée EST le montage exportable et qu'il n'est pas vide. L'écart
//  du Jalon 9 (bouton présent mais désactivé, « l'export arrive dans une
//  prochaine version ») est résorbé : le hint ne promet plus rien, il décrit
//  l'action réelle — il annonce le RÉSUMÉ, jamais un enregistrement dans
//  Photos, qui reste un geste explicite dans l'écran d'export (§40, §55 ;
//  décision documentée en tête d'`ExportSummaryView`).
//
//  Cet aperçu survit à l'export : `ProjectView` route les statuts de montage
//  `assembling`/`partiallyPreviewable`/`complete`/`exporting` vers le MÊME
//  écran d'assemblage (§10, §58), de sorte que le passage au statut
//  `exporting` ne démonte ni cette feuille ni celle du résumé posée dessus.
//
//  ÉCART PRODUIT — EXPORT CONCATÉNÉ DES ZONES REMPLIES (13 août 2026,
//  demande utilisateur postérieure à la spécification ; détail dans
//  IMPLEMENTATION_STATUS.md). La portée §47.2 était le PRÉFIXE (depuis la
//  case 0, arrêt au premier trou) ; c'est désormais la CONCATÉNATION de
//  TOUTES les zones de cases prêtes — les cases vides ou non prêtes sont
//  supprimées, vidéo et musique comprises. Le nom d'énumération
//  `PreviewScope.contiguousPrefix` (domaine, hors périmètre de cette vue) est
//  inchangé — seule sa RÈGLE a changé ; les TEXTES de cet écran, eux, parlent
//  des ZONES exportées : titre de la feuille fourni par `AssemblyView`
//  (« Montage — plans 28 à 50 », « Montage — 19 plans en 2 zones »), messages
//  d'erreur §64 ci-dessous, hints du dock §36.
//
//  L'aperçu montre donc EXACTEMENT ce que l'export produira, jonctions
//  comprises : c'est le seul endroit où l'utilisateur peut entendre le saut de
//  musique entre deux zones avant d'exporter.
//

import AVFoundation
import AVKit
import Combine
import SwiftData
import SwiftUI

// MARK: - Lecteur de prévisualisation (§47, §48)

/// Feuille plein écran de prévisualisation.
///
/// Contrat Jalon 9 : `PreviewPlayerView(projectID:scope:title:)` — présentée
/// en `sheet` par `AssemblyView` (§47.1 aperçu local de la case active
/// prête, §47.2 aperçu principal des zones exportées) et par `ClipPickerView`
/// (§46 : « Montage complet » → Fermer / Prévisualiser).
///
/// Cycle de vie :
/// 1. `.task` : instantané du projet (`ProjectStore.projectSnapshot`) → clé
///    `PreviewCacheKey(scope:snapshot:)` (§48 : projet + portée + empreinte
///    des cases, associations et géométrie) → `CachedComposition` du
///    `PreviewCache` si elle existe, sinon `PreviewBuilder.makeComposition`
///    puis mise en cache ;
/// 2. un `AVPlayerItem` NEUF est fabriqué à partir de cette composition pour
///    CETTE présentation — un `AVPlayerItem` ne peut être associé qu'à un
///    seul `AVPlayer` (le réutiliser depuis un cache lèverait
///    `NSInvalidArgumentException`). Ce que le cache §48 évite, c'est
///    l'assemblage des pistes, pas la création de l'item ;
/// 3. lecture immédiate au chargement (l'utilisateur a demandé un aperçu) ;
/// 4. surveillance des échecs de lecture (§64) : `AVPlayerItem.status` et
///    `failedToPlayToEndTimeNotification` — jamais d'écran noir muet ;
/// 5. `.onDisappear` : lecture arrêtée, observation résiliée, item et lecteur
///    libérés. Seule la composition survit, dans le cache.
struct PreviewPlayerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private let projectID: UUID
    private let scope: PreviewScope
    private let title: String

    /// Lecteur courant — `nil` tant que la composition n'est pas prête.
    @State private var player: AVPlayer?
    /// État de lecture (piloté par le dock, jamais deviné).
    @State private var isPlaying = false
    /// Message d'erreur français (§64) — `nil` : aucun échec.
    @State private var errorMessage: String?
    /// Observation de `AVPlayerItem.status` (§64) — un item qui bascule en
    /// `.failed` ne doit JAMAIS rester un écran noir silencieux.
    @State private var statusObserver: AnyCancellable?
    /// Jalon 10 : feuille du résumé avant export §56 présentée par la zone
    /// droite du dock (§36).
    @State private var isExportPresented = false

    init(projectID: UUID, scope: PreviewScope, title: String) {
        self.projectID = projectID
        self.scope = scope
        self.title = title
    }

    // MARK: - Corps

    var body: some View {
        Group {
            if let errorMessage {
                errorContent(errorMessage)
            } else if let player {
                playerContent(player)
            } else {
                preparingContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // §38 : le passage préparation → lecture (ou → erreur §64) n'est pas
        // animé — choix §38, rappelé ci-dessous à la fin de lecture. La garde
        // neutralise toute animation implicite héritée quand « Réduire les
        // animations » est actif.
        .reduceMotionSafe()
        .safeAreaInset(edge: .bottom) { previewDock }
        // Jalon 10 (§36 zone droite, §56) : le résumé avant export se présente
        // PAR-DESSUS l'aperçu — la portée lue reste intacte derrière, et
        // fermer le résumé rend l'aperçu tel quel (aucune reconstruction, le
        // cache §48 n'est pas touché).
        .sheet(isPresented: $isExportPresented) {
            ExportSummaryView(projectID: projectID)
        }
        .task { await preparePreview() }
        // §38 : rien à animer — la fin de lecture repositionne simplement
        // l'état du bouton Lecture/Pause.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item === player?.currentItem else { return }
            isPlaying = false
        }
        // §64 : une lecture qui s'interrompt en cours de route (rush évincé
        // du cache disque, fichier illisible) est un ÉCHEC, pas une fin de
        // portée — elle est signalée, jamais avalée.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item === player?.currentItem else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            handlePlaybackFailure(error ?? item.error)
        }
        .onDisappear { teardown() }
    }

    // MARK: - Contenus

    /// Vidéo plein cadre — aucun verre permanent par-dessus (§37).
    private func playerContent(_ player: AVPlayer) -> some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
    }

    private var preparingContent: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            ProgressView()
            Text("Préparation de l'aperçu…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Préparation de l'aperçu")
    }

    /// État d'erreur sobre (§64) : explication française + « Fermer ».
    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Aperçu impossible")
                .font(.title3.weight(.medium))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Fermer") {
                dismiss()
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.bordered)
            .frame(minHeight: 44) // cible ≥ 44 pt (§39)
            .accessibilityHint("Ferme l'aperçu et revient au montage.")
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Dock §36 « Prévisualisation »

    /// `[Retour] [Lecture/Pause] [Export]` — Export ACTIF (Jalon 10) quand la
    /// portée prévisualisée est celle qui sera exportée et qu'elle est
    /// lisible. Le titre de la portée est une ligne INFORMATIVE au-dessus
    /// des trois zones, jamais un contrôle.
    private var previewDock: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel("Aperçu : \(title)")

            HStack(spacing: 8) {
                dockSecondaryButton(
                    title: "Retour",
                    accessibilityHint: "Ferme l'aperçu et revient au montage."
                ) {
                    dismiss()
                }

                // Centre : Lecture/Pause (§36, §37).
                Button {
                    togglePlayback()
                } label: {
                    Label(
                        isPlaying ? "Pause" : "Lecture",
                        systemImage: isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(player == nil)
                .opacity(player == nil ? 0.4 : 1)
                .accessibilityLabel(isPlaying ? "Pause" : "Lecture")
                .accessibilityHint(
                    player == nil
                        ? "Disponible dès que l'aperçu est prêt."
                        : (isPlaying ? "Met l'aperçu en pause." : "Lance la lecture de l'aperçu.")
                )

                // Droite : Export (§36) — présente le résumé §56. L'état
                // désactivé est marqué par l'opacité ET annoncé par VoiceOver
                // (trait « estompé » automatique + hint), jamais par la seule
                // couleur (§39).
                Button {
                    requestExport()
                } label: {
                    Text("Export")
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52) // ≥ 44 pt (§39)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canExport)
                .opacity(canExport ? 1 : 0.4)
                .accessibilityLabel("Export")
                .accessibilityHint(exportHint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Export depuis l'aperçu (Jalon 10, §36, §56)

    /// Vrai si la portée AFFICHÉE est bien celle qui sera exportée.
    ///
    /// - `.contiguousPrefix` (§47.2) : ce sont exactement les ZONES
    ///   exportables §51 — l'aperçu et l'export partagent
    ///   `readyTimeline(slots:)` (le nom de l'énumération date d'avant l'écart
    ///   produit) ;
    /// - `.complete` : portée demandée quand TOUTES les cases sont prêtes
    ///   (§47.2) ; il n'y a alors qu'une zone, qui couvre le projet entier —
    ///   l'export produit donc rigoureusement le montage prévisualisé ;
    /// - `.slot` (§47.1) : aperçu d'UNE case. L'export ne porte jamais sur un
    ///   plan isolé (§51) — le bouton reste désactivé, avec un hint qui le
    ///   dit plutôt que de laisser deviner.
    private var isExportableScope: Bool {
        switch scope {
        case .contiguousPrefix, .complete: true
        case .slot: false
        }
    }

    /// §51 « export désactivé si le résultat est vide » : un montage sans
    /// aucune zone fait échouer la construction avec
    /// `PreviewError.emptyScope` — donc un lecteur PRÊT et sans erreur prouve
    /// que la portée contient au moins une case. Aucune seconde lecture du
    /// projet n'est nécessaire pour le savoir.
    private var canExport: Bool {
        isExportableScope && errorMessage == nil && player != nil
    }

    private var exportHint: String {
        if canExport {
            return "Affiche le résumé de l'export : les zones remplies que vous venez de voir."
        }
        if !isExportableScope {
            return "L'export porte sur le montage, pas sur un plan isolé."
        }
        return "Disponible dès que l'aperçu du montage est prêt."
    }

    /// Présente le résumé avant export §56. La lecture est mise en pause : le
    /// résumé se lit au calme, et rien ne continue à jouer sous la feuille.
    private func requestExport() {
        guard canExport else { return }
        player?.pause()
        isPlaying = false
        isExportPresented = true
    }

    // MARK: - Préparation de la composition (§48)

    /// Cherche la composition dans le cache (§48), sinon la construit et la
    /// range — puis en tire un `AVPlayerItem` NEUF pour cette présentation.
    ///
    /// **Empreinte** : la clé est construite par `PreviewCacheKey(scope:
    /// snapshot:)` à partir de l'instantané `ProjectSnapshot` lu sur le
    /// `ProjectStore` (acteur). Elle décrit donc l'état RÉELLEMENT persisté
    /// au moment de la construction — jamais un état d'affichage en avance
    /// sur la base — et couvre exactement les causes d'invalidation §48
    /// (cases, associations, statuts, géométrie). Une DEUXIÈME définition
    /// d'empreinte côté vue divergerait tôt ou tard : celle-ci est la seule.
    private func preparePreview() async {
        let store = environment.projectStore
        let snapshot: ProjectSnapshot
        do {
            snapshot = try await store.projectSnapshot(projectID: projectID)
        } catch is CancellationError {
            // §8 : fermer la feuille pendant la lecture du projet annule la
            // tâche — ce n'est pas un échec, rien à afficher ni à journaliser.
            return
        } catch {
            environment.logger.error("Lecture du projet impossible pour l'aperçu : \(error.localizedDescription)")
            // §87 : « Réessayez » ne désignait aucun geste — cet écran ne
            // porte pas de bouton de relance. Le message nomme celui qui
            // existe (le dock §36 « Retour »).
            errorMessage = "Le projet n'a pas pu être lu. Fermez l'aperçu, puis rouvrez-le."
            return
        }

        let key = PreviewCacheKey(scope: scope, snapshot: snapshot)

        if let cached = environment.previewCache.composition(for: key) {
            start(with: cached)
            return
        }

        do {
            let composition = try await environment.previewBuilder.makeComposition(for: snapshot, scope: scope)
            environment.previewCache.store(composition, for: key)
            start(with: composition)
        } catch is CancellationError {
            // §8 : « supporter l'annulation ». Fermer la feuille pendant la
            // construction interrompt la tâche `.task` : aucune erreur à
            // journaliser, aucun état d'échec à poser sur une vue qui
            // disparaît.
            return
        } catch let error as PreviewError {
            errorMessage = Self.message(for: error)
        } catch {
            environment.logger.error("Construction de l'aperçu impossible : \(error.localizedDescription)")
            errorMessage = "L'aperçu n'a pas pu être préparé. Fermez l'aperçu, puis rouvrez-le."
        }
    }

    /// Messages français §64.
    ///
    /// Formulation PROPRE À L'ÉCRAN plutôt que `errorDescription` : celui de
    /// `assetUnavailable` contient l'identifiant local PhotoKit du rush,
    /// utile en journal mais illisible pour l'utilisateur — et §69A demande
    /// de ne pas exposer d'inutiles détails techniques. Tous les cas sont
    /// couverts explicitement : un futur cas ajouté à `PreviewError` fera
    /// échouer la compilation ici (jamais d'erreur muette).
    ///
    /// Chaque message dit QUOI FAIRE, et les causes qui appellent des gestes
    /// différents sont distinguées (§40 Réglages / §44 attendre iCloud /
    /// §64 remplacer le rush).
    private static func message(for error: PreviewError) -> String {
        switch error {
        case .emptyScope:
            // ÉCART PRODUIT : n'importe quelle case remplie suffit désormais
            // à obtenir un montage — ce n'est plus « la première » qu'il faut
            // nommer, sinon le message décrirait un blocage qui n'existe plus.
            "Aucun plan prêt à prévisualiser. Remplissez au moins une case."
        case .missingAudio:
            "La musique du projet est introuvable. Réimportez-la pour prévisualiser."
        case .assetUnavailable:
            "Une vidéo de ce montage n'est plus disponible. Remplacez-la pour prévisualiser."
        case .accessDenied:
            "L'accès à vos photos est refusé. Autorisez-le dans Réglages pour prévisualiser le montage."
        case .icloudUnavailable:
            "Une vidéo de ce montage est encore dans iCloud. Attendez la fin de son téléchargement, puis réessayez."
        case .incompletePrefix:
            // Nom de cas hérité (`PreviewError`, domaine hors périmètre) : la
            // situation décrite est « les zones prêtes ne couvrent pas TOUTES
            // les cases » (portée `.complete`), pas « le début du montage
            // manque » — le montage est fait de toutes les zones remplies,
            // où qu'elles soient (écart produit).
            "Un plan de ce montage n'est pas encore prêt. Attendez la fin des téléchargements, puis réessayez."
        }
    }

    // MARK: - Lecture

    /// Fabrique un `AVPlayerItem` NEUF à partir de la composition, l'attache
    /// à un lecteur neuf et démarre la lecture (l'utilisateur a demandé un
    /// aperçu : il n'a pas à appuyer deux fois).
    ///
    /// **L'item n'est jamais recyclé.** Un `AVPlayerItem` ne peut être
    /// associé qu'à UN seul `AVPlayer` : rattacher un item déjà utilisé à un
    /// lecteur neuf lève `NSInvalidArgumentException`. C'est la
    /// `CachedComposition` (immuable, partageable) qui vit dans le cache
    /// §48 ; l'item, lui, est jetable et sa création est instantanée.
    private func start(with composition: CachedComposition) {
        let item = composition.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        // Aucune boucle, aucun effet : lecture simple de la portée (§47).
        player.actionAtItemEnd = .pause
        player.seek(to: .zero)
        observeStatus(of: item)
        self.player = player
        player.play()
        isPlaying = true
    }

    /// Surveille `AVPlayerItem.status` (§64) : un item qui bascule en
    /// `.failed` (piste illisible, fichier disparu entre la construction et
    /// la lecture) doit produire un message, jamais un écran noir muet.
    ///
    /// `receive(on: DispatchQueue.main)` : KVO notifie sur le fil qui a
    /// changé la valeur ; l'état de la vue ne se met à jour que sur le fil
    /// principal (§8).
    private func observeStatus(of item: AVPlayerItem) {
        statusObserver = item.publisher(for: \.status, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { status in
                guard status == .failed else { return }
                handlePlaybackFailure(item.error)
            }
    }

    /// Échec de lecture (§64) : journaliser, arrêter, purger le cache du
    /// projet, expliquer en français.
    ///
    /// Le cache est purgé parce qu'une composition qui ne se lit plus ne doit
    /// pas être resservie à la prochaine ouverture : le rush a disparu ou
    /// n'est plus déchiffrable (§48 : « un asset devient indisponible »
    /// invalide le cache). Le montage lui-même n'est PAS touché (§51).
    private func handlePlaybackFailure(_ error: Error?) {
        guard errorMessage == nil else { return } // échec déjà signalé
        player?.pause()
        isPlaying = false
        environment.logger.error(
            "Lecture de l'aperçu impossible : \(error?.localizedDescription ?? "cause inconnue")"
        )
        environment.previewCache.invalidateAll(projectID: projectID) // §48
        // Le lecteur est libéré : l'écran d'erreur remplace la vidéo et le
        // bouton Lecture redevient indisponible.
        player = nil
        errorMessage = "La lecture de l'aperçu a échoué. "
            + "Une vidéo du montage n'est peut-être plus lisible : vérifiez-la, puis réessayez."
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // Reprise après la fin de la portée : revenir au début plutôt que
            // de rester bloqué sur la dernière image.
            if let item = player.currentItem,
               item.duration.isNumeric,
               CMTimeCompare(player.currentTime(), item.duration) >= 0 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    /// Sortie de l'écran : lecture arrêtée, item détaché, observation
    /// résiliée — lecteur et item sont jetés. Seule la composition survit,
    /// dans le cache (§48) : la prochaine ouverture en refabriquera un item
    /// neuf sans réassembler les pistes.
    private func teardown() {
        statusObserver?.cancel()
        statusObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
    }

    // MARK: - Composants de dock partagés (§37, §39)

    /// Bouton secondaire de dock — même style que `AssemblyView`,
    /// `ClipPickerView` et `ProjectView` (capsule translucide, cible ≥ 44 pt).
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

// MARK: - Preview (aucune composition réelle : projet vide → état §64)

#Preview("Aperçu — projet sans association") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    return PreviewPlayerView(
        projectID: UUID(),
        scope: .contiguousPrefix,
        // Titre tel que le compose `AssemblyView` depuis les zones exportées
        // (écart produit) — ici un projet vide : aucun plan prêt, l'écran
        // affiche donc l'état §64 « Aperçu impossible ».
        title: "Montage — zones remplies"
    )
    .environment(environment)
    .modelContainer(container)
}
