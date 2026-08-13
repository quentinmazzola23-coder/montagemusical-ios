//
//  ProjectExporter.swift
//  MontageMusical
//
//  Export du montage — timeline exportable (changement produit, remplace §51),
//  §52 (profil maître), §53 (exactitude temporelle), §54 (composition),
//  §55 (encodage), §57 (stockage et espace disque), §58 (progression et
//  interruption), §66 (cas limites d'export).
//
//  CHANGEMENT PRODUIT (contrat complet dans `ExportModels.swift`) : l'export
//  CONCATÈNE toutes les zones remplies — « n'exporte que les parties avec de
//  la vidéo ». Cases 28…35 prêtes, 36…39 vides, 40…50 prêtes → 19 plans mis
//  bout à bout. Conséquences temporelles traitées ici :
//  - durée du fichier produit = SOMME des durées de toutes les cases
//    exportées (et NON `dernière.end - première.start`) ;
//  - musique insérée = UNE portion PAR RUN (`[run.musicStart, run.musicEnd]`
//    du fichier original), posée à la position de composition du run ; la
//    musique SAUTE donc à chaque jonction entre runs — conséquence assumée ;
//  - vidéo de la case `i` insérée à
//    `(position du run) + (slot.start - run.musicStart)`.
//  Les cases ne sont JAMAIS omises ni déplacées (temps musicaux absolus
//  conservés) et aucun écran noir n'est ajouté : les zones vides sont
//  SUPPRIMÉES, pas comblées.
//
//  Protocole §7 `ProjectExporting` : la SIGNATURE est respectée à
//  l'identique ; la conformance formelle n'est pas déclarée (même choix
//  documenté qu'au Jalon 9 pour `PreviewBuilding` — voir en bas de fichier).
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

// MARK: - Erreurs d'export (§57, §58, §66)

// Non defini par la specification — definition minimale V1.
/// Erreurs d'export. Aucune ne modifie le montage : « interruption : projet
/// intact » (§66).
enum ExportError: Error, Equatable, LocalizedError {

    /// Aucune case n'est prête : la TIMELINE exportable est vide, il n'y a
    /// rien à exporter (changement produit — §66 « première case vide :
    /// export désactivé » ne s'applique plus telle quelle : les cases vides
    /// sont SUPPRIMÉES du montage, où qu'elles soient, et seules comptent les
    /// zones remplies). Nom du cas CONSERVÉ pour ne pas casser ses appelants.
    case emptyPrefix

    /// §57/§66 : « espace insuffisant : bloquer avant encodage ». Aucun
    /// encodage n'a été lancé, aucun fichier temporaire n'a été écrit.
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)

    /// §54 étape 2 / §64 : rush introuvable, sans piste vidéo, devenu plus
    /// court que sa case, ou photothèque inaccessible au moment de
    /// l'assemblage. La chaîne porte l'identifiant local du rush : aucun
    /// écran noir n'est JAMAIS inséré à sa place (§51).
    case assetUnavailable(String)

    /// Musique du projet introuvable ou illisible (§11 `audio/original.<ext>`,
    /// §16.1). Sans musique il n'y a pas d'horloge maîtresse (§53) : aucun
    /// export n'est produit.
    case missingAudio

    /// Échec de l'encodage lui-même (§55). Le fichier temporaire a été
    /// supprimé (§57).
    case exportFailed(String)

    /// §40/§66 : « Photos refusé : conserver temporairement l'export et
    /// proposer d'autoriser l'accès ou partager via feuille système ». Le
    /// fichier exporté est CONSERVÉ dans `exports/` (§11).
    case photosAccessDenied

    /// §57/§66 : la COPIE dans Photos a manqué d'espace.
    ///
    /// `PHAssetCreationRequest` COPIE le fichier (`shouldMoveFile = false`,
    /// §60 : l'export reste disponible dans `exports/`) : l'ajout demande
    /// donc autant d'espace que l'export lui-même, APRÈS l'encodage. La
    /// vérification §57 exige déjà cette place avant d'encoder
    /// (`ProjectExporter.photosCopyFactor`) ; ce cas couvre l'espace consommé
    /// entre-temps par une autre application. Le fichier exporté est
    /// CONSERVÉ.
    case photosStorageFull

    /// §58 : export annulé. Le fichier temporaire a été supprimé et aucun
    /// asset Photos n'a été créé.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyPrefix:
            return "Il n'y a rien à exporter pour l'instant : "
                + "remplissez au moins une case du montage."
        case .insufficientStorage(let requiredBytes, let availableBytes):
            return "Espace de stockage insuffisant : environ "
                + "\(Self.megabytes(requiredBytes)) Mo sont nécessaires et "
                + "\(Self.megabytes(availableBytes)) Mo sont disponibles. "
                + "Libérez de l'espace, puis relancez l'export."
        case .assetUnavailable(let identifier):
            return "Une vidéo du montage n'est plus exploitable "
                + "(\(identifier)). Remplacez-la, puis relancez l'export."
        case .missingAudio:
            return "La musique du projet est introuvable ou illisible. "
                + "Réimportez la musique pour exporter le montage."
        case .exportFailed(let reason):
            return "L'export n'a pas abouti (\(reason)). Le montage est intact : réessayez."
        case .photosAccessDenied:
            return "L'ajout à la photothèque est refusé. "
                + "Le montage exporté est conservé : autorisez l'accès dans Réglages, ou partagez le fichier."
        case .photosStorageFull:
            return "L'ajout à la photothèque a manqué d'espace de stockage. "
                + "Le montage exporté est conservé : libérez de l'espace puis réessayez, "
                + "ou partagez directement le fichier."
        case .cancelled:
            return "Export interrompu. Le montage est intact : relancez l'export quand vous voulez."
        }
    }

    /// Mégaoctets décimaux (unité affichée par iOS pour le stockage).
    private static func megabytes(_ bytes: Int64) -> Int64 {
        max(0, bytes / 1_000_000)
    }
}

// MARK: - Résultat d'export observable (§58, §60)

// Non defini par la specification — definition minimale V1.
/// Dernier export réussi d'un projet, exposé par `ExportActor` (§58 : l'état
/// visible du dock ; §60 : « dernier export réussi » restauré).
struct ExportOutcome: Sendable, Equatable {
    let outputURL: URL
    let duration: MediaTime
    let slotCount: Int

    /// Vrai quand l'issue a été RESTAURÉE depuis le disque à la réouverture
    /// (§60), et non produite par un export de la session courante.
    ///
    /// Le schéma §10 est verbatim : aucune colonne ne décrit un export — seul
    /// le FICHIER survit (§11 `exports/`). `duration` et `slotCount` sont
    /// alors inconnus et valent zéro : ils ne doivent JAMAIS être affichés
    /// comme des mesures. Un tel résultat n'est pas non plus l'issue d'un
    /// export qui vient de se terminer (rien ne doit être ré-enregistré dans
    /// Photos sur cette base, §55).
    let isRestored: Bool

    init(outputURL: URL, duration: MediaTime, slotCount: Int, isRestored: Bool = false) {
        self.outputURL = outputURL
        self.duration = duration
        self.slotCount = slotCount
        self.isRestored = isRestored
    }
}

// MARK: - Plan d'export (timeline exportable) — logique PURE

// Non defini par la specification — definition minimale V1.
/// Ce qui sera réellement encodé : la TIMELINE concaténée des zones remplies
/// (changement produit — voir `ExportModels.swift`) et la durée du montage
/// exporté.
///
/// Type PUR et `nonisolated` : aucune AVFoundation, aucune E/S — c'est la
/// partie de l'export qui se teste sans encoder (§70).
struct ExportPlan: Sendable, Equatable {

    /// Timeline RÉELLEMENT exportée. Les cases y gardent leurs temps musicaux
    /// ABSOLUS : elles ne sont jamais recompactées ni réécrites — la
    /// concaténation est un CALCUL de position, pas une modification du
    /// montage.
    let timeline: ReadyTimeline

    /// Cases exportées, dans l'ordre du montage (runs concaténés), avec leurs
    /// temps ABSOLUS.
    var slots: [ProjectSlot] { timeline.allSlots }

    /// Runs exportés : chaque zone remplie, avec ses bornes musicales.
    var runs: [ReadyRun] { timeline.runs }

    /// Durée totale du fichier produit = SOMME des durées de toutes les cases
    /// exportées.
    ///
    /// **Ce n'est PAS `dernière.end - première.start`** : les zones vides
    /// n'existent pas dans le fichier, ni en vidéo ni en musique (changement
    /// produit). Exemple de l'utilisateur : cases 28…35 et 40…50 prêtes, à
    /// 30 000 ticks la case → 19 × 30 000 = 570 000 ticks (9,5 s), et non
    /// 1 530 000 − 840 000 = 690 000 ticks.
    var duration: MediaTime { timeline.duration }

