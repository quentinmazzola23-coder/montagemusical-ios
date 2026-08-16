//
//  EditScoreGenerating.swift
//  MontageMusical
//
//  Protocole de génération de partitions — spécification §7 (verbatim)
//  + configuration de score (§26.3 : poids centralisés, §28.2 : planchers).
//

import Foundation

// MARK: - Protocole (spec §7, verbatim)

protocol EditScoreGenerating {
    func generateScores(
        from analysis: MusicAnalysisResult,
        configuration: ScoreConfiguration
    ) throws -> EditScoreFamily
}

// MARK: - Configuration de score

// Non defini par la specification — definition minimale V1.
// Spec §26.3 : les poids d'utilité sont centralisés dans `ScoreConfiguration`
// et couverts par des tests.
//
// Utilité conceptuelle d'une ancre (spec §26.3) :
// ```text
// utility =
//   rhythmicStrength
//   + structuralStrength
//   + novelty
//   + contrast
//   + resolutionValue
//   + expectedFutureValue
//   - inhibition
//   - uncertaintyPenalty
//   - overcutPenalty
// ```
struct ScoreConfiguration: Codable, Sendable {

    // Poids d'utilité (spec §26.3).
    var rhythmicStrength: Double
    var structuralStrength: Double
    var novelty: Double
    var contrast: Double
    var resolutionValue: Double
    var expectedFutureValue: Double
    var inhibition: Double
    var uncertaintyPenalty: Double
    var overcutPenalty: Double

    // Sous-poids de l'inhibition §26.2 (correctif S1 de la critique). Les
    // trois composantes étaient sommées sous le seul poids `inhibition`,
    // donc de plage 0…2,5 face à des indices d'attraction de plage 0…1 :
    // l'inhibition disposait ainsi de deux fois et demie le bras de levier
    // de n'importe quel autre terme, sans que ce choix soit jamais énoncé.
    // Chacune porte désormais son poids. Non defini par la specification —
    // valeurs V1, à ajuster après écoute sur matériel réel (§74).

    /// Note tenue : son sans attaques. Conditionné à une densité rythmique
    /// basse depuis le correctif S1 — sans quoi une boucle de kick, qui a
    /// une variance de flux faible donc une stabilité élevée, était lue
    /// comme une note tenue. 0,5.
    var inhibitionHeldNote: Double

    /// Maintien juste après un impact (triangle culminant à 0,5 s). Le plus
    /// défendable musicalement des trois — on ne coupe pas dans l'attaque
    /// d'un drop — donc laissé à pleine échelle. 1,0.
    var inhibitionPostImpact: Double

    /// Absence de changement : nouveauté très faible. Sous-terme déjà
    /// divisé par deux dans sa propre formule, d'où une plage effective de
    /// 0…0,25. 0,5.
    var inhibitionNoChange: Double

    // Paramètres de l'`overcutPenalty` à la sélection (§26.3, §28.1 : ne
    // pas épuiser les micro-ancres). Appliqués par le générateur, jamais
    // au niveau du champ d'ancres.

    /// Demi-largeur de la fenêtre de densité locale : les frontières déjà
    /// actives à moins de cette distance du candidat comptent dans la
    /// densité. 1,5 s. Non defini par la specification.
    var overcutDensityWindow: MediaTime

    /// Facteur d'échelle de la pénalité par frontière active au-delà de
    /// deux dans la fenêtre. Non defini par la specification.
    var overcutDensityScale: Double

    // Durées minimales initiales configurables (spec §28.2).
    // Ces valeurs sont des planchers, pas des objectifs moyens.

    /// Fluide : 0,75 s = 45 000 ticks (spec §28.2).
    var minimumSlotDurationFluid: MediaTime

    /// Équilibré : 0,40 s = 24 000 ticks (spec §28.2).
    var minimumSlotDurationBalanced: MediaTime

    /// Percutant : 0,25 s = 15 000 ticks (spec §28.2).
    var minimumSlotDurationPercussive: MediaTime

    // Paramètres de raffinement hiérarchique (spec §28.3/§28.4).
    // Non defini par la specification — valeurs V1 par défaut, à ajuster
    // après tests. L'agent Wiring n'y touche pas.

    /// Coût d'une coupe ajoutée dans `splitGain` (spec §28.3).
    /// Non defini par la specification.
    var addedCutCost: Double

    /// Seuil de gain marginal sous lequel le mode Fluide cesse de raffiner
    /// (spec §28.3 : budget par mode). Non defini par la specification.
    var splitGainThresholdFluid: Double

