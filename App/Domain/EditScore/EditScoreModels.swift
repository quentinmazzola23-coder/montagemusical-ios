//
//  EditScoreModels.swift
//  MontageMusical
//
//  Partition de montage — spécification §13, §13.1, §13.2 (verbatim)
//  + geste de montage (support, types §27).
//

import Foundation

// MARK: - Modes de rythme (spec §13, verbatim)

enum PaceMode: String, Codable, CaseIterable {
    case fluid
    case balanced
    case percussive
}

// MARK: - Famille de partitions (spec §13, verbatim)

struct EditScoreFamily: Codable, Sendable {
    let analysisVersion: Int
    let fluid: EditScore
    let balanced: EditScore
    let percussive: EditScore
}

struct EditScore: Codable, Sendable {
    let mode: PaceMode
    let slots: [EditSlotDefinition]
    let gestures: [EditGesture]
    let averageDuration: MediaTime
    let minimumDuration: MediaTime
    let maximumDuration: MediaTime
}

// MARK: - Ancre (spec §13.1, verbatim)

enum AnchorKind: String, Codable {
    case exact
    case structural
    case soft
    case anticipatory
    case resolution
    case conditional
    case grouped
}

struct EditAnchor: Codable, Identifiable, Sendable {
    let id: UUID
    let center: MediaTime
    let optimalStart: MediaTime
    let optimalEnd: MediaTime
    let toleratedStart: MediaTime
    let toleratedEnd: MediaTime
    let kind: AnchorKind
    let hierarchyRank: Int
    let attraction: Double
    let inhibition: Double
    /// Utilité finale §26.3 au moment de la POSE de l'ancre :
    /// attraction − inhibition − pénalité d'incertitude. La valeur
    /// persistée EXCLUT le terme `overcutPenalty`, qui dépend de l'état de
    /// sélection (densité des coupes déjà activées) et n'est appliqué
    /// qu'au choix des splits (`DeterministicEditScoreGenerator.evaluate`).
    let finalUtility: Double
    let confidence: Double
    let reasons: [String]
}

// MARK: - Case (spec §13.2, verbatim)

struct EditSlotDefinition: Codable, Identifiable, Sendable {
    let id: UUID
    let index: Int
    let start: MediaTime
    let end: MediaTime
    let entryAnchorID: UUID
    let exitAnchorID: UUID
    let gestureID: UUID?
}

extension EditSlotDefinition {
    /// La durée est toujours calculée, jamais persistée comme valeur
    /// indépendante faisant autorité (spec §13.2).
    var duration: MediaTime { end - start }
}

// MARK: - Geste de montage (support, types spec §27)

// Non defini par la specification — definition minimale V1.
/// Les huit types de gestes V1 (spec §27) : accent simple, impact-maintien,
/// accélération, burst-résolution, respiration, écho d'un motif, variation,
/// réinitialisation.
enum EditGestureType: String, Codable, Sendable {
    case simpleAccent
    case impactHold
    case acceleration
    case burstResolution
    case breathing
    case motifEcho
    case variation
    case reset
}

// Non defini par la specification — definition minimale V1.
struct EditGesture: Codable, Identifiable, Sendable {
    let id: UUID
    let type: EditGestureType
    let start: MediaTime
    let end: MediaTime
    let anchorIDs: [UUID]
}