    /// Nombre TOTAL de plans exportés, tous runs confondus
    /// (§56 : « 19 plans • 9,50 s »).
    var slotCount: Int { timeline.slotCount }

    /// Instant de composition d'une case exportée :
    /// `(position de son run) + (slot.start - run.musicStart)` (§9, ticks
    /// entiers). Fonction PURE — c'est elle que testent les tests de position,
    /// sans AVFoundation.
    ///
    /// - Returns: `nil` si la case n'est pas exportée (elle n'a alors aucun
    ///   instant de composition).
    func compositionStart(of slot: ProjectSlot) -> MediaTime? {
        timeline.compositionStart(of: slot)
    }

    static let empty = ExportPlan(timeline: .empty)

    /// Plan d'export d'un projet (toutes les zones remplies, concaténées).
    ///
    /// Les DEUX portées §7 `ExportScope` produisent la même timeline :
    /// §66 impose « trou au milieu : export limité » — désormais lu comme
    /// « les trous sont supprimés du montage ». `.complete` est donc une
    /// DÉCLARATION d'intention de l'appelant (le montage est complet, la
    /// timeline couvre alors toutes les cases), jamais une demande d'exporter
    /// autre chose — c'est pourquoi aucune erreur « montage incomplet »
    /// n'existe côté export, contrairement à la prévisualisation §47.2.
    ///
    /// - Throws: `ExportError.emptyPrefix` si AUCUNE case n'est prête, ou si
    ///   la timeline est de durée nulle.
    static func make(project: ProjectSnapshot, scope: ExportScope) throws -> ExportPlan {
        switch scope {
        case .contiguousPrefix, .complete:
            break // même timeline dans les deux cas (voir ci-dessus)
        }
        let timeline = project.readyTimeline // changement produit
        guard !timeline.isEmpty, timeline.duration.ticks > 0 else {
            throw ExportError.emptyPrefix
        }
        return ExportPlan(timeline: timeline)
    }

    /// Plan RÉDUIT aux `index` premières cases du montage (§66 : « asset en
    /// téléchargement : export limité avant lui »).
    ///
    /// Utilisé quand un rush devient indisponible PENDANT l'assemblage
    /// (reparti dans iCloud, supprimé, photothèque révoquée).
    ///
    /// **Décision documentée — la troncature ABANDONNE tout ce qui suit.** La
    /// case en cause est retirée, la fin de SON run aussi, et les runs
    /// SUIVANTS sont abandonnés. C'est le comportement le plus simple et le
    /// plus prévisible : exporter les runs d'après produirait un montage
    /// DIFFÉRENT de celui annoncé par le résumé avant export (§56 : nombre de
    /// plans et durée), c'est-à-dire exactement la surprise que §3 interdit.
    /// L'utilisateur relance l'export quand le rush est redevenu disponible.
    ///
    /// Les cases conservées ne bougent PAS : la troncature ne retire qu'un
    /// SUFFIXE du montage, donc les positions de composition des cases
    /// gardées sont identiques à celles du plan complet. Aucun écran noir
    /// n'est ajouté, et la musique du dernier run conservé est recoupée à la
    /// fin absolue de sa dernière case.
    ///
    /// Faire échouer l'export ENTIER contredirait §66, qui décrit un export
    /// LIMITÉ, pas un export perdu.
    ///
    /// - Throws: `ExportError.emptyPrefix` si `index <= 0` — le TOUT PREMIER
    ///   rush du montage est indisponible, il ne reste rien à exporter.
    func truncated(before index: Int) throws -> ExportPlan {
        guard index > 0 else { throw ExportError.emptyPrefix }
        let kept = timeline.truncated(toFirst: index)
        guard !kept.isEmpty, kept.duration.ticks > 0 else {
            throw ExportError.emptyPrefix
        }
        return ExportPlan(timeline: kept)
    }
}

// MARK: - Estimation de taille (§57)

extension ExportPlan {

    /// Débit vidéo modélisé, en **bits par pixel et par image**.
    ///
    /// Valeur DOCUMENTÉE et volontairement généreuse : 0,30 bit/pixel/image
    /// donne ~75 Mbit/s en 4K30 et ~37 Mbit/s en 1080p60, au-dessus de ce que
    /// produit `AVAssetExportPresetHEVCHighestQuality` en pratique. §57 exige
    /// de « refuser proprement si insuffisant » : une estimation qui
    /// SURÉVALUE protège l'utilisateur, une estimation optimiste le laisserait
    /// tomber en panne de disque en fin d'encodage.
    /// Non defini par la specification — modèle minimal V1.
    static let videoBitsPerPixelPerFrame: Double = 0.30

    /// Débit audio modélisé (AAC stéréo haute qualité).
    static let audioBitsPerSecond: Double = 256_000

    /// Marge de sécurité appliquée à l'estimation (conteneur, en-têtes,
    /// variations de débit d'une scène très détaillée).
    static let storageSafetyMargin: Double = 1.2

    /// Taille estimée du fichier exporté, en octets (§57 : « estimer la
    /// taille »).
    ///
    /// Basée sur `duration`, c'est-à-dire la SOMME des durées des cases
    /// exportées — la durée RÉELLE du fichier produit (changement produit :
    /// ni les 90 premières secondes du morceau, ni les zones vides du milieu
    /// ne sont encodées).
    ///
    /// Croît strictement avec le nombre de pixels, la cadence et la durée —
    /// les trois grandeurs qui pilotent réellement le débit.
    func estimatedBytes(profile: MasterProfile) -> Int64 {
        guard duration.ticks > 0 else { return 0 }
        let seconds = duration.seconds
        let pixels = Double(profile.pixelCount)
        let videoBits = pixels * profile.frameRate * Self.videoBitsPerPixelPerFrame * seconds
        let audioBits = Self.audioBitsPerSecond * seconds
        let bytes = ((videoBits + audioBits) / 8) * Self.storageSafetyMargin
        guard bytes.isFinite, bytes > 0 else { return 0 }
        guard bytes < Double(Int64.max) else { return Int64.max }
        return Int64(bytes.rounded(.up))
    }

    /// Taille estimée de l'export d'un PROJET (§57), c'est-à-dire de sa
    /// TIMELINE exportable — une timeline vide donne 0, il n'y a rien à
    /// écrire.
    ///
    /// `nonisolated static` : logique PURE (aucune E/S, aucun acteur, aucune
    /// AVFoundation). C'est la forme testable et la SOURCE UNIQUE de
    /// l'estimation — `ProjectExporter.estimatedBytes(project:profile:)` s'y
    /// ramène, l'interface aussi.
    nonisolated static func estimatedBytes(
        project: ProjectSnapshot,
        profile: MasterProfile
    ) -> Int64 {
        let plan = (try? make(project: project, scope: .contiguousPrefix)) ?? .empty
        return plan.estimatedBytes(profile: profile)
    }
}

// MARK: - Exporteur (§7, §53, §54, §55)

/// Construit la composition d'export et l'encode (§54, §55).
///
/// **Isolation `@MainActor` — même choix documenté qu'au Jalon 9.**
/// `AVMutableComposition`, `AVURLAsset`, `AVAssetExportSession` ne sont pas
/// `Sendable` : les faire traverser une frontière d'isolation est un
/// diagnostic Swift 6 (« non-Sendable ... cannot cross actor boundary »). En
/// isolant l'exporteur sur `@MainActor`, TOUS les objets AVFoundation naissent
/// et meurent dans le même domaine d'isolation ; seules des valeurs `Sendable`
/// traversent des frontières (`URL` depuis `MediaLibraryActor`,
/// `ProjectSnapshot` et `ExportResult` depuis/vers `ExportActor`). Le travail
/// lourd n'occupe jamais le fil principal : les chargements AVFoundation et
/// l'encodage sont des `await` qui suspendent — l'encodage réel a lieu dans
/// les threads internes d'AVFoundation.
///
/// **Relation avec `PreviewBuilder` (§48/§54).** Les règles de composition
/// sont les MÊMES et le code partage tout ce qui est partageable :
/// `readyTimeline` (changement produit), `GeometryLock.orientedSize` /
/// `renderSize` / `cropToFillTransform` (§49/§50), `MediaLibraryActor`
/// (§8), `MediaTime.cmTime` (§9). L'assemblage n'est pas DÉLÉGUÉ à
/// `PreviewBuilder` pour trois raisons :
/// 1. le plan de rendu d'export est au PROFIL MAÎTRE (§52 : `renderSize` et
///    `frameDuration` du clip maître, colorimétrie §52.4), là où la preview
///    rend à sa cadence de travail 1/30 ;
/// 2. l'export doit COLLECTER par clip la cadence de lecture et la capacité
///    HDR (§52.2/§52.4) que la composition immuable de la preview n'expose
///    plus ;
/// 3. `PreviewBuilder` rend une `AVComposition` déjà figée avec son
///    `AVVideoComposition` : la réutiliser imposerait de reconstruire le plan
///    de rendu par-dessus, donc de reparcourir les assets — le coût évité
///    serait nul.
@MainActor
struct ProjectExporter: Sendable {

