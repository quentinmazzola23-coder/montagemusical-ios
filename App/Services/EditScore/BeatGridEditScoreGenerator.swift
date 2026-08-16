//
//  BeatGridEditScoreGenerator.swift
//  MontageMusical
//
//  Générateur de partitions par SUBDIVISION DE LA GRILLE — 16 août 2026,
//  second pivot.
//
//  POURQUOI CELUI-CI REMPLACE LE PRÉCÉDENT
//  ---------------------------------------
//  `PercussiveEditScoreGenerator` calait les coupes sur des frappes classées
//  en kick / caisse claire / charley. Essayé sur du matériel réel : « ça ne
//  fonctionne pas du tout ». La cause est identifiée et elle est
//  structurelle, pas un réglage de seuil.
//
//  `FeatureTimeline.bandFlux` est normalisé BANDE PAR BANDE, chacune par son
//  propre quantile 0,95 (`SpectralFeatureExtractor.normalizedRelative`). Le
//  charley à 8-11 kHz est donc remonté à la même échelle que le kick. Le
//  classificateur comparait des PROPORTIONS entre bandes déjà normalisées :
//  la part du grave tournait autour de 1/5 pour à peu près toute frappe,
//  alors qu'il en exigeait 0,45 pour un kick et 0,55 (en aigu) pour un
//  charley. Presque tout retombait donc sur la classe par défaut, la caisse
//  claire — deux rythmes sur trois quasi vides, le troisième ramassant tout.
//
//  Aucun réglage ne rattrape ça : la timeline ne conserve AUCUNE amplitude
//  brute, donc aucune comparaison inter-bandes n'y est fiable. Il fallait
//  changer d'axe, pas de constantes.
//
//  CE QUE FAIT CELUI-CI
//  --------------------
//  Il subdivise la grille rythmique. Trois alternatives = trois pas :
//  chaque temps, un temps sur deux, un temps sur quatre. C'est tout.
//
//  Pourquoi c'est robuste :
//  - la grille de beats est la partie la MIEUX TESTÉE du moteur — tempo
//    vérifié de 150 à 200 BPM avec et sans contretemps, et un oracle de
//    PHASE qui interdit une grille verrouillée sur le contretemps ;
//  - aucune comparaison entre bandes, donc aucune dépendance à une
//    normalisation ;
//  - en EDM le beat EST le kick : couper sur le temps, c'est couper sur la
//    grosse caisse, sans avoir à la reconnaître ;
//  - un seul chemin de code, une seule constante réglable (le pas).
//
//  REPLI EN CASCADE, un seul mécanisme
//  -----------------------------------
//  La règle est toujours « prendre un point sur N dans une liste triée ».
//  Seule la source change :
//  1. les beats suivis, si l'analyse en a trouvé au moins 4 ;
//  2. sinon les onsets §18, qui existent dès qu'il y a des attaques — un
//     morceau non métrique (ambiant, §63) reste ainsi découpable ;
//  3. sinon rien : une case unique couvrant le morceau (§63 garantit au
//     moins une case). Jamais de grille inventée sur du silence (§0.7).
//
//  ALIGNEMENT SUR LA MESURE
//  ------------------------
//  Quand on prend un temps sur deux ou sur quatre, la PHASE compte : « un
//  temps sur quatre » doit tomber sur les débuts de mesure, pas entre eux.
//  Le pas démarre donc au premier temps qui coïncide avec un downbeat quand
//  l'analyse en fournit ; à défaut au premier temps.
//

import Foundation

/// Erreurs de génération par subdivision.
enum GridScoreGenerationError: LocalizedError, Equatable {
    /// Morceau de durée nulle : aucune partition possible (§63).
    case emptyTrack

    var errorDescription: String? {
        switch self {
        case .emptyTrack:
            "La musique analysée a une durée nulle : aucun rythme ne peut être créé."
        }
    }
}

struct BeatGridEditScoreGenerator: EditScoreGenerating, Sendable {

    /// Version de la logique de génération (§61). 2 : le générateur par
    /// calage percussif portait 1, et ses partitions doivent être périmées.
    static let generatorVersion = 2

    /// Écart minimal entre deux coupes : 2 520 ticks = 42 ms, une image à
    /// 24 im/s. Contrainte TECHNIQUE et non réglage de densité — un plan
    /// plus court qu'une image ne peut pas être rendu, et §53 impose que la
    /// géométrie d'export soit honorée à l'image près.
    static let minimumCutSpacingTicks: Int64 = 2_520

