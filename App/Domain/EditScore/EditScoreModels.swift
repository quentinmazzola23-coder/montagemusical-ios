//
//  EditScoreModels.swift
//  MontageMusical
//
//  Partition de montage — spécification §13, §13.1, §13.2 (verbatim)
//  + geste de montage (support, types §27).
//

import Foundation

// MARK: - Modes de rythme

/// SECOND PIVOT DU 16 AOÛT 2026 — ÉCART MAJEUR ASSUMÉ PAR RAPPORT À §13.
///
/// Historique en deux temps, parce qu'il explique la forme actuelle :
///
/// 1. §13 définissait trois DENSITÉS (Fluide / Équilibré / Percutant),
///    produites par une interprétation dramaturgique du morceau — sections,
///    phrases, tension, nouveauté, montées, gestes, neuf poids d'utilité,
///    sélection gloutonne. Rien n'en a jamais été validé à l'oreille (§74).
/// 2. Elles sont devenues trois FAMILLES DE FRAPPE (kick / caisse claire /
///    charley). Essayé sur du matériel réel : inutilisable. `bandFlux` est
///    normalisé bande par bande, donc aucune comparaison inter-bandes n'y
///    est fiable et presque toute frappe retombait sur la même classe —
///    voir l'en-tête de `BeatGridEditScoreGenerator` pour la démonstration.
///
/// Elles sont maintenant trois PAS DE SUBDIVISION de la grille rythmique.
/// Aucune reconnaissance, aucune pondération : on prend un point sur N. En
/// EDM le temps EST le kick, donc couper sur le temps revient à couper sur
/// la grosse caisse sans avoir à la reconnaître.
///
/// CONSÉQUENCE ACTÉE, inchangée depuis le premier pivot : l'imbrication §70
/// n'est plus un invariant garanti. Elle se trouve être VRAIE ici — un temps
/// sur quatre est un sous-ensemble d'un temps sur deux, lui-même sous-ensemble
/// de chaque temps — mais c'est une propriété du pas, pas une construction
/// défendue par le code. Aucun test ne s'en réclame.
enum PaceMode: String, Codable, CaseIterable {
    /// Une coupe à chaque temps.
    case everyBeat
    /// Une coupe un temps sur deux.
    case everyTwoBeats
    /// Une coupe un temps sur quatre — le début de mesure en 4/4.
    case everyFourBeats

    /// Pas de subdivision : on retient un point de grille sur `gridStep`.
    var gridStep: Int {
        switch self {
        case .everyBeat: 1
        case .everyTwoBeats: 2
        case .everyFourBeats: 4
        }
    }
}

// MARK: - Famille de partitions (spec §13)

struct EditScoreFamily: Codable, Sendable {
    let analysisVersion: Int
    let everyBeat: EditScore
    let everyTwoBeats: EditScore
    let everyFourBeats: EditScore

    /// Partition d'un mode donné — évite de répéter le `switch` partout.
    func score(for mode: PaceMode) -> EditScore {
        switch mode {
        case .everyBeat: everyBeat
        case .everyTwoBeats: everyTwoBeats
        case .everyFourBeats: everyFourBeats
        }
    }
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
