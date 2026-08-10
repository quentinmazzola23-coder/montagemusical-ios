//
//  ThumbnailProvider.swift
//  MontageMusical
//
//  Miniatures de la grille vidéo (§42) : `PHCachingImageManager`,
//  préchargement uniquement autour de la zone visible, et JAMAIS de
//  décodage 4K — la taille demandée est TOUJOURS la taille de cellule en
//  pixels, jamais `PHImageManagerMaximumSize` (§42, §67 : « aucune
//  miniature 4K décodée dans la grille »).
//

import Photos
import UIKit

/// Fournisseur de miniatures pour la grille vidéo (§42).
///
/// `@MainActor` : consommé directement par les cellules SwiftUI ; le
/// décodage lui-même reste dans PhotoKit (files internes du
/// `PHCachingImageManager`).
///
/// Non defini par la specification — definition minimale V1.
@MainActor
final class ThumbnailProvider {

    private let cachingManager = PHCachingImageManager()

    init() {}

    // MARK: - Miniature d'une cellule

    /// Miniature d'un asset à la taille EXACTE de la cellule, en pixels
    /// (§42 : ne jamais décoder la 4K — PhotoKit ne décode que la taille
    /// demandée). `nil` si l'asset n'existe plus ou si la requête échoue —
    /// la cellule affiche alors un placeholder, jamais d'erreur bloquante.
    ///
    /// Options : livraison opportuniste (aperçu dégradé rapide puis version
    /// finale) + réseau autorisé — une miniature iCloud lointaine vaut
    /// mieux qu'une case grise, et son coût est minime comparé à la
    /// résolution vidéo (§44).
    ///
    /// Continuation avec garde double-resume : en mode opportuniste,
    /// PhotoKit rappelle le handler PLUSIEURS fois (version dégradée PUIS
    /// finale). On reprend la continuation au PREMIER résultat NON dégradé
    /// (version finale — directe quand l'image est déjà en cache) ; les
    /// versions dégradées intermédiaires sont ignorées, et un échec final
    /// (image `nil`, non dégradé) reprend avec `nil`.
    func thumbnail(for assetID: String, targetSize: CGSize) async -> UIImage? {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = fetched.firstObject else {
            return nil // asset supprimé (§64) → placeholder côté grille
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        let guardBox = ThumbnailResumeGuard()
        return await withCheckedContinuation { continuation in
            self.cachingManager.requestImage(
                for: asset,
                targetSize: targetSize, // taille de cellule EXACTE — jamais PHImageManagerMaximumSize (§42)
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                if isDegraded {
                    return // version dégradée intermédiaire : attendre la finale
                }
                guard guardBox.beginResume() else { return }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Préchargement (§42 : autour de la zone visible uniquement)

    /// Précharge les miniatures des assets donnés à la taille de cellule.
    /// À appeler avec la fenêtre AUTOUR de la zone visible uniquement (§42),
    /// jamais avec l'album entier.
    func startCaching(assetIDs: [String], targetSize: CGSize) {
        guard !assetIDs.isEmpty else { return }
        cachingManager.startCachingImages(
            for: Self.fetchAssets(ids: assetIDs),
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: Self.makeCachingOptions()
        )
    }

    /// Arrête le préchargement des assets donnés — cache BORNÉ (§42) : les
    /// identifiants SORTIS de la fenêtre visible sont retirés par lots
    /// (même mécanique que le préchargement), le `PHCachingImageManager`
    /// libère leurs miniatures au lieu d'accumuler tout l'album pendant un
    /// long défilement.
    ///
    /// Les paramètres (taille, mode, options) doivent être IDENTIQUES à
    /// ceux du `startCaching` correspondant — exigence PhotoKit pour que la
    /// requête de cache soit bien retrouvée et annulée (d'où les fabriques
    /// partagées `fetchAssets`/`makeCachingOptions`).
    func stopCaching(assetIDs: [String], targetSize: CGSize) {
        guard !assetIDs.isEmpty else { return }
        cachingManager.stopCachingImages(
            for: Self.fetchAssets(ids: assetIDs),
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: Self.makeCachingOptions()
        )
    }

    /// Vide tout le cache de préchargement (fermeture de la photothèque ou
    /// changement d'album).
    func stopCachingAll() {
        cachingManager.stopCachingImagesForAllAssets()
    }

    // MARK: - Fabriques partagées start/stop (paramètres identiques requis)

    /// Résolution des `PHAsset` d'une liste d'identifiants (les assets
    /// supprimés sont simplement absents du résultat — §64).
    private static func fetchAssets(ids: [String]) -> [PHAsset] {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    /// Options de cache UNIQUES pour `startCaching`/`stopCaching` — une
    /// divergence rendrait l'arrêt inopérant (PhotoKit apparie par
    /// paramètres).
    private static func makeCachingOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return options
    }
}

/// Garde de continuation unique pour `thumbnail(for:targetSize:)` —
/// PhotoKit peut rappeler le handler (dégradé puis final) ; exactement un
/// `resume` est garanti.
private final class ThumbnailResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func beginResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
