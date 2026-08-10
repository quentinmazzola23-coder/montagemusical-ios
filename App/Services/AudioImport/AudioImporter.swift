//
//  AudioImporter.swift
//  MontageMusical
//
//  Import audio (Jalon 3) — spec §7 (protocole `AudioImporting`), §11
//  (copie dans le sandbox), §16.1 (l'original est conservé inchangé),
//  §62 (validation réelle et erreurs), §69A (confidentialité des logs),
//  §78 (le projet ne dépend plus de l'URL externe après import).
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Importe un fichier audio externe (fileImporter) dans le sandbox du
/// projet (spec §7, §11, §62).
///
/// Étapes :
/// 1. accès security-scoped à l'URL externe (le temps de l'import
///    uniquement — aucune référence conservée ensuite, §78) ;
/// 2. validation §62 réelle par AVFoundation (l'extension seule ne
///    suffit jamais) ;
/// 3. copie ATOMIQUE dans le sandbox : écriture vers `temp/` du projet
///    puis déplacement vers `audio/original.<ext>` (§11) — l'original
///    externe n'est jamais modifié (§16.1) ;
/// 4. durée mesurée par AVFoundation, convertie en `MediaTime` à la
///    frontière (§9).
struct AudioImporter: AudioImporting, Sendable {

    /// Types §62 acceptés : M4A/AAC, MP3, WAV, AIFF.
    private static let allowedTypes: [UTType] = {
        var types: [UTType] = [.mpeg4Audio, .mp3, .wav, .aiff]
        if let aac = UTType("public.aac-audio") {
            types.append(aac)
        }
        return types
    }()

    /// Extensions §62 acceptées (repli lorsque le système ne fournit pas
    /// d'UTType pour l'extension).
    private static let allowedExtensions: Set<String> = [
        "m4a", "aac", "mp3", "wav", "wave", "aiff", "aif", "aifc",
    ]

    private let fileStore: ProjectFileStore

    /// §69A : jamais de nom complet de fichier personnel en Release —
    /// `AppLogger` passe par la confidentialité OSLog par défaut
    /// (interpolations masquées en Release) et les messages ci-dessous ne
    /// contiennent de toute façon que extension et durée, pas le nom.
    private let logger = AppLogger(category: .media)

    init(fileStore: ProjectFileStore) {
        self.fileStore = fileStore
    }

    /// Importe le fichier `url` dans le projet `projectID`.
    ///
    /// À la sortie, le projet ne dépend PLUS de l'URL externe (§78) :
    /// le résultat ne contient qu'un chemin relatif au dossier du projet.
    func importAudio(from url: URL, into projectID: UUID) async throws -> ImportedAudio {
        // Accès security-scoped (URL issue du fileImporter). Hors de son
        // sandbox l'appel retourne `false` sans que ce soit une erreur
        // (URL de test locale) : ne rendre l'accès que s'il a été pris.
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // 1. Type (§62 : type non supporté → expliquer). Extension OU UTType
        //    parmi M4A/AAC, MP3, WAV, AIFF ; la validité réelle du contenu
        //    est vérifiée ensuite par AVFoundation.
        let fileExtension = url.pathExtension.lowercased()
        guard Self.isAllowedType(fileExtension: fileExtension) else {
            throw AudioImportError.unsupportedType(fileExtension)
        }

        // 2. Taille > 0 (§62 : fichier vide → ne pas lancer l'analyse).
        //    Fichier illisible (absent, accès refusé) : traité comme vide.
        let sourcePath = url.path(percentEncoded: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw AudioImportError.emptyOrCorruptFile
        }

        // 3. Validation réelle par AVFoundation (§62 : l'extension seule ne
        //    suffit jamais) — DRM, piste audio décodable, durée.
        let asset = AVURLAsset(url: url)

        let hasProtectedContent: Bool
        do {
            hasProtectedContent = try await asset.load(.hasProtectedContent)
        } catch {
            throw AudioImportError.emptyOrCorruptFile
        }
        guard !hasProtectedContent else {
            throw AudioImportError.protectedContent
        }

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioImportError.noDecodableAudioTrack
        }
        guard let audioTrack = audioTracks.first else {
            throw AudioImportError.noDecodableAudioTrack
        }
        // §62 : « vérifier qu'une piste audio DÉCODABLE existe » — la seule
        // présence d'une piste ne suffit pas (codec non supporté, payload
        // corrompu passeraient sinon jusqu'à la waveform/lecture muette).
        let isDecodable: Bool
        do {
            isDecodable = try await audioTrack.load(.isDecodable)
        } catch {
            throw AudioImportError.noDecodableAudioTrack
        }
        guard isDecodable else {
            throw AudioImportError.noDecodableAudioTrack
        }

