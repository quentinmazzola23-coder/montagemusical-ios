//
//  MediaLibraryActor.swift
//  MontageMusical
//
//  Acteur dédié à la photothèque (§8 : « MediaLibraryActor : accès PhotoKit
//  et cache »). Implémente l'esprit du protocole §7 `MediaLibraryBrowsing`
//  (l'acteur ajoute la progression iCloud §44 — la conformance stricte au
//  protocole passe par une surcharge sans progression, en extension).
//
//  Règle de frontière : AUCUN objet PhotoKit (`PHAsset`, `PHAssetCollection`,
//  `AVAsset`…) ne traverse la frontière de l'acteur — uniquement les types
//  `Sendable` du Domain (`MediaAlbum`, `VideoAssetSummary`,
//  `ResolvedVideoAsset`, §7). Le temps est converti en `MediaTime` dès la
//  frontière (§9 : `Double`/`CMTime` autorisés aux frontières uniquement).
//

import AVFoundation
import Foundation
import Photos

// Non defini par la specification — definition minimale V1.
actor MediaLibraryActor {

    init() {}

    // MARK: - Autorisations (§40)

    /// Demande l'accès en LECTURE à la photothèque.
    ///
    /// PhotoKit ne définit que deux niveaux (`PHAccessLevel`) : `.addOnly`
    /// (écriture seule, réservé à l'enregistrement des exports §40) et
    /// `.readWrite`. Il n'existe PAS de niveau « lecture seule » : la
    /// LECTURE demandée ici passe donc par `.readWrite` — c'est le niveau
    /// PhotoKit requis pour parcourir la photothèque.
    ///
    /// Ne JAMAIS appeler au lancement de l'application : c'est l'appelant
    /// qui déclenche cette demande au premier appui sur « Ajouter une
    /// vidéo » (§40).
    func requestAccess() async -> MediaLibraryAuthorization {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.mapAuthorization(status)
    }

    /// État d'autorisation courant, SANS déclencher de demande système
    /// (affichage d'état, §40).
    func currentAuthorization() -> MediaLibraryAuthorization {
        Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Mapping §40 : non demandé / accès complet / accès limité / refusé.
    /// `.restricted` (contrôle parental…) est traité comme refusé : même
    /// écran explicatif + Réglages (§64).
    private static func mapAuthorization(_ status: PHAuthorizationStatus) -> MediaLibraryAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .full
        case .limited: .limited
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    // MARK: - Albums (§41)

    /// Albums à proposer, dans l'ordre §41 : Récents, Toutes les vidéos,
    /// albums utilisateur, albums intelligents utiles (Favoris).
    ///
    /// Le compte de vidéos est calculé par un fetch réel filtré vidéo
    /// (`PHAsset.fetchAssets(in:options:).count`) : `estimatedAssetCount`
    /// mélange photos et vidéos (et peut valoir `NSNotFound`), ce qui
    /// rendrait le compte affiché faux. Le fetch PhotoKit est paresseux et
    /// exécuté une fois par album au chargement de la liste — coût accepté
    /// et documenté. Non defini par la specification — choix minimal V1.
    func albums() async throws -> [MediaAlbum] {
        try requireReadAccess()

        var albums: [MediaAlbum] = []
        var seenIdentifiers = Set<String>()

        func append(_ collection: PHAssetCollection, title fallbackTitle: String) {
            guard seenIdentifiers.insert(collection.localIdentifier).inserted else { return }
            albums.append(MediaAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? fallbackTitle,
                estimatedVideoCount: Self.videoCount(in: collection)
            ))
        }

        // 1. Récents (bibliothèque utilisateur).
        if let recents = Self.smartAlbum(.smartAlbumUserLibrary) {
            append(recents, title: "Récents")
        }
        // 2. Toutes les vidéos.
        if let allVideos = Self.smartAlbum(.smartAlbumVideos) {
            append(allVideos, title: "Toutes les vidéos")
        }
        // 3. Albums utilisateur (ordre PhotoKit, titre localisé).
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        userAlbums.enumerateObjects { collection, _, _ in
            append(collection, title: "Album")
        }
        // 4. Albums intelligents utiles : Favoris (§41 « albums
        //    intelligents utiles » — liste minimale V1).
        if let favorites = Self.smartAlbum(.smartAlbumFavorites) {
            append(favorites, title: "Favoris")
        }

        return albums
    }

    private static func smartAlbum(_ subtype: PHAssetCollectionSubtype) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: subtype,
            options: nil
        ).firstObject
    }

    /// Nombre de vidéos d'une collection (fetch paresseux filtré vidéo).
    private static func videoCount(in collection: PHAssetCollection) -> Int {
        PHAsset.fetchAssets(in: collection, options: videosOnlyOptions()).count
    }

    /// Options de fetch communes : vidéos uniquement, tri date de création
    /// décroissante (les rushs les plus récents d'abord).
    private static func videosOnlyOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d",
            PHAssetMediaType.video.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    // MARK: - Grille vidéo (§42, §43 premier filtre)

    /// Vidéos d'un album, tri date de création décroissante.
    ///
    /// `duration` provient de `PHAsset.duration` (métadonnée, premier
    /// filtre §43) convertie en `MediaTime` DÈS la frontière (§9) — la
    /// validation finale utilise la durée réelle de l'`AVAsset` résolu
    /// (`resolveAsset`).
    ///
    /// `isCloudAsset` : PhotoKit n'expose AUCUNE API publique synchrone
    /// « non téléchargé localement » (`locallyAvailable` est privé ;
    /// `PHImageResultIsInCloudKey` n'arrive qu'en callback de requête,
    /// trop coûteux pour toute une grille). Valeur best effort `false`,
    /// limite documentée : l'état iCloud réel est découvert à la
    /// résolution (§44 — progression + statut `downloading`).
    func videoAssets(in albumID: MediaAlbum.ID) async throws -> [VideoAssetSummary] {
        try requireReadAccess()

        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID],
            options: nil
        )
        guard let collection = collections.firstObject else {
            throw MediaLibraryError.albumNotFound
        }

        let assets = PHAsset.fetchAssets(in: collection, options: Self.videosOnlyOptions())
        var summaries: [VideoAssetSummary] = []
        summaries.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            summaries.append(VideoAssetSummary(
                localIdentifier: asset.localIdentifier,
                duration: MediaTime(seconds: asset.duration), // frontière §9
                isCloudAsset: false, // limite PhotoKit documentée ci-dessus
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ))
        }
        return summaries
    }

    // MARK: - Résolution (§43 validation finale, §44 iCloud)

    /// Résout l'`AVAsset` réel d'une vidéo et retourne ses caractéristiques
    /// mesurées (JAMAIS les métadonnées PhotoKit) :
    /// - durée réelle via `load(.duration)` (§43 : validation finale) ;
    /// - piste vidéo obligatoire, sinon `noVideoTrack` (§64) ;
    /// - téléchargement iCloud à la demande si `allowNetwork`, progression
    ///   publiée via `progress` (§44).
    ///
    /// L'`AVAsset` lui-même ne quitte pas l'acteur (§8) : seuls les types
    /// `Sendable` du Domain sortent.
    func resolveAsset(
        id: String,
        allowNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ResolvedVideoAsset {
        try requireReadAccess()

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = fetched.firstObject else {
            throw MediaLibraryError.assetNotFound // §64 : asset supprimé
        }
        guard phAsset.mediaType == .video else {
            throw MediaLibraryError.noVideoTrack // §64 : refuser sans piste vidéo
        }

        return try await resolvedVideoAsset(
            for: phAsset,
            id: id,
            allowNetwork: allowNetwork,
            progress: progress
        )
    }

    // MARK: - Géométrie du projet (§49, Jalon 9)

    /// Géométrie que ce rush IMPOSE au projet (§49 : « au premier rush
    /// prêt… ») — appelée après une association devenue `ready`, puis
    /// verrouillée par `ProjectStore.lockGeometry` (NO-OP si une géométrie
    /// existe déjà : le verrou est définitif §49/§65).
    ///
    /// `naturalSize` et `preferredTransform` sont lus DANS le rappel
    /// PhotoKit, comme `resolvedVideoAsset` : l'`AVAsset` (non-`Sendable`)
    /// ne traverse JAMAIS la frontière de l'acteur — seul le
    /// `ProjectGeometry` (`Sendable`) en sort, calculé par le type PUR
    /// `GeometryLock` (dimensions orientées + rapport simplifié §49).
    ///
    /// `isNetworkAccessAllowed = false` : le rush vient d'être résolu pour
    /// remplir la case (§43/§44), il est donc local — relancer un
    /// téléchargement iCloud pour relire deux métadonnées serait coûteux et
    /// inutile. Si l'asset est malgré tout indisponible, l'erreur remonte
    /// (`icloudUnavailable`/`assetNotFound`) et l'appelant laisse la
    /// géométrie non verrouillée : la prochaine association prête réessaiera.
    func videoGeometry(id: String) async throws -> ProjectGeometry {
        try requireReadAccess()

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = fetched.firstObject else {
            throw MediaLibraryError.assetNotFound // §64 : asset supprimé
        }
        guard phAsset.mediaType == .video else {
            throw MediaLibraryError.noVideoTrack
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat

        let guardBox = SingleResumeGuard()
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(
                forVideo: phAsset,
                options: options
            ) { avAsset, _, info in
                guard guardBox.beginResume() else { return }
                guard let avAsset else {
                    continuation.resume(throwing: Self.resolutionError(info: info))
                    return
                }
                // Même contrat d'usage que `resolvedVideoAsset` : l'asset
                // n'est lu QUE dans cette Task (lectures AVFoundation
                // thread-safe), jamais partagé ni muté ailleurs.
                let assetBox = UncheckedSendableBox(value: avAsset)
                Task {
                    let avAsset = assetBox.value
                    do {
                        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
                        guard let videoTrack = videoTracks.first else {
                            throw MediaLibraryError.noVideoTrack // §64
                        }
                        let naturalSize = try await videoTrack.load(.naturalSize)
                        let preferredTransform = try await videoTrack.load(.preferredTransform)
                        continuation.resume(returning: GeometryLock.geometry(
                            naturalWidth: Int(naturalSize.width.rounded()),
                            naturalHeight: Int(naturalSize.height.rounded()),
                            preferredTransform: preferredTransform,
                            assetIdentifier: id
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Requête `PHImageManager.requestAVAsset(forVideo:)` pontée en async,
    /// avec TOUTES les lectures AVFoundation effectuées DANS le rappel
    /// PhotoKit : l'`AVAsset` (non-`Sendable`) reste dans la région du
    /// rappel et ne traverse JAMAIS la frontière de l'acteur (Swift 6 :
    /// « sending 'avAsset' risks causing data races ») — seul le
    /// `ResolvedVideoAsset` (`Sendable`) en sort.
    ///
    /// Continuation UNIQUE : PhotoKit peut rappeler le `resultHandler`
    /// (annulation + livraison, versions dégradées) — un garde verrouillé
    /// (`SingleResumeGuard`) garantit exactement un `resume`, les rappels
    /// suivants sont ignorés.
    private func resolvedVideoAsset(
        for phAsset: PHAsset,
        id: String,
        allowNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ResolvedVideoAsset {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork // §44 : à la demande
        options.deliveryMode = .highQualityFormat
        options.progressHandler = { fraction, _, _, _ in
            // Hop @Sendable : la progression est publiée telle quelle,
            // l'appelant (UI) décide de son affichage (§44).
            progress(fraction)
        }

        let guardBox = SingleResumeGuard()
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(
                forVideo: phAsset,
                options: options
            ) { avAsset, _, info in
                guard guardBox.beginResume() else { return }
                guard let avAsset else {
                    continuation.resume(throwing: Self.resolutionError(info: info))
                    return
                }
                // Lectures asynchrones dans une Task locale au rappel.
                // Le rappel PhotoKit n'est pas `sending` : le compilateur ne
                // peut pas prouver que la région de `avAsset` est déconnectée
                // — boîte `@unchecked Sendable`, sûreté par CONTRAT D'USAGE :
                // l'asset n'est lu QUE dans cette Task (lectures AVFoundation
                // thread-safe), jamais partagé ni muté ailleurs, et seul le
                // `ResolvedVideoAsset` (`Sendable`) en sort.
                let assetBox = UncheckedSendableBox(value: avAsset)
                Task {
                    let avAsset = assetBox.value
                    do {
                        // §64 : piste vidéo absente → refuser d'abord.
                        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
                        guard let videoTrack = videoTracks.first else {
                            throw MediaLibraryError.noVideoTrack
                        }

                        // §43 : durée RÉELLE de l'AVAsset résolu — jamais la
                        // métadonnée. Durée non numérique (asset corrompu) →
                        // refus, jamais de zéro fabriqué. Non defini par la
                        // specification — choix minimal V1.
                        let cmDuration = try await avAsset.load(.duration)
                        guard let duration = MediaTime(cmTime: cmDuration) else {
                            throw MediaLibraryError.noVideoTrack
                        }

                        // Largeur/hauteur BRUTES (naturalSize non orientée) —
                        // orientation et verrouillage §49 au Jalon 9.
                        let naturalSize = try await videoTrack.load(.naturalSize)
                        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

                        // HDR best effort — pipeline HDR/SDR complet au
                        // Jalon 10. Non defini par la specification — V1.
                        let isHDR = ((try? await videoTrack.load(.mediaCharacteristics))
                            ?? []).contains(.containsHDRVideo)

                        continuation.resume(returning: ResolvedVideoAsset(
                            localIdentifier: id,
                            duration: duration,
                            naturalWidth: Int(naturalSize.width.rounded()),
                            naturalHeight: Int(naturalSize.height.rounded()),
                            isHDR: isHDR,
                            nominalFrameRate: Double(nominalFrameRate)
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - URL locale du rush (aperçu §47/§48 ET export §54)

    // SUPPRIMÉ le 13 août 2026 : `videoAssetURL(id:allowNetwork:)`.
    //
    // Cette résolution REFUSAIT tout rush recomposé par Photos (ralenti,
    // timelapse, montage appliqué — livré comme `AVComposition` et non comme
    // `AVURLAsset`) : sa seule cliente, la prévisualisation, annonçait donc
    // « indisponible » un rush parfaitement exportable. Depuis que l'aperçu
    // passe par `exportableVideoURL(id:allowNetwork:intermediateDirectory:)`
    // — le MÊME chemin que l'export —, elle n'avait plus aucun appelant, ni en
    // production ni en test. Une API morte dont la documentation décrivait un
    // comportement disparu vaut moins que rien : elle est retirée plutôt que
    // conservée « au cas où ». Son unique chemin propre,
    // `requestFileURL(for:allowNetwork:)`, sert toujours ci-dessous.

    // MARK: - URL exploitable à l'EXPORT ET à l'APERÇU (§52.3, §54, §66)

    /// URL d'un fichier lisible par AVFoundation pour ce rush, **quel que
    /// soit son mode de livraison PhotoKit** — c'est la résolution utilisée
    /// par l'export (§54 étape 1) ET par l'aperçu (§48), qui ne doivent jamais
    /// voir deux images différentes du même rush.
    ///
    /// Deux chemins :
    /// 1. rush livré comme `AVURLAsset` (cas courant) → son URL, telle
    ///    quelle, AUCUNE copie ;
    /// 2. rush recomposé par Photos — **ralenti, timelapse**, montage
    ///    appliqué — livré comme `AVComposition` : PhotoKit fournit alors une
    ///    session d'export (`requestExportSession`) qui APPLIQUE le montage,
    ///    donc la cadence de LECTURE (§52.3). Le résultat est écrit dans
    ///    `intermediateDirectory` (le `temp/` du projet pour l'export, le
    ///    `previews/` du projet pour l'aperçu — §11) et son URL est rendue.
    ///
    /// **Pourquoi ce chemin et pas un refus.** Ces rushs ont pu être ASSOCIÉS
    /// (§43 : la résolution `resolveAsset` lit très bien un `AVComposition`) :
    /// les refuser à l'export seulement rendrait un montage déjà construit
    /// inexportable — §66 n'a aucune case pour un rush « associable mais pas
    /// exportable ». L'alternative (les refuser dès l'association, §64
    /// « piste vidéo absente : refuser ») interdirait tout montage de rushs
    /// ralentis, que §52.3 prévoit explicitement.
    ///
    /// **Limites V1, assumées et documentées :**
    /// - le fichier intermédiaire est un ré-encodage supplémentaire pour CES
    ///   rushs uniquement (§55 « une seule ré-encodage final » vise le
    ///   montage : ici il s'agit de matérialiser une SOURCE) ;
    /// - sa taille n'entre pas dans l'estimation §57 : elle est bornée par le
    ///   rush source, et le fichier ne survit pas au projet (§31, le dossier
    ///   entier est supprimé) — celui d'un export disparaît avec `temp/`
    ///   (`ProjectFileStore.clearTemporaryFiles`, vidé à chaque passage), celui
    ///   d'un aperçu avec `previews/`
    ///   (`ProjectFileStore.clearPreviewIntermediates`, appelé par
    ///   `PreviewCache.invalidateAll`) ;
    /// - le fichier est RÉUTILISÉ s'il existe déjà : le résumé §56 et l'export
    ///   qui le suit ne matérialisent qu'une fois.
    ///
    /// **Le nom porte la date de modification de l'asset** — voir
    /// `intermediateFileURL(id:modificationDate:in:)`. Sans elle, un rush
    /// RETOUCHÉ dans Photos (même identifiant local, §13.2) aurait été rejoué
    /// éternellement dans sa version périmée par l'aperçu, dont le dossier
    /// survit entre deux lectures, pendant que l'export — qui vide son `temp/`
    /// à chaque passage — aurait matérialisé la nouvelle : aperçu et export
    /// auraient de nouveau divergé, ce que le passage à cette résolution
    /// unique visait justement à supprimer.
    ///
    /// - Parameters:
    ///   - id: identifiant local PhotoKit du rush.
    ///   - allowNetwork: §44 — l'export passe `false` (une case `ready` a
    ///     déjà été résolue, aucun téléchargement surprise).
    ///   - intermediateDirectory: dossier d'accueil des fichiers
    ///     intermédiaires (`temp/` ou `previews/` du projet, §11) — créé si
    ///     nécessaire.
    func exportableVideoURL(
        id: String,
        allowNetwork: Bool,
        intermediateDirectory: URL
    ) async throws -> URL {
        try requireReadAccess()

        // L'asset est résolu AVANT de chercher un intermédiaire : sa date de
        // modification entre dans le nom du fichier, un rush retouché ne peut
        // donc pas rejouer l'ancien (`fetchAssets` est une lecture locale, pas
        // une requête réseau).
        //
        // Conséquence assumée : un rush SUPPRIMÉ de Photos échoue désormais
        // (§64 `assetNotFound`) même si un intermédiaire traîne encore sur le
        // disque. C'est ce que fait déjà l'export (son `temp/` est vidé à
        // chaque passage) — l'aperçu ne peut pas continuer de montrer une
        // vidéo que l'export refusera.
        let phAsset = try requireVideoAsset(id: id)
        let intermediateURL = Self.intermediateFileURL(
            id: id,
            modificationDate: phAsset.modificationDate,
            in: intermediateDirectory
        )

        // Intermédiaire déjà matérialisé pour CETTE version du rush (résumé
        // §56 puis export, ou aperçu relancé) : réutilisé tel quel, aucune
        // requête.
        if FileManager.default.fileExists(atPath: intermediateURL.path(percentEncoded: false)) {
            return intermediateURL
        }

        if let url = try await requestFileURL(for: phAsset, allowNetwork: allowNetwork) {
            return url
        }
        return try await materializeVideo(
            for: phAsset,
            allowNetwork: allowNetwork,
            destinationURL: intermediateURL
        )
    }

    /// Nom DÉTERMINISTE du fichier intermédiaire d'un rush (§11 `temp/` ou
    /// `previews/`) : deux résolutions de la MÊME version du même rush
    /// désignent le même fichier, donc une seule matérialisation.
    ///
    /// L'identifiant PhotoKit contient des `/` (`<uuid>/L0/001`) : tout
    /// caractère non alphanumérique devient `-`.
    ///
    /// `modificationDate` (secondes entières depuis 1970, `0` si PhotoKit ne
    /// la donne pas) DISCRIMINE les versions successives d'un même rush : une
    /// retouche dans Photos conserve l'identifiant local mais change la date,
    /// donc le nom — l'ancien intermédiaire n'est plus jamais rejoué. Les
    /// résidus disparaissent avec le dossier qui les porte (`temp/` vidé à
    /// chaque export, `previews/` vidé à chaque invalidation de cache §48, et
    /// tout le projet à sa suppression §31).
    static func intermediateFileURL(
        id: String,
        modificationDate: Date?,
        in directory: URL
    ) -> URL {
        let sanitized = String(id.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        }.prefix(80))
        let version = Int64((modificationDate?.timeIntervalSince1970 ?? 0).rounded())
        return directory.appending(path: "source-\(sanitized)-\(version).mov")
    }

    /// PHAsset vidéo du projet, ou erreur §64 (asset supprimé / média non
    /// vidéo) — garde commune à toutes les résolutions.
    private func requireVideoAsset(id: String) throws -> PHAsset {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let phAsset = fetched.firstObject else {
            throw MediaLibraryError.assetNotFound // §64 : asset supprimé
        }
        guard phAsset.mediaType == .video else {
            throw MediaLibraryError.noVideoTrack // §64 : refuser sans piste vidéo
        }
        return phAsset
    }

    /// URL du fichier livré par PhotoKit, ou `nil` si le rush est recomposé
    /// (`AVComposition` — ralenti/timelapse/montage).
    ///
    /// Aucune boîte `@unchecked Sendable` n'est nécessaire : la lecture est
    /// SYNCHRONE dans le rappel (aucune `Task` capturant l'asset) et seule
    /// l'`URL` (`Sendable`) en sort — l'`AVAsset` reste dans la région du
    /// rappel PhotoKit (§8).
    ///
    /// Continuation UNIQUE garantie par `SingleResumeGuard` (PhotoKit peut
    /// rappeler son handler : versions dégradées, annulation).
    private func requestFileURL(for phAsset: PHAsset, allowNetwork: Bool) async throws -> URL? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork // §44 : à la demande
        options.deliveryMode = .highQualityFormat

        let guardBox = SingleResumeGuard()
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(
                forVideo: phAsset,
                options: options
            ) { avAsset, _, info in
                guard guardBox.beginResume() else { return }
                guard let avAsset else {
                    continuation.resume(throwing: Self.resolutionError(info: info))
                    return
                }
                // Seule l'URL (`Sendable`) sort du rappel.
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }

    /// Écrit le rush recomposé dans un fichier lisible (§52.3) via la session
    /// d'export fournie par PhotoKit — c'est elle qui applique le montage
    /// Photos (ralenti, trim), donc la cadence de LECTURE.
    ///
    /// La session (non-`Sendable`) est livrée par un rappel qui n'est pas
    /// `sending` : elle transite par la boîte `UncheckedSendableBox` et n'est
    /// utilisée QUE dans la `Task` locale au rappel — même contrat d'usage
    /// que `resolvedVideoAsset`.
    ///
    /// Le preset est celui de plus haute qualité : un `Passthrough`
    /// ignorerait le remappage temporel d'un ralenti et livrerait le fichier
    /// de capture (120/240 i/s), ce que §52.3 interdit d'exporter.
    private func materializeVideo(
        for phAsset: PHAsset,
        allowNetwork: Bool,
        destinationURL: URL
    ) async throws -> URL {
        try? FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork // §44
        options.deliveryMode = .highQualityFormat
        options.version = .current // montage Photos APPLIQUÉ (§52.3)

        let guardBox = SingleResumeGuard()
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestExportSession(
                forVideo: phAsset,
                options: options,
                exportPreset: AVAssetExportPresetHighestQuality
            ) { exportSession, info in
                guard guardBox.beginResume() else { return }
                guard let exportSession else {
                    continuation.resume(throwing: Self.resolutionError(info: info))
                    return
                }
                let sessionBox = UncheckedSendableBox(value: exportSession)
                Task {
                    let session = sessionBox.value
                    // Résidu d'une matérialisation interrompue : jamais
                    // réutilisé à moitié.
                    try? FileManager.default.removeItem(at: destinationURL)
                    do {
                        try await session.export(to: destinationURL, as: .mov)
                        continuation.resume(returning: destinationURL)
                    } catch {
                        try? FileManager.default.removeItem(at: destinationURL)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Classement des échecs de résolution (§64) :
    /// - asset dans iCloud (réseau interdit) ou erreur réseau/temps
    ///   dépassé → `icloudUnavailable` (réessai possible) ;
    /// - sinon → `assetNotFound` (asset supprimé/inutilisable).
    private static func resolutionError(info: [AnyHashable: Any]?) -> MediaLibraryError {
        let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
        if inCloud {
            return .icloudUnavailable
        }
        if let error = info?[PHImageErrorKey] as? NSError {
            // Erreurs réseau (téléchargement iCloud interrompu, hors
            // connexion, temps dépassé) → réessai permis (§64).
            if error.domain == NSURLErrorDomain || error.domain == CKErrorDomainName {
                return .icloudUnavailable
            }
        }
        return .assetNotFound
    }

    /// §40/§64 : les lectures exigent un accès complet OU limité (en accès
    /// limité, PhotoKit ne retourne que les assets autorisés — l'application
    /// fonctionne avec). Refusé/non demandé → `accessDenied` (l'appelant
    /// affiche l'écran explicatif + Réglages ; la demande initiale passe
    /// par `requestAccess`).
    private func requireReadAccess() throws {
        switch currentAuthorization() {
        case .full, .limited:
            return
        case .notDetermined, .denied:
            throw MediaLibraryError.accessDenied
        }
    }
}

// Domaine CloudKit des erreurs iCloud remontées par PhotoKit — constante
// locale pour éviter une dépendance à CloudKit entière.
private let CKErrorDomainName = "CKErrorDomain"

// MARK: - Garde de continuation unique

// Non defini par la specification — outil de concurrence V1.
/// Boîte de transfert pour une valeur non-`Sendable` livrée par un rappel
/// système (PhotoKit) dont la fermeture n'est pas `sending` : le compilateur
/// ne peut pas prouver la déconnexion de région. Sûreté par CONTRAT
/// D'USAGE, documenté à chaque point d'emploi (valeur lue par une seule
/// Task, jamais partagée).
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Verrou minimal garantissant qu'une continuation n'est reprise qu'UNE
/// fois même si PhotoKit rappelle son handler (documenté : rappels
/// possibles avec versions dégradées ou après annulation).
private final class SingleResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// `true` la première fois seulement — l'appelant peut alors reprendre
    /// la continuation ; toute tentative suivante retourne `false`.
    func beginResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

// MARK: - Conformance §7 (surcharge sans progression)

/// Conformance stricte au protocole §7 `MediaLibraryBrowsing` : la
/// résolution sans suivi de progression délègue à la version complète
/// (progression ignorée).
extension MediaLibraryActor: MediaLibraryBrowsing {
    func resolveAsset(id: String, allowNetwork: Bool) async throws -> ResolvedVideoAsset {
        try await resolveAsset(id: id, allowNetwork: allowNetwork, progress: { _ in })
    }
}
