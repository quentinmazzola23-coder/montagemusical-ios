//
//  WaveformStore.swift
//  MontageMusical
//
//  Cache mémoire de la forme d'onde d'affichage.
//
//  POURQUOI CE TYPE EXISTE
//  -----------------------
//  `WaveformExtractor` décode le fichier audio ENTIER pour produire ses bins
//  (§16.2 : lecture par blocs, mais lecture intégrale tout de même). Il était
//  appelé sans aucun cache par `ProjectView` et `AssemblyView`, donc à chaque
//  apparition de ces écrans ; le sélecteur de rushs en est un troisième
//  appelant. Sur un morceau de 3 minutes, chaque appel coûte un décodage
//  complet pour un résultat strictement identique — l'audio d'un projet est
//  immuable (§11 : `audio/original.<ext>` n'est réécrit que par un réimport,
//  qui vide d'abord le dossier).
//
//  Ce cache est volontairement EN MÉMOIRE et non sur disque : il supprime le
//  coût dans une session sans introduire de format persistant à migrer ni de
//  fichier à invalider. Un cache disque §69 reste souhaitable — il éviterait
//  aussi le premier décodage après relance — mais il demande une clé
//  d'invalidation (empreinte audio) et un format versionné, ce qui n'est pas
//  le sujet ici.
//
//  INVALIDATION
//  ------------
//  La clé porte la TAILLE du fichier en plus de son chemin et du nombre de
//  bins. Un réimport produit presque toujours un fichier de taille
//  différente ; à taille rigoureusement égale le contenu affiché resterait
//  celui de l'ancien morceau, ce qui est un défaut d'affichage sans
//  conséquence sur le montage (aucune décision ne dépend de cette courbe).
//  Retenu tel quel : lire la taille coûte un `stat`, calculer une empreinte
//  coûterait une lecture intégrale, soit exactement ce qu'on veut éviter.
//

import Foundation

/// Cache mémoire, partagé par tous les écrans qui affichent la forme d'onde.
actor WaveformStore {

    /// Identité d'une extraction : deux appels de même clé rendent le même
    /// tableau. Le chemin seul ne suffit pas — le nombre de bins fait partie
    /// du résultat.
    private struct Key: Hashable {
        let path: String
        let binCount: Int
        let fileSize: Int64
    }

    private let extractor: WaveformExtractor
    private var cached: [Key: [Float]] = [:]
    /// Extractions EN COURS, pour que deux écrans qui apparaissent en même
    /// temps ne lancent pas deux décodages du même fichier : le second
    /// attend le premier.
    private var inFlight: [Key: Task<[Float], any Error>] = [:]

    init(extractor: WaveformExtractor = WaveformExtractor()) {
        self.extractor = extractor
    }

    /// Forme d'onde normalisée `0...1`, `binCount` valeurs.
    ///
    /// - Note: l'annulation de l'appelant ne détruit PAS l'extraction en
    ///   cours si un autre appelant l'attend encore — c'est le comportement
    ///   voulu, une vue qui disparaît ne doit pas priver l'autre de son
    ///   résultat. L'appelant annulé, lui, remonte bien `CancellationError`.
    func waveform(for url: URL, binCount: Int = 200) async throws -> [Float] {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        let key = Key(path: url.path, binCount: binCount, fileSize: size ?? -1)

        if let hit = cached[key] { return hit }

        if let running = inFlight[key] {
            return try await running.value
        }

        let extractor = self.extractor
        let task = Task<[Float], any Error> {
            try await extractor.waveform(for: url, binCount: binCount)
        }
        inFlight[key] = task

        do {
            let samples = try await task.value
            cached[key] = samples
            inFlight[key] = nil
            return samples
        } catch {
            // Échec ou annulation : ne RIEN mémoriser, pour que la prochaine
            // apparition retente. Un tableau vide mis en cache condamnerait
            // l'affichage jusqu'à la fin de la session.
            inFlight[key] = nil
            throw error
        }
    }

    /// Oublie tout ce qui concerne un fichier — à appeler après un réimport.
    func invalidate(url: URL) {
        cached = cached.filter { $0.key.path != url.path }
        for (key, task) in inFlight where key.path == url.path {
            task.cancel()
            inFlight[key] = nil
        }
    }
}
