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

    /// URL du fichier audio du projet : premier fichier de `audio/` trié
    /// par nom, `nil` si le dossier est vide ou absent.
    ///
    /// §11 : V1 n'a qu'un seul original (`audio/original.<extension>`) ;
    /// le tri par nom rend le choix déterministe si un résidu inattendu
    /// subsistait.
    func audioFileURL(projectID: UUID) -> URL? {
        let audioDirectory = subdirectoryURL(.audio, for: projectID)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return contents
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// Vrai si `exports/` contient au moins un fichier — utilisé pour la
    /// confirmation avant suppression (spec §31 : « … une musique, des
    /// associations ou un export »).
    func hasExportFiles(projectID: UUID) -> Bool {
        hasFiles(in: .exports, projectID: projectID)
    }

    /// URL du DERNIER export réussi du projet (§60 : « dernier export
    /// réussi » restauré à la réouverture), ou `nil` si `exports/` est vide
    /// ou absent.
    ///
    /// Le schéma §10 est verbatim : aucune colonne ne décrit un export — le
    /// FICHIER est la trace durable (§11). Son nom est horodaté et TRIABLE
    /// (`Montage-yyyyMMdd-HHmmss[-n].mov`, `ProjectExporter.uniqueOutputURL`) :
    /// le maximum lexicographique est donc le plus récent, sans lire aucune
    /// date système (une date de fichier peut être altérée par une
    /// restauration de sauvegarde, pas un nom).
    ///
    /// Un seul export est normalement conservé (`pruneExports`) ; le tri
    /// reste correct si un résidu subsiste.
    func lastExportURL(projectID: UUID) -> URL? {
        exportFileURLs(projectID: projectID)
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Ne conserve dans `exports/` que le fichier `keptURL` (§11, §57 : un
    /// export complet par relance saturerait le stockage ; §60 ne demande de
    /// restaurer que le DERNIER export réussi).
    ///
    /// Appelé APRÈS le déplacement du nouvel export : à aucun instant le
    /// projet ne se retrouve sans export livrable. Retourne le nombre de
    /// fichiers supprimés.
    @discardableResult
    func pruneExports(projectID: UUID, keeping keptURL: URL) -> Int {
        let keptName = keptURL.lastPathComponent
        var removedCount = 0
        for url in exportFileURLs(projectID: projectID) where url.lastPathComponent != keptName {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removedCount += 1
            }
        }
        return removedCount
    }

    /// Contenu de `exports/` (§11), fichiers cachés exclus. Vide si le
    /// dossier n'existe pas encore.
    private func exportFileURLs(projectID: UUID) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: subdirectoryURL(.exports, for: projectID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
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
        clearContents(of: .temp, projectID: projectID)
    }

    /// Vide `previews/` du projet — les SOURCES matérialisées de l'aperçu
    /// (`source-<rush>-<version>.mov`, `MediaLibraryActor.exportableVideoURL`).
    ///
    /// CORRECTIF (relecture du 13 août 2026, second passage) : depuis que
    /// l'aperçu résout ses rushs par le chemin de l'export, un rush recomposé
    /// par Photos (ralenti, timelapse) est ré-encodé dans `previews/`. Rien ne
    /// supprimait jamais ce fichier : `clearTemporaryFiles` ne touche que
    /// `temp/` et `PreviewCache.invalidateAll` ne purgeait que la mémoire. Le
    /// ré-encodage restait donc sur le disque pour toute la vie du projet,
    /// hors de l'estimation §57.
    ///
    /// Appelée par `PreviewCache.invalidateAll(projectID:)` — l'invalidation
    /// du cache §48 est exactement le moment où une association ou un asset a
    /// changé, donc où les matières d'aperçu déjà calculées ne valent plus
    /// rien. Silencieux si le dossier est absent.
    ///
    /// Ne touche PAS `exports/` (§60 : le dernier export est restauré à la
    /// réouverture) ni `analysis/` (§69 : les checkpoints survivent).
    func clearPreviewIntermediates(projectID: UUID) {
        clearContents(of: .previews, projectID: projectID)
    }

    /// Supprime le contenu d'un sous-dossier §11 sans supprimer le dossier
    /// lui-même (l'arbre reste valide). Silencieux si le dossier est absent.
    private func clearContents(of subdirectory: Subdirectory, projectID: UUID) {
        let url = subdirectoryURL(subdirectory, for: projectID)
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
