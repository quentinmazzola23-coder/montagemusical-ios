//
//  WaveformView.swift
//  MontageMusical
//
//  Rendu sobre de la forme d'onde de la musique — Jalon 3.
//  Spec §38 : aucune animation décorative ; §39 : l'accessibilité (libellé,
//  valeur, trait bouton) est portée par la vue parente qui gère le toucher.
//

import Foundation
import SwiftUI

/// Forme d'onde en barres verticales centrées, dessinée avec `Canvas`.
///
/// - `samples` : pics normalisés `0...1` (produits par `WaveformExtractor`,
///   §16.2/§68) — environ 200 bins restent parfaitement fluides ;
/// - `progress` : position de lecture optionnelle `0...1`, matérialisée par
///   une fine barre verticale sobre (aucune animation propre : la barre suit
///   simplement les mises à jour d'état du lecteur, §38).
///
/// Couleur `.secondary` pour les barres : le contenu reste prioritaire (§37)
/// et le rendu fonctionne en mode clair comme en mode sombre (§39).
struct WaveformView: View {
    /// Pics normalisés `0...1`, un par barre.
    let samples: [Float]

    /// Position de lecture `0...1`, ou `nil` pour ne rien afficher.
    var progress: Double?

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }

            // Une barre par échantillon, largeur stable, centrage vertical.
            let step = size.width / CGFloat(samples.count)
            let barWidth = max(1, step * 0.6)
            let midY = size.height / 2

            var bars = Path()
            for (index, sample) in samples.enumerated() {
                // Défense en profondeur : le contrat garantit 0...1, mais un
                // échantillon hors bornes ne doit jamais casser le dessin.
                let clamped = CGFloat(min(max(sample, 0), 1))
                // Hauteur minimale de 2 pt : un silence reste visible comme
                // une fine ligne, la forme globale reste lisible.
                let barHeight = max(2, clamped * size.height)
                let x = CGFloat(index) * step + (step - barWidth) / 2
                bars.addRect(CGRect(
                    x: x,
                    y: midY - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                ))
            }
            context.fill(bars, with: .color(.secondary))

            // Barre de position sobre (§38 : pas d'animation décorative).
            if let progress {
                let clampedProgress = CGFloat(min(max(progress, 0), 1))
                let x = clampedProgress * size.width
                let cursor = Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height))
                context.fill(cursor, with: .color(.primary))
            }
        }
    }
}

// MARK: - Previews

#Preview("Sans lecture") {
    WaveformView(
        samples: (0..<200).map { index in
            Float(0.2 + 0.8 * abs(sin(Double(index) * 0.13)) * Double.random(in: 0.5...1))
        },
        progress: nil
    )
    .frame(height: 96)
    .padding()
}

#Preview("Lecture à 40 %") {
    WaveformView(
        samples: (0..<200).map { index in
            Float(0.2 + 0.8 * abs(sin(Double(index) * 0.13)))
        },
        progress: 0.4
    )
    .frame(height: 96)
    .padding()
}
