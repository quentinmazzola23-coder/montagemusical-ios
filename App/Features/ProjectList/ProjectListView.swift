import SwiftUI

/// Écran d'accueil (spec §31) — Jalon 0 : état vide uniquement.
///
/// - État vide : « Aucun projet » + sous-texte.
/// - Gros bouton `+` circulaire centré en bas, au-dessus de la safe area :
///   règle du pouce §30, aucune action essentielle en haut de l'écran.
/// - Le bouton est inerte pour l'instant : le Jalon 2 branchera la création
///   du projet (créer, générer le titre, ouvrir immédiatement la timeline).
/// - Matériau translucide sobre pour le bouton principal (§37), sans
///   animation décorative (§38).
struct ProjectListView: View {
    var body: some View {
        ZStack {
            emptyState
            VStack {
                Spacer()
                createButton
            }
        }
    }

    /// État vide §31 : la liste des projets (Jalon 2) remplacera ce contenu
    /// lorsque des projets existeront.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Aucun projet")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Touchez + pour créer votre premier montage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    /// Gros bouton `+` circulaire (§31), centré au-dessus de la safe area.
    /// Cible tactile ≥ 44 points (§39). Inerte au Jalon 0.
    private var createButton: some View {
        Button {
            // Jalon 2 : créer le projet, générer le titre,
            // puis ouvrir immédiatement la timeline (§31).
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 64, height: 64)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Créer un projet")
        .padding(.bottom, 16)
    }
}

#Preview {
    ProjectListView()
}
