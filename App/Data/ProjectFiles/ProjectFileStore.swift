//
//  ProjectFileStore.swift
//  MontageMusical
//
//  Fichiers lourds d'un projet, hors SwiftData — arbre spec §11 :
//
//  Application Support/
//  └── Projects/
//      └── <project-uuid>/
//          ├── audio/
//          ├── analysis/
//          ├── previews/
//          ├── exports/
//          └── temp/
//

import Foundation

/// Accès aux dossiers de fichiers d'un projet (spec §11).
///
/// Ce type ne manipule que des fichiers créés par l'application dans son
/// sandbox. Il ne touche JAMAIS la photothèque : les rushs originaux de
/// Photos ne sont ni modifiés ni supprimés (spec §31, §69A).
struct ProjectFileStore: Sendable {

    /// Sous-dossiers d'un projet — arbre §11 exact.
    enum Subdirectory: String, CaseIterable, Sendable {
        case audio
        case analysis
        case previews
        case exports
        case temp
    }

    /// Racine des projets : `Application Support/Projects/`.
    let rootURL: URL

    /// Racine par défaut (production) : `Application Support/Projects/`.
    init() {
        self.init(
            rootURL: URL.applicationSupportDirectory
                .appending(path: "Projects", directoryHint: .isDirectory)
        )
    }

    // Non defini par la specification — definition minimale V1 :
    // init d'injection de la racine pour les tests (dossier temporaire).
    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Dossier racine d'un projet : `Projects/<project-uuid>/`.
    func directory(for projectID: UUID) -> URL {
        rootURL.appending(path: projectID.uuidString, directoryHint: .isDirectory)
    }

    /// URL d'un sous-dossier §11 d'un projet.
    func subdirectoryURL(_ subdirectory: Subdirectory, for projectID: UUID) -> URL {
        directory(for: projectID)
            .appending(path: subdirectory.rawValue, directoryHint: .isDirectory)
    }

    /// Crée l'arbre §11 complet du projet
    /// (`audio/ analysis/ previews/ exports/ temp/`), intermédiaires compris.
    func createDirectories(for projectID: UUID) throws {
        // §69A : protection de fichiers iOS adaptée aux dossiers de projet.
        // `completeUntilFirstUserAuthentication` protège au repos tout en
        // laissant une tâche courte d'arrière-plan terminer une écriture
        // (§8.1). Le niveau exact n'est pas défini par la spécification —
        // choix minimal V1.
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        for subdirectory in Subdirectory.allCases {
            try FileManager.default.createDirectory(
                at: subdirectoryURL(subdirectory, for: projectID),
                withIntermediateDirectories: true,
                attributes: attributes
            )
        }
    }

    /// Supprime le dossier du projet et tout son contenu (métadonnées
    /// fichiers, analyses, previews, exports, temporaires — spec §31).
    /// Silencieux si le dossier est absent.
    ///
    /// §69A : une suppression de projet ne supprime que les références et
    /// fichiers créés par l'application — jamais les rushs de Photos.
    func deleteDirectory(for projectID: UUID) throws {
        let url = directory(for: projectID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Vrai si `audio/` contient au moins un fichier
    /// (`original.<extension>`, spec §11).
    func hasAudioFile(projectID: UUID) -> Bool {
        hasFiles(in: .audio, projectID: projectID)
    }

    /// Vrai si `exports/` contient au moins un fichier — utilisé pour la
    /// confirmation avant suppression (spec §31 : « … une musique, des
    /// associations ou un export »).
    func hasExportFiles(projectID: UUID) -> Bool {
        hasFiles(in: .exports, projectID: projectID)
    }

    /// Identifiants des dossiers projets présents sur disque — réconciliation
    /// au lancement : une suppression interrompue entre la sauvegarde SwiftData
    /// et la suppression du dossier laisse un dossier orphelin (§69A).
    func projectDirectoryIDs() -> [UUID] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return contents.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    /// Vide `temp/` du projet (§69A : supprimer les temporaires au prochain
    /// lancement après un crash). Silencieux si le dossier est absent.
    func clearTemporaryFiles(projectID: UUID) {
        let url = subdirectoryURL(.temp, for: projectID)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for item in contents {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func hasFiles(in subdirectory: Subdirectory, projectID: UUID) -> Bool {
        let url = subdirectoryURL(subdirectory, for: projectID)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return !contents.isEmpty
    }
}
