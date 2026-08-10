//
//  MediaModels.swift
//  MontageMusical
//
//  Association vidéo — spécification §13.3 (verbatim)
//  + types de support pour la photothèque (§7, §40).
//

import Foundation
import SwiftData

// MARK: - Statut d'association (spec §13.3, verbatim)

enum ClipAssignmentStatus: String, Codable {
    case resolving
    case downloading
    case ready
    case unavailable
    case tooShort
}

// MARK: - Association persistée (spec §13.3, verbatim)

/// Enregistrement SwiftData d'une association vidéo → case.
///
/// Dans la V1, `sourceStartTicks` vaut toujours `0` (spec §13.3).
///
/// `requiredDurationTicks` est un champ stocké par la spécification (§13.3),
/// conservé tel quel.
@Model
final class ClipAssignmentRecord {
    var id: UUID
    var projectID: UUID
    var slotID: UUID
    var assetLocalIdentifier: String
    var sourceStartTicks: Int64
    var requiredDurationTicks: Int64
    var observedAssetDurationTicks: Int64
    var statusRaw: String
    var assignedAt: Date

    init(
        id: UUID,
        projectID: UUID,
        slotID: UUID,
        assetLocalIdentifier: String,
        sourceStartTicks: Int64,
        requiredDurationTicks: Int64,
        observedAssetDurationTicks: Int64,
        statusRaw: String,
        assignedAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.slotID = slotID
        self.assetLocalIdentifier = assetLocalIdentifier
        self.sourceStartTicks = sourceStartTicks
        self.requiredDurationTicks = requiredDurationTicks
        self.observedAssetDurationTicks = observedAssetDurationTicks
        self.statusRaw = statusRaw
        self.assignedAt = assignedAt
    }
}

// MARK: - Types de support photothèque (spec §7, §40)

// Non defini par la specification — definition minimale V1.
/// États d'autorisation Photos à gérer (spec §40) : non demandé,
/// accès complet, accès limité, refusé.
enum MediaLibraryAuthorization: String, Codable, Sendable {
    case notDetermined
    case full
    case limited
    case denied
}

// Non defini par la specification — definition minimale V1.
struct MediaAlbum: Codable, Identifiable, Sendable {
    typealias ID = String

    let id: String
    let title: String
    let estimatedVideoCount: Int?
}

// Non defini par la specification — definition minimale V1.
struct VideoAssetSummary: Codable, Sendable {
    let localIdentifier: String
    let duration: MediaTime
    let isCloudAsset: Bool
    let pixelWidth: Int
    let pixelHeight: Int
}

// Non defini par la specification — definition minimale V1.
// Support minimal : le verrouillage de géométrie complet
// (naturalSize + preferredTransform, spec §49) arrive au Jalon 9.
struct ResolvedVideoAsset: Codable, Sendable {
    let localIdentifier: String
    let duration: MediaTime
    let naturalWidth: Int
    let naturalHeight: Int
    let isHDR: Bool
    let nominalFrameRate: Double
}
