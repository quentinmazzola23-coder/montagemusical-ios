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

        let avAsset = try await requestAVAsset(
            for: phAsset,
            allowNetwork: allowNetwork,
            progress: progress
        )

        // §64 : piste vidéo absente → refuser (avant toute autre lecture).
        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw MediaLibraryError.noVideoTrack
        }

        // §43 : durée RÉELLE de l'AVAsset résolu — jamais la métadonnée.
        // Une durée non numérique (asset corrompu) est refusée comme un
        // asset sans piste vidéo lisible (§64 : refuser, jamais de zéro
        // fabriqué). Non defini par la specification — choix minimal V1.
        let cmDuration = try await avAsset.load(.duration)
        guard let duration = MediaTime(cmTime: cmDuration) else {
            throw MediaLibraryError.noVideoTrack
        }

        // Largeur/hauteur BRUTES de la piste (naturalSize non orientée) —
        // l'orientation et le verrouillage de géométrie complets (§49)
        // arrivent au Jalon 9.
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

        // HDR best effort : caractéristique média officielle de la piste.
        // En cas d'échec de lecture, `false` (le pipeline HDR/SDR complet
        // arrive au Jalon 10). Non defini par la specification — V1.
        let isHDR = ((try? await videoTrack.load(.mediaCharacteristics))
            ?? []).contains(.containsHDRVideo)

        return ResolvedVideoAsset(
            localIdentifier: id,
            duration: duration,
            naturalWidth: Int(naturalSize.width.rounded()),
            naturalHeight: Int(naturalSize.height.rounded()),
            isHDR: isHDR,
            nominalFrameRate: Double(nominalFrameRate)
        )
    }

    /// Requête `PHImageManager.requestAVAsset(forVideo:)` pontée en async.
    ///
    /// Continuation UNIQUE : PhotoKit peut rappeler le `resultHandler`
    /// (annulation + livraison, versions dégradées) — un garde verrouillé
    /// (`SingleResumeGuard`) garantit exactement un `resume`, les rappels
    /// suivants sont ignorés.
    private func requestAVAsset(
        for phAsset: PHAsset,
        allowNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVAsset {
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
                if let avAsset {
                    continuation.resume(returning: avAsset)
                    return
                }
                continuation.resume(throwing: Self.resolutionError(info: info))
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
