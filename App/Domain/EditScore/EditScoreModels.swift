//
//  EditScoreModels.swift
//  MontageMusical
//
//  Partition de montage — spécification §13, §13.1, §13.2 (verbatim)
//  + geste de montage (support, types §27).
//

import Foundation

// MARK: - Modes de rythme

/// PIVOT DU 16 AOÛT 2026 — ÉCART MAJEUR ASSUMÉ PAR RAPPORT À §13.
///
/// Les trois modes de la spécification (Fluide / Équilibré / Percutant)
/// étaient trois DENSITÉS de coupe, produites par une interprétation
/// dramaturgique du morceau — sections, phrases, tension, nouveauté,
/// montées, gestes, neuf poids d'utilité, sélection gloutonne. Aucune de
/// ces interprétations n'a jamais été validée à l'oreille (§74 : les huit
/// mesures demandées n'ont jamais été relevées).
///
/// Les trois modes deviennent trois FAMILLES DE FRAPPE. Une partition par
/// famille, et chaque coupe tombe exactement sur une frappe de cette
/// famille. Ce que le moteur promet devient vérifiable en une écoute, ce
/// qui n'était pas le cas de « cette section est une accumulation ».
///
/// CONSÉQUENCE ACTÉE : l'imbrication §70 (Fluide ⊆ Équilibré ⊆ Percutant)
/// DISPARAÎT. Kick, caisse claire et charley sont des ensembles disjoints,
/// pas emboîtés — l'invariant le plus structurant du générateur précédent
/// n'a plus d'objet. Le verrou §65 (le mode se verrouille à la première
/// association) prend donc encore plus de poids : changer de mode après
/// coup n'est plus une fusion de cases, c'est une autre grille.
///
/// La couche dramaturgique n'est pas supprimée, elle est MISE EN SOMMEIL :
/// `DeterministicMusicAnalyzer` continue de la produire, plus personne ne
/// la lit. C'est réversible tant que ce commentaire est là pour le dire.
enum PaceMode: String, Codable, CaseIterable {
    /// Grave : grosse caisse, kick distordu.
    case kick
    /// Médium large bande : caisse claire, clap.
    case snare
    /// Aigu : charley, shaker, cymbale.
    case hat

    /// Famille percussive correspondante. Les deux énumérations sont
    /// volontairement distinctes : `PercussiveClass` appartient à l'analyse,
    /// `PaceMode` est ce qui est PERSISTÉ dans `ProjectSlotRecord` (§10.1)
    /// et affiché. Les faire coïncider par ce pont plutôt que par un alias
    /// laisse la possibilité d'ajouter une famille sans toucher au schéma.
    var percussiveClass: PercussiveClass {
        switch self {
        case .kick: .kick
        case .snare: .snare
        case .hat: .hat
        }
    }

    init(percussiveClass: PercussiveClass) {
        switch percussiveClass {
        case .kick: self = .kick
        case .snare: self = .snare
        case .hat: self = .hat
        }
    }
}

// MARK: - Famille de partitions (spec §13)

struct EditScoreFamily: Codable, Sendable {
    let analysisVersion: Int
    let kick: EditScore
    let snare: EditScore
    let hat: EditScore

    /// Partition d'un mode donné — évite d'avoir à répéter le `switch`
    /// partout où l'on passe d'un mode à sa partition.
    func score(for mode: PaceMode) -> EditScore {
        switch mode {
        case .kick: kick
        case .snare: snare
        case .hat: hat
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
