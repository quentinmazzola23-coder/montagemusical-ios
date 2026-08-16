//
//  PercussiveEditScoreGenerator.swift
//  MontageMusical
//
//  Générateur de partitions par CALAGE sur les frappes — pivot du
//  16 août 2026.
//
//  CE QUI CHANGE
//  -------------
//  `DeterministicEditScoreGenerator` construisait un champ d'ancres pondéré
//  par neuf poids d'utilité, détectait des gestes, puis sélectionnait des
//  coupes par un raffinement glouton sous contrainte de plancher, de cible
//  de durée et de seuil de gain marginal. Trois modes en sortaient, imbriqués
//  par construction (§70).
//
//  Ici : une partition par famille de frappe, et chaque coupe tombe
//  EXACTEMENT sur une frappe de cette famille. Pas de pondération, pas de
//  cible de durée, pas de sélection. Ce que le moteur promet devient
//  vérifiable en une écoute.
//
//  L'ancien générateur n'est pas supprimé : il reste compilé et testé, il
//  n'est simplement plus câblé dans `AppEnvironment`. Le pivot est
//  réversible.
//
//  LA SEULE CONTRAINTE CONSERVÉE
//  -----------------------------
//  Deux frappes plus rapprochées qu'une image vidéo ne peuvent pas être deux
//  points de coupe. Ce n'est PAS un réglage de densité — l'utilisateur a
//  explicitement demandé « une coupe par frappe » — c'est une contrainte
//  technique : un plan plus court qu'une image ne peut pas être rendu, et
//  §53 impose que la géométrie d'export soit honorée à l'image près. Le
//  plancher est donc fixé au niveau de la cadence la plus lente qu'on puisse
//  rencontrer (24 im/s → 41,7 ms), arrondi à 42 ms. Un roulement de charley
//  en doubles-croches à 150 BPM place une frappe toutes les 100 ms : il
//  passe intégralement.
//

import Foundation

/// Erreurs de génération par calage.
enum PercussiveScoreGenerationError: LocalizedError, Equatable {
    /// Morceau de durée nulle : aucune partition possible (§63).
    case emptyTrack

    var errorDescription: String? {
        switch self {
        case .emptyTrack:
            "La musique analysée a une durée nulle : aucun rythme ne peut être créé."
        }
    }
}

struct PercussiveEditScoreGenerator: EditScoreGenerating, Sendable {

    /// Version de la logique de génération (§61). Repart de 1 : ce n'est pas
    /// une évolution du générateur précédent, c'est un autre générateur.
    /// `ScoreLibrary` compare cette valeur à celle écrite dans la méta, donc
    /// toute partition produite avant le pivot est périmée.
    static let generatorVersion = 1

    /// Écart minimal entre deux coupes, en ticks canoniques : 2 520 ticks
    /// = 42 ms, soit une image à 24 im/s, la cadence la plus lente
    /// supportée. Voir l'en-tête pour le raisonnement — contrainte
    /// technique, pas réglage de densité.
    static let minimumCutSpacingTicks: Int64 = 2_520

    init() {}

    func generateScores(
        from analysis: MusicAnalysisResult,
        configuration: ScoreConfiguration = .production
    ) throws -> EditScoreFamily {
        let durationTicks = analysis.duration.ticks
        guard durationTicks > 0 else { throw PercussiveScoreGenerationError.emptyTrack }

        return EditScoreFamily(
            analysisVersion: analysis.version,
            kick: score(for: .kick, analysis: analysis, durationTicks: durationTicks),
            snare: score(for: .snare, analysis: analysis, durationTicks: durationTicks),
            hat: score(for: .hat, analysis: analysis, durationTicks: durationTicks)
        )
    }

    // MARK: - Une partition

    /// Construit la partition d'une famille.
    ///
    /// Frontières = début du morceau + chaque frappe de la famille + fin du
    /// morceau. Le début et la fin sont TOUJOURS frontières (§28.1) : sans
    /// eux la partition ne couvrirait pas le morceau et l'export laisserait
    /// des trous.
    private func score(
        for mode: PaceMode,
        analysis: MusicAnalysisResult,
        durationTicks: Int64
    ) -> EditScore {
        let target = mode.percussiveClass
        let hitTicks = analysis.percussiveHits
            .filter { $0.percussiveClass == target }
            .map(\.time.ticks)
            .filter { $0 > 0 && $0 < durationTicks }
            .sorted()

        var boundaries: [Int64] = [0]
        for tick in hitTicks {
            guard let last = boundaries.last else { continue }
            // Écart minimal : une frappe trop proche de la coupe précédente
            // est ignorée, jamais déplacée — déplacer une coupe la ferait
            // tomber à côté d'une frappe, ce qui est exactement ce que ce
            // générateur promet de ne pas faire.
            guard tick - last >= Self.minimumCutSpacingTicks else { continue }
            // Et il doit rester la place d'une dernière case jusqu'à la fin.
            guard durationTicks - tick >= Self.minimumCutSpacingTicks else { continue }
            boundaries.append(tick)
        }
        boundaries.append(durationTicks)

        var slots: [EditSlotDefinition] = []
        slots.reserveCapacity(max(boundaries.count - 1, 0))
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard end > start else { continue }
            slots.append(EditSlotDefinition(
                id: UUID(),
                index: slots.count,
                start: MediaTime(ticks: start),
                end: MediaTime(ticks: end),
                // Les ancres et gestes de §13.1/§27 n'ont plus d'objet dans
                // ce générateur. Les identifiants restent dans le schéma
                // §10.1, qui n'est pas modifié : on y met un UUID nul
                // déterministe plutôt que d'inventer une ancre.
                entryAnchorID: Self.noAnchorID,
                exitAnchorID: Self.noAnchorID,
                gestureID: nil
            ))
        }

        let durations = slots.map { $0.end.ticks - $0.start.ticks }
        return EditScore(
            mode: mode,
            slots: slots,
            gestures: [],
            averageDuration: durations.isEmpty
                ? .zero
                : MediaTime(ticks: MediaTime.roundedDivision(durations.reduce(0, +), dividedBy: durations.count)),
            minimumDuration: MediaTime(ticks: durations.min() ?? 0),
            maximumDuration: MediaTime(ticks: durations.max() ?? 0)
        )
    }

    /// UUID nul déterministe — aucune ancre derrière ces cases. Déterministe
    /// et non aléatoire : deux générations sur la même analyse doivent
    /// produire des partitions identiques (§70, non-régression).
    static let noAnchorID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
