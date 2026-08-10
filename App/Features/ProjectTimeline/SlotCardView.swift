//
//  SlotCardView.swift
//  MontageMusical
//
//  Carte d'une case du carrousel d'assemblage — Jalon 7, spec §35.2.
//  États : vide (« Plan N » + durée + « + »), remplie (miniature RÉELLE du
//  rush fournie par le parent depuis le Jalon 8 — placeholder neutre tant
//  qu'elle n'est pas chargée + numéro + durée + coche), téléchargement
//  (§44), indisponible (§64), trop courte, vérification. Matériaux sobres
//  §37, aucune animation DÉCORATIVE §38 (la seule animation de la carte est
//  le « morphing doux case vide → miniature » EXIGÉ par §38, décrit plus
//  bas), accessibilité §39 (« Plan 7, durée requise 1 virgule 20 seconde,
//  rempli »).
//
//  Jalon 12 (§39/§87) — DYNAMIC TYPE : les hauteurs de la carte et de sa
//  miniature ne sont plus des constantes. Elles passent par `@ScaledMetric`
//  (base `SlotCardView.baseMinHeight` / `baseThumbnailHeight`) et grandissent
//  donc avec la taille de texte choisie par l'utilisateur, jusqu'aux tailles
//  d'accessibilité AX1–AX5 où le contenu était auparavant TRONQUÉ.
//  `minHeight` (et non `height`) : la carte peut toujours dépasser sa hauteur
//  de référence si son contenu l'exige. La LARGEUR, elle, reste imposée par
//  le parent (§35.2 : « les cartes ont une largeur tactile stable ») — elle
//  ne dépend pas de la taille de texte.
//
//  Jalon 12 (§38) — « MORPHING DOUX CASE VIDE → MINIATURE » : §38 demande
//  QUATRE retours, deux haptiques (association réussie, asset invalide) et
//  deux ANIMATIONS (« glissement vers la prochaine case », orchestré par le
//  parent `AssemblyView`, et « morphing doux case vide → miniature », porté
//  ICI). Ce fondu court est, avec le glissement du carrousel, la SEULE
//  animation du projet : tout le reste demeure sans animation décorative
//  (§38 « aucune animation décorative longue »). Il est NEUTRALISÉ quand
//  « Réduire les animations » est actif (§38/§87), par le MÊME mécanisme que
//  `reduceMotionSafe()` (App/Core/DesignSystem/ReduceMotion.swift) : lecture
//  de `\.accessibilityReduceMotion`, puis animation `nil`.
//

import SwiftUI
import UIKit

/// Carte d'une case du carrousel (§35.2). Vue d'AFFICHAGE pure : le toucher
/// (sélection, ajout de vidéo) est géré par le parent (`AssemblyView`).
///
/// - La largeur tactile stable est IMPOSÉE par le parent (§35.2) : la carte
///   remplit la largeur proposée ;
/// - la case active est légèrement mise en avant : trait renforcé + échelle
///   1,0 contre 0,96 — simple changement d'état, SANS animation (§38, le
///   glissement vers la case suivante est orchestré par le parent) ;
/// - SEULE animation de la carte : le « morphing doux case vide → miniature »
///   exigé par §38 — un fondu court sur le changement d'état et sur l'arrivée
///   de la miniature réelle, neutralisé sous « Réduire les animations » ;
/// - chaque état est distingué par sa forme et son texte, jamais par la
///   seule couleur (§39).
struct SlotCardView: View {
    /// Hauteur de RÉFÉRENCE d'une carte à la taille de texte standard
    /// (§35.2). Base du `@ScaledMetric` ci-dessous — `AssemblyView` s'en sert
    /// pour dimensionner le carrousel avec la MÊME règle (source unique).
    static let baseMinHeight: CGFloat = 132
    /// Hauteur de référence de la miniature dans la carte (§35.2).
    static let baseThumbnailHeight: CGFloat = 56

    let item: AssemblySlotItem
    let isActive: Bool
    /// Miniature RÉELLE du rush (Jalon 8, §35.2) — chargée fenêtrée par le
    /// parent (`AssemblyView`) via `ThumbnailProvider`. `nil` (défaut :
    /// previews, chargement en cours, case non prête) → placeholder neutre.
    var thumbnail: UIImage? = nil

