//
//  ExportSummaryView.swift
//  MontageMusical
//
//  Résumé avant export, progression et issue — Jalon 10, spec §56 (résumé
//  INFORMATIF, jamais un réglage), §51 (préfixe exportable), §52 (profil
//  maître : géométrie du projet, résolution/cadence d'un même clip maître,
//  HDR/SDR), §57 (taille estimée et espace disque vérifiés AVANT tout
//  encodage), §58 (progression dans le dock inférieur, annulation possible,
//  jamais deux exports simultanés), §66 (première case vide, interruption,
//  Photos refusé), §40 (autorisation d'ÉCRITURE Photos demandée au PREMIER
//  enregistrement), §55 (Photos seulement après succès complet),
//  §8.1 (arrière-plan : aucune promesse, jamais de succès annoncé avant
//  confirmation effective).
//
//  RÉGRESSION INTERDITE §89 — « elle ajoute un écran d'export technique ».
//  Cet écran ne propose AUCUN choix : ni résolution, ni format, ni qualité,
//  ni destination, ni case à cocher. Il ANNONCE ce que l'application a
//  décidé seule (§52) et offre un unique bouton « Exporter » (§56). Toute
//  évolution qui y ajouterait un réglage violerait §89.
//
//  DÉCISION Jalon 10 — le profil §52 vient d'une SOURCE UNIQUE.
//  Le résumé n'a plus AUCUN calcul de profil qui lui soit propre : il lit
//  `ProjectExporter.masterProfile(project:)`, exactement ce que l'encodage
//  utilisera. Un calcul parallèle côté vue (résolution PhotoKit rush par
//  rush, rushs illisibles ignorés) pouvait ANNONCER « HDR » alors que le
//  fichier produit était SDR : §56 informe sur le fichier réel, jamais sur
//  une approximation d'écran. Profil indisponible (un rush du préfixe est
//  illisible) → « Profil technique indisponible » : jamais un profil PARTIEL.
//
//  DÉCISION Jalon 10 — l'enregistrement dans Photos est une action DISTINCTE.
//  Le CTA reste « Exporter » (§56, verbatim) et s'arrête au fichier produit ;
//  une phase « Montage prêt » propose ensuite [Fermer] [Partager]
//  [Enregistrer dans Photos] (trois zones §36). Raisons : §40 (« Ne demander
//  l'accès d'écriture qu'au premier enregistrement dans Photos » — la demande
//  système suit alors un geste explicite de l'utilisateur, pas un effet de
//  bord du bouton « Exporter »), §55 (« enregistrement dans Photos seulement
//  après succès complet »), et la documentation de `PhotoLibrarySaver`, qui
//  décrit déjà l'écriture Photos comme une action utilisateur séparée.
//  L'enchaînement automatique précédent obligeait à rebaptiser le CTA
//  (« Exporter et enregistrer dans Photos »), ce qui s'écartait du libellé
//  verbatim §56 : la phase intermédiaire est plus honnête à coût égal.
//
//  DÉCISION Jalon 10 — arrière-plan pendant l'encodage (§8.1, §58).
//  Pendant l'encodage, l'écran affiche la consigne « Gardez l'application
//  ouverte pendant l'export » (§8.1) et OBSERVE `scenePhase` : un passage en
//  arrière-plan est annoncé comme une INTERRUPTION (« Export interrompu »,
//  possibilité de recommencer), jamais comme un succès. Détail du choix et de
//  ses conséquences : `handleScenePhase(_:)`.
//
//  Règle du pouce §30 : le CTA, la progression, l'annulation et toutes les
//  sorties vivent dans le DOCK BAS ; la zone haute est purement informative.
//  Matériaux translucides sobres §37 (aucun verre permanent sur du contenu),
//  AUCUNE animation décorative §38, accessibilité §39 complète (Dynamic
//  Type, libellés parlés, cibles ≥ 44 pt, état jamais porté par la seule
//  couleur).
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Logique pure d'affichage (§56, §57, §58, §66)

// Non defini par la specification — definitions minimales V1.
/// Formatage du résumé §56 et des messages d'issue, extraits en fonctions
/// **pures** testables sans UI (`Tests/Unit/ExportSummaryLogicTests.swift`).
///
/// Le bloc §56 de la spécification est reproduit tel quel :
///
/// ```text
/// Export automatique
/// 2160 × 3840
/// Vertical • 60 i/s • SDR
/// 12 plans • 18,43 s
/// ```
///
/// Tous les nombres affichés sont des valeurs MESURÉES (dimensions de rendu,
/// cadence du clip maître, nombre de cases du préfixe §51, durée exacte) :
/// aucune n'est réglable, conformément à §56 (« Information, pas réglage »)
/// et §89.
enum ExportSummaryLogic {

    /// Titre du résumé (§56, verbatim).
    static let heading = "Export automatique"

    // MARK: Dimensions et orientation

    /// « 2160 × 3840 » (§56, verbatim — signe multiplication U+00D7 entouré
    /// d'espaces, comme dans la spécification).
    static func dimensionsLabel(width: Int, height: Int) -> String {
        "\(width) × \(height)"
    }

    /// Orientation du rendu, déduite des dimensions de rendu (§52.1 : la
    /// géométrie est TOUJOURS celle du projet — le libellé décrit donc bien
    /// la forme du montage produit, jamais celle d'un rush isolé).
    ///
    /// Vocabulaire de la spécification §56 (« Vertical ») étendu aux deux
    /// autres formes possibles §49 (« Le premier rush peut être vertical,
    /// horizontal, carré ou autre ») :
    /// `portrait → Vertical`, `landscape → Horizontal`, `square → Carré`.
    static func orientationLabel(width: Int, height: Int) -> String {
        if height > width {
            return "Vertical"
        }
        if width > height {
            return "Horizontal"
        }
        return "Carré"
    }

    /// Même libellé à partir de l'orientation verrouillée du projet (§14).
    static func orientationLabel(_ orientation: ProjectOrientation) -> String {
        switch orientation {
        case .portrait: "Vertical"
        case .landscape: "Horizontal"
        case .square: "Carré"
        }
    }

    // MARK: Cadence (§52.3)

