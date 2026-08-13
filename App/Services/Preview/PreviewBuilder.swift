//
//  PreviewBuilder.swift
//  MontageMusical
//
//  Constructeur de compositions de prévisualisation — spec §47 (portées),
//  §48 (composition), §50 (crop-to-fill), §53 (exactitude temporelle : la
//  musique est l'horloge maîtresse), §54 (composition slot par slot).
//
//  Protocole §7 `PreviewBuilding`.
//
//  CHANGEMENT PRODUIT (contrat complet dans `ExportModels.swift`) : l'aperçu
//  principal §47.2 n'est plus celui du PRÉFIXE, ni celui d'un SEGMENT unique,
//  mais celui de la TIMELINE CONCATÉNÉE — toutes les zones remplies mises
//  bout à bout, les cases vides étant SUPPRIMÉES (vidéo ET musique).
//
//  Conséquences pour ce fichier :
//  - une insertion de musique PAR RUN (et non une par case : inutile, et cela
//    multiplierait les coupures audio à l'intérieur d'une zone remplie) :
//    portion `[run.musicStart, run.musicEnd]` posée à la position de
//    composition du run ;
//  - la vidéo de la case `i` est posée à
//    `(position du run) + (slot.start - run.musicStart)` ;
//  - les instructions de rendu couvrent `[0, durée totale]` sans trou.
//  Les cases gardent leurs temps musicaux ABSOLUS — aucune n'est déplacée,
//  aucun écran noir n'est ajouté. La musique SAUTE à chaque jonction entre
//  runs : conséquence assumée de « n'exporte que les parties avec de la
//  vidéo ».
//
//  ─────────────────────────────────────────────────────────────────────
//  CE QUE L'APERÇU PROMET — ET CE QU'IL NE PROMET PAS
//  ─────────────────────────────────────────────────────────────────────
//
//  **Identique à l'export** : le DÉCOUPAGE. Les positions de composition et
//  les portions de musique viennent des MÊMES fonctions du domaine
//  (`ReadyTimeline.placements` / `.musicInsertions`) que celles que consomme
//  `ProjectExporter.assemble` — un seul calcul, donc les mêmes instants, les
//  mêmes coupes, la même durée. La résolution des rushs suit elle aussi le
//  chemin de l'export (`MediaLibraryActor.exportableVideoURL`), pour qu'un
//  rush recomposé par Photos (ralenti, timelapse, §52.3) soit visible à
//  l'aperçu exactement comme il sera exporté, et non refusé — seul le dossier
//  d'accueil du fichier intermédiaire diffère (`previews/` ici, `temp/` à
//  l'export, pour la raison expliquée sur `insertVideo`).
//
//  **DIFFÉRENT de l'export** : le RENDU. L'aperçu rend à une cadence de
//  travail (1/30) et dimensionne sur le premier rush de la portée, là où
//  l'export applique le PROFIL MAÎTRE §52 (résolution, cadence exacte
//  29,97/59,94, colorimétrie §52.4) puis ré-encode (§55). L'aperçu montre donc
//  le MONTAGE qui sera exporté, jamais l'IMAGE finale au pixel près : aucune
//  promesse de « fichier exact » n'est faite ici.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

// MARK: - Erreurs de prévisualisation

// Non defini par la specification — definition minimale V1.
/// Erreurs de construction d'une prévisualisation (§47, §48, §51, §64).
///
/// Aucun de ces cas ne modifie le projet : une prévisualisation impossible
/// laisse le montage strictement intact (§51 : « les clips ultérieurs ne sont
/// jamais déplacés » ; §64 : jamais de perte silencieuse d'association).
enum PreviewError: Error, Equatable, LocalizedError {

    /// Portée vide : aucune case à lire — case introuvable ou non remplie
    /// (§47.1), ou TIMELINE exportable vide car AUCUNE case n'est prête
    /// (§47.2 ; changement produit : des cases vides ne vident plus la portée,
    /// elles sont simplement supprimées du montage — seule l'absence TOTALE de
    /// case prête laisse la portée vide).
    case emptyScope

    /// Musique du projet introuvable ou illisible (§11 `audio/original.<ext>`,
    /// §16.1 : l'original est conservé inchangé pour la lecture et l'export).
    /// Sans musique il n'y a pas d'horloge maîtresse (§53) : aucune
    /// prévisualisation n'est produite.
    case missingAudio

