//
//  AssignmentRules.swift
//  MontageMusical
//
//  Règles pures d'association vidéo → case : filtrage de durée (§43) et
//  avancement automatique (§46). Fonctions pures sur ticks §9, sans aucun
//  appel PhotoKit — testables unitairement (`MediaAssignmentTests`).
//

import Foundation

// Non defini par la specification — definition minimale V1.
enum AssignmentRules {

    /// Compatibilité de durée (§43) :
    ///
    /// ```text
    /// assetDuration >= slotEnd - slotStart
    /// ```
    ///
    /// L'égalité EXACTE est acceptée (§43 : « une égalité exacte est
    /// acceptée si la plage est réellement insérable »).
    ///
    /// S'applique aux DEUX étapes du §43 avec la même règle :
    /// - premier filtre : `assetTicks` = `PHAsset.duration` (métadonnée,
    ///   convertie en ticks à la frontière §9) ;
    /// - validation finale : `assetTicks` = durée réelle de l'`AVAsset`
    ///   résolu (`load(.duration)`). Si le premier filtre annonçait
    ///   compatible mais que la validation finale échoue, l'association est
    ///   refusée (`MediaLibraryError.assetTooShort`) et la case reste vide.
    ///
    /// - Parameters:
    ///   - assetTicks: durée de l'asset en ticks (§9).
    ///   - requiredTicks: durée requise de la case en ticks (`end - start`).
    static func isDurationCompatible(assetTicks: Int64, requiredTicks: Int64) -> Bool {
        assetTicks >= requiredTicks
    }

    /// Prochaine case à sélectionner après une association valide (§46 :
    /// « sélectionner la prochaine case vide après la case courante »).
    ///
    /// Règle :
    /// - première case vide STRICTEMENT après `index` (jamais `index`
    ///   lui-même) ;
    /// - sinon, REBOUCLAGE au début : première case vide avant `index`.
    ///   Non defini par la specification — le §46 ne dit pas quoi faire
    ///   quand il ne reste des cases vides QU'AVANT la case courante ;
    ///   choix V1 : reboucler plutôt que s'arrêter, pour que
    ///   l'enchaînement continue tant qu'il reste des cases vides ;
    /// - `nil` si aucune case vide ne reste — l'appelant affiche alors
    ///   « Montage complet » et propose Fermer/Prévisualiser (§46).
    ///
    /// - Parameters:
    ///   - index: index de la case courante (celle qui vient d'être
    ///     remplie).
    ///   - emptySlotIndexes: index des cases vides (l'ordre d'entrée est
    ///     indifférent — trié en interne).
    static func nextEmptySlotIndex(after index: Int, emptySlotIndexes: [Int]) -> Int? {
        let sorted = emptySlotIndexes.sorted()
        if let next = sorted.first(where: { $0 > index }) {
            return next
        }
        return sorted.first(where: { $0 < index })
    }
}
