//
//  ProjectGeometry.swift
//  MontageMusical
//
//  Géométrie du projet — spécification §14 (verbatim).
//  Le premier rush valide fixe la géométrie. Elle ne change plus ensuite,
//  même si un rush plus défini est ajouté (spec §14, §49).
//

import Foundation

struct ProjectGeometry: Codable, Sendable {
    let aspectWidth: Int
    let aspectHeight: Int
    let orientation: ProjectOrientation
    let lockedByAssetIdentifier: String
}

// Non defini par la specification — definition minimale V1.
enum ProjectOrientation: String, Codable, Sendable {
    case portrait
    case landscape
    case square
}