    // MARK: Constantes documentées (§55)

    /// Conteneur de sortie : QuickTime.
    ///
    /// C'est le conteneur natif des presets `AVAssetExportSession`, celui que
    /// la caméra iOS produit, et celui que `PHAssetCreationRequest` ingère
    /// sans transcodage (§55 : « enregistrement dans Photos seulement après
    /// succès complet »).
    static let outputFileType: AVFileType = .mov
    static let outputFileExtension = "mov"

    /// Intervalle de publication de la progression d'encodage (§58 :
    /// « progression visible dans le dock inférieur »). 0,2 s : assez fluide
    /// à l'œil, sans réveiller l'interface 60 fois par seconde.
    static let progressUpdateInterval: TimeInterval = 0.2

    private let fileStore: ProjectFileStore
    private let mediaLibrary: MediaLibraryActor
    private let logger = AppLogger(category: .export)

    init(fileStore: ProjectFileStore, mediaLibrary: MediaLibraryActor) {
        self.fileStore = fileStore
        self.mediaLibrary = mediaLibrary
    }

    // MARK: - Signature §7 `ProjectExporting`

    /// Exporte le montage (§51 → §55) et rend le fichier final dans
    /// `exports/` du projet (§11).
    ///
    /// Déroulé, dans cet ordre STRICT :
    /// 1. timeline exportable (vide → `emptyPrefix`) ;
    /// 2. composition §54 (résolution des rushs, vérification des durées
    ///    RÉELLES, insertion de chaque case à sa position dans la timeline
    ///    concaténée, musique = UNE portion par run posée à la position du
    ///    run) — un rush devenu indisponible TRONQUE la FIN du montage (§66)
    ///    au lieu de faire échouer l'export entier ;
    /// 3. profil maître §52 (résolution + cadence du même clip, SDR §52.4) ;
    /// 4. plan de rendu §50/§52 au profil maître ;
    /// 5. **estimation de taille et vérification de l'espace disque §57 —
    ///    AVANT tout encodage**, place de la copie Photos comprise ;
    /// 6. encodage §55 : UNE seule ré-encodage vers un fichier temporaire
    ///    unique ;
    /// 7. déplacement vers `exports/`, purge des exports précédents (§11/§57)
    ///    puis suppression des temporaires (§57).
    ///
    /// L'annulation (§58) est coopérative : elle est vérifiée entre chaque
    /// étape et propagée à la session d'encodage ; les fichiers temporaires
    /// sont supprimés dans TOUS les cas (succès, échec, annulation).
    func export(
        project: ProjectSnapshot,
        scope: ExportScope,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        // §57 : « nettoyer les fichiers temporaires après succès/échec ». Le
        // temporaire d'encodage a son propre `defer` ; celui-ci couvre EN PLUS
        // les sources matérialisées des rushs recomposés (§52.3,
        // `MediaLibraryActor.exportableVideoURL`). Le fichier final est déjà
        // dans `exports/` quand ce nettoyage a lieu.
        defer { fileStore.clearTemporaryFiles(projectID: project.projectID) }

        // Timeline concaténée des zones remplies (changement produit).
        let plan = try ExportPlan.make(project: project, scope: scope)
        progress(0)
        try checkCancellation()

        // §54 : composition (pistes + caractéristiques techniques par clip).
        // `assembly.plan` peut être PLUS COURT que `plan` : §66 — un rush
        // devenu indisponible pendant l'assemblage tronque l'export.
        let assembly = try await assemble(project: project, plan: plan)
        let effectivePlan = assembly.plan
        try checkCancellation()

        // §52 : profil maître — résolution ET cadence du MÊME clip.
        guard let profile = MasterProfileSelector.selectMaster(
            clips: assembly.clips,
            geometry: assembly.geometry
        ) else {
            throw ExportError.emptyPrefix // liste de clips vide : filtré en amont
        }

        let videoComposition = makeVideoComposition(
            segments: assembly.segments,
            videoTrack: assembly.videoTrack,
            profile: profile,
            totalDuration: assembly.totalDuration
        )

        // §57 : estimer PUIS vérifier l'espace AVANT d'encoder quoi que ce
        // soit — place de l'encodage ET de la copie Photos qui suivra.
        let estimatedBytes = effectivePlan.estimatedBytes(profile: profile)
        let requiredBytes = Self.requiredBytesIncludingPhotosCopy(estimatedBytes)
        try Self.requireSufficientStorage(
            requiredBytes: requiredBytes,
            availableBytes: availableCapacityBytes(projectID: project.projectID)
        )
        try checkCancellation()

        let outputURL = try await encode(
            composition: assembly.composition,
            videoComposition: videoComposition,
            profile: profile,
            projectID: project.projectID,
            progress: progress
        )

        progress(1)
        // Bornes de CHAQUE zone remplie journalisées : un export fait de
        // plusieurs zones concaténées est le cas NORMAL désormais, il doit
        // être lisible dans les journaux (§69A : aucun nom de fichier
        // personnel, seuls des index).
        //
        // Numérotation HUMAINE (1-based), comme partout dans l'interface
        // (« Plan 8 » §35.2) : une même zone ne doit pas se lire « 29 à 36 »
        // à l'écran et « 28 à 35 » dans les journaux.
        let runsDescription = effectivePlan.runs
            .map { "\($0.startIndex + 1)–\($0.endIndex + 1)" }
            .joined(separator: ", ")
        logger.info(
            "Export terminé : \(effectivePlan.slotCount) plans "
            + "en \(effectivePlan.runs.count) zone(s) [\(runsDescription)], "
            + "durée \(effectivePlan.duration.ticks) ticks, "
            + "\(profile.renderWidth)×\(profile.renderHeight), "
            + "\(profile.isHDR ? "HDR" : "SDR"), taille estimée \(estimatedBytes) octets."
        )
        return ExportResult(
            outputURL: outputURL,
            duration: effectivePlan.duration,
            slotCount: effectivePlan.slotCount
        )
    }

    /// Taille estimée du montage exporté (§57), pour le résumé avant export
    /// (§56) et la vérification d'espace disque.
    ///
    /// Portée `.contiguousPrefix` : c'est TOUJOURS la timeline concaténée des
    /// zones remplies qui est encodée (§66). Une timeline vide donne 0 — il
    /// n'y a rien à écrire.
    ///
    /// Façade sur la logique PURE `ExportPlan.estimatedBytes(project:profile:)`
    /// — source unique, testable sans acteur ni disque.
    func estimatedBytes(project: ProjectSnapshot, profile: MasterProfile) -> Int64 {
        ExportPlan.estimatedBytes(project: project, profile: profile)
    }

    // MARK: - §52/§56 Profil maître — SOURCE UNIQUE

    /// Profil maître §52 de la TIMELINE exportable d'un projet, **calculé par
    /// le même chemin que l'export** : `loadClipFacts` (résolution du rush,
    /// lecture `AVURLAsset` de `naturalSize`/`preferredTransform`/cadence/HDR,
    /// dimensions orientées `GeometryLock.orientedSize`), même repli de
    /// géométrie §52.1, même `MasterProfileSelector`.
    ///
    /// C'est l'API que le résumé avant export (§56) doit consommer : sans
    /// elle, l'interface recalculerait un profil par un AUTRE chemin et
    /// pourrait annoncer une résolution ou une cadence que l'export ne
    /// produirait pas — deux vérités pour une seule décision (§52 : « Prendre
    /// la résolution et la cadence d'un même clip maître »).
    ///
    /// Coût documenté : ce calcul résout réellement chaque rush exporté (sans
    /// réseau, §44) et matérialise au besoin la source d'un rush recomposé
    /// (§52.3) — le fichier intermédiaire est alors RÉUTILISÉ par l'export qui
    /// suit, jamais produit deux fois.
    ///
    /// - Returns: `nil` si la timeline est vide ou si un SEUL rush exporté est
    ///   illisible. Jamais de profil PARTIEL : calculé sur une partie des
    ///   rushs, il pourrait désigner un autre clip maître que l'export
    ///   (§52.2). L'appelant affiche alors l'essentiel sans rien inventer
    ///   (§56).
    func masterProfile(project: ProjectSnapshot) async -> MasterProfile? {
        guard let plan = try? ExportPlan.make(project: project, scope: .contiguousPrefix) else {
            return nil // timeline vide : rien à profiler
        }

        var clips: [MasterClipInfo] = []
        var firstFacts: ClipFacts?
        clips.reserveCapacity(plan.slots.count)

        for (order, slot) in plan.slots.enumerated() {
            guard let facts = try? await loadClipFacts(
                slot: slot,
                appearanceOrder: order,
                projectID: project.projectID
            ) else {
                return nil // un rush illisible → aucun profil annoncé
            }
            if firstFacts == nil { firstFacts = facts }
            clips.append(facts.info)
        }

        // §52.1 : géométrie du PROJET, avec le même repli documenté que
        // l'assemblage quand le verrou §49 n'a pas encore été posé.
        let geometry = project.geometry ?? fallbackGeometry(from: firstFacts)
        return MasterProfileSelector.selectMaster(clips: clips, geometry: geometry)
    }

