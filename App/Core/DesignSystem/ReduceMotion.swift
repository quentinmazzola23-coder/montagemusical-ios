//
//  ReduceMotion.swift
//  MontageMusical
//
//  Garde « Réduire les animations » — Jalon 12, spec §38 (« respecter
//  Réduire les animations ») et §87 (animations).
//
//  RAPPEL DU CHOIX DE CONCEPTION : l'application ne pose AUCUNE animation
//  décorative (§38 : « aucune animation décorative longue »). Il n'y a donc
//  rien à désactiver au sens habituel — ni fondu, ni ressort, ni morphing
//  personnalisé. Ce fichier ne retire pas une animation existante : il
//  GARANTIT qu'aucune animation implicite ne puisse s'attacher aux
//  changements de phase d'écran (contenu vide → contenu chargé, résumé →
//  progression → issue) si un contexte parent — une future feuille, un
//  `withAnimation` ajouté ailleurs, une transition système — en propageait
//  une, lorsque l'utilisateur a activé « Réduire les animations ».
//
//  L'haptique n'est PAS concernée : §38 la demande explicitement
//  (association réussie, asset invalide, issue d'export) et ce n'est pas une
//  animation. `reduceMotionSafe()` ne la touche donc pas.
//

import SwiftUI

extension View {
    /// Neutralise toute animation implicite propagée à cette vue lorsque
    /// « Réduire les animations » est actif (§38).
    ///
    /// À poser sur le CONTENU d'un écran dont l'affichage dépend d'un état
    /// (phase, statut, chargement) : c'est le seul endroit où une transition
    /// implicite pourrait apparaître dans ce projet, qui n'anime rien par
    /// ailleurs.
    func reduceMotionSafe() -> some View {
        modifier(ReduceMotionSafeModifier())
    }
}

// Non defini par la specification — definition minimale V1.
/// Implémentation de `reduceMotionSafe()` : lit
/// `\.accessibilityReduceMotion` (le réglage système « Réduire les
/// animations ») et met l'animation de la transaction courante à `nil`
/// quand il est actif.
struct ReduceMotionSafeModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            guard reduceMotion else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}
