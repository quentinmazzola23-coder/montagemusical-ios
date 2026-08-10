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

    // Durées minimales initiales configurables (spec §28.2).
    // Ces valeurs sont des planchers, pas des objectifs moyens.

    /// Fluide : 0,75 s = 45 000 ticks (spec §28.2).
    var minimumSlotDurationFluid: MediaTime

    /// Équilibré : 0,40 s = 24 000 ticks (spec §28.2).
    var minimumSlotDurationBalanced: MediaTime

    /// Percutant : 0,25 s = 15 000 ticks (spec §28.2).
    var minimumSlotDurationPercussive: MediaTime

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
        minimumSlotDurationFluid: MediaTime = MediaTime(ticks: 45_000),
        minimumSlotDurationBalanced: MediaTime = MediaTime(ticks: 24_000),
        minimumSlotDurationPercussive: MediaTime = MediaTime(ticks: 15_000)
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
        self.minimumSlotDurationFluid = minimumSlotDurationFluid
        self.minimumSlotDurationBalanced = minimumSlotDurationBalanced
        self.minimumSlotDurationPercussive = minimumSlotDurationPercussive
    }

    static let production = ScoreConfiguration()
}