    /// Nombre minimal de points pour qu'une source de grille soit retenue.
    /// En dessous, on descend d'un cran dans le repli plutôt que de
    /// fabriquer une partition sur deux ou trois événements isolés.
    static let minimumGridPoints = 4

    init() {}

    func generateScores(
        from analysis: MusicAnalysisResult,
        configuration: ScoreConfiguration = .production
    ) throws -> EditScoreFamily {
        let durationTicks = analysis.duration.ticks
        guard durationTicks > 0 else { throw GridScoreGenerationError.emptyTrack }

        let grid = Self.gridTicks(analysis: analysis, durationTicks: durationTicks)
        let phase = Self.downbeatPhase(grid: grid, analysis: analysis)

        return EditScoreFamily(
            analysisVersion: analysis.version,
            everyBeat: score(for: .everyBeat, grid: grid, phase: phase, durationTicks: durationTicks),
            everyTwoBeats: score(for: .everyTwoBeats, grid: grid, phase: phase, durationTicks: durationTicks),
            everyFourBeats: score(for: .everyFourBeats, grid: grid, phase: phase, durationTicks: durationTicks)
        )
    }

    // MARK: - Source de la grille

    /// Points de coupe candidats, triés, strictement dans le morceau.
    ///
    /// Repli en cascade décrit en tête de fichier. Rend un tableau vide
    /// quand aucune source ne convient — le morceau formera alors une case
    /// unique, ce qui est le comportement honnête (§0.7, §63).
    static func gridTicks(analysis: MusicAnalysisResult, durationTicks: Int64) -> [Int64] {
        let beats = analysis.beats
            .map(\.time.ticks)
            .filter { $0 > 0 && $0 < durationTicks }
            .sorted()
        if beats.count >= minimumGridPoints { return beats }

        let onsets = analysis.musicalEvents
            .filter { $0.type == .onset }
            .map(\.start.ticks)
            .filter { $0 > 0 && $0 < durationTicks }
            .sorted()
        if onsets.count >= minimumGridPoints { return onsets }

        return []
    }

    /// Index, dans la grille, du premier point qui coïncide avec un début de
    /// mesure — la phase à partir de laquelle le pas est compté.
    ///
    /// Sans mesure détectée, 0 : le pas démarre au premier point. La
    /// tolérance de coïncidence vaut la moitié d'un intervalle de grille, ce
    /// qui apparie un downbeat au temps le plus proche sans jamais sauter au
    /// suivant.
    static func downbeatPhase(grid: [Int64], analysis: MusicAnalysisResult) -> Int {
        guard grid.count >= 2, let firstBar = analysis.bars.first else { return 0 }
        let step = grid[1] - grid[0]
        guard step > 0 else { return 0 }
        let target = firstBar.start.ticks
        var bestIndex = 0
        var bestDistance = Int64.max
        for (index, tick) in grid.enumerated() {
            let distance = abs(tick - target)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestDistance <= step / 2 ? bestIndex : 0
    }

    // MARK: - Une partition

    private func score(
        for mode: PaceMode,
        grid: [Int64],
        phase: Int,
        durationTicks: Int64
    ) -> EditScore {
        var boundaries: [Int64] = [0]

        if !grid.isEmpty {
            let step = mode.gridStep
            // Le pas est compté DEPUIS la phase : les points antérieurs au
            // premier downbeat ne sont pas des coupes, sinon « un temps sur
            // quatre » ne tomberait plus sur les débuts de mesure.
            var index = phase
            while index < grid.count {
                let tick = grid[index]
                index += step
                guard let last = boundaries.last else { continue }
                // Une coupe trop proche de la précédente est IGNORÉE, jamais
                // déplacée : la déplacer la ferait tomber à côté du temps.
                guard tick - last >= Self.minimumCutSpacingTicks else { continue }
                // Il doit rester la place d'une dernière case jusqu'à la fin.
                guard durationTicks - tick >= Self.minimumCutSpacingTicks else { continue }
                boundaries.append(tick)
            }
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
                // Ni ancres ni gestes dans ce générateur : le schéma §10.1
                // conserve les champs, on y met un UUID nul déterministe
                // plutôt que d'inventer une ancre.
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
                : MediaTime(ticks: MediaTime.roundedDivision(
                    durations.reduce(0, +),
                    dividedBy: Int64(durations.count)
                )),
            minimumDuration: MediaTime(ticks: durations.min() ?? 0),
            maximumDuration: MediaTime(ticks: durations.max() ?? 0)
        )
    }

    /// UUID nul déterministe — aucune ancre derrière ces cases.
    static let noAnchorID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