    /// Rush indisponible à la lecture (§64 : asset supprimé, sans piste
    /// vidéo, ou plus court que la case). La chaîne contient l'identifiant
    /// local du rush concerné.
    ///
    /// Ne couvre PAS l'accès refusé ni l'attente iCloud : ces deux causes ont
    /// leur propre cas, car elles appellent une action utilisateur
    /// DIFFÉRENTE (§64 : « accès refusé : écran explicatif + Réglages » /
    /// « iCloud hors réseau : permettre réessai »).
    case assetUnavailable(String)

    /// §40/§64 : accès à la photothèque refusé ou restreint. Le montage est
    /// intact, seule la lecture est impossible — l'utilisateur est renvoyé
    /// vers Réglages, jamais bloqué dans l'application (§40).
    case accessDenied

    /// §44/§64 : le rush est encore dans iCloud et n'a pas pu être résolu
    /// sans réseau (`allowNetwork: false` : une prévisualisation ne déclenche
    /// jamais un téléchargement surprise). Réessai possible une fois la case
    /// réellement résolue (§44 : « ne la considérer prête pour
    /// prévisualisation/export qu'après résolution complète »).
    case icloudUnavailable(String)

    /// Portée `.complete` demandée alors que le montage n'est pas terminé :
    /// au moins une case reste vide, en téléchargement ou indisponible —
    /// autrement dit la TIMELINE prête ne couvre pas TOUTES les cases
    /// (§47.2). L'appelant se rabat sur `.contiguousPrefix`. Nom du cas
    /// conservé pour ne pas casser ses appelants.
    case incompletePrefix

    var errorDescription: String? {
        switch self {
        case .emptyScope:
            return "Il n'y a rien à prévisualiser pour l'instant : "
                + "remplissez au moins une case du montage."
        case .missingAudio:
            return "La musique du projet est introuvable ou illisible. "
                + "Réimportez la musique pour prévisualiser le montage."
        case .assetUnavailable(let identifier):
            return "Une vidéo du montage n'est plus lisible "
                + "(\(identifier)). Remplacez-la pour prévisualiser cette partie."
        case .accessDenied:
            return "L'accès à la photothèque est refusé. "
                + "Autorisez l'accès à vos photos dans Réglages pour prévisualiser le montage."
        case .icloudUnavailable(let identifier):
            return "Une vidéo du montage est encore dans iCloud "
                + "(\(identifier)). Attendez la fin de son téléchargement, puis réessayez."
        case .incompletePrefix:
            // Le montage n'est plus un « début » : c'est la concaténation de
            // toutes les zones prêtes, où qu'elles se trouvent dans le
            // morceau. Le message ne doit plus parler de début.
            return "Le montage n'est pas encore complet. "
                + "Prévisualisez les zones déjà prêtes, ou remplissez les cases restantes."
        }
    }
}

extension PreviewError {

    /// Traduit une erreur de photothèque en erreur de prévisualisation
    /// (§40, §44, §64) — jamais d'aplatissement en `assetUnavailable` : une
    /// autorisation refusée et un rush effacé n'appellent pas la même action.
    ///
    /// Le `switch` est EXHAUSTIF sans `default` : un nouveau cas de
    /// `MediaLibraryError` fera échouer la compilation ici plutôt que de
    /// glisser silencieusement vers le message générique (§64).
    static func fromMediaLibrary(_ error: MediaLibraryError, assetIdentifier: String) -> PreviewError {
        switch error {
        case .accessDenied:
            // §40 : expliquer et proposer Réglages.
            .accessDenied
        case .icloudUnavailable:
            // §44/§64 : réessai possible.
            .icloudUnavailable(assetIdentifier)
        case .assetNotFound, .noVideoTrack, .assetTooShort, .albumNotFound:
            // §64 : asset supprimé, sans piste vidéo, ou trop court — le rush
            // doit être remplacé. (`albumNotFound` n'est pas atteignable
            // depuis la résolution d'un asset ; il est cité pour l'exhaustivité.)
            .assetUnavailable(assetIdentifier)
        }
    }
}

// MARK: - Constructeur de prévisualisation (§7, §47, §48)

