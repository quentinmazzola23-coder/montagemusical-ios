//
//  ScoreLibrary.swift
//  MontageMusical
//
//  Lecture des partitions générées (Jalon 6) — `analysis/scores-v1.json`
//  et validité via `analysis/scores-meta-v1.json` (§11, §61).
//

import CryptoKit
import Foundation

// Non defini par la specification — definition minimale V1.
/// Empreinte de la `ScoreConfiguration` — calcul PARTAGÉ entre l'écriture
/// des métadonnées (`AudioAnalysisActor.writeScoresMeta`) et leur
/// vérification (`ScoreLibrary.scoresAreCurrent`) : §61 exige que la
/// configuration utilisée soit tracée puis comparée à l'IDENTIQUE — un seul
/// point de calcul, jamais deux implémentations qui divergent.
enum ScoreConfigurationFingerprint {

    /// SHA-256 de la configuration ENCODÉE en JSON à clés triées (encodage
    /// déterministe : deux configurations égales donnent la même empreinte).
    /// Même approche que `configurationFingerprint` côté analyse
    /// (`AnalysisCache`/`DeterministicMusicAnalyzer`), appliquée à la
    /// configuration des partitions.
    static func fingerprint(of configuration: ScoreConfiguration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// Non defini par la specification — definition minimale V1.
/// Bibliothèque de partitions d'un projet : décode la famille §13 écrite
/// par `AudioAnalysisActor` (`analysis/scores-v1.json`, §11) et dit si elle
/// est à jour (§61) vis-à-vis du générateur et de la configuration courants.
///
/// Lecture seule, aucune écriture : des partitions absentes ou périmées
/// déclenchent une régénération EXPLICITE (§61 : jamais de recalcul
/// automatique d'un projet terminé).
struct ScoreLibrary: Sendable {

    private let fileStore: ProjectFileStore

    init(fileStore: ProjectFileStore) {
        self.fileStore = fileStore
    }

    /// Famille de partitions du projet (`analysis/scores-v1.json`, §11),
    /// ou `nil` si le fichier est absent ou illisible.
    func loadScores(projectID: UUID) -> EditScoreFamily? {
        let url = fileStore.directory(for: projectID)
            .appending(path: AudioAnalysisActor.scoresRelativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EditScoreFamily.self, from: data)
    }

    /// Vrai ssi `analysis/scores-meta-v1.json` est présent ET
    /// `generatorVersion` == `DeterministicEditScoreGenerator.generatorVersion`
    /// ET `analysisVersion` == `DeterministicMusicAnalyzer.engineVersion`
    /// ET `configurationFingerprint` == empreinte de
    /// `ScoreConfiguration.production` (§61). Toute divergence — méta
    /// absente/illisible, générateur, MOTEUR D'ANALYSE ou configuration
    /// ayant évolué — → partitions PÉRIMÉES : l'application propose une
    /// régénération explicite, jamais silencieuse.
    ///
    /// L'empreinte du fichier audio (§61) n'est pas dupliquée ici : elle est
    /// déjà la clé du cache d'analyse (§69) — un audio différent invalide
    /// l'analyse, donc les partitions, par ce chemin.
    func scoresAreCurrent(projectID: UUID) -> Bool {
        let url = fileStore.directory(for: projectID)
            .appending(path: AudioAnalysisActor.scoresMetaRelativePath)
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(ScoresMeta.self, from: data),
              meta.generatorVersion == DeterministicEditScoreGenerator.generatorVersion,
              meta.analysisVersion == DeterministicMusicAnalyzer.engineVersion,
              let expected = try? ScoreConfigurationFingerprint.fingerprint(of: .production)
        else {
            return false
        }
        return meta.configurationFingerprint == expected
    }
}

// Non defini par la specification — definition minimale V1.
/// Schéma UNIQUE de `analysis/scores-meta-v1.json` (§61) — partagé par
/// l'écriture (`AudioAnalysisActor.writeScoresMeta`), la lecture
/// (`ScoreLibrary.scoresAreCurrent`) et les tests : un seul point de
/// vérité, un renommage de champ casse la compilation partout.
struct ScoresMeta: Codable {
    /// Version du générateur de partitions (`DeterministicEditScoreGenerator`).
    let generatorVersion: Int
    /// Empreinte SHA-256 de la `ScoreConfiguration` utilisée.
    let configurationFingerprint: String
    /// Version du moteur d'analyse dont provient le `MusicAnalysisResult`
    /// source (§61 : un moteur d'analyse qui évolue périme les partitions).
    let analysisVersion: Int
}
