//
//  AnalysisCache.swift
//  MontageMusical
//
//  Cache d'analyse (§69) et checkpoints de phase (§8, §63, §79) dans le
//  dossier `analysis/` du projet (§11) :
//  - `analysis-v1.json`      : le `MusicAnalysisResult` complet ;
//  - `analysis-meta-v1.json` : empreinte audio + version moteur + empreinte
//    de configuration (clés d'invalidation §69 — le résultat lui-même
//    reste un JSON pur §11) ;
//  - `checkpoint-v1.json`    : dernier jalon de phase terminé (§8.1 :
//    sauvegarder le dernier jalon, reprendre au retour de l'utilisateur).
//
//  Invalidation §69 : empreinte audio + version moteur + configuration —
//  pour le RÉSULTAT comme pour le checkpoint (la configuration est fournie
//  par l'analyseur, qui la calcule via `configurationFingerprint`).
//

import CryptoKit
import Foundation

// MARK: - Checkpoint de phase

// Non defini par la specification — definition minimale V1.
/// Dernier jalon d'analyse terminé (§8 : chaque opération longue sauvegarde
/// son état et reprend proprement ; §63 : annulation → conserver le dernier
/// checkpoint).
struct AnalysisCheckpoint: Codable, Sendable {
    /// Empreinte combinée audio + configuration (§69 : les deux invalident).
    let fingerprint: String
    let engineVersion: Int
    /// `AnalysisPhase.rawValue` des phases terminées, dans l'ordre.
    let completedPhases: [String]
    /// Encodage binaire des caractéristiques si la phase 1 est finie.
    let featureTimelineData: Data?
    /// Hypothèses + beats si la phase 2 est finie.
    let rhythmData: Data?
}

// MARK: - Cache

// Non defini par la specification — definition minimale V1.
struct AnalysisCache: Sendable {

    private let fileStore: ProjectFileStore
    private let logger = AppLogger(category: .analysis)

    /// Noms de fichiers dans `analysis/` (§11).
    private enum FileName {
        static let result = "analysis-v1.json"
        static let meta = "analysis-meta-v1.json"
        static let checkpoint = "checkpoint-v1.json"
    }

    /// Métadonnées d'invalidation du résultat (§69, §61 : empreinte du
    /// fichier audio + version moteur + empreinte de configuration
    /// conservées avec l'analyse — un changement de configuration doit
    /// invalider le résultat, pas seulement le checkpoint).
    private struct CacheMeta: Codable {
        let fingerprint: String
        let engineVersion: Int
        let configurationFingerprint: String
    }

    init(fileStore: ProjectFileStore) {
        self.fileStore = fileStore
    }

    // MARK: Empreinte audio (§61, §69)

    /// SHA-256 du fichier audio, lu en blocs d'1 Mio (§68 : jamais tout le
    /// fichier en mémoire).
    func audioFingerprint(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Résultat complet

    /// Résultat en cache s'il correspond exactement à l'empreinte audio, à
    /// la version moteur ET à l'empreinte de configuration (§69) — sinon
    /// `nil`, jamais de résultat périmé.
    func load(
        projectID: UUID,
        fingerprint: String,
        engineVersion: Int,
        configurationFingerprint: String
    ) -> MusicAnalysisResult? {
        guard
            let metaData = try? Data(contentsOf: metaURL(projectID: projectID)),
            let meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData),
            meta.fingerprint == fingerprint,
            meta.engineVersion == engineVersion,
            meta.configurationFingerprint == configurationFingerprint,
            let resultData = try? Data(contentsOf: resultURL(projectID: projectID)),
            let result = try? JSONDecoder().decode(MusicAnalysisResult.self, from: resultData),
            result.version == engineVersion
        else {
            return nil
        }
        return result
    }

    /// Écrit `analysis-v1.json` puis ses métadonnées d'invalidation.
    /// Écritures atomiques : jamais de JSON partiel lisible (§59 esprit).
    func save(
        _ result: MusicAnalysisResult,
        projectID: UUID,
        fingerprint: String,
        engineVersion: Int,
        configurationFingerprint: String
    ) throws {
        let encoder = Self.makeEncoder()
        let resultData = try encoder.encode(result)
        // Le résultat d'abord, la méta ensuite : une méta sans résultat
        // validerait un cache vide ; l'inverse est inoffensif (méta absente
        // → cache ignoré).
        try resultData.write(to: resultURL(projectID: projectID), options: .atomic)
        let metaData = try encoder.encode(CacheMeta(
            fingerprint: fingerprint,
            engineVersion: engineVersion,
            configurationFingerprint: configurationFingerprint
        ))
        try metaData.write(to: metaURL(projectID: projectID), options: .atomic)
    }

    // MARK: Checkpoints de phase (§8, §63)

    /// Checkpoint valable pour cette empreinte (audio + configuration) et la
    /// version moteur courante — sinon `nil` (checkpoint périmé ignoré, §69).
    func loadCheckpoint(projectID: UUID, fingerprint: String) -> AnalysisCheckpoint? {
        guard
            let data = try? Data(contentsOf: checkpointURL(projectID: projectID)),
            let checkpoint = try? JSONDecoder().decode(AnalysisCheckpoint.self, from: data),
            checkpoint.fingerprint == fingerprint
        else {
            return nil
        }
        return checkpoint
    }

    func saveCheckpoint(_ checkpoint: AnalysisCheckpoint, projectID: UUID) throws {
        let data = try Self.makeEncoder().encode(checkpoint)
        try data.write(to: checkpointURL(projectID: projectID), options: .atomic)
    }

    /// Supprime le checkpoint (après un succès complet). Silencieux si absent.
    func clearCheckpoint(projectID: UUID) {
        let url = checkpointURL(projectID: projectID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Non bloquant : un checkpoint résiduel est ignoré à la
            // prochaine analyse (empreinte différente ou phases déjà
            // complètes) — journalisé, jamais silencieusement fatal.
            logger.error("Suppression du checkpoint impossible : \(error.localizedDescription)")
        }
    }

    // MARK: - URLs (§11)

    private func resultURL(projectID: UUID) -> URL {
        fileStore.subdirectoryURL(.analysis, for: projectID).appending(path: FileName.result)
    }

    private func metaURL(projectID: UUID) -> URL {
        fileStore.subdirectoryURL(.analysis, for: projectID).appending(path: FileName.meta)
    }

    private func checkpointURL(projectID: UUID) -> URL {
        fileStore.subdirectoryURL(.analysis, for: projectID).appending(path: FileName.checkpoint)
    }

    /// Encodeur JSON déterministe (clés triées) : deux sauvegardes du même
    /// résultat produisent le même octet à octet.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