        // Durée : conversion CMTime → MediaTime à la frontière AVFoundation
        // (§9). Init failable : CMTime non numérique → fichier corrompu.
        let loadedDuration: CMTime
        do {
            loadedDuration = try await asset.load(.duration)
        } catch {
            throw AudioImportError.emptyOrCorruptFile
        }
        guard let duration = MediaTime(cmTime: loadedDuration),
              duration.ticks > 0 else {
            throw AudioImportError.emptyOrCorruptFile
        }

        // 4. Copie atomique dans le sandbox (§11) : temp/ puis move vers
        //    audio/original.<ext>. L'original externe est seulement LU —
        //    jamais modifié (§16.1).
        try fileStore.createDirectories(for: projectID) // idempotent
        let temporaryURL = fileStore
            .subdirectoryURL(.temp, for: projectID)
            .appending(path: "import-\(UUID().uuidString).\(fileExtension)")
        let destinationURL = fileStore
            .subdirectoryURL(.audio, for: projectID)
            .appending(path: "original.\(fileExtension)")

        do {
            try FileManager.default.copyItem(at: url, to: temporaryURL)
        } catch {
            // §62 : copie interrompue → nettoyer le fichier partiel.
            try? FileManager.default.removeItem(at: temporaryURL)
            throw AudioImportError.copyInterrupted
        }

        // Remplacement quasi atomique (V1 : un seul original, extension
        // éventuellement différente) : le nouveau fichier entre d'abord dans
        // audio/ sous un nom provisoire (même volume), l'ancien n'est
        // supprimé qu'ensuite — jamais d'état « ancien perdu, nouveau
        // absent » avec un `audioRelativePath` pointant dans le vide.
        let audioDirectory = fileStore.subdirectoryURL(.audio, for: projectID)
        let stagedURL = audioDirectory
            .appending(path: "staged-\(UUID().uuidString).\(fileExtension)")
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: stagedURL)
            if let existing = try? FileManager.default.contentsOfDirectory(
                at: audioDirectory,
                includingPropertiesForKeys: nil
            ) {
                for previous in existing
                where previous.lastPathComponent != stagedURL.lastPathComponent {
                    try FileManager.default.removeItem(at: previous)
                }
            }
            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
        } catch {
            // §62 : nettoyer le fichier partiel ET le provisoire — audio/
            // ne reste jamais dans un état ambigu.
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: stagedURL)
            throw AudioImportError.copyInterrupted
        }

        // §69A : pas de nom de fichier dans les logs — extension et durée
        // uniquement (et masqués par défaut en Release via OSLog).
        logger.info("Import audio réussi : .\(fileExtension), \(duration.ticks) ticks")

        // §78 : aucune référence à l'URL externe ne survit à cette fonction.
        return ImportedAudio(
            projectID: projectID,
            relativePath: "audio/original.\(fileExtension)", // §11
            originalFilename: url.lastPathComponent,
            duration: duration,
            fileExtension: fileExtension
        )
    }

    // MARK: - Validation de type (§62)

    /// Vrai si l'extension (ou l'UTType qu'elle désigne) correspond à un
    /// format §62 : M4A/AAC, MP3, WAV, AIFF.
    private static func isAllowedType(fileExtension: String) -> Bool {
        if allowedExtensions.contains(fileExtension) {
            return true
        }
        guard let type = UTType(filenameExtension: fileExtension) else {
            return false
        }
        return allowedTypes.contains { type.conforms(to: $0) }
    }
}