    // MARK: - §57 Espace disque

    /// Facteur appliqué à l'estimation pour couvrir la COPIE dans Photos.
    ///
    /// `PHAssetCreationRequest` COPIE le fichier (`shouldMoveFile = false` —
    /// §60 : l'export doit rester dans `exports/` pour être restauré et
    /// partagé) : à l'instant de l'ajout, le montage occupe DEUX fois sa
    /// taille sur le même volume. §57 demande de « refuser proprement si
    /// insuffisant » : vérifier seulement la place de l'encodage laisserait
    /// l'ajout à Photos échouer après coup, c'est-à-dire exactement l'échec
    /// tardif que §57 veut éviter.
    ///
    /// La vérification a lieu une seule fois, AVANT l'encodage (§66 :
    /// « espace insuffisant : bloquer avant encodage »). Un manque survenu
    /// APRÈS (autre application, photothèque pleine) reste possible : il est
    /// alors annoncé distinctement par `ExportError.photosStorageFull`, le
    /// fichier exporté étant conservé.
    /// `nonisolated` comme les deux fonctions de vérification : la règle §57
    /// est une politique PURE, lisible depuis n'importe quel contexte (tests
    /// compris) sans passer par `@MainActor`.
    /// Non defini par la specification — modèle minimal V1.
    nonisolated static let photosCopyFactor: Int64 = 2

    /// Espace total à exiger pour un export dont la taille encodée est
    /// estimée à `estimatedBytes` (§57) : encodage + copie Photos.
    ///
    /// `nonisolated`, arithmétique saturante : une estimation déjà à
    /// `Int64.max` ne déborde pas.
    nonisolated static func requiredBytesIncludingPhotosCopy(_ estimatedBytes: Int64) -> Int64 {
        guard estimatedBytes > 0 else { return 0 }
        let (product, overflowed) = estimatedBytes.multipliedReportingOverflow(by: photosCopyFactor)
        return overflowed ? Int64.max : product
    }