/// Construit la composition d'une portée de prévisualisation (§47, §48).
///
/// **Composition mise en cache, item jetable (§48).** `makeComposition` rend
/// un `CachedComposition` IMMUABLE — c'est lui que `PreviewCache` conserve,
/// car le coût à éviter est l'assemblage des pistes (résolution PhotoKit,
/// chargement des pistes, insertions, transformations §50), pas la création
/// de l'`AVPlayerItem`. `makePreview` reste la porte d'entrée §7 : il
/// fabrique un item NEUF à partir de cette composition. Un `AVPlayerItem` ne
/// pouvant appartenir qu'à un seul `AVPlayer`, il ne doit JAMAIS être
/// partagé entre deux présentations.
///
/// **Conformance au protocole §7 — choix documenté.** Le protocole
/// `PreviewBuilding` (§7, verbatim) est NON isolé et rend un `AVPlayerItem`
/// non-`Sendable` : une conformance depuis ce type `@MainActor` est un écart
/// d'isolation en Swift 6 strict. La conformance formelle a donc été retirée
/// plutôt que rétrogradée par `@preconcurrency` (qui masquait la
/// vérification au lieu de traiter l'écart), et plutôt que déclarée isolée
/// (`extension PreviewBuilder: @MainActor PreviewBuilding {}`, SE-0470) dont
/// la disponibilité dépend du mode de langage retenu. `makePreview(for:scope:)`
/// garde la SIGNATURE EXACTE du protocole §7 : le jour où un consommateur
/// générique en aura besoin (moteur de remplacement §7), la conformance
/// pourra être rétablie sans toucher à l'implémentation. Aucun appelant
/// n'utilise `any PreviewBuilding` aujourd'hui.
///
/// **Isolation `@MainActor` — choix documenté (Swift 6 strict).**
/// Le protocole §7 renvoie un `AVPlayerItem`, qui n'est PAS `Sendable` (pas
/// plus que les `AVURLAsset`/`AVAssetTrack` utilisés en chemin). Un
/// constructeur non isolé devrait donc « envoyer » (`sending`) son résultat
/// vers l'appelant `@MainActor` — diagnostic Swift 6 « non-Sendable result
/// cannot cross actor boundary ». En isolant le constructeur sur
/// `@MainActor` :
/// - la vue de prévisualisation (`@MainActor`, §8 « les vues et view models
///   restent sur `@MainActor` ») appelle `makePreview` SANS aucune frontière
///   d'isolation à franchir, donc sans transfert d'objet non-`Sendable` ;
/// - l'`AVPlayerItem` est créé exactement là où il sera consommé
///   (`AVPlayer`/`VideoPlayer`), ce qui est de toute façon exigé par
///   AVFoundation côté lecture ;
/// - aucun objet AVFoundation ne traverse une frontière d'acteur : la
///   photothèque ne rend qu'une `URL` (`Sendable`) via
///   `MediaLibraryActor.exportableVideoURL(id:allowNetwork:intermediateDirectory:)`
///   — le MÊME chemin de résolution que l'export —, et chaque `AVURLAsset` est
///   reconstruit ici.
///
/// Le travail lourd reste hors du fil principal : les chargements
/// AVFoundation (`loadTracks`, `load(.duration)`, `load(.naturalSize)`) sont
/// des `await` qui suspendent, et l'assemblage d'un `AVMutableComposition`
/// est une manipulation de métadonnées (aucun décodage d'image).
///
/// Compositions (§48, §54) :
/// - `AVMutableComposition` avec UNE piste vidéo et UNE piste audio ;
/// - piste audio = musique ORIGINALE du projet (§11, §16.1), dont UNE PORTION
///   PAR RUN (`[run.musicStart, run.musicEnd]`) est insérée à la position de
///   composition du run — une seule portion pour un aperçu local §47.1 ;
/// - **aucune piste audio de rush** (§48, §54.5 : « ignorer les pistes audio
///   source ») ;
/// - chaque case insère `[0, slotDuration]` de la piste vidéo de son rush à
///   `(position du run) + (slot.start - run.musicStart)` (§53, §54.4) —
///   l'écart entre deux cases d'un même run reste celui de la musique, et
///   aucun clip n'est déplacé par rapport à ses voisins de run ;
/// - une instruction de composition par case, avec orientation + échelle +
///   translation (§50, §54.6/§54.7).
@MainActor
struct PreviewBuilder: Sendable {

    private let fileStore: ProjectFileStore
    private let mediaLibrary: MediaLibraryActor

    /// Cadence de rendu de la prévisualisation.
    ///
    /// 1/30 par défaut, valeur de travail : le **profil maître exact**
    /// (§52.2 clip maître, §52.3 cadences 29,97/59,94 préservées, plafond
    /// 60 i/s) est sélectionné au **Jalon 10**. La cadence de rendu
    /// n'influence ni les frontières de cases ni la synchronisation : les
    /// temps restent absolus en `MediaTime` (§9, §53).
    private static let defaultFrameDuration = CMTime(value: 1, timescale: 30)

    init(fileStore: ProjectFileStore, mediaLibrary: MediaLibraryActor) {
        self.fileStore = fileStore
        self.mediaLibrary = mediaLibrary
    }

