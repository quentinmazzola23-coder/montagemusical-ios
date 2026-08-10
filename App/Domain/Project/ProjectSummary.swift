//
//  ProjectSummary.swift
//  MontageMusical
//
//  Résumé de projet pour la liste de l'écran d'accueil (spec §31).
//

import Foundation

// Non defini par la specification — definition minimale V1.
/// Instantané immuable et `Sendable` d'un projet, destiné à la liste des
/// projets (spec §31 : date, progression, actions renommer/dupliquer/
/// supprimer). Construit par `ProjectStore` à partir d'un `ProjectRecord`.
struct ProjectSummary: Identifiable, Sendable, Equatable {
    let id: UUID

    /// Titre affiché : `customTitle ?? automaticTitle` (spec §10).
    let displayTitle: String

    let createdAt: Date
    let updatedAt: Date
    let status: ProjectStatus

    /// Vrai si le projet contient une musique, des associations ou un
    /// export — la suppression demande alors confirmation (spec §31).
    let hasContent: Bool
}