    /// Vérifie l'espace disponible AVANT encodage (§57 : « vérifier l'espace
    /// disponible », « refuser proprement si insuffisant » ; §66 : « espace
    /// insuffisant : bloquer avant encodage »).
    ///
    /// `availableBytes == nil` : le volume ne rapporte pas sa capacité (cas
    /// rare — volume exotique, simulateur). L'export N'EST PAS bloqué : refuser
    /// un export parce que le système n'a rien répondu serait une panne
    /// inventée. Un vrai manque de place sera alors signalé par l'encodeur et
    /// traduit en `exportFailed`.
    ///
    /// `nonisolated` : logique pure, testable sans `@MainActor` ni disque réel.
    nonisolated static func requireSufficientStorage(
        requiredBytes: Int64,
        availableBytes: Int64?
    ) throws {
        guard let availableBytes else { return }
        guard availableBytes >= requiredBytes else {
            throw ExportError.insufficientStorage(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
    }

    /// Espace réellement disponible pour une écriture importante sur le
    /// volume du projet, ou `nil` si le système ne le rapporte pas.
    ///
    /// `volumeAvailableCapacityForImportantUsage` (et non
    /// `volumeAvailableCapacity`) : c'est la valeur qui tient compte de la
    /// purge possible des caches système — celle qu'iOS considère réellement
    /// disponible pour un fichier que l'utilisateur a demandé.
    ///
    /// **La sonde doit porter sur un chemin qui EXISTE** : `resourceValues`
    /// échoue sur un dossier absent, et la vérification §57 se désactiverait
    /// alors SILENCIEUSEMENT (capacité `nil` = « ne pas bloquer »). `temp/`
    /// n'est créé qu'à l'encodage : les candidats sont donc essayés du plus
    /// précis au plus sûr — dossier du projet (créé à la création du projet,
    /// §11), racine des projets, puis `Application Support` (toujours
    /// présent). Tous vivent sur le MÊME volume : la valeur ne dépend pas du
    /// candidat retenu, seule son existence compte.
    private func availableCapacityBytes(projectID: UUID) -> Int64? {
        let candidates = [
            fileStore.directory(for: projectID),
            fileStore.rootURL,
            URL.applicationSupportDirectory
        ]
        for candidate in candidates {
            if let values = try? candidate.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ), let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
        }
        return nil
    }

    // MARK: - §54 Composition

    /// Segment vidéo inséré : plage occupée dans la composition et géométrie
    /// source, mémorisées pour construire les instructions (§54.6/§54.7)
    /// APRÈS avoir déterminé le profil maître.
    private struct Segment {
        let timeRange: CMTimeRange
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let assetIdentifier: String
    }

    /// Position d'une case dans le montage concaténé : la case et son instant
    /// de départ DANS la composition
    /// (`position du run + slot.start - run.musicStart`). Calculée UNE fois,
    /// avant l'assemblage, pour que l'ordre d'insertion et l'ordre de
    /// troncature §66 soient exactement le même.
    private struct Placement {
        let slot: ProjectSlot
        let compositionStart: MediaTime
    }

    /// Portion de musique à insérer : le passage ABSOLU
    /// `[sourceStart, sourceStart + duration]` du morceau, posé à
    /// `compositionStart`. UNE portion par RUN (§53) — jamais une par case.
    private struct MusicInsertion {
        let sourceStart: MediaTime
        let duration: MediaTime
        let compositionStart: MediaTime
    }

    /// Composition assemblée + matière du profil maître (§52).
    private struct Assembly {
        let composition: AVMutableComposition
        let videoTrack: AVMutableCompositionTrack
        let segments: [Segment]
        let clips: [MasterClipInfo]
        let geometry: ProjectGeometry
        let totalDuration: CMTime
        /// Plan RÉELLEMENT assemblé — identique au plan demandé, sauf
        /// TRONCATURE §66 par un rush devenu indisponible en cours
        /// d'assemblage (la FIN du montage est raccourcie ; les cases
        /// conservées ne bougent pas). C'est lui qui fixe la durée du fichier
        /// (somme des durées des cases exportées), le nombre de plans annoncé
        /// et l'estimation §57.
        let plan: ExportPlan
    }

    /// Échec de résolution d'un rush pendant l'assemblage (§54, §66).
    ///
    /// Type INTERNE : il ne sert qu'à distinguer, au retour de
    /// `loadClipFacts`, une INDISPONIBILITÉ (qui tronque le plan §66) d'un
    /// refus STRUCTUREL (qui fait échouer l'export). Vers l'extérieur, seule
    /// `ExportError` circule.
    private struct ClipLoadFailure: Error {
        let identifier: String
        /// §66 : « asset en téléchargement : export limité avant lui ». Vrai
        /// pour les causes d'INDISPONIBILITÉ (rush reparti dans iCloud, rush
        /// supprimé, photothèque devenue inaccessible) : le montage reste
        /// valide, seule la matière manque à partir de cette case.
        let truncatesPlan: Bool

        /// Erreur exposée quand la troncature n'est pas possible (§51 :
        /// l'identifiant du rush dit QUELLE case remplacer).
        var exportError: ExportError { .assetUnavailable(identifier) }
    }

    /// §66 : causes d'INDISPONIBILITÉ d'un rush — elles tronquent le plan.
    ///
    /// Les autres causes (`noVideoTrack`, `assetTooShort`, `albumNotFound`)
    /// décrivent un rush qui n'aurait JAMAIS dû être associé (§43/§64 le
    /// refusent à l'association) : les taire en tronquant masquerait une
    /// incohérence du montage. Elles restent des échecs explicites.
    private static func truncatesPlan(_ error: MediaLibraryError) -> Bool {
        switch error {
        case .icloudUnavailable, .accessDenied, .assetNotFound:
            return true
        case .albumNotFound, .assetTooShort, .noVideoTrack:
            return false
        }
    }

    /// Assemble la composition d'export (§54) : UNE piste vidéo, UNE piste
    /// audio (la musique ORIGINALE du projet, §11/§16.1), aucune piste audio
    /// de rush (§54 étape 5).
    ///
    /// **Concaténation des zones remplies (changement produit).** Chaque case
    /// est insérée à `(position de son run) + (slot.start - run.musicStart)` :
    /// la première case du premier run tombe à `.zero`, les cases d'un même
    /// run conservent EXACTEMENT leur écart musical (§53), et un run commence
    /// là où le précédent finit — sans trou et sans écran noir. Les cases
    /// elles-mêmes ne sont jamais réécrites : leurs temps restent absolus.
    ///
    /// **Troncature §66.** Si un rush est devenu indisponible (reparti dans
    /// iCloud, supprimé, photothèque révoquée) alors que l'export a déjà
    /// commencé, l'assemblage S'ARRÊTE à la case précédente : le plan est
    /// réduit (`ExportPlan.truncated(before:)`) — la case en cause, la fin de
    /// SON run et TOUS les runs suivants sont abandonnés (décision documentée
    /// sur `truncated(before:)` : livrer les runs d'après donnerait un montage
    /// différent de celui annoncé par le résumé §56). Les cases conservées ne
    /// bougent pas d'un tick, la musique du dernier run conservé est recoupée
    /// à la fin absolue de sa dernière case, et l'export livre ce montage
    /// réduit. Faire échouer l'export ENTIER perdrait un montage parfaitement
    /// exportable, ce que §66 ne demande nulle part. Si la case en cause est
    /// la TOUTE PREMIÈRE, il ne reste rien à exporter : `emptyPrefix`.
    private func assemble(project: ProjectSnapshot, plan: ExportPlan) async throws -> Assembly {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.exportFailed("Piste vidéo de composition impossible à créer.")
        }

        // Positions FINALES calculées en une fois, dans l'ordre du montage :
        // `runStarts` cumule les durées des runs en ticks entiers (§9), et
        // c'est LE MÊME calcul que l'aperçu (`ReadyTimeline`).
        var placements: [Placement] = []
        placements.reserveCapacity(plan.slotCount)
        for (run, runStart) in zip(plan.timeline.runs, plan.timeline.runStarts) {
            for slot in run.slots {
                placements.append(
                    Placement(slot: slot, compositionStart: runStart + run.offset(of: slot))
                )
            }
        }

        var segments: [Segment] = []
        var clips: [MasterClipInfo] = []
        var firstFacts: ClipFacts?
        var effectivePlan = plan
        segments.reserveCapacity(placements.count)
        clips.reserveCapacity(placements.count)

        for (order, placement) in placements.enumerated() {
            try checkCancellation() // §58 : annulation coopérative
            let facts: ClipFacts
            do {
                facts = try await loadClipFacts(
                    slot: placement.slot,
                    appearanceOrder: order,
                    projectID: project.projectID
                )
            } catch let failure as ClipLoadFailure where failure.truncatesPlan {
                // §66 : export LIMITÉ avant la case indisponible. `truncated`
                // lève `emptyPrefix` si c'est la toute première case.
                effectivePlan = try plan.truncated(before: order)
                logger.error(
                    "Rush indisponible en cours d'export (\(failure.identifier)) — "
                    + "export limité aux \(effectivePlan.slotCount) premiers plans (§66)."
                )
                break
            } catch let failure as ClipLoadFailure {
                throw failure.exportError
            }
            if firstFacts == nil { firstFacts = facts }
            segments.append(try insertVideo(
                facts: facts,
                slot: placement.slot,
                // Position dans le montage concaténé. Elle est valable pour
                // le plan COMPLET comme pour le plan tronqué : la troncature
                // ne retire qu'un SUFFIXE, donc aucune case conservée ne
                // change de place.
                compositionStart: placement.compositionStart,
                into: videoTrack
            ))
            clips.append(facts.info)
        }

        // §53 : la musique est l'horloge maîtresse. UNE portion par RUN du
        // plan EFFECTIF : `[run.musicStart, run.musicEnd]` du morceau, posée à
        // la position de composition du run. La musique de la dernière zone
        // conservée est donc coupée à la fin absolue de sa dernière case, et
        // les passages des cases vides n'existent pas dans le fichier.
        let musicEnd = try await insertMusic(
            projectID: project.projectID,
            insertions: zip(
                effectivePlan.timeline.runs,
                effectivePlan.timeline.runStarts
            ).map { (run, runStart) in
                MusicInsertion(
                    sourceStart: run.musicStart,
                    duration: run.duration,
                    compositionStart: runStart
                )
            },
            into: composition
        )

        let videoEnd = segments.reduce(CMTime.zero) { CMTimeMaximum($0, $1.timeRange.end) }

        // §52.1 : la géométrie est TOUJOURS celle du projet. Repli documenté
        // (identique à `PreviewBuilder`) si le verrou §49 n'a pas encore été
        // posé : géométrie du premier rush EXPORTÉ, calculée mais JAMAIS
        // persistée ici — le verrouillage reste la seule responsabilité du
        // store (§49 étapes 4 et 5).
        let geometry = project.geometry ?? fallbackGeometry(from: firstFacts)

        return Assembly(
            composition: composition,
            videoTrack: videoTrack,
            segments: segments,
            clips: clips,
            geometry: geometry,
            totalDuration: CMTimeMaximum(videoEnd, musicEnd),
            plan: effectivePlan
        )
    }

    /// Géométrie de repli quand le verrou §49 n'a pas encore été posé :
    /// celle du PREMIER rush exporté (§49 : « le premier rush valide fixe
    /// la géométrie »). Calculée, jamais persistée ici.
    private func fallbackGeometry(from facts: ClipFacts?) -> ProjectGeometry {
        GeometryLock.geometry(
            naturalWidth: Int((facts?.naturalSize.width ?? 0).rounded()),
            naturalHeight: Int((facts?.naturalSize.height ?? 0).rounded()),
            preferredTransform: facts?.preferredTransform ?? .identity,
            assetIdentifier: facts?.info.assetLocalIdentifier ?? ""
        )
    }

    /// Piste vidéo d'un rush et ses caractéristiques mesurées — matière
    /// COMMUNE à la composition (§54) et au résumé avant export (§56), lue
    /// une seule fois par case.
    ///
    /// `asset` est conservé VOLONTAIREMENT : `AVAssetTrack.asset` est une
    /// référence FAIBLE. Sans cette propriété, l'`AVURLAsset` local de
    /// `loadClipFacts` serait libéré à la sortie de la fonction et la piste
    /// rendue inutilisable au moment de l'insertion.
    private struct ClipFacts {
        let asset: AVURLAsset
        let sourceTrack: AVAssetTrack
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let info: MasterClipInfo
    }

