//
//  ModelContainerFactory.swift
//  MontageMusical
//
//  Fabriques du conteneur SwiftData — schéma des enregistrements persistés
//  (spec §10, §10.1, §13.3).
//

import Foundation
import SwiftData

/// Fabriques du conteneur SwiftData.
///
/// Schéma du Jalon 2 : `ProjectRecord` (§10), `ProjectSlotRecord` (§10.1),
/// `ClipAssignmentRecord` (§13.3). Les fichiers lourds (audio, analyses,
/// previews, exports) restent hors SwiftData (§11) — voir `ProjectFileStore`.
enum ModelContainerFactory {

    /// Schéma persisté commun aux deux fabriques.
    private static var schema: Schema {
        Schema([
            ProjectRecord.self,
            ProjectSlotRecord.self,
            ClipAssignmentRecord.self,
        ])
    }

    /// Conteneur persistant de production, à l'emplacement par défaut de
    /// SwiftData (Application Support — cohérent avec l'arbre §11).
    static func makeShared() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Conteneur en mémoire seulement — tests unitaires et previews SwiftUI.
    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
