//
//  AssemblyModels.swift
//  MontageMusical
//
//  Types d'affichage de la timeline d'assemblage — Jalon 7 (§35).
//  Non defini par la specification — definitions minimales V1.
//
//  Contrat partagé Jalon 7 : ces types sont consommés par `SlotCardView`,
//  `AssemblyMiniTimelineView` (agent Composants) et `AssemblyView`
//  (agent Écran). Ne pas modifier les signatures sans synchroniser les deux.
//

import Foundation

// MARK: - État d'affichage d'une case (dérivé de ClipAssignmentStatus §13.3)

/// État d'affichage d'une case d'assemblage.
///
/// Miroir d'affichage de `ClipAssignmentStatus` (§13.3) augmenté du cas
/// `empty` (aucune association). La dérivation depuis la persistance passe
/// UNIQUEMENT par `from(assignmentStatusRaw:)` — aucun autre endroit du code
/// ne doit interpréter `statusRaw`.
enum AssemblySlotState: Equatable, Sendable {
    /// Aucune association.
    case empty
    /// `ClipAssignmentStatus.resolving` — résolution des métadonnées en cours.
    case resolving
    /// `.downloading` — téléchargement iCloud à la demande (§44).
    case downloading
    /// `.ready` — case remplie, exportable.
    case ready
    /// `.unavailable` — asset supprimé ou inaccessible (§64).
    case unavailable
    /// `.tooShort` — rush trop court après résolution.
    case tooShort

    /// Dérivation UNIQUE depuis le `statusRaw` persisté (§13.3).
    ///
    /// - `nil` (aucune association) → `.empty` ;
    /// - rawValue inconnu (donnée corrompue ou écrite par une version
    ///   future) → `.unavailable` : repli sobre — une case au statut
    ///   illisible ne doit JAMAIS être considérée comme prête (§64, §51),
    ///   l'export partiel s'arrête donc avant elle.
    /// Forme parlée UNIQUE de l'état (§39 : même vocabulaire sur tout
    /// l'écran d'assemblage — zone haute, cartes, mini-timeline), alignée
    /// sur les libellés visibles des cartes.
    var spokenLabel: String {
        switch self {
        case .empty: "vide"
        case .resolving: "vérification en cours"
        case .downloading: "téléchargement en cours"
        case .ready: "rempli"
        case .unavailable: "indisponible"
        case .tooShort: "vidéo trop courte"
        }
    }

    static func from(assignmentStatusRaw: String?) -> AssemblySlotState {
        guard let raw = assignmentStatusRaw else { return .empty }
        guard let status = ClipAssignmentStatus(rawValue: raw) else {
            return .unavailable
        }
        switch status {
        case .resolving: return .resolving
        case .downloading: return .downloading
        case .ready: return .ready
        case .unavailable: return .unavailable
        case .tooShort: return .tooShort
        }
    }
}

// MARK: - Case d'affichage

/// Projection d'affichage d'un `ProjectSlotRecord` (§10.1) : valeur
/// `Sendable`, les enregistrements SwiftData ne traversent jamais une
/// frontière d'acteur.
struct AssemblySlotItem: Identifiable, Equatable, Sendable {
    /// Identifiant du `ProjectSlotRecord`.
    let id: UUID
    /// Index de la case dans la partition (0-based, strictement croissant).
    let index: Int
    /// Début absolu depuis le début de la musique (§9).
    let start: MediaTime
    /// Fin absolue depuis le début de la musique (§9).
    let end: MediaTime
    /// État d'affichage dérivé par `AssemblySlotState.from`.
    let state: AssemblySlotState

    /// Durée TOUJOURS calculée `end - start`, jamais stockée (§9).
    var duration: MediaTime { end - start }
}

// MARK: - Géométrie durée-proportionnelle (§35.3)

/// Grille durée-proportionnelle de la mini-timeline (§35.3) : conversion
/// entre une fraction `0...1` de la largeur et l'index de case.
///
/// Les positions sont dérivées des ticks CUMULÉS entiers (jamais
/// d'accumulation flottante — §9 appliqué au dessin) ; le flottant
/// n'apparaît qu'à la division finale par le total.
///
/// Les deux fonctions travaillent sur la POSITION dans le tableau `slots`,
/// qui doit être ordonné par index croissant (ordre produit par le store).
/// Pour une partition complète, position == `AssemblySlotItem.index`.
enum AssemblyGeometry {

    /// Index de la case sous la fraction de largeur donnée.
    ///
    /// - `fraction` est bornée à `0...1` (un glisser qui sort de la vue
    ///   reste sur la première/dernière case) ;
    /// - `nil` si `slots` est vide, ou si le total des durées est nul
    ///   (dégénéré — impossible en pratique : `endTicks > startTicks` §10.1) ;
    /// - une frontière exacte appartient à la case SUIVANTE (convention
    ///   constante), sauf `fraction == 1` qui reste sur la dernière case.
    static func slotIndex(atFraction fraction: Double, slots: [AssemblySlotItem]) -> Int? {
        guard !slots.isEmpty else { return nil }
        let total = totalTicks(of: slots)
        guard total > 0 else { return nil }

        // Défense : une fraction non finie (largeur nulle en amont) est
        // traitée comme 0 plutôt que de propager un NaN.
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0

        var cumulative: Int64 = 0
        for (position, slot) in slots.enumerated() {
            cumulative += max(0, slot.duration.ticks)
            // Frontière de fin de la case, en fraction exacte de la largeur
            // (ticks cumulés entiers, une seule division flottante).
            let endFraction = Double(cumulative) / Double(total)
            if clamped < endFraction {
                return position
            }
        }
        // clamped == 1 (ou frontière finale) : dernière case.
        return slots.count - 1
    }

    /// Plage de fractions `0...1` occupée par la case à la position donnée.
    ///
    /// `nil` si la position est hors bornes ou si le total des durées est
    /// nul. Exemple : durées 1 s / 2 s / 1 s → `fractionRange(of: 1)` vaut
    /// `0.25...0.75` (ticks cumulés 60 000 / 240 000).
    static func fractionRange(of index: Int, slots: [AssemblySlotItem]) -> ClosedRange<Double>? {
        guard slots.indices.contains(index) else { return nil }
        let total = totalTicks(of: slots)
        guard total > 0 else { return nil }

        var cumulative: Int64 = 0
        for (position, slot) in slots.enumerated() {
            let startCumulative = cumulative
            cumulative += max(0, slot.duration.ticks)
            if position == index {
                return (Double(startCumulative) / Double(total))...(Double(cumulative) / Double(total))
            }
        }
        return nil // inatteignable : `indices.contains` a validé la position
    }

    /// Somme entière des durées (ticks cumulés, aucun flottant).
    /// Les durées négatives (données incohérentes) comptent pour zéro.
    private static func totalTicks(of slots: [AssemblySlotItem]) -> Int64 {
        slots.reduce(Int64(0)) { $0 + max(0, $1.duration.ticks) }
    }
}
