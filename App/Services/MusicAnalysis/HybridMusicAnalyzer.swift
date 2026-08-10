//
//  HybridMusicAnalyzer.swift
//  MontageMusical
//
//  Moteur hybride avancé — niveau B (§15), Jalon 11 (§86).
//
//  ⛔ POINT DE BRANCHEMENT DU JALON 11 — JALON NON TERMINÉ.
//
//  §15 niveau B annonce : modèle Core ML beats/downbeats, half/double-time
//  plus robuste, embeddings, segmentation sémantique, build-up/drop/breakdown,
//  présence vocale, meilleure calibration des confiances. AUCUN de ces apports
//  n'est implémenté ici, parce qu'AUCUN d'eux n'est possible sans modèle
//  entraîné : ce fichier est le socle qui accueillera le chemin hybride, pas
//  le chemin hybride lui-même.
//
//  §29A « Interdiction » : « L'agent de programmation ne doit pas prétendre
//  avoir créé un modèle intelligent en ajoutant des règles aléatoires ou un
//  fichier Core ML vide. En l'absence de modèle entraîné, il implémente le
//  protocole, le fallback et les tests, puis marque clairement le jalon avancé
//  comme non terminé. » C'est exactement ce que fait ce fichier : il
//  n'invente AUCUNE analyse. Sans modèle — et même avec un modèle, tant que le
//  décodeur hybride n'existe pas — le résultat renvoyé est BIT POUR BIT celui
//  du moteur déterministe (§86 : « fallback déterministe toujours
//  disponible » ; prouvé par `HybridAnalyzerFallbackTests`).
//
//  ⚠️ NON CÂBLÉ DANS `AppEnvironment` — DÉLIBÉRÉMENT.
//  L'application continue d'utiliser `DeterministicMusicAnalyzer` directement.
//  Raisons :
//  1. brancher ce type aujourd'hui ne changerait STRICTEMENT rien au résultat
//     (délégation intégrale) : ce serait de l'indirection sans contrepartie ;
//  2. §61 exige de tracer la « version du modèle Core ML » avec l'analyse ;
//     tant que cette version est `nil` (aucun modèle), un moteur qui se
//     présente comme « hybride » dans l'environnement de production
//     laisserait croire à une analyse assistée par modèle qui n'existe pas ;
//  3. §61 encore : « ne pas modifier automatiquement un projet terminé ».
//     Changer le moteur de production doit être un acte explicite,
//     accompagné de la comparaison A/B exigée par le §86 — pas un effet de
//     bord de la préparation du socle.
//  Le câblage se fera au même moment que l'arrivée d'un modèle validé, avec
//  la mesure d'amélioration sur corpus de référence exigée par le §86.
//

import Foundation

// Non defini par la specification — definition minimale V1.
struct HybridMusicAnalyzer: MusicAnalyzing, Sendable {

    /// Le chemin hybride (décodage des activations du modèle, fusion avec les
    /// hypothèses déterministes, recalibration des confiances) N'EST PAS
    /// implémenté. Constante volontairement `false` et lisible depuis les
    /// tests : elle documente l'état du Jalon 11 dans le code lui-même, pas
    /// seulement dans un commentaire.
    static let isHybridPathImplemented = false

    /// Moteur déterministe niveau A (§15) — seul moteur produisant réellement
    /// une analyse aujourd'hui, et fallback permanent (§86).
    private let deterministic: DeterministicMusicAnalyzer

    /// Modèle d'activation beats/downbeats (§19.2), `nil` tant qu'aucun modèle
    /// entraîné et licencié n'est embarqué — c'est le cas aujourd'hui
    /// (`CoreMLModelRegistry.beatActivationModel()` renvoie toujours `nil`).
    ///
    /// Note Swift 6 : le type existentiel s'écrit `(any BeatActivationModel)?`.
    /// La signature reste celle demandée par la spécification (§19.2 :
    /// `BeatActivationModel`), avec le mot-clé `any` obligatoire.
    private let activationModel: (any BeatActivationModel)?

    private let logger = AppLogger(category: .analysis)

    init(
        deterministic: DeterministicMusicAnalyzer,
        activationModel: (any BeatActivationModel)?
    ) {
        self.deterministic = deterministic
        self.activationModel = activationModel
    }

    /// Vrai si un modèle a été injecté. N'implique PAS qu'il soit utilisé :
    /// voir `isHybridPathImplemented`.
    var hasActivationModel: Bool { activationModel != nil }

    // MARK: - MusicAnalyzing (§7) — même protocole que le niveau A (§15)

    func analyze(
        audio: ImportedAudio,
        configuration: AnalysisConfiguration,
        progress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> MusicAnalysisResult {
        guard activationModel != nil else {
            // Cas nominal actuel : aucun modèle → délégation INTÉGRALE au
            // moteur déterministe (§86). Aucune journalisation ici : ce n'est
            // pas une anomalie, c'est l'état documenté du Jalon 11, et
            // l'analyse est déjà journalisée par le moteur déterministe.
            return try await deterministic.analyze(
                audio: audio,
                configuration: configuration,
                progress: progress
            )
        }

        // TODO (Jalon 11, §19.2 / §86) — chemin hybride, à écrire QUAND un
        // modèle entraîné, converti et licencié existe :
        //   1. construire `ModelInputFeatures` (log/Mel-spectrogramme) à
        //      partir du même flux PCM que le niveau A (§16.2, §16.3) ;
        //   2. `try await model.predict(features:)` → `BeatActivations` ;
        //   3. DÉCODER hors modèle (§19.2 : post-traitement séparé) : peak
        //      picking + programmation dynamique + phase, en réutilisant les
        //      hypothèses déterministes comme prior half/double-time (§19.1) ;
        //   4. fusionner structure/fonctions (§22, §24) et RECALIBRER les
        //      confiances (§86) au lieu de les recopier ;
        //   5. tracer la version du modèle avec l'analyse (§61) ;
        //   6. comparer A/B au moteur déterministe sur corpus de référence
        //      (§86 « amélioration mesurable ») avant tout câblage.
        //
        // En attendant, on DÉLÈGUE (choix le plus sûr : l'utilisateur obtient
        // une analyse valide, jamais une erreur ni un résultat dégradé) et on
        // journalise franchement que le modèle fourni n'est pas consulté.
        // Fabriquer ici un résultat « différent » sans décodeur reviendrait à
        // simuler une intelligence inexistante — interdit par le §29A.
        logger.error(
            "Modèle d'activation fourni mais chemin hybride non implémenté "
            + "(Jalon 11 non terminé, §29A) : analyse déléguée au moteur déterministe (§86)."
        )
        return try await deterministic.analyze(
            audio: audio,
            configuration: configuration,
            progress: progress
        )
    }
}
