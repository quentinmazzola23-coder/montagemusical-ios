//
//  AssemblyMiniTimelineView.swift
//  MontageMusical
//
//  Mini-timeline de l'écran d'assemblage — Jalon 7, spec §35.3 :
//  largeur proportionnelle aux durées, cases remplies/vides distinguées,
//  position courante, fenêtre du carrousel, limite d'export partiel (§51).
//  Toucher déplace la sélection ; glisser permet une navigation rapide.
//  ÉCART documenté (IMPLEMENTATION_STATUS.md) : la « courbe musicale
//  simplifiée » §35.3 n'est pas encore dessinée — résorption au Jalon 9
//  (waveform 200 bins déjà disponible).
//
//  Canvas pur, O(N) par frame, fluide à 300+ cases (§67, §82) : les
//  segments sont précalculés à la construction (aucun tri, aucune
//  accumulation flottante — positions par ticks CUMULÉS, §9).
//

import SwiftUI

/// Mini-timeline durée-proportionnelle (§35.3).
///
/// États visuels distincts SANS dépendre de la seule couleur (§39) :
/// - vide = contour ;
/// - remplie (`ready`) = teinte pleine `.secondary` ;
/// - téléchargement/vérification = plein atténué + trait pointillé ;
/// - indisponible/trop courte = croix fine.
///
/// Repères :
/// - position courante = barre verticale `.primary` pleine hauteur ;
/// - fenêtre du carrousel = soulignement sous la piste ;
/// - limite d'export partiel (début de la première case non prête, §51) =
///   petit marqueur triangulaire discret en haut.
///
/// Gestes : tap et glisser horizontal → `AssemblyGeometry.slotIndex` →
/// `onSelect` (index clampé, appelé uniquement quand la sélection change —
/// le debounce §59 de navigation est géré par l'écran).
struct AssemblyMiniTimelineView: View {
    let slots: [AssemblySlotItem]
    let activeIndex: Int
    /// Fenêtre du carrousel (§35.3) : indices des cases visibles.
    let windowRange: ClosedRange<Int>
    /// Toucher/glisser déplace la sélection (§35.3).
    let onSelect: (Int) -> Void

    /// Segment précalculé : fractions de largeur dérivées des ticks cumulés.
    private struct Segment {
        let startFraction: Double
        let endFraction: Double
        let state: AssemblySlotState
    }

    /// Segments précalculés à la construction — recalcul uniquement quand la
    /// vue reçoit de nouvelles valeurs, JAMAIS pendant le dessin (§67 :
    /// défilement à 60 i/s ; §82 : projet long navigable sans perte de
    /// fluidité).
    private let segments: [Segment]

    /// Fraction de la limite d'export partiel (§51) : début de la première
    /// case non prête. `nil` si toutes les cases sont prêtes (aucun trou).
    private let exportLimitFraction: Double?

