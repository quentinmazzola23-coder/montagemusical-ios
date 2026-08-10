//
//  ExportModels.swift
//  MontageMusical
//
//  Portées de prévisualisation (spec §47, verbatim), portée d'export,
//  snapshots de projet et préfixe exportable (spec §51, verbatim).
//

import Foundation

// MARK: - Portées de prévisualisation (spec §47, verbatim)

enum PreviewScope: Sendable {
    case slot(UUID)
    case contiguousPrefix
    case complete
}

// MARK: - Portée d'export

// Non defini par la specification — definition minimale V1.
enum ExportScope: Sendable {
    case contiguousPrefix
    case complete
}

// MARK: - Résultat d'export

// Non defini par la specification — definition minimale V1.
struct ExportResult: Codable, Sendable {
    let outputURL: URL
    let duration: MediaTime
    let slotCount: Int
}

// MARK: - Snapshots (support)

// Non defini par la specification — definition minimale V1.
struct ClipAssignmentSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let assetLocalIdentifier: String
    let status: ClipAssignmentStatus
}

// Non defini par la specification — definition minimale V1.
struct ProjectSlot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let index: Int
    let start: MediaTime
    let end: MediaTime
    let assignment: ClipAssignmentSnapshot?
}

extension ProjectSlot {
    /// Durée calculée `end - start` — jamais persistée (spec §9, §13.2).
    var duration: MediaTime { end - start }
}

// Non defini par la specification — definition minimale V1.
struct ProjectSnapshot: Codable, Sendable {
    let projectID: UUID
    let slots: [ProjectSlot]
    let geometry: ProjectGeometry?

    /// Préfixe continu prêt à prévisualiser/exporter (spec §51).
    var contiguousReadyPrefix: [ProjectSlot] {
        MontageMusical.contiguousReadyPrefix(slots: slots)
    }
}

// MARK: - Préfixe exportable (spec §51, verbatim)

/// Règles (spec §51) :
/// - export désactivé si le résultat est vide ;
/// - les cases après le premier trou sont ignorées ;
/// - aucun écran noir n'est ajouté ;
/// - la musique est coupée à la fin absolue de la dernière case exportée ;
/// - les clips ultérieurs ne sont jamais déplacés.
func contiguousReadyPrefix(slots: [ProjectSlot]) -> [ProjectSlot] {
    var result: [ProjectSlot] = []
    for slot in slots.sorted(by: { $0.index < $1.index }) {
        guard slot.assignment?.status == .ready else { break }
        result.append(slot)
    }
    return result
}
