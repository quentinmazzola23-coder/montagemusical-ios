//
//  MediaLibraryBrowsing.swift
//  MontageMusical
//
//  Protocole d'accès à la photothèque — spécification §7 (verbatim).
//

import Foundation

protocol MediaLibraryBrowsing {
    func requestAccess() async -> MediaLibraryAuthorization
    func albums() async throws -> [MediaAlbum]
    func videoAssets(in album: MediaAlbum.ID) async throws -> [VideoAssetSummary]
    func resolveAsset(id: String, allowNetwork: Bool) async throws -> ResolvedVideoAsset
}