    init(
        slots: [AssemblySlotItem],
        activeIndex: Int,
        windowRange: ClosedRange<Int>,
        onSelect: @escaping (Int) -> Void
    ) {
        self.slots = slots
        self.activeIndex = activeIndex
        self.windowRange = windowRange
        self.onSelect = onSelect

        // Précalcul O(N) : positions par ticks CUMULÉS entiers, une seule
        // division flottante par frontière (aucune accumulation de largeurs
        // flottantes, §9 appliqué au dessin). Aucun tri : l'ordre des index
        // est garanti par le store (§10.1 : index strictement croissant).
        let total = slots.reduce(Int64(0)) { $0 + max(0, $1.duration.ticks) }
        var built: [Segment] = []
        built.reserveCapacity(slots.count)
        var exportLimit: Double?
        if total > 0 {
            var cumulative: Int64 = 0
            for slot in slots {
                let startFraction = Double(cumulative) / Double(total)
                cumulative += max(0, slot.duration.ticks)
                let endFraction = Double(cumulative) / Double(total)
                if exportLimit == nil, slot.state != .ready {
                    // Première case non prête : frontière du préfixe
                    // exportable (§51) — les cases suivantes sont ignorées
                    // par l'export, jamais déplacées.
                    exportLimit = startFraction
                }
                built.append(Segment(
                    startFraction: startFraction,
                    endFraction: endFraction,
                    state: slot.state
                ))
            }
        }
        self.segments = built
        self.exportLimitFraction = exportLimit
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(selectionGesture(width: proxy.size.width))
        }
        // §39 : un seul élément, ajustable — VoiceOver navigue par
        // balayage vertical sans dépendre du dessin.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mini-timeline des plans")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selectClamped(activeIndex + 1)
            case .decrement: selectClamped(activeIndex - 1)
            @unknown default: break
            }
        }
    }

    // MARK: - Dessin (Canvas pur, §38 : aucune animation décorative)

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard !segments.isEmpty, size.width > 0, size.height > 0 else { return }
        let width = size.width

        // Piste centrale : marge haute pour le marqueur d'export, marge
        // basse pour le soulignement de la fenêtre du carrousel.
        let markerHeight: CGFloat = 5
        let underlineHeight: CGFloat = 2
        let trackTop = markerHeight + 1
        let trackBottom = size.height - underlineHeight - 2
        let trackHeight = trackBottom - trackTop
        guard trackHeight > 0 else { return }

        // Un chemin par classe visuelle : nombre de commandes de dessin
        // constant, coût O(N) uniquement dans la construction des rects.
        let gap: CGFloat = 1
        var filled = Path()      // ready : teinte pleine
        var attenuated = Path()  // downloading/resolving : plein atténué…
        var dashed = Path()      // … + trait pointillé (§39)
        var outlines = Path()    // vide : contour
        var crosses = Path()     // unavailable/tooShort : croix fine

        for segment in segments {
            let x0 = CGFloat(segment.startFraction) * width
            let x1 = CGFloat(segment.endFraction) * width
            // Séparation d'1 pt entre cases ; les cases très fines (< 1 pt,
            // projet 300+ plans sur petite largeur) gardent une largeur
            // minimale d'un demi-point pour rester visibles.
            let rectWidth = max(x1 - x0 - gap, min(0.5, x1 - x0))
            guard rectWidth > 0 else { continue }
            let rect = CGRect(x: x0, y: trackTop, width: rectWidth, height: trackHeight)

            switch segment.state {
            case .ready:
                filled.addRect(rect)
            case .empty:
                outlines.addRect(rect.insetBy(dx: 0.5, dy: 0.5))
            case .downloading, .resolving:
                // Les deux états « en cours » partagent le motif atténué
                // pointillé — ni prêts ni en erreur (§44).
                attenuated.addRect(rect)
                dashed.addRect(rect.insetBy(dx: 0.5, dy: 0.5))
            case .unavailable, .tooShort:
                // États bloquants (§64, §3.8) : croix fine — motif, jamais
                // la seule couleur (§39).
                outlines.addRect(rect.insetBy(dx: 0.5, dy: 0.5))
                crosses.move(to: CGPoint(x: rect.minX, y: rect.minY))
                crosses.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                crosses.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                crosses.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
        }

        // `.secondary` : sobre, lisible en clair et en sombre (§39) — même
        // convention que `WaveformView` et `MiniTimelineView`.
        context.fill(filled, with: .color(.secondary))
        context.fill(attenuated, with: .color(.secondary.opacity(0.3)))
        context.stroke(
            dashed,
            with: .color(.secondary),
            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
        )
        context.stroke(outlines, with: .color(.secondary), lineWidth: 1)
        context.stroke(crosses, with: .color(.secondary), lineWidth: 1)

        // Fenêtre du carrousel (§35.3) : soulignement sous la piste.
        if !segments.isEmpty {
            let lower = min(max(windowRange.lowerBound, 0), segments.count - 1)
            let upper = min(max(windowRange.upperBound, 0), segments.count - 1)
            if lower <= upper {
                let x0 = CGFloat(segments[lower].startFraction) * width
                let x1 = CGFloat(segments[upper].endFraction) * width
                let underline = Path(CGRect(
                    x: x0,
                    y: size.height - underlineHeight,
                    width: max(0, x1 - x0),
                    height: underlineHeight
                ))
                context.fill(underline, with: .color(.secondary))
            }
        }

        // Position courante (§35.3) : barre verticale `.primary` pleine
        // hauteur au début de la case active — même langage visuel que le
        // curseur de `WaveformView`.
        if segments.indices.contains(activeIndex) {
            let x = CGFloat(segments[activeIndex].startFraction) * width
            let barX = min(max(x - 1, 0), width - 2)
            let bar = Path(CGRect(x: barX, y: 0, width: 2, height: size.height))
            context.fill(bar, with: .color(.primary))
        }

        // Limite d'export partiel (§51) : petit marqueur triangulaire
        // discret pointant vers la frontière du préfixe exportable.
        if let exportLimitFraction {
            let half: CGFloat = 3.5
            let x = min(max(CGFloat(exportLimitFraction) * width, half), width - half)
            var triangle = Path()
            triangle.move(to: CGPoint(x: x - half, y: 0))
            triangle.addLine(to: CGPoint(x: x + half, y: 0))
            triangle.addLine(to: CGPoint(x: x, y: markerHeight))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(.primary))
        }
    }

    // MARK: - Gestes (§35.3 : toucher déplace, glisser navigue vite)

    /// `DragGesture(minimumDistance: 0)` couvre le tap (un seul événement)
    /// ET le glisser horizontal (sélection continue pendant le mouvement).
    private func selectionGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                select(atX: value.location.x, width: width)
            }
            .onEnded { value in
                select(atX: value.location.x, width: width)
            }
    }

    private func select(atX x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        // `slotIndex` borne la fraction 0...1 : un doigt qui sort de la vue
        // reste sur la première/dernière case (index clampé).
        guard let index = AssemblyGeometry.slotIndex(
            atFraction: Double(x / width),
            slots: slots
        ) else { return }
        if index != activeIndex {
            onSelect(index)
        }
    }

    private func selectClamped(_ index: Int) {
        guard !slots.isEmpty else { return }
        let clamped = min(max(index, 0), slots.count - 1)
        if clamped != activeIndex {
            onSelect(clamped)
        }
    }

    // MARK: - Accessibilité (§39)

    private var accessibilityValue: String {
        guard !slots.isEmpty else { return "Aucun plan" }
        return "Plan \(activeIndex + 1) sur \(slots.count)"
    }
}

