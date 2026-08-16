//
//  MusicAnalysisModels.swift
//  MontageMusical
//
//  Modèles d'analyse musicale — spécification §12, §12.1–§12.5 (verbatim)
//  + types de support minimaux (§23 pour les descripteurs et courbes).
//

import Foundation

// MARK: - Résultat d'analyse (spec §12, verbatim)

struct MusicAnalysisResult: Codable, Sendable {
    let version: Int
    let duration: MediaTime
    let rhythmHypotheses: [RhythmHypothesis]
    let selectedRhythmHypothesisID: UUID
    let beats: [BeatEvent]
    let bars: [BarEvent]
    let structuralUnits: [StructuralUnit]
    let functionalStates: [FunctionalStateInterval]
    let musicalEvents: [MusicalEvent]
    let eventRelations: [EventRelation]
    let continuousCurves: ContinuousCurves
    let analysisConfidence: ConfidenceBreakdown

}

// MARK: - Hypothèse rythmique (spec §12.1, verbatim)

struct RhythmHypothesis: Codable, Sendable {
    let id: UUID
    let tempoBPM: Double
    let tempoCurve: [TimedValue]
    let meterNumerator: Int?
    let meterDenominator: Int?
    let phaseOffset: MediaTime
    let probability: Double
    let halfTimeRelation: UUID?
    let doubleTimeRelation: UUID?
}

// MARK: - UMS — Unité musicale structurelle (spec §12.2, verbatim)

enum StructuralLevel: String, Codable {
    case microEvent
    case beat
    case bar
    case phrase
    case section
    case globalArc
}

struct StructuralUnit: Codable, Identifiable, Sendable {
    let id: UUID
    let parentID: UUID?
    let level: StructuralLevel
    let start: MediaTime
    let end: MediaTime
    let repetitionGroupID: UUID?
    let boundaryStrengthIn: Double
    let boundaryStrengthOut: Double
    let descriptors: MusicalDescriptorVector
    let confidence: Double
}

// MARK: - Fonctions musicales universelles (spec §12.3, verbatim)

enum MusicalFunction: String, Codable {
    case exposition
    case accumulation
    case anticipation
    case suspension
    case impact
    case sustain
    case release
    case transition
    case contrast
    case conclusion
    case unknown
}

// MARK: - Événements (spec §12.4, verbatim)

enum MusicalEventGeometry: String, Codable {
    case point
    case interval
}

enum MusicalEventType: String, Codable {
    case onset
    case accent
    case downbeat
    case phraseBoundary
    case sectionBoundary
    case buildUp
    case suspension
    case impact
    case fill
    case breakdown
    case vocalPhrase
    case silence
    case release
    case unknown
}

struct MusicalEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let type: MusicalEventType
    let geometry: MusicalEventGeometry
    let start: MediaTime
    let end: MediaTime?
    let salience: Double
    let confidence: Double
    let evidence: [EvidenceContribution]
}

// MARK: - Relations (spec §12.5, verbatim)

enum EventRelationType: String, Codable {
    case contains
    case prepares
    case resolves
    case repeats
    case transforms
    case contrasts
    case interrupts
    case sustains
}

// Non defini par la specification — definition minimale V1.
struct EventRelation: Codable, Identifiable, Sendable {
    let id: UUID
    let type: EventRelationType
    let sourceEventID: UUID
    let targetEventID: UUID
    let confidence: Double
}

// MARK: - Types de support

// Non defini par la specification — definition minimale V1.
struct TimedValue: Codable, Sendable {
    let time: MediaTime
    let value: Double
}

// Non defini par la specification — definition minimale V1.
struct BeatEvent: Codable, Sendable {
    let time: MediaTime
    let strength: Double
    let confidence: Double
}

// Non defini par la specification — definition minimale V1.
struct BarEvent: Codable, Sendable {
    let start: MediaTime
    let end: MediaTime
    let index: Int
    let confidence: Double
}

// Non defini par la specification — definition minimale V1.
struct FunctionalStateInterval: Codable, Sendable {
    let function: MusicalFunction
    let start: MediaTime
    let end: MediaTime
    let confidence: Double
}

// Non defini par la specification — definition minimale V1.
// Dimensions de l'état musical continu (spec §23) : énergie, densité
// rythmique, tension, nouveauté, stabilité, régularité, présence vocale,
// présence des graves.
struct MusicalDescriptorVector: Codable, Sendable {
    let energy: Double
    let rhythmicDensity: Double
    let tension: Double
    let novelty: Double
    let stability: Double
    let regularity: Double
    let vocalPresence: Double
    let bassPresence: Double
}

// Non defini par la specification — definition minimale V1.
struct EvidenceContribution: Codable, Sendable {
    let source: String
    let weight: Double
}

// Non defini par la specification — definition minimale V1.
// Une courbe `[TimedValue]` par dimension de l'état musical continu (spec §23).
struct ContinuousCurves: Codable, Sendable {
    let energy: [TimedValue]
    let density: [TimedValue]
    let tension: [TimedValue]
    let novelty: [TimedValue]
    let stability: [TimedValue]
    let regularity: [TimedValue]
    let vocalPresence: [TimedValue]
    let bassPresence: [TimedValue]
}

// Non defini par la specification — definition minimale V1.
struct ConfidenceBreakdown: Codable, Sendable {
    let overall: Double
    let rhythm: Double
    let structure: Double
    let functions: Double
}