    /// Seuil de gain marginal du mode Équilibré.
    /// Non defini par la specification.
    var splitGainThresholdBalanced: Double

    /// Seuil de gain marginal du mode Percutant.
    /// Non defini par la specification.
    var splitGainThresholdPercussive: Double

    /// Durée cible d'une case en mode Fluide — « peu de plans, durées
    /// longues » (spec §2). 2,5 s. Non defini par la specification.
    var targetSlotDurationFluid: MediaTime

    /// Durée cible d'une case en mode Équilibré — « progression naturelle »
    /// (spec §2). 1,2 s. Non defini par la specification.
    var targetSlotDurationBalanced: MediaTime

    /// Durée cible d'une case en mode Percutant — « davantage de
    /// subdivisions » (spec §2). 0,6 s. Non defini par la specification.
    var targetSlotDurationPercussive: MediaTime

    init(
        rhythmicStrength: Double = 1.0,
        structuralStrength: Double = 1.0,
        novelty: Double = 1.0,
        contrast: Double = 1.0,
        resolutionValue: Double = 1.0,
        expectedFutureValue: Double = 1.0,
        inhibition: Double = 1.0,
        uncertaintyPenalty: Double = 1.0,
        overcutPenalty: Double = 1.0,
        inhibitionHeldNote: Double = 0.5,
        inhibitionPostImpact: Double = 1.0,
        inhibitionNoChange: Double = 0.5,
        overcutDensityWindow: MediaTime = MediaTime(ticks: 90_000),
        overcutDensityScale: Double = 0.1,
        minimumSlotDurationFluid: MediaTime = MediaTime(ticks: 45_000),
        minimumSlotDurationBalanced: MediaTime = MediaTime(ticks: 24_000),
        minimumSlotDurationPercussive: MediaTime = MediaTime(ticks: 15_000),
        addedCutCost: Double = 0.5,
        splitGainThresholdFluid: Double = 0.3,
        splitGainThresholdBalanced: Double = 0.12,
        splitGainThresholdPercussive: Double = 0.05,
        targetSlotDurationFluid: MediaTime = MediaTime(ticks: 150_000),
        targetSlotDurationBalanced: MediaTime = MediaTime(ticks: 72_000),
        targetSlotDurationPercussive: MediaTime = MediaTime(ticks: 36_000)
    ) {
        self.rhythmicStrength = rhythmicStrength
        self.structuralStrength = structuralStrength
        self.novelty = novelty
        self.contrast = contrast
        self.resolutionValue = resolutionValue
        self.expectedFutureValue = expectedFutureValue
        self.inhibition = inhibition
        self.uncertaintyPenalty = uncertaintyPenalty
        self.overcutPenalty = overcutPenalty
        self.inhibitionHeldNote = inhibitionHeldNote
        self.inhibitionPostImpact = inhibitionPostImpact
        self.inhibitionNoChange = inhibitionNoChange
        self.overcutDensityWindow = overcutDensityWindow
        self.overcutDensityScale = overcutDensityScale
        self.minimumSlotDurationFluid = minimumSlotDurationFluid
        self.minimumSlotDurationBalanced = minimumSlotDurationBalanced
        self.minimumSlotDurationPercussive = minimumSlotDurationPercussive
        self.addedCutCost = addedCutCost
        self.splitGainThresholdFluid = splitGainThresholdFluid
        self.splitGainThresholdBalanced = splitGainThresholdBalanced
        self.splitGainThresholdPercussive = splitGainThresholdPercussive
        self.targetSlotDurationFluid = targetSlotDurationFluid
        self.targetSlotDurationBalanced = targetSlotDurationBalanced
        self.targetSlotDurationPercussive = targetSlotDurationPercussive

        // Garde-fou §28.2/§70 : planchers MONOTONES (fluid ≥ balanced ≥
        // percussive). L'imbrication par séquence d'activations unique
        // (`DeterministicEditScoreGenerator`) suppose que chaque étape
        // RELÂCHE le plancher — des planchers non monotones rendraient
        // faisable en Fluide un split infaisable en Percutant et
        // briseraient Fluide ⊆ Équilibré ⊆ Percutant.
        assert(
            minimumSlotDurationFluid.ticks >= minimumSlotDurationBalanced.ticks
                && minimumSlotDurationBalanced.ticks >= minimumSlotDurationPercussive.ticks,
            "Planchers §28.2 non monotones : fluid ≥ balanced ≥ percussive requis"
        )
    }

    static let production = ScoreConfiguration()
}