// MARK: - Previews

private func makePreviewItems() -> [AssemblySlotItem] {
    let entries: [(Int64, AssemblySlotState)] = [
        (72_000, .ready),
        (96_000, .ready),
        (60_000, .downloading),
        (120_000, .empty),
        (84_000, .ready),
        (48_000, .unavailable),
        (108_000, .empty),
        (66_000, .tooShort),
        (90_000, .empty),
        (72_000, .resolving)
    ]
    var items: [AssemblySlotItem] = []
    var start: Int64 = 0
    for (index, entry) in entries.enumerated() {
        items.append(AssemblySlotItem(
            id: UUID(),
            index: index,
            start: MediaTime(ticks: start),
            end: MediaTime(ticks: start + entry.0),
            state: entry.1
        ))
        start += entry.0
    }
    return items
}

#Preview("Mini-timeline") {
    AssemblyMiniTimelineView(
        slots: makePreviewItems(),
        activeIndex: 3,
        windowRange: 2...4,
        onSelect: { _ in }
    )
    .frame(height: 44)
    .padding()
}

#Preview("Projet long (300 cases)") {
    // §82 : projet long navigable sans perte de fluidité.
    let durations: [Int64] = (0..<300).map { index in
        [30_000, 45_000, 24_000, 60_000, 36_000, 18_000][index % 6]
    }
    var items: [AssemblySlotItem] = []
    var start: Int64 = 0
    for (index, duration) in durations.enumerated() {
        items.append(AssemblySlotItem(
            id: UUID(),
            index: index,
            start: MediaTime(ticks: start),
            end: MediaTime(ticks: start + duration),
            state: index < 120 ? .ready : .empty
        ))
        start += duration
    }
    return AssemblyMiniTimelineView(
        slots: items,
        activeIndex: 119,
        windowRange: 118...120,
        onSelect: { _ in }
    )
    .frame(height: 44)
    .padding()
}
