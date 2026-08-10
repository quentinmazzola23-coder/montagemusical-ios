//
//  SlotCardView.swift
//  MontageMusical
//
//  Carte d'une case du carrousel d'assemblage — Jalon 7, spec §35.2.
//  États : vide (« Plan N » + durée + « + »), remplie (placeholder de
//  miniature neutre + numéro + durée + coche — la vraie miniature arrive
//  au Jalon 8), téléchargement (§44), indisponible (§64), trop courte,
//  vérification. Matériaux sobres §37, aucune animation décorative §38,
//  accessibilité §39 (« Plan 7, durée requise 1 virgule 20 seconde,
//  rempli »).
//

import SwiftUI

/// Carte d'une case du carrousel (§35.2). Vue d'AFFICHAGE pure : le toucher
/// (sélection, ajout de vidéo) est géré par le parent (`AssemblyView`).
///
/// - La largeur tactile stable est IMPOSÉE par le parent (§35.2) : la carte
///   remplit la largeur proposée ;
/// - la case active est légèrement mise en avant : trait renforcé + échelle
///   1,0 contre 0,96 — simple changement d'état, SANS animation (§38, le
///   glissement vers la case suivante est orchestré par le parent) ;
/// - chaque état est distingué par sa forme et son texte, jamais par la
///   seule couleur (§39).
struct SlotCardView: View {
    let item: AssemblySlotItem
    let isActive: Bool

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 132)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16).strokeBorder(
                    isActive
                        ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                        : AnyShapeStyle(HierarchicalShapeStyle.quaternary),
                    lineWidth: isActive ? 2 : 1
                )
            )
            // Mise en avant légère de la case active — valeur d'état, aucune
            // animation attachée (§38).
            .scaleEffect(isActive ? 1.0 : 0.96)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Contenu par état (§35.2)

    @ViewBuilder
    private var content: some View {
        switch item.state {
        case .empty:
            // Calque du gabarit spec §35.2 : « Plan 8 » / « 1,20 s » / « + ».
            VStack(spacing: 6) {
                planText
                durationText
                Image(systemName: "plus")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

        case .ready:
            // Ordre spec §35.2 : miniature, numéro, durée, coche.
            VStack(spacing: 8) {
                thumbnailPlaceholder
                HStack(spacing: 6) {
                    planText
                    durationText
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
            }

        case .downloading:
            // §44 : téléchargement iCloud en cours — la case reste visible
            // et navigable, jamais considérée prête avant résolution.
            VStack(spacing: 6) {
                planText
                ProgressView()
                durationText
            }

        case .resolving:
            VStack(spacing: 6) {
                planText
                ProgressView()
                Text("Vérification…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .unavailable:
            // §64 : asset supprimé ou inaccessible — état sobre.
            VStack(spacing: 6) {
                planText
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Indisponible")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .tooShort:
            // Un rush trop court ne peut jamais remplir une case (§3.8).
            VStack(spacing: 6) {
                planText
                Image(systemName: "exclamationmark.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Trop courte")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Briques communes

    /// Placeholder de miniature neutre (Jalon 7). La vraie miniature PhotoKit
    /// arrive au Jalon 8 — aucun verre permanent par-dessus (§37).
    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .frame(height: 56)
            .overlay(
                Image(systemName: "video.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            )
    }

    private var planText: some View {
        Text(planLabel)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
    }

    private var durationText: some View {
        Text(item.duration.shortDurationString)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Numérotation humaine : l'index persisté est 0-based (§10.1), la case
    /// affichée est « Plan index + 1 » (§35.2 : « Plan 8 »).
    private var planLabel: String {
        "Plan \(item.index + 1)"
    }

    // MARK: - Accessibilité (§39)

    /// Calque EXACT de l'exemple spec §39 :
    /// « Plan 7, durée requise 1 virgule 20 seconde, rempli ».
    private var accessibilityLabel: String {
        "\(planLabel), durée requise \(item.duration.spokenString), \(stateSpokenLabel)"
    }

    /// Source UNIQUE du vocabulaire d'état (§39 : cohérent sur tout
    /// l'écran) — `AssemblySlotState.spokenLabel`.
    private var stateSpokenLabel: String {
        item.state.spokenLabel
    }
}

// MARK: - Previews

#Preview("États des cases") {
    let base: [(AssemblySlotState, Int64)] = [
        (.empty, 72_000),
        (.ready, 72_000),
        (.downloading, 120_000),
        (.resolving, 60_000),
        (.unavailable, 90_000),
        (.tooShort, 45_000)
    ]
    return ScrollView {
        VStack(spacing: 16) {
            ForEach(Array(base.enumerated()), id: \.offset) { entry in
                SlotCardView(
                    item: AssemblySlotItem(
                        id: UUID(),
                        index: entry.offset + 6,
                        start: MediaTime(ticks: Int64(entry.offset) * 100_000),
                        end: MediaTime(ticks: Int64(entry.offset) * 100_000 + entry.element.1),
                        state: entry.element.0
                    ),
                    isActive: entry.offset == 1
                )
                .frame(width: 150)
            }
        }
        .padding()
    }
}
