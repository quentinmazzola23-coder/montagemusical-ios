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

    /// Portion du morceau à mettre en avant, en fractions `0...1` du total,
    /// ou `nil` pour n'en mettre aucune. Sert au sélecteur de rushs à
    /// montrer OÙ tombe la case en cours de remplissage : hors de cette
    /// plage les barres sont estompées, dans la plage elles gardent leur
    /// contraste et deux traits verticaux en marquent les bornes.
    ///
    /// La distinction ne repose pas sur la seule couleur (§39) : l'écart
    /// d'opacité s'accompagne des deux traits de bornes.
    var highlight: ClosedRange<Double>?

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }

            // Une barre par échantillon, largeur stable, centrage vertical.
            let step = size.width / CGFloat(samples.count)
            let barWidth = max(1, step * 0.6)
            let midY = size.height / 2

            // Bornes de la portion mise en avant, en pixels. Calculées AVANT
            // le dessin des barres pour répartir celles-ci en deux chemins.
            let band: (start: CGFloat, end: CGFloat)? = highlight.map { range in
                let lower = CGFloat(min(max(range.lowerBound, 0), 1)) * size.width
                let upper = CGFloat(min(max(range.upperBound, 0), 1)) * size.width
                return (min(lower, upper), max(lower, upper))
            }

            var bars = Path()
            var dimmedBars = Path()
            for (index, sample) in samples.enumerated() {
                // Défense en profondeur : le contrat garantit 0...1, mais un
                // échantillon hors bornes ne doit jamais casser le dessin.
                let clamped = CGFloat(min(max(sample, 0), 1))
                // Hauteur minimale de 2 pt : un silence reste visible comme
                // une fine ligne, la forme globale reste lisible.
                let barHeight = max(2, clamped * size.height)
                let x = CGFloat(index) * step + (step - barWidth) / 2
                let rect = CGRect(
                    x: x,
                    y: midY - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                )
                // Une barre appartient à la portion mise en avant dès que son
                // CENTRE y tombe : au-delà de ~200 barres, une barre vaut
                // moins d'un point, et un test sur les bords ferait clignoter
                // l'appartenance d'une case à l'autre.
                if let band, x + barWidth / 2 >= band.start, x + barWidth / 2 <= band.end {
                    bars.addRect(rect)
                } else if band != nil {
                    dimmedBars.addRect(rect)
                } else {
                    bars.addRect(rect)
                }
            }
            if !dimmedBars.isEmpty {
                context.fill(dimmedBars, with: .color(.secondary.opacity(0.25)))
            }
            context.fill(bars, with: .color(.secondary))

            // Bornes de la portion : deux traits pleins. C'est eux qui
            // portent l'information quand le contraste ne suffit pas (§39),
            // et ils restent visibles même si la portion est plus étroite
            // qu'une barre — cas d'une case courte sur un long morceau.
            if let band {
                var edges = Path()
                edges.addRect(CGRect(x: band.start - 1, y: 0, width: 2, height: size.height))
                edges.addRect(CGRect(x: band.end - 1, y: 0, width: 2, height: size.height))
                context.fill(edges, with: .color(.primary))
            }

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