    /// « 60 i/s », « 29,97 i/s » — la cadence FRACTIONNAIRE est préservée
    /// (§52.3 : « préserver 29,97/59,94 lorsque le clip maître utilise une
    /// cadence fractionnaire ») : afficher « 30 » à la place de « 29,97 »
    /// mentirait sur le fichier produit.
    ///
    /// Arrondi au centième — même convention d'affichage que les temps (§9) :
    /// 30000/1001 = 29,97002997… s'affiche « 29,97 », 60000/1001 = 59,94…
    /// s'affiche « 59,94 », 24000/1001 = 23,976… s'affiche « 23,98 ».
    /// Une cadence entière ne montre aucune décimale (« 60 »), et un
    /// centième nul en fin de valeur est retiré (« 30,5 » et non « 30,50 »).
    ///
    /// Valeur absente/incohérente (0, négative, non finie, hors plage
    /// crédible) → tiret cadratin : jamais un « 0 i/s » qui donnerait une
    /// fausse impression de mesure.
    static func frameRateLabel(_ frameRate: Double) -> String {
        "\(frameRateValueLabel(frameRate)) i/s"
    }

    /// Valeur seule de la cadence, sans unité (voir `frameRateLabel`).
    static func frameRateValueLabel(_ frameRate: Double) -> String {
        guard frameRate.isFinite, frameRate > 0, frameRate < 1_000 else { return "—" }
        let hundredths = Int((frameRate * 100).rounded())
        let integerPart = hundredths / 100
        let fraction = hundredths % 100
        if fraction == 0 {
            return "\(integerPart)"
        }
        if fraction % 10 == 0 {
            return "\(integerPart),\(fraction / 10)"
        }
        return "\(integerPart),\(fraction < 10 ? "0" : "")\(fraction)"
    }

    // MARK: Colorimétrie (§52.4)

    /// « HDR » / « SDR » (§52.4 : mélange HDR/SDR → sortie SDR cohérente —
    /// la décision est prise par le sélecteur de profil, ce libellé ne fait
    /// que la rapporter).
    static func colorLabel(isHDR: Bool) -> String {
        isHDR ? "HDR" : "SDR"
    }

    /// Ligne technique complète §56 : « Vertical • 60 i/s • SDR ».
    static func technicalLine(width: Int, height: Int, frameRate: Double, isHDR: Bool) -> String {
        [
            orientationLabel(width: width, height: height),
            frameRateLabel(frameRate),
            colorLabel(isHDR: isHDR)
        ].joined(separator: " • ")
    }

    // MARK: Plans et durée

    /// « 1 plan » / « 12 plans » — accord au singulier, jamais « 1 plans ».
    static func planCountLabel(_ count: Int) -> String {
        let safeCount = max(0, count)
        return safeCount <= 1 ? "\(safeCount) plan" : "\(safeCount) plans"
    }

    /// Durée totale du montage exporté.
    ///
    /// - moins d'une minute → forme courte §35.2 « 18,43 s », exactement le
    ///   format du bloc §56 ;
    /// - à partir d'une minute → forme horodatée §9 « 01:30,00 », sans quoi
    ///   un montage de trois minutes s'afficherait « 184,32 s » (illisible).
    ///
    /// Dans les deux cas le centième est une précision d'AFFICHAGE (§9) :
    /// cette chaîne n'est jamais reparsée ni réinjectée dans un calcul.
    static func durationLabel(_ duration: MediaTime) -> String {
        let oneMinuteInTicks = Int64(MediaTime.canonicalTimescale) * 60
        return duration.ticks < oneMinuteInTicks
            ? duration.shortDurationString
            : duration.displayString
    }

    /// « 12 plans • 18,43 s » (§56, verbatim).
    static func plansAndDurationLabel(slotCount: Int, duration: MediaTime) -> String {
        "\(planCountLabel(slotCount)) • \(durationLabel(duration))"
    }

    // MARK: VoiceOver (§39)

    /// Énoncé unique du résumé pour VoiceOver (§39) — les puces et le signe
    /// « × » ne se lisent pas : ils sont remplacés par des mots.
    static func spokenSummary(
        width: Int,
        height: Int,
        frameRate: Double,
        isHDR: Bool,
        slotCount: Int,
        duration: MediaTime
    ) -> String {
        "\(heading). \(width) par \(height), "
            + "\(orientationLabel(width: width, height: height)), "
            + "\(frameRateValueLabel(frameRate)) images par seconde, "
            + "\(colorLabel(isHDR: isHDR)). "
            + "\(planCountLabel(slotCount)), durée \(duration.spokenString)."
    }

    /// Énoncé réduit quand le profil technique n'a pas pu être lu (§56 :
    /// afficher l'essentiel sans bloquer).
    static func spokenEssentials(slotCount: Int, duration: MediaTime) -> String {
        "\(heading). \(planCountLabel(slotCount)), durée \(duration.spokenString)."
    }

    // MARK: Arrière-plan (§8.1, §58)

    /// §8.1 : « demander de garder l'application ouverte pendant l'encodage
    /// final ». Affiché PENDANT l'encodage, jamais avant : c'est à ce
    /// moment-là que la consigne a un sens.
    static let keepAppOpenNotice = "Gardez l'application ouverte pendant l'export."

    /// §8.1/§58 : passage en arrière-plan pendant l'encodage. iOS peut
    /// suspendre le processus : l'export est ANNONCÉ comme interrompu et
    /// l'utilisateur peut recommencer — jamais présenté comme un succès
    /// (§8.1 : « ne jamais annoncer un export réussi avant confirmation
    /// effective »).
    static let backgroundInterruptionMessage =
        "L'application est passée en arrière-plan pendant l'encodage : l'export a été interrompu. "
        + "Votre montage est intact — vous pouvez recommencer."

    /// Formulation neutre d'une interruption sans cause exploitable (§66 :
    /// « interruption : projet intact »).
    static let genericInterruptionMessage =
        "Votre montage est intact. Vous pouvez recommencer l'export."

    // MARK: - Phases de l'écran (§57, §58, §66)