    // MARK: - Signature §7 et composition mise en cache §48

    /// Construit la prévisualisation de la portée demandée (§47).
    ///
    /// Signature EXACTE du protocole §7. L'`AVPlayerItem` rendu est NEUF et
    /// destiné à un seul `AVPlayer` : ne jamais le conserver pour une autre
    /// présentation (c'est `makeComposition` qui alimente le cache §48).
    func makePreview(for project: ProjectSnapshot, scope: PreviewScope) async throws -> AVPlayerItem {
        try await makeComposition(for: project, scope: scope).makePlayerItem()
    }

    /// Assemble la composition IMMUABLE d'une portée (§47, §48) — objet mis
    /// en cache par `PreviewCache`, réutilisable par autant de présentations
    /// que nécessaire.
    func makeComposition(for project: ProjectSnapshot, scope: PreviewScope) async throws -> CachedComposition {
        switch scope {
        case .slot(let slotID):
            return try await makeSlotComposition(project: project, slotID: slotID)
        case .contiguousPrefix:
            return try await makeTimelineComposition(project: project, requiresCompleteMontage: false)
        case .complete:
            return try await makeTimelineComposition(project: project, requiresCompleteMontage: true)
        }
    }

    // MARK: - §47.1 Aperçu local (une case)

    /// Aperçu d'UNE case (§47.1) : « Disponible pour toute case remplie,
    /// même après un trou » — l'état des cases précédentes n'est jamais
    /// consulté ici.
    ///
    /// Lecture (§47.1) : la vidéo de la case, le passage musical
    /// correspondant, uniquement la plage de la case. La case commence donc
    /// à zéro dans la composition, mais la musique est prélevée à son temps
    /// ABSOLU `[slot.start, slot.end]` (§53 : la musique est l'horloge
    /// maîtresse — on entend exactement ce qu'on entendra dans le montage).
    private func makeSlotComposition(project: ProjectSnapshot, slotID: UUID) async throws -> CachedComposition {
        guard let slot = project.slots.first(where: { $0.id == slotID }),
              let assignment = slot.assignment else {
            throw PreviewError.emptyScope // case inconnue ou vide (§47.1)
        }
        guard assignment.status == .ready else {
            // `resolving`/`downloading`/`unavailable`/`tooShort` : rien de
            // lisible pour l'instant (§64). Le téléchargement iCloud en cours
            // est distingué : il se termine tout seul, l'utilisateur n'a rien
            // à remplacer (§44).
            if assignment.status == .downloading {
                throw PreviewError.icloudUnavailable(assignment.assetLocalIdentifier)
            }
            throw PreviewError.assetUnavailable(assignment.assetLocalIdentifier)
        }
        guard slot.duration.ticks > 0 else {
            throw PreviewError.emptyScope // §10.1 : `end > start` — jamais attendu
        }

        return try await assembleComposition(
            project: project,
            placements: [SlotPlacement(slot: slot, compositionStart: .zero)],
            // UNE seule portion de musique : le passage ABSOLU de la case,
            // posé à l'instant 0 (§47.1). L'aperçu local est INCHANGÉ par le
            // changement produit — il ne connaît ni run ni timeline.
            musicInsertions: [
                MusicInsertion(
                    sourceStart: slot.start,
                    duration: slot.duration,
                    compositionStart: .zero
                )
            ]
        )
    }

    // MARK: - §47.2 Aperçu principal (timeline concaténée)

