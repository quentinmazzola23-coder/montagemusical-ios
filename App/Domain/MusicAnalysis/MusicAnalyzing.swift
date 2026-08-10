//
//  MusicAnalyzing.swift
//  MontageMusical
//
//  Protocole d'analyse musicale — spécification §7 (verbatim)
//  + configuration d'analyse (§16) et progression par phases (§33).
//

import Foundation

// MARK: - Protocole (spec §7, verbatim)

protocol MusicAnalyzing {
    func analyze(
        audio: ImportedAudio,
        configuration: AnalysisConfiguration,
        progress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> MusicAnalysisResult
}

// MARK: - Configuration d'analyse

// Non defini par la specification — definition minimale V1.
// Spec §16.3 : les valeurs exactes (tailles FFT, hops, fenêtre) doivent être
// configurables ici, pas dispersées dans le code.
struct AnalysisConfiguration: Codable, Sendable {

    /// Une branche de représentation multirésolution (spec §16.3).
    struct FFTBranch: Codable, Sendable {
        let fftSize: Int
        let hopSize: Int
    }

    /// Fenêtre d'analyse (spec §16.3 : fenêtre de Hann).
    enum WindowFunction: String, Codable, Sendable {
        case hann
    }

    /// Fréquence d'échantillonnage du flux d'analyse (spec §16.2 :
    /// 22 050 Hz pour la première implémentation).
    let analysisSampleRate: Int

    /// Branche courte : FFT 1 024, hop 256 (spec §16.3).
    let shortBranch: FFTBranch

    /// Branche moyenne : FFT 2 048, hop 512 (spec §16.3).
    let mediumBranch: FFTBranch

    /// Branche longue : FFT 4 096, hop 1 024 (spec §16.3).
    let longBranch: FFTBranch

    /// Fenêtre appliquée avant FFT (spec §16.3).
    let window: WindowFunction

    static let production = AnalysisConfiguration(
        analysisSampleRate: 22_050,
        shortBranch: FFTBranch(fftSize: 1_024, hopSize: 256),
        mediumBranch: FFTBranch(fftSize: 2_048, hopSize: 512),
        longBranch: FFTBranch(fftSize: 4_096, hopSize: 1_024),
        window: .hann
    )
}

// MARK: - Progression d'analyse (spec §33)

// Non defini par la specification — definition minimale V1.
/// Les cinq phases compréhensibles affichées pendant l'analyse (spec §33).
enum AnalysisPhase: String, Codable, CaseIterable, Sendable {
    case audioPreparation
    case pulseAndTempo
    case phrasesAndStructure
    case buildUpsAndImpacts
    case rhythmCreation

    /// Libellé français affichable (spec §33).
    var displayLabel: String {
        switch self {
        case .audioPreparation: return "Préparation audio"
        case .pulseAndTempo: return "Pulsation et tempo"
        case .phrasesAndStructure: return "Phrases et structure"
        case .buildUpsAndImpacts: return "Montées et impacts"
        case .rhythmCreation: return "Création des rythmes"
        }
    }
}

// Non defini par la specification — definition minimale V1.
/// Spec §33 : ne pas afficher de faux pourcentage si la durée des phases
/// n'est pas calibrée. Préférer : phase courante + étapes terminées.
struct AnalysisProgress: Codable, Sendable {
    let phase: AnalysisPhase
    let completedPhases: [AnalysisPhase]
}