    /// §39/§87 : la taille de texte pilote la hauteur de la carte — aux
    /// tailles d'accessibilité, elle grandit au lieu de tronquer.
    @ScaledMetric(relativeTo: .subheadline)
    private var minHeight: CGFloat = SlotCardView.baseMinHeight
    @ScaledMetric(relativeTo: .subheadline)
    private var thumbnailHeight: CGFloat = SlotCardView.baseThumbnailHeight
    /// §39 : aux tailles d'accessibilité, la ligne « numéro • durée • coche »
    /// d'une case remplie passe en colonne (elle ne tient plus côte à côte).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// §38/§87 « respecter Réduire les animations » — MÊME mécanisme que
    /// `reduceMotionSafe()` (App/Core/DesignSystem/ReduceMotion.swift) :
    /// lecture du réglage système, puis animation `nil`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            // §38 « morphing doux case vide → miniature » : le passage d'un
            // état de carte à un autre (vide → prête, en cours → prête…)
            // traverse un fondu COURT au lieu de sauter d'un gabarit à
            // l'autre. `nil` sous « Réduire les animations » → aucun fondu,
            // le changement reste instantané (§38/§87).
            .animation(morphAnimation, value: item.state)
            // Même fondu quand la miniature RÉELLE remplace le placeholder
            // neutre d'une case déjà prête (chargement fenêtré du parent,
            // Jalon 8) : c'est le second temps du « case vide → miniature ».
            .animation(morphAnimation, value: thumbnail != nil)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: minHeight)
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

    // MARK: - Animation §38 (« morphing doux case vide → miniature »)

    /// Animation du morphing exigé par §38 — `nil` dès que « Réduire les
    /// animations » est actif (§38 « respecter Réduire les animations »,
    /// §87) : `.animation(nil, value:)` n'anime RIEN, le changement d'état
    /// redevient instantané.
    ///
    /// Volontairement COURTE (0,2 s) et sans ressort : §38 interdit toute
    /// « animation décorative longue ». Avec le glissement du carrousel
    /// (`AssemblyView.slideAnimation`), c'est la seule animation du projet.
    private var morphAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
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
            // Miniature RÉELLE du rush si le parent l'a fournie (Jalon 8),
            // placeholder neutre sinon (chargement en cours, previews).
            VStack(spacing: 8) {
                if let thumbnail {
                    thumbnailImage(thumbnail)
                } else {
                    thumbnailPlaceholder
                }
                // §39/§87 : en colonne aux tailles d'accessibilité — les trois
                // éléments ne tiennent plus sur une ligne sans être tronqués.
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 4) {
                        planText
                        durationText
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                    }
                } else {
                    HStack(spacing: 6) {
                        planText
                        durationText
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                    }
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

    /// Miniature RÉELLE du rush (Jalon 8, §35.2) — `aspectFill` dans le
    /// MÊME gabarit que le placeholder (coins arrondis 8, hauteur
    /// `thumbnailHeight`, mise à l'échelle de la taille de texte §39),
    /// aucun verre permanent par-dessus (§37). L'image est posée en
    /// `overlay` d'un gabarit fixe puis rognée : sa taille intrinsèque
    /// n'influence jamais la mise en page de la carte.
    private func thumbnailImage(_ image: UIImage) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .frame(height: thumbnailHeight) // §39 : suit la taille de texte
            .overlay(
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Placeholder de miniature neutre (Jalon 7) : affiché tant que la
    /// vraie miniature PhotoKit (Jalon 8) n'est pas chargée — aucun verre
    /// permanent par-dessus (§37).
    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .frame(height: thumbnailHeight) // §39 : suit la taille de texte
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

/// Les six états §35.2/§44/§64, à largeur tactile FIXE (comme dans le
/// carrousel) : c'est la hauteur qui doit s'adapter, jamais la largeur.
///
/// `@MainActor` OBLIGATOIRE : le protocole `View` est isolé au `MainActor`
/// dans le SDK iOS 26, et cette propriété de portée FICHIER est sinon
/// `nonisolated` — construire des vues depuis un contexte non isolé ne
/// compile pas en Swift 6.
@MainActor
private var slotCardStatesPreview: some View {
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

#Preview("États des cases") {
    slotCardStatesPreview
}

// §39/§87 : contrôle visuel Dynamic Type — à cette taille, les hauteurs
// fixes du Jalon 7 tronquaient le contenu des cartes. Rien ne doit être
// coupé ici, et la largeur doit rester la même qu'en taille standard
// (§35.2 : « largeur tactile stable »).
#Preview("États des cases — accessibilité 3") {
    slotCardStatesPreview
        .environment(\.dynamicTypeSize, .accessibility3)
}