    /// Aperçu principal (§47.2), **version changement produit** : c'est
    /// l'aperçu de la TIMELINE CONCATÉNÉE — toutes les zones remplies mises
    /// bout à bout, les cases vides ou non prêtes étant SUPPRIMÉES (vidéo ET
    /// musique). On prévisualise donc le MONTAGE qui sera exporté : mêmes
    /// coupes, mêmes instants, même durée (le rendu, lui, diffère — voir
    /// l'en-tête du fichier).
    ///
    /// La timeline vient de `readyTimeline(slots:)` — jamais recalculée ici.
    /// Chaque case garde son temps musical ABSOLU : aucune n'est réécrite
    /// (§3.12). Ce qui change, c'est la façon de POSER les portions, et ces
    /// positions sont LUES sur la timeline, jamais recomposées ici :
    /// - musique : UNE insertion PAR RUN (`timeline.musicInsertions`) —
    ///   portion `[run.musicStart, run.musicEnd]` du fichier original, posée à
    ///   la position de composition du run. Une insertion par CASE serait
    ///   inutile (les cases d'un run sont jointives) et multiplierait les
    ///   coupures audio à l'intérieur d'une zone remplie ;
    /// - vidéo : chaque case à l'instant que lui donne `timeline.placements`,
    ///   soit `.zero` pour la première case du premier run.
    ///
    /// On entend donc EXACTEMENT le passage musical de chaque zone remplie, et
    /// chaque coupe tombe au même endroit de la musique que dans le montage
    /// final (§53 : la musique est l'horloge maîtresse). La musique SAUTE aux
    /// jonctions entre runs : c'est la conséquence assumée de la suppression
    /// des zones vides.
    ///
    /// Portée `.complete` (`requiresCompleteMontage`) : identique à la
    /// timeline SI celle-ci couvre TOUTES les cases du projet ; sinon
    /// `incompletePrefix` — un montage complet ne peut pas être « presque
    /// complet », l'appelant retombe explicitement sur `.contiguousPrefix`
    /// (§47.2).
    private func makeTimelineComposition(
        project: ProjectSnapshot,
        requiresCompleteMontage: Bool
    ) async throws -> CachedComposition {
        let timeline = project.readyTimeline // changement produit
        // Complétude vérifiée AVANT la vacuité : demander le montage complet
        // d'un projet dont aucune case n'est prête est un montage
        // INCOMPLET (message « attendez la fin des téléchargements »), pas
        // une portée vide.
        if requiresCompleteMontage, timeline.slotCount != project.slots.count {
            throw PreviewError.incompletePrefix
        }
        guard !timeline.isEmpty else {
            throw PreviewError.emptyScope // aucune case prête
        }

        // Concaténation des runs : temps musicaux ABSOLUS conservés dans les
        // cases, position finale calculée en ticks entiers (§9) — jamais par
        // une réécriture des cases. Ces deux dérivations sont celles du
        // DOMAINE, littéralement les mêmes fonctions que consomme
        // `ProjectExporter.assemble` : l'aperçu et l'export ne peuvent pas
        // diverger, puisqu'il n'existe qu'UN calcul de positions.
        return try await assembleComposition(
            project: project,
            placements: timeline.placements,
            musicInsertions: timeline.musicInsertions
        )
    }

    // MARK: - Composition (§48, §54)

    // `SlotPlacement` (case + instant de composition) et `MusicInsertion`
    // (portion de musique posée à un instant) sont les types du DOMAINE
    // (`ExportModels.swift`) : l'aperçu principal les reçoit de
    // `ReadyTimeline.placements` / `.musicInsertions` — exactement comme
    // l'export — et l'aperçu local §47.1 en construit un seul, posé à l'instant
    // zéro. Aucun type local ne les duplique : deux définitions parallèles
    // seraient deux occasions de diverger.

    /// Segment vidéo inséré : plage occupée dans la composition et géométrie
    /// source, mémorisées pour construire les instructions (§54.6/§54.7)
    /// APRÈS avoir déterminé la taille de rendu.
    private struct Segment {
        let timeRange: CMTimeRange
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let assetIdentifier: String
    }

    /// Assemble la composition complète (§48) et rend le couple IMMUABLE
    /// mis en cache (§48) : pistes + plan de rendu géométrique.
    private func assembleComposition(
        project: ProjectSnapshot,
        placements: [SlotPlacement],
        musicInsertions: [MusicInsertion]
    ) async throws -> CachedComposition {
        guard !placements.isEmpty else { throw PreviewError.emptyScope }

        let composition = AVMutableComposition()

        // UNE seule piste vidéo pour toutes les cases : les plages sont
        // disjointes et chaque case reçoit sa propre instruction de
        // composition (§54.6). Aucune piste audio de rush n'est créée (§48).
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PreviewError.assetUnavailable(
                placements[0].slot.assignment?.assetLocalIdentifier ?? ""
            )
        }

        var segments: [Segment] = []
        segments.reserveCapacity(placements.count)
        for placement in placements {
            segments.append(try await insertVideo(
                placement,
                projectID: project.projectID,
                into: videoTrack
            ))
        }

        let musicEnd = try await insertMusic(
            projectID: project.projectID,
            insertions: musicInsertions,
            into: composition
        )

        // Durée réelle de la composition = fin de la piste la plus longue.
        // Elle borne les instructions de rendu, qui doivent couvrir TOUTE la
        // durée (voir `makeVideoComposition`).
        let videoEnd = segments.reduce(CMTime.zero) { CMTimeMaximum($0, $1.timeRange.end) }
        let totalDuration = CMTimeMaximum(videoEnd, musicEnd)

        let renderPlan = makeVideoComposition(
            project: project,
            segments: segments,
            videoTrack: videoTrack,
            totalDuration: totalDuration
        )

