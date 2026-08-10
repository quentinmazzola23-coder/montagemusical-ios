//
//  CoreMLModelRegistry.swift
//  MontageMusical
//
//  Registre des modèles Core ML embarqués — spec §29A (pipeline de modèles),
//  §61 (« version du modèle Core ML » conservée), §86 (« fallback
//  déterministe toujours disponible »).
//
//  ⛔ JALON 11 — NON TERMINÉ, ET CE FICHIER LE DIT HONNÊTEMENT.
//
//  État réel aujourd'hui : AUCUN modèle n'est embarqué dans le bundle de
//  l'application. Aucun `.mlpackage`/`.mlmodelc` n'existe dans le dépôt,
//  aucun poids n'a été entraîné, aucune licence de corpus n'a été validée.
//  En conséquence :
//
//      CoreMLModelRegistry.beatActivationModel()        →  nil
//      CoreMLModelRegistry.beatActivationModelVersion() →  nil
//
//  §29A « Interdiction » : « L'agent de programmation ne doit pas prétendre
//  avoir créé un modèle intelligent en ajoutant des règles aléatoires ou un
//  fichier Core ML vide. » Ce registre ne fabrique donc RIEN : il ne charge
//  pas de modèle factice, ne simule pas d'inférence, ne renvoie pas une
//  version inventée. Il constate l'absence et laisse le moteur déterministe
//  faire le travail (§86).
//
//  POINT D'EXTENSION UNIQUE : le jour où un modèle entraîné, converti en
//  `.mlpackage` et dont la licence est validée est ajouté à la cible iOS,
//  SEULE cette fabrique change (chargement `MLModel` + adaptateur conforme à
//  `BeatActivationModel` + lecture de la version dans les métadonnées du
//  modèle). Le reste du moteur — `BeatActivationModel`, `HybridMusicAnalyzer`,
//  le fallback et ses tests — est déjà branché et n'a pas à bouger.
//
//  `import CoreML` est volontairement ABSENT : sans modèle, aucune API Core ML
//  n'est appelée. L'import arrivera avec l'adaptateur réel.
//

import Foundation

// Non defini par la specification — definition minimale V1.
enum CoreMLModelRegistry {

    // MARK: - Ressources attendues (§29A « Modèles recommandés »)

    /// Description d'un modèle ATTENDU dans le bundle. « Attendu » ne veut pas
    /// dire « présent » : ces descripteurs décrivent la convention de nommage
    /// que l'export `ml/export_coreml/` devra respecter, rien de plus.
    struct EmbeddedModelDescriptor: Sendable, Equatable {

        /// Nom de la ressource, sans extension (§29A : `BeatDownbeatModel`,
        /// `MusicEmbeddingModel`, `FunctionalStateModel`).
        let resourceName: String

        /// Extension de la ressource telle qu'elle apparaît dans le bundle
        /// APRÈS compilation Xcode : un `.mlpackage` ajouté à la cible est
        /// compilé en `.mlmodelc`.
        let compiledExtension: String

        init(resourceName: String, compiledExtension: String = "mlmodelc") {
            self.resourceName = resourceName
            self.compiledExtension = compiledExtension
        }
    }

    /// Modèle beats/downbeats (§19.2, §29A n° 1) — le seul dont le protocole
    /// (`BeatActivationModel`) est défini à ce stade. Les deux autres modèles
    /// recommandés (`MusicEmbeddingModel`, `FunctionalStateModel`) n'ont pas
    /// encore de protocole : ils ne sont donc PAS déclarés ici, pour ne pas
    /// laisser croire qu'un socle existe là où il n'existe pas.
    static let beatDownbeatDescriptor = EmbeddedModelDescriptor(resourceName: "BeatDownbeatModel")

    // MARK: - Détection (aucun chargement)

    /// URL de la ressource compilée si elle est réellement présente dans le
    /// bundle, `nil` sinon. Simple constat de présence — aucun fichier n'est
    /// ouvert, aucun modèle n'est instancié.
    ///
    /// Aujourd'hui : renvoie `nil` (aucune ressource de ce nom n'est ajoutée
    /// à la cible iOS).
    static func embeddedResourceURL(
        for descriptor: EmbeddedModelDescriptor,
        in bundle: Bundle = .main
    ) -> URL? {
        bundle.url(
            forResource: descriptor.resourceName,
            withExtension: descriptor.compiledExtension
        )
    }

    /// Vrai si la ressource du modèle beats/downbeats est présente dans le
    /// bundle. Faux aujourd'hui, et tant qu'aucun modèle licencié n'est validé.
    static func isBeatDownbeatModelEmbedded(in bundle: Bundle = .main) -> Bool {
        embeddedResourceURL(for: beatDownbeatDescriptor, in: bundle) != nil
    }

    // MARK: - Fabrique (§86 : le fallback reste la seule voie réelle)

    /// Modèle d'activation beats/downbeats utilisable par
    /// `HybridMusicAnalyzer`.
    ///
    /// - Returns: `nil` dans TOUS les cas aujourd'hui.
    ///   - ressource absente (cas réel) : rien à charger ;
    ///   - ressource présente (cas impossible aujourd'hui, mais traité
    ///     honnêtement) : il manquerait encore l'adaptateur
    ///     `MLModel` → `BeatActivationModel`, dont l'interface dépend des
    ///     entrées/sorties du modèle entraîné. Renvoyer un objet « qui ferait
    ///     semblant » serait exactement ce qu'interdit le §29A ; on journalise
    ///     l'incohérence et on renvoie `nil` pour que le fallback
    ///     déterministe s'applique (§86).
    static func beatActivationModel(in bundle: Bundle = .main) -> (any BeatActivationModel)? {
        guard isBeatDownbeatModelEmbedded(in: bundle) else {
            // Cas nominal actuel : aucun modèle embarqué → fallback §86.
            return nil
        }
        AppLogger(category: .analysis).error(
            "Ressource \(beatDownbeatDescriptor.resourceName) présente dans le bundle mais aucun "
            + "adaptateur Core ML n'est implémenté (Jalon 11 non terminé, §29A) : "
            + "moteur déterministe conservé."
        )
        return nil
    }

    /// Version du modèle Core ML réellement utilisé, à conserver avec
    /// `analysisVersion` et `scoreVersion` (§61).
    ///
    /// - Returns: `nil` tant qu'aucun modèle n'est chargé — une analyse
    ///   produite sans modèle n'a PAS de version de modèle, et inventer une
    ///   chaîne (`"v1"`, `"none"`, un numéro de build…) rendrait le
    ///   versionnement §61 mensonger.
    ///
    /// Implémentation future : lire la métadonnée de version du `MLModel`
    /// chargé (`modelDescription.metadata[.versionString]`), écrite lors de
    /// l'export `ml/export_coreml/` et reprise dans la model card (§29A).
    static func beatActivationModelVersion(in bundle: Bundle = .main) -> String? {
        // Aucun modèle n'est jamais chargé par `beatActivationModel` (voir
        // ci-dessus) : la version est donc TOUJOURS `nil` aujourd'hui.
        // Le paramètre `bundle` existe pour la symétrie de l'API et pour
        // l'implémentation future (lecture des métadonnées du modèle chargé
        // depuis CE bundle).
        nil
    }
}