    // Non defini par la specification — definition minimale V1.
    /// Étapes de l'écran. Une seule est active à la fois : le dock bas en
    /// dérive ses boutons, ce qui garantit qu'aucune action contradictoire
    /// n'est proposée (§58 : jamais deux exports simultanés).
    ///
    /// Type INTERNE (et non privé à la vue) : les transitions terminales sont
    /// dérivées par des fonctions pures testables sans UI.
    enum ExportPhase: Equatable {
        /// Résumé §56, CTA « Exporter » disponible.
        case summary
        /// Démarrage demandé, réponse de l'acteur d'export pas encore connue
        /// (§58 : on n'affiche « export en cours » qu'une fois le démarrage
        /// CONFIRMÉ — jamais sur une simple intention).
        case starting
        /// Encodage en cours (§58) — progression + annulation.
        case exporting
        /// §55 : encodage terminé, fichier écrit et CONFIRMÉ. L'enregistrement
        /// dans Photos est une action utilisateur distincte (§40) : partage et
        /// enregistrement sont proposés, rien n'est fait dans le dos.
        case ready(url: URL)
        /// Enregistrement dans Photos en cours (§55) — déclenché par
        /// l'utilisateur depuis `ready`.
        case saving(url: URL)
        /// Enregistré dans Photos (§55).
        case succeeded
        /// §66 : le fichier existe et est CONSERVÉ, mais n'a pas rejoint
        /// Photos — partage proposé, Réglages si la cause est un refus (§40).
        case fileKept(reason: FileKeptReason, url: URL)
        /// §57 : espace insuffisant — refus AVANT tout encodage.
        case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
        /// §66 : export interrompu (échec, rush devenu indisponible, passage
        /// en arrière-plan §8.1) — projet intact, possibilité de recommencer.
        case failed(message: String)
        /// Annulation explicite (§58) — fichier temporaire supprimé par
        /// l'acteur, projet intact.
        case cancelled
    }

    // Non defini par la specification — definition minimale V1.
    enum FileKeptReason: Equatable {
        /// §66/§40 : accès Photos refusé — proposer Réglages ET le partage.
        case photosDenied
        /// Échec d'écriture Photos (photothèque pleine, erreur système) — le
        /// partage reste possible, les Réglages n'y changeraient rien.
        case photosFailed
    }

    /// Phase terminale correspondant à une erreur d'export (§57, §58, §66) —
    /// dérivation PURE, partagée par le refus de démarrage et par l'issue de
    /// l'encodage : les deux chemins ne peuvent donc pas diverger.
    static func terminalPhase(for error: ExportError) -> ExportPhase {
        switch error {
        case .cancelled:
            return .cancelled
        case .insufficientStorage(let required, let available):
            return .insufficientStorage(requiredBytes: required, availableBytes: available)
        default:
            return .failed(message: message(for: error))
        }
    }

    // MARK: - Messages d'issue (§57, §64, §66)

    /// Message français d'une erreur d'export (§64/§66) : la description
    /// localisée de `ExportError` est déjà rédigée pour l'utilisateur et dit
    /// quoi faire ; toute autre erreur reçoit une formulation neutre.
    static func message(for error: Error) -> String {
        if let exportError = error as? ExportError,
           let description = exportError.errorDescription {
            return description
        }
        return genericInterruptionMessage
    }

    /// §66 : message expliquant que le fichier est CONSERVÉ.
    static func fileKeptMessage(_ reason: FileKeptReason) -> String {
        switch reason {
        case .photosDenied:
            "L'ajout à Photos n'est pas autorisé. Le fichier exporté est conservé : "
                + "partagez-le maintenant, ou autorisez l'accès dans Réglages puis réessayez."
        case .photosFailed:
            "Le montage n'a pas pu être ajouté à Photos. Le fichier exporté est conservé : "
                + "partagez-le maintenant, ou réessayez plus tard."
        }
    }

    /// §57 : message clair AVANT tout encodage — la taille attendue et
    /// l'espace réellement disponible, en unités lisibles.
    static func storageMessage(requiredBytes: Int64, availableBytes: Int64) -> String {
        let required = byteCountString(requiredBytes)
        let available = byteCountString(availableBytes)
        return "Ce montage a besoin d'environ \(required) et il reste \(available) sur cet iPhone. "
            + "Libérez de l'espace, puis réessayez. Votre projet est conservé."
    }

    /// Taille lisible (Mo/Go) — une valeur négative (jamais attendue) est
    /// ramenée à zéro plutôt qu'affichée telle quelle.
    static func byteCountString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// Pourcentage entier borné `0…100` (§58) — valeur mesurée, jamais
    /// extrapolée.
    static func percentLabel(_ progress: Double) -> String {
        let clamped = progress.isFinite ? min(max(progress, 0), 1) : 0
        return "\(Int((clamped * 100).rounded())) %"
    }
}

// MARK: - Écran de résumé et de progression d'export (§56, §58)