    /// Résout un rush et mesure tout ce dont §52 et §54 ont besoin, SANS
    /// rien insérer (§54, étapes 1 à 3) :
    /// 1. résoudre l'asset (URL locale — aucun `AVAsset` ne traverse de
    ///    frontière d'acteur, §8) ; un rush recomposé par Photos
    ///    (ralenti/timelapse, §52.3) est matérialisé dans le `temp/` du
    ///    projet par `MediaLibraryActor.exportableVideoURL` ;
    /// 2. **vérifier la durée RÉELLE** : un rush devenu plus court que sa case
    ///    (ou introuvable) est refusé — §51 « aucun écran noir n'est ajouté »,
    ///    donc JAMAIS de complétion par du noir ;
    /// 3. sélectionner la piste vidéo principale et lire géométrie, cadence
    ///    de lecture et capacité HDR (§52.2/§52.3/§52.4).
    ///
    /// Sortie d'erreur UNIQUE : `ClipLoadFailure` (interne — l'appelant
    /// décide entre TRONCATURE §66 et échec) ou `ExportError.cancelled` (§58).
    private func loadClipFacts(
        slot: ProjectSlot,
        appearanceOrder: Int,
        projectID: UUID
    ) async throws -> ClipFacts {
        guard let assignment = slot.assignment else {
            // Filtré par le calcul de la timeline : jamais atteint.
            throw ExportError.emptyPrefix
        }
        let identifier = assignment.assetLocalIdentifier

        do {
            // §44 : `allowNetwork: false` — une case `ready` a déjà été
            // résolue ; un export ne déclenche jamais un téléchargement iCloud
            // surprise (§66 : « asset en téléchargement : export limité avant lui »).
            let url = try await mediaLibrary.exportableVideoURL(
                id: identifier,
                allowNetwork: false,
                intermediateDirectory: fileStore.subdirectoryURL(.temp, for: projectID)
            )
            let asset = AVURLAsset(url: url)

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceTrack = videoTracks.first else {
                // §64 : piste vidéo absente — refus STRUCTUREL, jamais une
                // troncature silencieuse.
                throw ClipLoadFailure(identifier: identifier, truncatesPlan: false)
            }

            // §54 étape 2 + §70 « Durée d'asset » : la durée RÉELLE, jamais la
            // métadonnée PhotoKit (« métadonnée arrondie mais durée réelle
            // insuffisante »). La durée exigée est celle de la CASE
            // (`end - start`), indépendante de sa position dans le montage.
            let assetDuration = try await asset.load(.duration)
            let slotDuration = slot.duration.cmTime // frontière §9
            guard assetDuration.isNumeric, assetDuration >= slotDuration else {
                // Rush devenu trop court : refus STRUCTUREL (§43/§64 le
                // refusent déjà à l'association) — pas une indisponibilité.
                throw ClipLoadFailure(identifier: identifier, truncatesPlan: false)
            }

            let naturalSize = try await sourceTrack.load(.naturalSize)
            let preferredTransform = try await sourceTrack.load(.preferredTransform)
            // §52.3 : cadence de LECTURE de la piste. Deux cas :
            // - rush ralenti RECOMPOSÉ par Photos : la source matérialisée par
            //   `exportableVideoURL` porte déjà le montage appliqué, donc la
            //   cadence de lecture — « respecter la cadence de lecture, pas
            //   seulement la cadence de capture ralentie » ;
            // - rush livré comme fichier de capture 120/240 i/s : la cadence
            //   est PLAFONNÉE à 60 par `MasterProfile` (§52.3 : « ne pas
            //   exporter à 120/240 i/s », « ne pas appliquer de flux
            //   optique »).
            let nominalFrameRate = Double(try await sourceTrack.load(.nominalFrameRate))
            // §52.4 : capacité HDR de la piste (même lecture qu'à la
            // résolution §43, `MediaLibraryActor`).
            let isHDR = ((try? await sourceTrack.load(.mediaCharacteristics)) ?? [])
                .contains(.containsHDRVideo)

            // Dimensions ORIENTÉES (§49 étape 2) : le classement §52.2 porte
            // sur ce qui est affiché, jamais sur le buffer capteur.
            let orientedSize = GeometryLock.orientedSize(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform
            )

            return ClipFacts(
                asset: asset,
                sourceTrack: sourceTrack,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                info: MasterClipInfo(
                    assetLocalIdentifier: identifier,
                    orientedWidth: Int(orientedSize.width.rounded()),
                    orientedHeight: Int(orientedSize.height.rounded()),
                    nominalFrameRate: nominalFrameRate,
                    isHDR: isHDR,
                    appearanceOrder: appearanceOrder
                )
            )
        } catch is CancellationError {
            throw ExportError.cancelled // §58
        } catch let failure as ClipLoadFailure {
            throw failure
        } catch let error as ExportError {
            throw error
        } catch let error as MediaLibraryError {
            // §40/§44/§64 : la cause exacte est journalisée ; elle décide
            // aussi du traitement — INDISPONIBILITÉ (accès refusé, rush
            // encore dans iCloud, rush supprimé) → troncature §66 ;
            // refus structurel → échec explicite.
            logger.error("Rush indisponible à l'export (\(identifier)) : \(error)")
            throw ClipLoadFailure(
                identifier: identifier,
                truncatesPlan: Self.truncatesPlan(error)
            )
        } catch {
            // Cause inconnue (lecture AVFoundation en échec) : jamais
            // interprétée comme une indisponibilité — l'export échoue et dit
            // QUELLE case est en cause.
            logger.error("Rush illisible à l'export (\(identifier)) : \(error.localizedDescription)")
            throw ClipLoadFailure(identifier: identifier, truncatesPlan: false)
        }
    }