        // Copies IMMUABLES (`NSCopying`) : `AVMutableComposition.copy()` rend
        // une `AVComposition`, `AVMutableVideoComposition.copy()` une
        // `AVVideoComposition`. Ce sont ces instances figées qui sont mises
        // en cache et partagées par plusieurs `AVPlayerItem` successifs —
        // muter une composition pendant une lecture est un comportement
        // indéfini côté AVFoundation.
        let immutableRenderPlan: AVVideoComposition? = renderPlan.map { $0.copy() as! AVVideoComposition }
        return CachedComposition(
            asset: composition.copy() as! AVComposition,
            videoComposition: immutableRenderPlan
        )
    }

    /// Insère la vidéo d'une case (§54, étapes 1 à 5) :
    /// 1. résoudre l'asset (URL locale — l'`AVAsset` ne traverse aucune
    ///    frontière d'acteur) ;
    /// 2. vérifier la durée ;
    /// 3. sélectionner la piste vidéo principale ;
    /// 4. insérer `[0, slotDuration]` à `placement.compositionStart` (temps
    ///    absolu de la case RAMENÉ dans la timeline concaténée, §53) ;
    /// 5. ignorer les pistes audio source (§48 : aucune piste audio de rush).
    ///
    /// **Résolution ALIGNÉE sur l'export.** La preview passait autrefois par
    /// `MediaLibraryActor.videoAssetURL`, qui REFUSE un rush recomposé par
    /// PhotoKit (ralenti, timelapse, montage Photos appliqué — livré comme
    /// `AVComposition`, §52.3) : un rush parfaitement exportable était alors
    /// annoncé « indisponible » à l'aperçu, et l'utilisateur n'avait aucun
    /// moyen de voir ce qu'il allait exporter. `exportableVideoURL` est le
    /// chemin de l'export : un rush livré comme fichier est utilisé TEL QUEL
    /// (aucune copie, cas courant), et seul un rush recomposé est matérialisé.
    /// `allowNetwork: false` reste vrai (§44 : jamais de téléchargement iCloud
    /// surprise pendant une lecture).
    ///
    /// **Le fichier intermédiaire va dans `previews/`, PAS dans `temp/`
    /// (§11).** L'export vide `temp/` à chaque passage
    /// (`clearTemporaryFiles`) : une composition d'aperçu MISE EN CACHE (§48)
    /// qui y pointerait deviendrait muette après le premier export, sans que
    /// rien ne l'invalide. `previews/` est justement le dossier des matières
    /// d'aperçu ; le nom du fichier est déterministe, donc il n'est
    /// matérialisé qu'UNE fois par rush et réutilisé par tous les aperçus
    /// suivants. Le prix payé est une matérialisation de plus que l'export
    /// (qui garde la sienne dans `temp/`), pour les seuls rushs recomposés —
    /// et le dossier disparaît avec le projet (§31).
    ///
    /// Les échecs de photothèque sont DISCRIMINÉS (§40, §44, §64) : accès
    /// refusé, rush encore dans iCloud, ou rush à remplacer — trois actions
    /// utilisateur différentes, trois messages différents. Un échec inconnu
    /// reste `assetUnavailable(identifiant)` : l'appelant sait au moins quelle
    /// case est en cause. L'annulation (§8) est propagée telle quelle, jamais
    /// déguisée en erreur d'asset.
    private func insertVideo(
        _ placement: SlotPlacement,
        projectID: UUID,
        into videoTrack: AVMutableCompositionTrack
    ) async throws -> Segment {
        guard let assignment = placement.slot.assignment else {
            throw PreviewError.emptyScope // filtré en amont (timeline exportable)
        }
        let identifier = assignment.assetLocalIdentifier

        do {
            // §44 : `allowNetwork: false` — une case `ready` a déjà été
            // résolue ; une prévisualisation ne déclenche jamais un
            // téléchargement iCloud surprise. Un fichier évincé depuis
            // devient `assetUnavailable` (§48 : « un asset devient
            // indisponible » invalide le cache).
            //
            // MÊME résolution que l'export (§52.3, §54 étape 1) : un rush
            // recomposé par Photos est matérialisé au lieu d'être refusé.
            // Destination `previews/` et non `temp/` : l'export vide `temp/`,
            // ce qui rendrait muette une composition mise en cache (§48) —
            // voir la documentation de cette méthode.
            let url = try await mediaLibrary.exportableVideoURL(
                id: identifier,
                allowNetwork: false,
                intermediateDirectory: fileStore.subdirectoryURL(.previews, for: projectID)
            )
            let asset = AVURLAsset(url: url)

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceTrack = videoTracks.first else {
                throw PreviewError.assetUnavailable(identifier) // §64 : piste vidéo absente
            }

            // §54.2 : vérifier la durée. Un rush plus court que sa case ne
            // peut PAS être complété par du noir (§51 : « aucun écran noir
            // n'est ajouté ») — la case est refusée (§43/§64).
            let assetDuration = try await asset.load(.duration)
            let slotDuration = placement.slot.duration.cmTime
            guard assetDuration.isNumeric, assetDuration >= slotDuration else {
                throw PreviewError.assetUnavailable(identifier)
            }

            // §13.3 V1 : `sourceStart` vaut toujours 0 → `[0, slotDuration]`.
            let compositionStart = placement.compositionStart.cmTime // frontière §9
            try videoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: slotDuration),
                of: sourceTrack,
                at: compositionStart
            )

            let naturalSize = try await sourceTrack.load(.naturalSize)
            let preferredTransform = try await sourceTrack.load(.preferredTransform)

            return Segment(
                timeRange: CMTimeRange(start: compositionStart, duration: slotDuration),
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                assetIdentifier: identifier
            )
        } catch is CancellationError {
            throw CancellationError() // §8 : l'annulation reste une annulation
        } catch let error as PreviewError {
            throw error
        } catch let error as MediaLibraryError {
            // §40/§44/§64 : accès refusé ≠ iCloud ≠ rush à remplacer.
            throw PreviewError.fromMediaLibrary(error, assetIdentifier: identifier)
        } catch {
            throw PreviewError.assetUnavailable(identifier) // §64 (cause inconnue)
        }
    }

    /// Insère les portions de musique du projet (§48 : « insérer la musique …
    /// sur toute la portée » ; §53 : la musique est l'horloge maîtresse).
    ///
    /// La source est l'ORIGINAL inchangé (§11 `audio/original.<ext>`, §16.1 :
    /// « Conserver le fichier original inchangé pour la lecture et
    /// l'export ») — jamais le flux d'analyse normalisé (§16.2).
    ///
    /// **Une portion par RUN** pour l'aperçu principal (changement produit) :
    /// chaque zone remplie apporte son propre passage du morceau, posé à la
    /// position de composition de son run. Une seule portion pour un aperçu
    /// local (§47.1 : « le passage musical correspondant »), posée à
    /// l'instant 0. Les portions sont JOINTIVES dans la composition : la piste
    /// audio est continue, elle saute simplement d'un passage à l'autre aux
    /// jonctions.
    ///
    /// Rend la FIN de la piste musicale dans la composition — nécessaire pour
    /// couvrir toute la durée par des instructions de rendu.
    @discardableResult
    private func insertMusic(
        projectID: UUID,
        insertions: [MusicInsertion],
        into composition: AVMutableComposition
    ) async throws -> CMTime {
        guard insertions.contains(where: { $0.duration.ticks > 0 }) else {
            throw PreviewError.emptyScope
        }
        guard let audioURL = fileStore.audioFileURL(projectID: projectID) else {
            throw PreviewError.missingAudio
        }

        do {
            let audioAsset = AVURLAsset(url: audioURL)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = audioTracks.first,
                  let musicTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                throw PreviewError.missingAudio
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
                    // Garde-fou : une portion dépassant la fin de la musique
                    // (fichier remplacé hors app) est tronquée plutôt que de
                    // faire échouer l'insertion. Jamais attendu : les cases
                    // sont engendrées À PARTIR de cette musique (§28).
                    sourceRange = CMTimeRange(start: sourceRange.start, end: audioDuration)
                }
                guard sourceRange.duration > .zero else {
                    // Portion entièrement hors du fichier : la musique s'arrête
                    // là. On N'INSÈRE PAS les portions suivantes, qui
                    // tomberaient après un trou et désynchroniseraient tout ce
                    // qui suit ; la vidéo, elle, reste posée et le rendu
                    // demeure défini (instructions de fond §54.8).
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
            guard musicEnd > .zero else { throw PreviewError.missingAudio }
            return musicEnd
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PreviewError {
            throw error
        } catch {
            throw PreviewError.missingAudio
        }
    }

    // MARK: - Géométrie de rendu (§49, §50, §54.6/§54.7)

    /// Composition vidéo : taille de rendu issue de la géométrie VERROUILLÉE
    /// (§52.1 : « Toujours celle du projet, définie par le premier rush ») et
    /// une instruction par case, chacune portant la transformation
    /// crop-to-fill de SON rush (§50).
    ///
    /// Géométrie absente (prévisualisation d'un projet dont le premier rush
    /// n'a pas encore verrouillé — l'ordre normal est : rush prêt →
    /// `ProjectStore.lockGeometry` → preview) : repli sur la géométrie du
    /// premier rush de la portée, calculée mais **jamais persistée ici** —
    /// le verrouillage §49 reste la seule responsabilité du store.
    private func makeVideoComposition(
        project: ProjectSnapshot,
        segments: [Segment],
        videoTrack: AVMutableCompositionTrack,
        totalDuration: CMTime
    ) -> AVMutableVideoComposition? {
        guard let first = segments.first else { return nil }

        let geometry = project.geometry ?? GeometryLock.geometry(
            naturalWidth: Int(first.naturalSize.width.rounded()),
            naturalHeight: Int(first.naturalSize.height.rounded()),
            preferredTransform: first.preferredTransform,
            assetIdentifier: first.assetIdentifier
        )

        // Clip maître provisoire = premier rush de la portée. Le classement
        // complet du clip maître (§52.2 : pixels orientés, cadence, HDR,
        // ordre d'apparition) arrive au Jalon 10.
        let masterSize = GeometryLock.orientedSize(
            naturalSize: first.naturalSize,
            preferredTransform: first.preferredTransform
        )
        let renderSize = GeometryLock.renderSize(
            for: geometry,
            masterWidth: Int(masterSize.width.rounded()),
            masterHeight: Int(masterSize.height.rounded())
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = Self.defaultFrameDuration

        // §54.8 : fond opaque cohérent — le crop-to-fill ne laisse
        // normalement aucun pixel découvert.
        let opaqueBackground = CGColor(gray: 0, alpha: 1)
        var instructions: [AVMutableVideoCompositionInstruction] = []

        // AVFoundation exige que les instructions couvrent TOUTE la durée de
        // la composition, sans trou ni recouvrement : une plage non décrite
        // produit un rendu indéfini. On parcourt donc la timeline et on
        // comble CHAQUE intervalle découvert par une instruction de fond
        // opaque, jamais par un clip avancé (les clips ne sont jamais
        // déplacés les uns par rapport aux autres — combler un trou avec la
        // vidéo suivante désynchroniserait le montage de la musique, §53).
        //
        // Ceinture de sécurité : les cases d'un RUN sont jointives par
        // construction (§28.1 — la partition pave la musique sans trou), la
        // position d'un run est la SOMME des durées des runs précédents, et la
        // première case tombe exactement à zéro (aperçu local : zéro
        // également). Les instructions couvrent donc `[0, durée totale]` sans
        // trou, y compris AUX JONCTIONS entre runs. Cette boucle garantit que
        // s'il en apparaissait un (partition d'une version antérieure §61,
        // plage tronquée), le rendu resterait défini.
        var coveredUntil = CMTime.zero
        for segment in segments {
            if segment.timeRange.start > coveredUntil {
                instructions.append(
                    makeBackgroundInstruction(
                        from: coveredUntil,
                        to: segment.timeRange.start,
                        color: opaqueBackground
                    )
                )
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
                    renderSize: renderSize
                ),
                at: .zero
            )
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)

            coveredUntil = CMTimeMaximum(coveredUntil, segment.timeRange.end)
        }

        // Fin de portée : la musique peut dépasser la dernière image (portée
        // dont la dernière case a été tronquée). Le silence visuel est décrit
        // explicitement, jamais laissé au hasard.
        if totalDuration.isNumeric, totalDuration > coveredUntil {
            instructions.append(
                makeBackgroundInstruction(
                    from: coveredUntil,
                    to: totalDuration,
                    color: opaqueBackground
                )
            )
        }

        videoComposition.instructions = instructions
        return videoComposition
    }

    /// Instruction de fond opaque sans calque : couvre une plage sans vidéo
    /// (§54.8) pour qu'aucune portion de la durée ne reste non décrite.
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
}

// MARK: - Protocole §7

// La conformance formelle à `PreviewBuilding` (§7) est volontairement ABSENTE
// — voir la documentation de `PreviewBuilder` : le protocole §7 est non isolé
// et rend un `AVPlayerItem` non-`Sendable`, ce qui est un écart d'isolation
// réel depuis un type `@MainActor`. `@preconcurrency` ne faisait que
// rétrograder la vérification sans traiter l'écart. `makePreview(for:scope:)`
// conserve la signature exacte du protocole : la conformance (isolée
// `@MainActor`, SE-0470) pourra être ajoutée le jour où un consommateur
// générique existera. Aucun appelant n'utilise `any PreviewBuilding`.