/// Feuille présentée par `AssemblyView` (zone DROITE du dock §36) et par
/// `PreviewPlayerView` (dock « Prévisualisation » §36) — contrat Jalon 10 :
/// `ExportSummaryView(projectID:)`.
///
/// Déroulé :
/// 1. **Résumé §56** — dimensions de rendu, orientation, cadence, HDR/SDR,
///    nombre de plans, durée totale. Les deux dernières valeurs viennent de
///    l'instantané du projet (§51 : préfixe continu prêt) et s'affichent
///    IMMÉDIATEMENT ; le profil technique (§52) est lu ensuite auprès de
///    l'EXPORTATEUR (`masterProfile(project:)`, source unique) — s'il est
///    indisponible, l'essentiel reste affiché et l'export reste possible,
///    mais aucun profil partiel n'est annoncé ;
/// 2. **CTA « Exporter »** (§56) en zone basse — vérification §57 de l'espace
///    disque AVANT tout encodage, puis `ExportActor.startExport` (§8/§58 :
///    un seul export actif par projet). La phase « export en cours » n'est
///    affichée que si l'acteur CONFIRME le démarrage ;
/// 3. **Progression §58** dans le dock inférieur, avec pourcentage RÉEL
///    (progression d'encodage MESURÉE — contrairement à l'analyse §33, où un
///    pourcentage serait inventé), consigne §8.1 « gardez l'application
///    ouverte » et bouton « Annuler » ;
/// 4. **Issue** : fichier écrit → « Montage prêt » avec [Fermer] [Partager]
///    [Enregistrer dans Photos] (§40 : l'autorisation d'écriture est demandée
///    ici, au premier enregistrement ; §55 : seulement après succès complet)
///    → « Montage enregistré dans Photos » ; refus Photos → §66 : le fichier
///    est CONSERVÉ, proposé au partage, avec un accès aux Réglages ;
///    interruption → « Export interrompu » avec possibilité de recommencer,
///    projet intact.
///
/// La vue ne reçoit qu'un `UUID` : aucun enregistrement SwiftData ne traverse
/// de frontière d'acteur.
struct ExportSummaryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// §8.1 : un passage en arrière-plan pendant l'encodage est une
    /// INTERRUPTION annoncée, jamais un succès silencieux.
    @Environment(\.scenePhase) private var scenePhase

    private typealias ExportPhase = ExportSummaryLogic.ExportPhase
    private typealias FileKeptReason = ExportSummaryLogic.FileKeptReason

    private let projectID: UUID

    // MARK: État du résumé (§56)

    /// Instantané du projet — source du préfixe §51 et entrée du profil §52.
    @State private var snapshot: ProjectSnapshot?
    /// Nombre de cases du préfixe exportable (§51).
    @State private var prefixSlotCount = 0
    /// Nombre total de cases du projet — sert uniquement à signaler un export
    /// PARTIEL (§51 : « les cases après le premier trou sont ignorées »).
    @State private var totalSlotCount = 0
    /// Durée totale du montage exporté = fin ABSOLUE de la dernière case du
    /// préfixe (§51 : « la musique est coupée à la fin absolue de la dernière
    /// case exportée »).
    @State private var exportDuration: MediaTime = .zero
    /// Profil maître §52 tel que l'EXPORTATEUR le calculera — `nil` tant
    /// qu'il n'est pas lu, ou s'il n'a pas pu l'être (un rush du préfixe est
    /// illisible : §52 n'admet pas de profil partiel).
    @State private var profile: MasterProfile?
    /// Vrai pendant la lecture de l'instantané (§56 : aucun écran vide muet).
    @State private var isLoadingSummary = true
    /// Vrai pendant la lecture du profil §52 auprès de l'exportateur.
    /// Vrai DÈS LE DÉPART : la lecture suit toujours une lecture d'instantané
    /// réussie avec un préfixe non vide — sans cela, l'écran afficherait un
    /// bref « profil indisponible » avant même d'avoir essayé.
    @State private var isLoadingProfile = true
    /// Message d'échec de LECTURE du projet (§64) — jamais un échec muet.
    @State private var loadErrorMessage: String?

    // MARK: État de l'export (§58)

    @State private var phase: ExportPhase = .summary
    /// Progression d'encodage `0...1` (§58) — valeur MESURÉE.
    @State private var progress: Double = 0
    /// Tâche de suivi (lancement + interrogation périodique + issue).
    @State private var monitorTask: Task<Void, Never>?
    /// Vrai si l'utilisateur a demandé l'annulation (§58) — distingue
    /// « annulé » de « interrompu » dans le message final (§66).
    @State private var didRequestCancel = false

    init(projectID: UUID) {
        self.projectID = projectID
    }

    /// Vrai pendant qu'un export occupe le projet : le CTA disparaît (§58 :
    /// « empêcher un second export simultané »).
    private var isBusy: Bool {
        switch phase {
        case .starting, .exporting, .saving: true
        default: false
        }
    }

    /// Vrai pendant l'ENCODAGE proprement dit (§8.1 : c'est cette phase-là
    /// qu'un passage en arrière-plan interrompt).
    private var isEncoding: Bool {
        switch phase {
        case .starting, .exporting: true
        default: false
        }
    }

    /// §51/§66 : « export désactivé si le résultat est vide », « première case
    /// vide : export désactivé ».
    private var hasExportablePrefix: Bool {
        prefixSlotCount > 0
    }

    // MARK: - Corps

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 28)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) { dock }
        .task { await load() }
        // §8.1 : iOS peut suspendre le processus — l'écran ne promet rien et
        // annonce l'interruption dès le passage en arrière-plan.
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
        .onDisappear {
            // Seul le SUIVI est arrêté : un encodage en cours continue dans
            // l'acteur (§8) et la progression sera retrouvée à la
            // réouverture de cet écran. L'annulation reste un geste
            // EXPLICITE de l'utilisateur (§58).
            monitorTask?.cancel()
            monitorTask = nil
        }
    }

    // MARK: - Zone haute informative (§56)

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .summary, .starting, .exporting:
            summaryContent
        case .ready, .saving:
            // §55 : le fichier est écrit et CONFIRMÉ ; rien n'est encore dans
            // Photos — l'enregistrement est un geste explicite (§40).
            messageContent(
                systemImage: "checkmark.circle",
                title: "Montage prêt",
                message: "Votre montage est exporté. Enregistrez-le dans Photos, ou partagez-le."
            )
        case .succeeded:
            // §55 : l'asset Photos n'existe qu'après un succès complet.
            messageContent(
                systemImage: "checkmark.circle",
                title: "Montage enregistré dans Photos",
                message: "Votre montage est disponible dans l'application Photos."
            )
        case .fileKept(let reason, _):
            messageContent(
                systemImage: "square.and.arrow.up",
                title: "Montage conservé",
                message: ExportSummaryLogic.fileKeptMessage(reason)
            )
        case .insufficientStorage(let requiredBytes, let availableBytes):
            messageContent(
                systemImage: "externaldrive.badge.exclamationmark",
                title: "Espace insuffisant",
                message: ExportSummaryLogic.storageMessage(
                    requiredBytes: requiredBytes,
                    availableBytes: availableBytes
                )
            )
        case .failed(let message):
            // §66 : « interruption : projet intact » — la cause est DITE et
            // l'utilisateur peut recommencer.
            messageContent(
                systemImage: "exclamationmark.triangle",
                title: "Export interrompu",
                message: message
            )
        case .cancelled:
            messageContent(
                systemImage: nil,
                title: "Export annulé",
                message: "Votre montage est intact. Vous pouvez relancer l'export."
            )
        }
    }

    /// Résumé §56 — INFORMATION, jamais réglage (§89).
    private var summaryContent: some View {
        VStack(spacing: 10) {
            Text(ExportSummaryLogic.heading)
                .font(.title3.weight(.medium))

            if isLoadingSummary {
                ProgressView()
                    .padding(.top, 4)
            } else if let loadErrorMessage {
                Text(loadErrorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if !hasExportablePrefix {
                // §66 : « première case vide : export désactivé » — la raison
                // est DITE, le bouton n'est pas seulement grisé.
                Text("Aucun plan n'est encore prêt au début du montage.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Remplissez la première case pour pouvoir exporter.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                profileLines
                Text(ExportSummaryLogic.plansAndDurationLabel(
                    slotCount: prefixSlotCount,
                    duration: exportDuration
                ))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

                if isPartialExport {
                    // §51 : « les cases après le premier trou sont ignorées »,
                    // « les clips ultérieurs ne sont jamais déplacés » — dit
                    // explicitement, jamais découvert après coup.
                    Text("Seul le début déjà monté est exporté ; le reste du projet est conservé.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }

                if isEncoding {
                    // §8.1 : « demander de garder l'application ouverte
                    // pendant l'encodage final » — consigne affichée pendant
                    // l'encodage, jamais une promesse de poursuite.
                    Text(ExportSummaryLogic.keepAppOpenNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummaryLabel)
    }

    /// Dimensions de rendu + ligne technique (§56). Tant que le profil §52
    /// n'est pas lu, une ligne d'attente sobre le remplace — l'essentiel
    /// (plans et durée) reste visible et l'export reste possible.
    @ViewBuilder
    private var profileLines: some View {
        if let profile {
            Text(ExportSummaryLogic.dimensionsLabel(
                width: profile.renderWidth,
                height: profile.renderHeight
            ))
            .font(.largeTitle.weight(.semibold).monospacedDigit())

            Text(ExportSummaryLogic.technicalLine(
                width: profile.renderWidth,
                height: profile.renderHeight,
                frameRate: profile.frameRate,
                isHDR: profile.isHDR
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else if isLoadingProfile {
            Text("Lecture du profil des plans…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            // §52 : information indisponible (rush reparti dans iCloud, accès
            // photothèque refusé, géométrie jamais verrouillée) — l'exportateur
            // refuse alors de livrer un profil PARTIEL, et cet écran n'invente
            // rien. L'export reste possible : c'est lui qui tranchera.
            Text("Profil technique indisponible pour l'instant.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// État terminal sobre (§64) : icône facultative, titre, explication.
    private func messageContent(
        systemImage: String?,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Dock inférieur (§30, §36, §58)

    /// Toutes les actions de l'écran, en zone basse (§30) — au plus trois
    /// zones (§36). La progression §58 y vit aussi : « progression visible
    /// dans le dock inférieur ».
    @ViewBuilder
    private var dock: some View {
        VStack(spacing: 8) {
            switch phase {
            case .starting:
                startingRow
            case .exporting:
                progressRow
                HStack(spacing: 8) {
                    dockSecondaryButton(
                        title: "Annuler",
                        accessibilityHint: "Arrête l'export en cours. Le montage reste intact."
                    ) {
                        cancelExport()
                    }
                    Spacer(minLength: 0)
                }
            case .saving:
                savingRow
            case .summary:
                HStack(spacing: 8) {
                    dockSecondaryButton(
                        title: "Fermer",
                        accessibilityHint: "Ferme l'export et revient au montage."
                    ) {
                        dismiss()
                    }
                    exportButton(title: "Exporter")
                }
            case .ready(let url):
                readyDock(url: url)
            case .succeeded:
                HStack(spacing: 8) {
                    dockPrimaryButton(
                        title: "Fermer",
                        accessibilityLabel: "Fermer",
                        accessibilityHint: "Revient au montage."
                    ) {
                        dismiss()
                    }
                }
            case .fileKept(let reason, let url):
                fileKeptDock(reason: reason, url: url)
            case .insufficientStorage:
                HStack(spacing: 8) {
                    dockSecondaryButton(
                        title: "Fermer",
                        accessibilityHint: "Ferme l'export et revient au montage."
                    ) {
                        dismiss()
                    }
                    exportButton(title: "Réessayer")
                }
            case .failed, .cancelled:
                HStack(spacing: 8) {
                    dockSecondaryButton(
                        title: "Fermer",
                        accessibilityHint: "Ferme l'export et revient au montage."
                    ) {
                        dismiss()
                    }
                    exportButton(title: "Recommencer")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Démarrage demandé, réponse de l'acteur pas encore connue (§58) : ni
    /// barre de progression (aucune valeur mesurée), ni CTA (un second appui
    /// serait refusé de toute façon).
    private var startingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Préparation de l'export…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Préparation de l'export")
    }

    /// §58 : barre de progression + pourcentage RÉEL. Le pourcentage est
    /// légitime ici — c'est une progression d'ENCODAGE mesurée, pas une durée
    /// d'analyse non calibrée (§33, où un pourcentage serait inventé).
    private var progressRow: some View {
        let percent = ExportSummaryLogic.percentLabel(progress)
        return VStack(spacing: 6) {
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
            HStack {
                Text("Export en cours")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(percent)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progression de l'export")
        .accessibilityValue(percent)
    }

    /// Enregistrement dans Photos (§55) : court, sobre, non annulable — le
    /// fichier est déjà encodé, l'interrompre ne rendrait rien à personne.
    private var savingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Enregistrement dans Photos…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Enregistrement dans Photos en cours")
    }

    /// §55/§40 : le fichier est écrit. TROIS zones (§36) — [Fermer]
    /// [Partager] [Enregistrer dans Photos] : l'enregistrement est une action
    /// utilisateur explicite, c'est elle qui déclenche (au premier usage) la
    /// demande d'autorisation d'écriture §40.
    private func readyDock(url: URL) -> some View {
        HStack(spacing: 8) {
            dockSecondaryButton(
                title: "Fermer",
                accessibilityHint: "Ferme l'export et revient au montage. Le fichier est conservé."
            ) {
                dismiss()
            }

            shareButton(url: url)

            Button {
                saveToPhotos(url: url)
            } label: {
                Text("Enregistrer dans Photos")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Enregistrer dans Photos")
            .accessibilityHint("Ajoute le montage exporté à l'application Photos.")
        }
    }

    /// §66 : Photos refusé ou impossible → le fichier est CONSERVÉ. Partage
    /// (feuille système) toujours proposé ; Réglages seulement si la cause
    /// est une autorisation refusée (§40).
    private func fileKeptDock(reason: FileKeptReason, url: URL) -> some View {
        HStack(spacing: 8) {
            dockSecondaryButton(
                title: "Fermer",
                accessibilityHint: "Ferme l'export et revient au montage. Le fichier est conservé."
            ) {
                dismiss()
            }

            shareButton(url: url)

            if reason == .photosDenied {
                dockSecondaryButton(
                    title: "Réglages",
                    accessibilityHint: "Ouvre les Réglages pour autoriser l'ajout à Photos."
                ) {
                    openSettings()
                }
            }
        }
    }

    /// Partage du fichier exporté par la feuille système (§66) — même
    /// présentation que les autres actions de dock.
    private func shareButton(url: URL) -> some View {
        ShareLink(item: url) {
            Text("Partager")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Partager le montage")
        .accessibilityHint("Ouvre la feuille de partage du fichier exporté.")
    }

    /// CTA principal §56 (« Exporter ») et ses variantes de reprise
    /// (« Réessayer » §57, « Recommencer » §66). Désactivé si le préfixe §51
    /// est vide ou pendant un export (§58).
    ///
    /// Le libellé §56 est VERBATIM : ce bouton produit le FICHIER, il
    /// n'enregistre rien dans Photos (action distincte, §40/§55).
    private func exportButton(title: String) -> some View {
        let isEnabled = hasExportablePrefix && !isBusy && loadErrorMessage == nil
        return Button {
            startExport()
        } label: {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // État désactivé porté par l'opacité ET annoncé par VoiceOver (trait
        // « estompé » + hint), jamais par la seule couleur (§39).
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityHint(
            isEnabled
                ? "Lance l'export du montage déjà prêt. Gardez l'application ouverte pendant l'export."
                : "Remplissez la première case pour exporter."
        )
    }

    private func dockPrimaryButton(
        title: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    /// Bouton secondaire de dock — même style que `AssemblyView`,
    /// `ClipPickerView`, `PaceSelectionView` et `PreviewPlayerView`.
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

    // MARK: - Chargement du résumé (§51, §52, §56)

    /// Lit l'instantané du projet, en tire le préfixe §51 (nombre de plans et
    /// durée totale — affichés IMMÉDIATEMENT), puis demande le profil maître
    /// §52 à l'exportateur.
    ///
    /// Si un export du même projet est DÉJÀ en cours (§8/§58 : l'acteur n'en
    /// autorise qu'un), l'écran reprend son suivi au lieu d'afficher un CTA
    /// qui serait refusé.
    private func load() async {
        let store = environment.projectStore
        let snapshot: ProjectSnapshot
        do {
            snapshot = try await store.projectSnapshot(projectID: projectID)
        } catch is CancellationError {
            return // écran fermé pendant la lecture : rien à signaler (§8)
        } catch {
            environment.logger.error(
                "Lecture du projet impossible pour l'export : \(error.localizedDescription)"
            )
            loadErrorMessage = "Le projet n'a pas pu être lu. Réessayez."
            isLoadingSummary = false
            isLoadingProfile = false
            return
        }

        let prefix = snapshot.contiguousReadyPrefix
        self.snapshot = snapshot
        prefixSlotCount = prefix.count
        totalSlotCount = snapshot.slots.count
        // §51 : « la musique est coupée à la fin ABSOLUE de la dernière case
        // exportée » — la durée du montage est donc cette frontière, jamais
        // une somme de durées affichées (§9).
        exportDuration = prefix.last?.end ?? .zero
        isLoadingSummary = false

        // Export déjà en cours pour ce projet (écran rouvert pendant
        // l'encodage) : reprendre le suivi §58 plutôt que proposer un second
        // export, que l'acteur refuserait de toute façon (§8).
        if let current = await environment.exportActor.currentProgress(projectID: projectID) {
            progress = current
            phase = .exporting
            monitorExport(startsNewExport: false)
        }

        guard !prefix.isEmpty else {
            isLoadingProfile = false
            return // §66 : rien à profiler
        }
        await loadProfile(snapshot: snapshot)
    }

    /// Profil maître §52 — lu auprès de l'EXPORTATEUR, source UNIQUE.
    ///
    /// `ProjectExporter.masterProfile(project:)` applique exactement la règle
    /// §52 qui sera utilisée à l'encodage (§52.1 géométrie du projet, §52.2
    /// clip maître, §52.3 cadence, §52.4 colorimétrie) et rend `nil` si un
    /// rush du préfixe est illisible : il n'existe pas de profil PARTIEL, donc
    /// pas de « HDR » annoncé à tort parce qu'un rush SDR n'a pas pu être lu.
    /// Cet écran n'ouvre plus AUCUN asset PhotoKit : il affiche, il ne calcule
    /// pas (§56 : « information, pas réglage »).
    private func loadProfile(snapshot: ProjectSnapshot) async {
        isLoadingProfile = true
        let resolved = await environment.projectExporter.masterProfile(project: snapshot)
        guard !Task.isCancelled else { return } // écran fermé (§8)
        profile = resolved
        isLoadingProfile = false
    }

    // MARK: - Lancement de l'export (§57, §58)

    /// CTA « Exporter » : vérification §57 AVANT tout encodage, puis
    /// `ExportActor.startExport` (§8 : un seul export actif par projet).
    private func startExport() {
        guard hasExportablePrefix, !isBusy, let snapshot else { return }

        // §57 : « estimer la taille ; vérifier l'espace disponible ; refuser
        // proprement si insuffisant » — le refus arrive AVANT l'encodage, avec
        // un message clair. La RÈGLE est celle de l'exportateur
        // (`requireSufficientStorage`, source unique) et l'estimation porte
        // déjà sa marge : aucune seconde marge n'est ajoutée ici, sinon cet
        // écran refuserait des exports que l'exportateur accepterait.
        // Sans profil §52 (information manquante), la vérification est laissée
        // à l'exportateur, qui la refait avant d'écrire quoi que ce soit.
        if let profile {
            let requiredBytes = environment.projectExporter.estimatedBytes(
                project: snapshot,
                profile: profile
            )
            do {
                try ProjectExporter.requireSufficientStorage(
                    requiredBytes: requiredBytes,
                    availableBytes: availableCapacityBytes()
                )
            } catch let error as ExportError {
                phase = ExportSummaryLogic.terminalPhase(for: error)
                return
            } catch {
                phase = .failed(message: ExportSummaryLogic.message(for: error))
                return
            }
        }

        didRequestCancel = false
        progress = 0
        // §58 : « export en cours » n'est affiché qu'une fois le démarrage
        // CONFIRMÉ par l'acteur — en attendant, une phase d'attente neutre.
        phase = .starting
        monitorExport(startsNewExport: true)
    }

    /// Suivi d'un export, du lancement à l'issue (§58).
    ///
    /// `ExportActor.startExport` rend un RÉSULTAT explicite : `started` (cet
    /// écran devient la progression de CE run), `alreadyRunning` (§58 : un
    /// seul export par projet — on reprend le suivi de celui qui tourne, sans
    /// jamais réafficher l'issue d'un run précédent), `refused(erreur)`
    /// (préfixe vide §66, instantané illisible… — la cause est DITE).
    /// Sans ce résultat, un refus laissait lire `lastOutcome` du run
    /// PRÉCÉDENT et pouvait annoncer un succès qui n'avait pas eu lieu (§8.1).
    ///
    /// La fin de l'encodage ne se déduit pas du retour de `startExport` (qui
    /// rend la main aussitôt) mais de la disparition de la progression
    /// (`currentProgress == nil`), ce qui couvre du même coup l'écran rouvert
    /// pendant un encodage déjà lancé (`startsNewExport: false`).
    ///
    /// Un SEUL suivi vit à la fois (`monitorTask`) : deux suivis simultanés
    /// pourraient présenter deux issues contradictoires.
    private func monitorExport(startsNewExport: Bool) {
        let exportActor = environment.exportActor
        let id = projectID
        monitorTask?.cancel()
        monitorTask = Task {
            if startsNewExport {
                let startResult = await exportActor.startExport(projectID: id)
                // Suivi annulé PENDANT l'attente (écran fermé §8, passage en
                // arrière-plan §8.1) : ne rien réécrire — un `phase` posé ici
                // écraserait le message d'interruption déjà affiché.
                guard !Task.isCancelled else { return }
                switch startResult {
                case .started:
                    phase = .exporting
                case .alreadyRunning:
                    // §8/§58 : l'acteur garde l'invariante « un seul export
                    // par projet ». On suit celui qui tourne déjà.
                    let current = await exportActor.currentProgress(projectID: id)
                    guard !Task.isCancelled else { return }
                    progress = current ?? progress
                    phase = .exporting
                case .refused(let error):
                    // §66 : la raison du refus est annoncée, jamais avalée —
                    // et surtout aucun résultat d'un run antérieur n'est lu.
                    phase = ExportSummaryLogic.terminalPhase(for: error)
                    return
                }
            }
            await pollUntilFinished()
            guard !Task.isCancelled else { return }
            await finish()
        }
    }

    /// §58 : progression interrogée toutes les 300 ms — assez court pour que
    /// la barre avance visiblement, assez long pour ne pas réveiller l'acteur
    /// d'export en continu pendant un encodage (§67).
    ///
    /// La première lecture a lieu SANS attendre : si l'encodage s'est terminé
    /// entre le démarrage et cette boucle, l'issue est traitée immédiatement.
    private func pollUntilFinished() async {
        let exportActor = environment.exportActor
        let id = projectID
        while !Task.isCancelled {
            guard let current = await exportActor.currentProgress(projectID: id) else { return }
            progress = current
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Issue de l'export : l'ERREUR exposée par l'acteur fait foi (§58 : une
    /// interruption est annoncée, jamais avalée) ; à défaut, le fichier
    /// produit est proposé à l'enregistrement et au partage (§55 : Photos
    /// seulement sur geste explicite de l'utilisateur).
    private func finish() async {
        let exportActor = environment.exportActor
        let lastError = await exportActor.lastError(projectID: projectID)
        // Suivi annulé pendant l'interrogation (§8, §8.1) : l'écran a déjà son
        // état — ne rien réécrire par-dessus.
        guard !Task.isCancelled else { return }
        if let lastError {
            phase = ExportSummaryLogic.terminalPhase(for: lastError)
            return
        }

        let lastOutcome = await exportActor.lastOutcome(projectID: projectID)
        guard !Task.isCancelled else { return }
        guard let outcome = lastOutcome else {
            // Ni erreur ni résultat : état inattendu — annoncé quand même
            // (§66 : jamais d'échec muet), le projet reste intact.
            environment.logger.error("Export terminé sans résultat ni erreur exploitables.")
            phase = didRequestCancel
                ? .cancelled
                : .failed(message: ExportSummaryLogic.genericInterruptionMessage)
            return
        }
        progress = 1
        // §8.1 : le succès n'est annoncé qu'ICI, sur confirmation effective de
        // l'écriture du fichier par l'acteur.
        phase = .ready(url: outcome.outputURL)
    }

    /// §58 : annulation possible à tout moment pendant l'encodage. L'acteur
    /// supprime le fichier temporaire ; aucun asset Photos incomplet n'a pu
    /// être créé puisque l'enregistrement n'a lieu qu'après succès (§55).
    private func cancelExport() {
        didRequestCancel = true
        let exportActor = environment.exportActor
        let id = projectID
        Task {
            await exportActor.cancelExport(projectID: id)
        }
    }

    // MARK: - Arrière-plan (§8.1, §58)

    /// §8.1 : « Ne pas promettre qu'une analyse ou un export continuera
    /// indéfiniment lorsque l'application est placée en arrière-plan. iOS peut
    /// suspendre le processus. » ; §58 : « en cas de passage en arrière-plan,
    /// terminer si le système l'autorise, sinon annoncer l'interruption et
    /// permettre de recommencer ».
    ///
    /// DÉCISION V1 : l'application ne prend AUCUNE assertion de tâche
    /// d'arrière-plan pour l'encodage (§8.1 réserve la tâche courte à la
    /// finition d'une écriture ou au nettoyage d'un temporaire). Le système ne
    /// nous autorise donc pas à terminer : le passage en arrière-plan pendant
    /// l'ENCODAGE est traité comme une interruption — suivi arrêté, annulation
    /// demandée à l'acteur (temporaire supprimé §57, statut du projet restauré
    /// §10, aucun asset Photos incomplet §58) et message d'interruption
    /// affiché. Jamais un succès : §8.1 interdit d'annoncer un export réussi
    /// avant confirmation effective.
    ///
    /// Si l'annulation n'a pas eu le temps d'être prise en compte avant la
    /// suspension, l'encodage peut se poursuivre : « Recommencer » recevra
    /// alors `alreadyRunning` et l'écran REPRENDRA le suivi du run en cours au
    /// lieu d'en lancer un second (§58).
    ///
    /// L'enregistrement dans Photos (`saving`) n'est PAS interrompu : c'est
    /// l'écriture courte que §8.1 autorise à terminer, et son succès est
    /// confirmé par PhotoKit.
    private func handleScenePhase(_ newPhase: ScenePhase) {
        guard newPhase == .background, isEncoding else { return }
        monitorTask?.cancel()
        monitorTask = nil
        let exportActor = environment.exportActor
        let id = projectID
        Task { await exportActor.cancelExport(projectID: id) }
        progress = 0
        phase = .failed(message: ExportSummaryLogic.backgroundInterruptionMessage)
        environment.logger.info(
            "Export interrompu par un passage en arrière-plan (§8.1) — projet intact."
        )
    }

    // MARK: - Enregistrement dans Photos (§40, §55, §66)

    /// §55 : « enregistrement dans Photos seulement après succès complet » —
    /// déclenché par le bouton « Enregistrer dans Photos » de la phase
    /// `ready`, jamais automatiquement.
    /// §40 : l'autorisation d'ÉCRITURE est demandée au PREMIER enregistrement
    /// — c'est `PhotoLibrarySaver.save` qui s'en charge (et qui ne
    /// re-sollicite jamais un refus déjà exprimé) : la vue ne duplique pas
    /// cette règle, elle en traite seulement l'issue.
    /// §66 : refus → le fichier est CONSERVÉ, partage et Réglages proposés.
    private func saveToPhotos(url: URL) {
        guard case .ready = phase else { return }
        phase = .saving(url: url)
        let saver = environment.photoLibrarySaver
        let logger = environment.logger
        Task {
            do {
                try await saver.save(fileURL: url)
                phase = .succeeded
            } catch ExportError.photosAccessDenied {
                phase = .fileKept(reason: .photosDenied, url: url)
            } catch is CancellationError {
                // Écriture interrompue : le fichier reste sur disque et reste
                // proposé au partage (§66).
                phase = .fileKept(reason: .photosFailed, url: url)
            } catch {
                logger.error(
                    "Enregistrement dans Photos impossible : \(error.localizedDescription)"
                )
                phase = .fileKept(reason: .photosFailed, url: url)
            }
        }
    }

    // MARK: - Espace disque (§57)

    /// Espace réellement disponible pour un usage important, sur le volume où
    /// l'export sera écrit (§11 `temp/` du projet — MÊME sonde que
    /// l'exportateur, donc même verdict).
    ///
    /// `nil` si le système ne le rapporte pas : la vérification est alors
    /// laissée à l'exportateur, jamais devinée (refuser un export parce que le
    /// système n'a rien répondu serait une panne inventée).
    private func availableCapacityBytes() -> Int64? {
        let directory = environment.fileStore.subdirectoryURL(.temp, for: projectID)
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Libellés dépendant de l'état

    /// Vrai si le projet contient des cases au-delà du préfixe exporté (§51).
    private var isPartialExport: Bool {
        totalSlotCount > prefixSlotCount
    }

    /// Énoncé VoiceOver du résumé (§39) — un seul élément parlé, sans puce ni
    /// signe « × » (voir `ExportSummaryLogic.spokenSummary`).
    private var spokenSummaryLabel: String {
        if isLoadingSummary {
            return "Préparation du résumé d'export"
        }
        if let loadErrorMessage {
            return loadErrorMessage
        }
        guard hasExportablePrefix else {
            return "Aucun plan n'est encore prêt au début du montage. "
                + "Remplissez la première case pour pouvoir exporter."
        }
        var spoken: String
        if let profile {
            spoken = ExportSummaryLogic.spokenSummary(
                width: profile.renderWidth,
                height: profile.renderHeight,
                frameRate: profile.frameRate,
                isHDR: profile.isHDR,
                slotCount: prefixSlotCount,
                duration: exportDuration
            )
        } else {
            spoken = ExportSummaryLogic.spokenEssentials(
                slotCount: prefixSlotCount,
                duration: exportDuration
            )
        }
        if isPartialExport {
            spoken += " Seul le début déjà monté est exporté ; "
                + "le reste du projet est conservé."
        }
        if isEncoding {
            // §8.1/§39 : la consigne est AUSSI parlée — elle ne doit pas
            // dépendre de la seule lecture visuelle.
            spoken += " " + ExportSummaryLogic.keepAppOpenNotice
        }
        return spoken
    }

    /// §40/§66 : ouvrir Réglages pour autoriser l'ajout à Photos.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - Preview (projet vide : §66 « première case vide → export désactivé »)
//
// Aucune photothèque n'est sollicitée par cet écran (le profil §52 vient de
// l'exportateur) : la preview reste purement locale.

#Preview("Export — aucun plan prêt") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    return ExportSummaryView(projectID: UUID())
        .environment(environment)
        .modelContainer(container)
}