    /// Insère la vidéo d'une case dans la piste de composition (§54, étapes
    /// 4 et 5) :
    /// 4. insérer `[0, slotDuration]` à `compositionStart`, c'est-à-dire à la
    ///    position de la case dans le montage concaténé
    ///    (`position du run + slot.start - run.musicStart`, §53) — aucun clip
    ///    n'est avancé pour combler un trou (les trous sont SUPPRIMÉS), et
    ///    l'écart entre deux cases d'un même run reste exactement celui de la
    ///    musique ;
    /// 5. ignorer les pistes audio source (aucune piste audio de rush n'est
    ///    créée : la seule piste audio est la musique du projet).
    ///
    /// La durée réelle a déjà été vérifiée par `loadClipFacts` (§54 étape 2).
    private func insertVideo(
        facts: ClipFacts,
        slot: ProjectSlot,
        compositionStart: MediaTime,
        into videoTrack: AVMutableCompositionTrack
    ) throws -> Segment {
        // §13.3 V1 : `sourceStart` vaut toujours 0 → `[0, slotDuration]`.
        let slotDuration = slot.duration.cmTime           // frontière §9
        let insertionTime = compositionStart.cmTime       // frontière §9
        do {
            try videoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: slotDuration),
                of: facts.sourceTrack,
                at: insertionTime
            )
        } catch {
            logger.error(
                "Insertion impossible pour le rush "
                + "\(facts.info.assetLocalIdentifier) : \(error.localizedDescription)"
            )
            throw ExportError.assetUnavailable(facts.info.assetLocalIdentifier)
        }
        return Segment(
            timeRange: CMTimeRange(start: insertionTime, duration: slotDuration),
            naturalSize: facts.naturalSize,
            preferredTransform: facts.preferredTransform,
            assetIdentifier: facts.info.assetLocalIdentifier
        )
    }

    /// Insère les portions de musique du montage (§53) : pour chaque RUN, le
    /// passage `[sourceStart, sourceStart + duration]` du morceau posé à la
    /// position de composition du run.
    ///
    /// Changement produit : il y a UNE portion par zone remplie, et non plus
    /// une seule portion continue. Les passages couverts par des cases vides
    /// n'existent PAS dans le fichier exporté — c'est la demande « n'exporte
    /// que les parties avec de la vidéo ». La musique est donc continue à
    /// l'intérieur d'un run et SAUTE à chaque jonction : conséquence assumée.
    /// Les portions sont JOINTIVES dans la composition (la position d'un run
    /// est la somme des durées des précédents) : la piste audio n'a aucun
    /// trou, et le montage ne commence jamais par du silence.
    ///
    /// La source est l'ORIGINAL inchangé (§11 `audio/original.<ext>`, §16.1 :
    /// « Conserver le fichier original inchangé pour la lecture et
    /// l'export ») — jamais le flux d'analyse normalisé (§16.2).
    ///
    /// Rend la fin de la piste musicale dans la composition.
    @discardableResult
    private func insertMusic(
        projectID: UUID,
        insertions: [MusicInsertion],
        into composition: AVMutableComposition
    ) async throws -> CMTime {
        guard insertions.contains(where: { $0.duration.ticks > 0 }) else {
            throw ExportError.emptyPrefix
        }
        guard let audioURL = fileStore.audioFileURL(projectID: projectID) else {
            throw ExportError.missingAudio
        }

        do {
            let audioAsset = AVURLAsset(url: audioURL)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = audioTracks.first,
                  let musicTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                throw ExportError.missingAudio
            }

            let audioDuration = try await audioAsset.load(.duration)
            var musicEnd = CMTime.zero
            for insertion in insertions {
                // Frontière §9 : conversion en `CMTime` seulement ici.
                var sourceRange = CMTimeRange(
                    start: insertion.sourceStart.cmTime,
                    duration: insertion.duration.cmTime
                )
                if audioDuration.isNumeric, sourceRange.end > audioDuration {
                    // Garde-fou : musique remplacée hors application. Jamais
                    // attendu — les cases sont engendrées À PARTIR de cette
                    // musique (§28).
                    sourceRange = CMTimeRange(start: sourceRange.start, end: audioDuration)
                }
                guard sourceRange.duration > .zero else {
                    // Portion entièrement hors du fichier : la musique s'arrête
                    // là. Les portions suivantes ne sont PAS insérées — elles
                    // tomberaient après un trou et désynchroniseraient tout ce
                    // qui suit.
                    break
                }
                try musicTrack.insertTimeRange(
                    sourceRange,
                    of: sourceTrack,
                    at: insertion.compositionStart.cmTime
                )
                let insertedRange = CMTimeRange(
                    start: insertion.compositionStart.cmTime,
                    duration: sourceRange.duration
                )
                musicEnd = CMTimeMaximum(musicEnd, insertedRange.end)
            }
            guard musicEnd > .zero else { throw ExportError.missingAudio }
            return musicEnd
        } catch is CancellationError {
            throw ExportError.cancelled
        } catch let error as ExportError {
            throw error
        } catch {
            logger.error("Musique illisible à l'export : \(error.localizedDescription)")
            throw ExportError.missingAudio
        }
    }

    // MARK: - Plan de rendu au profil maître (§50, §52, §54.6/§54.7)

    /// Composition vidéo au PROFIL MAÎTRE : taille de rendu et cadence issues
    /// de §52, colorimétrie EXPLICITE §52.4, et une instruction par case
    /// portant la transformation crop-to-fill de SON rush (§50).
    ///
    /// **Colorimétrie §52.4 — jamais implicite.** Les trois propriétés
    /// colorimétriques de la composition sont renseignées dans TOUS les cas :
    /// - profil SDR : Rec.709 (primaires, fonction de transfert, matrice).
    ///   Si des sources sont HDR, c'est CETTE déclaration qui impose la
    ///   conversion — le tone mapping HDR→SDR est alors demandé
    ///   explicitement, conformément à §52.4 (« appliquer un tone mapping
    ///   explicite en cas de conversion, ne pas se fier à un comportement
    ///   implicite non testé ») ;
    /// - profil HDR : Rec.2020 + HLG — branche CONSERVÉE mais **inatteignable
    ///   en V1** : `MasterProfileSelector.allowsHDROutput` vaut `false`, car
    ///   aucun preset §55 ne garantit une sortie HDR (voir la constante). La
    ///   sortie est donc toujours SDR cohérente, tone mapping explicite
    ///   compris — c'est le choix HONNÊTE tant que le chemin HDR n'a pas été
    ///   vérifié sur matériel réel, et il devient exact le jour où l'export
    ///   passera à `AVAssetReader`/`AVAssetWriter` (§55, V2).
    private func makeVideoComposition(
        segments: [Segment],
        videoTrack: AVMutableCompositionTrack,
        profile: MasterProfile,
        totalDuration: CMTime
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = profile.renderSize   // §52.1
        videoComposition.frameDuration = profile.frameDuration // §52.2/§52.3

        if profile.isHDR {
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        } else {
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }

        // §54.8 : fond opaque cohérent — le crop-to-fill ne laisse
        // normalement aucun pixel découvert.
        let opaqueBackground = CGColor(gray: 0, alpha: 1)
        var instructions: [AVMutableVideoCompositionInstruction] = []

        // AVFoundation exige des instructions couvrant TOUTE la durée, sans
        // trou ni recouvrement. Chaque intervalle découvert reçoit une
        // instruction de fond opaque — JAMAIS un clip avancé (les clips ne
        // sont jamais déplacés les uns par rapport aux autres ; §53 : la
        // musique reste l'horloge maîtresse). Les cases d'un RUN sont
        // jointives par construction (§28.1), la position d'un run est la
        // somme des durées des runs précédents et la première case tombe
        // exactement à zéro : les instructions couvrent donc
        // `[0, durée totale]` sans trou, jonctions comprises. Cette boucle est
        // une ceinture de sécurité.
        var coveredUntil = CMTime.zero
        for segment in segments {
            if segment.timeRange.start > coveredUntil {
                instructions.append(makeBackgroundInstruction(
                    from: coveredUntil,
                    to: segment.timeRange.start,
                    color: opaqueBackground
                ))
            }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = segment.timeRange
            instruction.backgroundColor = opaqueBackground

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            // §50/§54.7 : orientation, échelle et translation en UNE seule
            // transformation, posée au début de la plage.
            layerInstruction.setTransform(
                GeometryLock.cropToFillTransform(
                    naturalSize: segment.naturalSize,
                    preferredTransform: segment.preferredTransform,
                    renderSize: profile.renderSize
                ),
                at: .zero
            )
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)

            coveredUntil = CMTimeMaximum(coveredUntil, segment.timeRange.end)
        }

        if totalDuration.isNumeric, totalDuration > coveredUntil {
            instructions.append(makeBackgroundInstruction(
                from: coveredUntil,
                to: totalDuration,
                color: opaqueBackground
            ))
        }

        videoComposition.instructions = instructions
        return videoComposition
    }

    /// Instruction de fond opaque sans calque (§54.8).
    private func makeBackgroundInstruction(
        from start: CMTime,
        to end: CMTime,
        color: CGColor
    ) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: start, end: end)
        instruction.backgroundColor = color
        instruction.layerInstructions = []
        return instruction
    }

    // MARK: - §55 Encodage

    /// Presets candidats, du meilleur au repli (§55 : « le preset de plus
    /// haute qualité compatible avec le profil maître »).
    ///
    /// - **`AVAssetExportPresetHEVCHighestQuality`** est le choix principal :
    ///   c'est le seul preset de la famille « plus haute qualité » qui
    ///   respecte la `renderSize` de la composition vidéo ET qui encode en
    ///   10 bits (indispensable pour une sortie HDR §52.4).
    /// - **`AVAssetExportPresetHighestQuality`** (H.264) sert de repli
    ///   UNIQUEMENT en SDR. En HDR il n'est PAS proposé : un repli 8 bits
    ///   produirait une image fausse tout en annonçant du HDR — mieux vaut un
    ///   échec explicite (§3 : jamais de résultat silencieusement dégradé).
    /// - **Le passthrough est impossible ici** (`AVAssetExportPresetPassthrough`) :
    ///   la composition applique un recadrage, une mise à l'échelle et une
    ///   cadence de rendu (§50, §52) — les pixels DOIVENT être ré-encodés.
    ///   §55 : « une seule ré-encodage final ».
    ///
    /// En V1 la branche HDR est INATTEIGNABLE
    /// (`MasterProfileSelector.allowsHDROutput == false`, §52.4) : c'est
    /// précisément parce qu'AUCUN de ces presets ne garantit une sortie HDR
    /// que la V1 rend en SDR. La branche est conservée pour la V2 §55
    /// (`AVAssetReader`/`AVAssetWriter`).
    static func candidatePresets(for profile: MasterProfile) -> [String] {
        profile.isHDR
            ? [AVAssetExportPresetHEVCHighestQuality]
            : [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
    }

    // MARK: Boîtes de transfert Swift 6 (paramètres `sending`)

    // Non defini par la specification — outil de concurrence V1.
    /// Boîte de transfert des objets de composition vers les API `sending`
    /// d'`AVAssetExportSession` (§55).
    ///
    /// `AVAssetExportSession(asset:presetName:)` prend son asset en paramètre
    /// **`sending`** : il exige une valeur dont la région est DÉCONNECTÉE.
    /// Ici la composition arrive en PARAMÈTRE de fonction — sa région est
    /// celle de l'appelant, donc non détachée — et une simple copie ne suffit
    /// pas : une valeur produite localement reste rattachée à la région dont
    /// elle dérive (diagnostic « sending value of non-Sendable type »,
    /// exactement l'échec CI corrigé par les commits 57076c9 et 1933acb).
    /// **Traverser une valeur `Sendable` est le seul moyen de détacher la
    /// région** : c'est l'idiome validé par `PreviewCache.AssetBox`, repris
    /// ici tel quel — la valeur est EXTRAITE de la boîte juste avant l'appel.
    ///
    /// Sûreté par CONTRAT D'USAGE : les deux objets encapsulés sont IMMUABLES
    /// (`AVComposition`/`AVVideoComposition`, copies figées des versions
    /// mutables de travail — plus aucune mutation possible pendant
    /// l'encodage) et ne sont lus que sur `@MainActor`, où vit tout
    /// l'exporteur (§8).
    private struct AssetBox: @unchecked Sendable {
        let composition: AVComposition
        let videoComposition: AVVideoComposition
    }

    // Non defini par la specification — outil de concurrence V1.
    /// Boîte de transfert de la session d'encodage (§55, §58).
    ///
    /// Deux besoins la rendent nécessaire :
    /// - le suivi de progression §58 doit être AUTO-SUFFISANT : la séquence
    ///   `states(updateInterval:)` est un type opaque non-`Sendable` dérivé
    ///   de la session ; la capturer depuis l'extérieur de la `Task` la
    ///   ferait traverser une frontière d'isolation. La tâche ne capture donc
    ///   que CETTE boîte (et la fermeture `@Sendable` de progression) et crée
    ///   la séquence elle-même ;
    /// - `withTaskCancellationHandler(onCancel:)` (§58) exécute son bloc
    ///   `@Sendable` HORS `@MainActor`, potentiellement sur le fil de
    ///   l'annulateur : il ne peut donc toucher QUE cette boîte.
    ///
    /// Sûreté par CONTRAT D'USAGE : la session n'est plus CONFIGURÉE après sa
    /// mise en boîte (preset, `videoComposition` et options sont posés
    /// avant) ; seules l'observation d'état, le lancement de l'export et
    /// `cancelExport()` ont lieu ensuite — `cancelExport()` est justement
    /// prévue pour interrompre un export depuis un autre contexte
    /// d'exécution.
    private struct SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
    }

    /// Encode la composition (§55) et rend l'URL du fichier FINAL dans
    /// `exports/` (§11).
    ///
    /// Fichier temporaire UNIQUE dans `temp/` du projet (§55), supprimé dans
    /// tous les cas (§57 : « nettoyer les fichiers temporaires après
    /// succès/échec »). Le fichier n'apparaît dans `exports/` qu'après un
    /// succès COMPLET (§58 : « ne créer aucun asset Photos incomplet » — la
    /// même règle vaut pour le fichier livrable).
    private func encode(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        profile: MasterProfile,
        projectID: UUID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let temporaryDirectory = fileStore.subdirectoryURL(.temp, for: projectID)
        let exportsDirectory = fileStore.subdirectoryURL(.exports, for: projectID)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: exportsDirectory, withIntermediateDirectories: true
            )
        } catch {
            throw ExportError.exportFailed(error.localizedDescription)
        }

        // Nom unique : deux exports simultanés du même projet sont interdits
        // (§58, garanti par `ExportActor`), mais un temporaire résiduel d'une
        // session tuée ne doit jamais être écrasé « à moitié ».
        let temporaryURL = temporaryDirectory
            .appending(path: "export-\(UUID().uuidString).\(Self.outputFileExtension)")
        // §57 : nettoyage du temporaire sur TOUS les chemins de sortie
        // (succès — où il a déjà été déplacé —, échec et annulation).
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        // §55 : copies IMMUABLES des objets de travail, portées par une boîte
        // `Sendable` — c'est cette traversée qui DÉTACHE la région exigée par
        // les paramètres `sending` d'`AVAssetExportSession` (voir `AssetBox`).
        guard let immutableComposition = composition.copy() as? AVComposition,
              let immutableVideoComposition = videoComposition.copy() as? AVVideoComposition else {
            throw ExportError.exportFailed("Composition d'export impossible à figer.")
        }
        let assets = AssetBox(
            composition: immutableComposition,
            videoComposition: immutableVideoComposition
        )

        var createdSession: AVAssetExportSession?
        for preset in Self.candidatePresets(for: profile) {
            // Asset EXTRAIT de la boîte au point d'appel : la valeur lue
            // depuis un type `Sendable` est dans une région déconnectée.
            if let candidate = AVAssetExportSession(asset: assets.composition, presetName: preset) {
                createdSession = candidate
                logger.info("Encodage §55 avec le preset \(preset).")
                break
            }
        }
        guard let session = createdSession else {
            throw ExportError.exportFailed(
                "Aucun preset d'encodage compatible avec le profil maître."
            )
        }
        // Même exigence `sending` pour le plan de rendu : même extraction.
        session.videoComposition = assets.videoComposition
        session.shouldOptimizeForNetworkUse = false // fichier local, jamais streamé

        // La session est CONFIGURÉE : elle passe en boîte, et c'est la boîte
        // seule qui circule ensuite (progression §58, annulation §58).
        let sessionBox = SessionBox(session: session)

        // §58 : progression publiée pendant l'encodage. API iOS 18+
        // `states(updateInterval:)` — les propriétés `progress`/`status`
        // dépréciées ne sont PAS utilisées. La tâche est AUTO-SUFFISANTE :
        // elle ne capture que la boîte `Sendable` et la fermeture `@Sendable`
        // de progression, et crée la séquence d'états elle-même. Aucune
        // valeur non-`Sendable` (session, séquence opaque) ne traverse de
        // frontière d'isolation.
        let updateInterval = Self.progressUpdateInterval
        let monitor = Task { [sessionBox, progress] in
            for await state in sessionBox.session.states(updateInterval: updateInterval) {
                if case .exporting(let sessionProgress) = state {
                    progress(min(max(sessionProgress.fractionCompleted, 0), 1))
                }
            }
        }
        defer { monitor.cancel() }

        do {
            try checkCancellation()
            // §58 : « permettre annulation ». L'annulation doit atteindre
            // l'ENCODEUR, pas seulement la tâche Swift : sans ce gestionnaire,
            // `cancelExport()` n'était appelé qu'APRÈS le retour de l'`await`,
            // c'est-à-dire jamais tant qu'AVFoundation encodait. `onCancel`
            // s'exécute DÈS l'annulation, `@Sendable` et hors `@MainActor` :
            // il ne touche donc que la boîte.
            try await withTaskCancellationHandler {
                // API iOS 18+ : `export(to:as:)` remplace
                // `exportAsynchronously(completionHandler:)` (déprécié).
                try await sessionBox.session.export(to: temporaryURL, as: Self.outputFileType)
            } onCancel: {
                sessionBox.session.cancelExport()
            }
        } catch {
            // §58 : annulation → session annulée (idempotent : `onCancel` a
            // déjà pu le faire), temporaire supprimé (defer), aucun fichier
            // dans `exports/`, aucun asset Photos.
            sessionBox.session.cancelExport()
            if Task.isCancelled || error is CancellationError {
                throw ExportError.cancelled
            }
            throw ExportError.exportFailed(error.localizedDescription)
        }

        // Une annulation arrivée pendant les toutes dernières images ne doit
        // pas livrer un fichier que l'utilisateur croit avoir annulé.
        try checkCancellation()

        let finalURL = Self.uniqueOutputURL(in: exportsDirectory, date: .now)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            throw ExportError.exportFailed(error.localizedDescription)
        }
        // §11/§57 : un seul export conservé par projet — les fichiers des
        // relances précédentes sont supprimés APRÈS le déplacement, jamais
        // avant (le projet n'est à aucun instant sans export livrable). C'est
        // aussi ce qui rend `ProjectFileStore.lastExportURL` sans ambiguïté
        // (§60).
        let prunedCount = fileStore.pruneExports(projectID: projectID, keeping: finalURL)
        if prunedCount > 0 {
            logger.info("Exports précédents supprimés (§11/§57) : \(prunedCount).")
        }
        return finalURL
    }

    /// URL de sortie dans `exports/` (§11).
    ///
    /// Nom horodaté TRIABLE (`Montage-20260810-112433.mov`) : le fichier le
    /// plus récent d'`exports/` est le « dernier export réussi » que §60
    /// demande de restaurer — aucune colonne n'existe pour lui dans le schéma
    /// §10 (verbatim), le fichier EST la trace durable.
    ///
    /// Un suffixe court est ajouté si un fichier de la même seconde existe
    /// déjà : un export précédent n'est JAMAIS écrasé.
    static func uniqueOutputURL(in directory: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "Montage-\(formatter.string(from: date))"

        var candidate = directory.appending(path: "\(base).\(outputFileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: "\(base)-\(suffix).\(outputFileExtension)")
            suffix += 1
        }
        return candidate
    }

    // MARK: - §58 Annulation coopérative

    /// Traduit l'annulation de la tâche en `ExportError.cancelled` : l'export
    /// ne laisse échapper QUE des `ExportError`, jamais un `CancellationError`
    /// nu que l'interface devrait deviner (§58 : l'interruption est annoncée).
    private func checkCancellation() throws {
        if Task.isCancelled { throw ExportError.cancelled }
    }
}

// MARK: - Protocole §7

// La conformance formelle à `ProjectExporting` (§7) est volontairement
// ABSENTE — même choix documenté qu'au Jalon 9 pour `PreviewBuilding` : le
// protocole §7 est NON isolé, alors que l'exporteur doit être `@MainActor`
// (les objets AVFoundation manipulés ne sont pas `Sendable`). En Swift 6
// strict, un témoin `@MainActor` ne peut pas satisfaire une exigence de
// protocole non isolée ; `@preconcurrency` ne ferait que rétrograder la
// vérification sans traiter l'écart, et une conformance isolée
// (`extension ProjectExporter: @MainActor ProjectExporting {}`, SE-0470)
// dépend du mode de langage retenu.
// `export(project:scope:progress:)` conserve la SIGNATURE EXACTE du protocole
// §7 : la conformance pourra être rétablie sans toucher à l'implémentation le
// jour où un consommateur générique (`any ProjectExporting`) existera. Aucun
// appelant n'en utilise aujourd'hui.
