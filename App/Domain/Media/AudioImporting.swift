//
//  AudioImporting.swift
//  MontageMusical
//
//  Protocole d'import audio — spécification §7 (verbatim)
//  + résultat d'import (support).
//

import Foundation

protocol AudioImporting {
    func importAudio(from url: URL, into projectID: UUID) async throws -> ImportedAudio
}

// Non defini par la specification — definition minimale V1.
// Spec §11 : à l'import, le fichier audio est copié dans le sandbox de
// l'application ; `relativePath` est relatif au dossier du projet, sans
// dépendance durable à une URL externe.
struct ImportedAudio: Codable, Sendable {
    let projectID: UUID
    let relativePath: String
    let originalFilename: String
    let duration: MediaTime
    let fileExtension: String
}
