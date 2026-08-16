//
//  AnchorField.swift
//  MontageMusical
//
//  Champ d'ancres éditoriales (Jalon 5, niveau A) :
//  - §26.1 attraction (raisons de couper), §26.2 inhibition (raisons de ne
//    pas couper), §26.3 utilité finale avec les 9 poids de
//    `ScoreConfiguration` ;
//  - §13.1 ancres typées, hiérarchisées, avec fenêtres optimale/tolérée ;
//  - §29 explicabilité : chaque ancre stocke ses raisons en français.
//
//  DÉTERMINISTE : aucun aléatoire hors UUID d'identité ; tous les tris
//  reposent sur (ticks, rang, utilité), jamais sur les UUID.
//

import Foundation

// MARK: - Champ d'ancres

// Non defini par la specification — definition minimale V1.
/// Résultat de la pose d'ancres : la liste complète triée par `center`
/// croissant, et l'ensemble des ancres **majeures** (début + fin +
/// frontières structurelles de rang ≤ 1) — communes aux trois modes
/// (spec §28.1 : « les ancres majeures restent dans les trois modes »).
struct AnchorField: Sendable {
    /// Ancres triées par `center` croissant, centres uniques (candidats
    /// co-localisés fusionnés composante par composante, puis déduplication
    /// à 60 ms près — voir `coalesceColocated` et `deduplicate`).
    ///
    /// Le champ est **non destructif** et **indépendant du mode** : une
    /// majeure trop proche d'une autre est RÉTROGRADÉE (rang 4, sortie de
    /// `majorAnchorIDs`) et non retirée, de sorte qu'Équilibré et Percutant
    /// peuvent encore y couper. Seule la SÉLECTION est spécifique au mode.
    let anchors: [EditAnchor]

    /// Début + fin + frontières de section/phrase (`hierarchyRank` ≤ 1)
    /// **non rétrogradées**. Deux majeures consécutives sont toujours
    /// espacées d'au moins le plancher fluide §28.2 — invariant exigé par
    /// `DeterministicEditScoreGenerator.buildRoot`.
    let majorAnchorIDs: Set<UUID>
}

// MARK: - Support partagé (échantillonnage, intervalle de beat)

// Non defini par la specification — definition minimale V1.
/// Échantillonneur déterministe d'une courbe continue §23 (`[TimedValue]`) :
/// interpolation linéaire entre échantillons, bornes tenues aux extrémités.
struct AnchorCurveSampler: Sendable {

    private let ticks: [Int64]
    private let values: [Double]

    init(_ curve: [TimedValue]) {
        // Tri défensif par temps croissant (déterministe : clé = ticks).
        let sorted = curve.sorted { $0.time.ticks < $1.time.ticks }
        self.ticks = sorted.map { $0.time.ticks }
        self.values = sorted.map(\.value)
    }

    /// Valeur interpolée à l'instant `tick`. Courbe vide → 0 (jamais de
    /// valeur inventée).
    func value(at tick: Int64) -> Double {
        guard !ticks.isEmpty else { return 0 }
        if tick <= ticks[0] { return values[0] }
        if tick >= ticks[ticks.count - 1] { return values[values.count - 1] }
        var low = 0
        var high = ticks.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if ticks[mid] <= tick { low = mid } else { high = mid }
        }
        let leftTick = ticks[low]
        let rightTick = ticks[high]
        guard rightTick > leftTick else { return values[low] }
        let fraction = Double(tick - leftTick) / Double(rightTick - leftTick)
        return values[low] + (values[high] - values[low]) * fraction
    }
}

// Non defini par la specification — definition minimale V1.
/// Utilitaires partagés entre `AnchorFieldBuilder`, `GestureDetector` et
/// `DeterministicEditScoreGenerator`.
enum AnchorFieldSupport {

    /// Intervalle de beat médian en ticks. Repli 30 000 ticks (0,5 s,
    /// soit 120 BPM) quand la pulsation est absente (§63 : ambiant).
    static func medianBeatIntervalTicks(beats: [BeatEvent]) -> Int64 {
        let fallback: Int64 = 30_000
        guard beats.count > 1 else { return fallback }
        let times = beats.map(\.time.ticks).sorted()
        var gaps: [Int64] = []
        for index in 1..<times.count {
            let gap = times[index] - times[index - 1]
            if gap > 0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return fallback }
        return gaps.sorted()[gaps.count / 2]
    }
}

// MARK: - Constructeur du champ d'ancres

// Non defini par la specification — definition minimale V1.
struct AnchorFieldBuilder: Sendable {

    /// Seuils déterministes du niveau A (heuristiques documentées).
    private enum Threshold {
        /// Fusion des candidats à moins de 60 ms l'un de l'autre.
        static let mergeTicks: Int64 = 3_600
        /// Demi-fenêtre optimale minimale : 60 ms (« beat/2 borné 60 ms »).
        static let minimumOptimalHalfTicks: Int64 = 3_600
        /// Fenêtre d'anticipation d'un impact (expectedFutureValue) : 1,5 s.
        static let anticipationTicks: Int64 = 90_000
        /// Fenêtre de maintien juste après impact (§26.2) : ~1 s.
        static let postImpactTicks: Int64 = 60_000
        /// Fenêtre de recherche d'un release après impact : 2,5 s.
        static let resolutionSearchTicks: Int64 = 150_000
        /// Salience minimale d'un onset « fort » (§26.1 accent).
        static let strongOnsetSalience = 0.75
        /// Confiance sous laquelle une ancre devient `conditional` (§13.1).
        static let conditionalConfidence = 0.5

        /// **Co-localisation** : écart maximal en deçà duquel deux candidats
        /// décrivent le MÊME instant observé et sont fusionnés composante
        /// par composante AVANT évaluation (voir `coalesceColocated`).
        ///
        /// 348 ticks = 5,8 ms = **une demi-frame d'analyse**. Justification
        /// du seuil : tout ce que le moteur observe (onsets, impacts, beats,
        /// bornes de spans) est quantifié au hop de la STFT, 256 échantillons
        /// à 22 050 Hz, soit 11,61 ms = 696,6 ticks — et la conversion
        /// frame → ticks est l'unique `FeatureTimeline.mediaTime(forFrame:)`,
        /// déterministe. Deux observations DISTINCTES sont donc séparées d'au
        /// moins une frame entière ; un écart inférieur à une demi-frame ne
        /// peut provenir que de deux descriptions du même instant — cas
        /// canonique : `bar.start` EST littéralement `beats[k].time`, écart
        /// exactement 0.
        ///
        /// Le seuil reste 10× sous `mergeTicks` (60 ms), pour que la passe 1
        /// garde son rôle : arbitrer entre deux instants que l'analyse SAIT
        /// distinguer, ce qui est un vrai choix de position de coupe et non
        /// une fusion d'indices.
        static let coLocationTicks: Int64 = 348
    }

    /// Rang hiérarchique donné à une ancre majeure **rétrogradée** par la
    /// passe 2 (voir `deduplicate`) : elle sort de `majorAnchorIDs` et
    /// redevient un candidat ordinaire, au même rang que les subdivisions.
    private static let demotedHierarchyRank = 4

    /// Raison §29 ajoutée à une majeure rétrogradée (explicabilité : sans
    /// elle, l'ancre porterait « Nouvelle section » sans être frontière
    /// racine, ce qui serait incompréhensible dans l'inspecteur).
    private static let demotionReason = "Rétrogradée : majeure trop proche"

    init() {}

    // MARK: - Construction

    func build(
        from analysis: MusicAnalysisResult,
        configuration: ScoreConfiguration
    ) -> AnchorField {
        let durationTicks = analysis.duration.ticks
        guard durationTicks > 0 else {
            return AnchorField(anchors: [], majorAnchorIDs: [])
        }

        let beatTicks = AnchorFieldSupport.medianBeatIntervalTicks(beats: analysis.beats)
        let energy = AnchorCurveSampler(analysis.continuousCurves.energy)
        let novelty = AnchorCurveSampler(analysis.continuousCurves.novelty)
        let stability = AnchorCurveSampler(analysis.continuousCurves.stability)
        // Densité rythmique D (§23) — nécessaire pour distinguer une NOTE
        // TENUE d'une boucle de kick régulière : voir `heldNote` dans
        // `makeAnchor`.
        let density = AnchorCurveSampler(analysis.continuousCurves.density)
        let impactTicks = analysis.musicalEvents
            .filter { $0.type == .impact && $0.start.ticks >= 0 && $0.start.ticks <= durationTicks }
            .map(\.start.ticks)
            .sorted()

        // 1. Candidats bruts (toutes sources §26.1).
        let rawList = rawCandidates(
            analysis: analysis,
            durationTicks: durationTicks,
            impactTicks: impactTicks
        )

        // 1 bis. Fusion des candidats CO-LOCALISÉS, AVANT évaluation :
        //        deux sources qui décrivent le même instant additionnent
        //        leurs indices au lieu de s'éliminer (voir
        //        `coalesceColocated`). Après cette passe, tous les centres
        //        sont deux à deux distincts.
        let candidates = coalesceColocated(rawList)

        // 2. Évaluation §26.3 de chaque candidat → EditAnchor.
        var built: [(anchor: EditAnchor, isProtected: Bool)] = []
        built.reserveCapacity(candidates.count)
        for candidate in candidates {
            let anchor = makeAnchor(
                from: candidate,
                configuration: configuration,
                durationTicks: durationTicks,
                beatTicks: beatTicks,
                impactTicks: impactTicks,
                energy: energy,
                novelty: novelty,
                stability: stability,
                density: density
            )
            built.append((anchor, candidate.isProtected))
        }

        // 3. Déduplication : candidats à < 60 ms fusionnés (passe 1, le plus
        //    fort survit, raisons cumulées), puis paires de MAJEURES à moins
        //    du plancher fluide RÉTROGRADÉES — jamais supprimées (passe 2) —
        //    tri final par center croissant.
        let deduplicated = deduplicate(
            built,
            majorMergeTicks: configuration.minimumSlotDurationFluid.ticks
        )

        // 4. Majeures : début + fin + rang ≤ 1 (sections, phrases) — les
        //    rétrogradées de la passe 2 portent le rang 4 et sont donc
        //    exclues ici, tout en restant présentes dans `anchors`.
        let majorIDs = Set(deduplicated.filter { $0.hierarchyRank <= 1 }.map(\.id))

        return AnchorField(anchors: deduplicated, majorAnchorIDs: majorIDs)
    }

    // MARK: - Candidats bruts

    /// Source d'un candidat — détermine kind de base, rang §13.1 et
    /// largeur de fenêtre.
    private enum CandidateSource {
        case trackEdge      // début / fin du morceau (§28.1)
        case section        // bord d'UMS section
        case phrase         // bord d'UMS phrase
        case downbeat       // début de mesure
        case beat
        case impact
        case strongOnset    // accent / onset fort
        case resolution     // release après impact

        var baseKind: AnchorKind {
            switch self {
            case .trackEdge, .section, .phrase: return .structural
            case .downbeat, .beat, .impact: return .exact
            case .strongOnset: return .soft
            case .resolution: return .resolution
            }
        }

        /// Hiérarchie §13.1 : 0 = début/fin/sections, 1 = phrases,
        /// 2 = downbeats (et impacts, même précision), 3 = beats
        /// (et résolutions), 4 = onsets/subdivisions.
        var hierarchyRank: Int {
            switch self {
            case .trackEdge, .section: return 0
            case .phrase: return 1
            case .downbeat, .impact: return 2
            case .beat, .resolution: return 3
            case .strongOnset: return 4
            }
        }

        /// Ordre total EXPLICITE des sources, utilisé comme départage à
        /// `hierarchyRank` égal lors de la fusion des candidats
        /// co-localisés (règle de déterminisme du moteur : jamais d'ordre
        /// implicite d'itération ni de tri instable pour décider d'un
        /// résultat). Lit : « à instant égal et rang égal, quelle source
        /// décrit le mieux cet instant ? ».
        ///
        /// `impact` passe devant `downbeat` à rang 2 : un impact est un
        /// événement daté et raffiné à la frame de dérivée RMS maximale,
        /// plus spécifique qu'un début de mesure déduit de la grille.
        var mergeOrder: Int {
            switch self {
            case .trackEdge: return 0
            case .section: return 1
            case .phrase: return 2
            case .impact: return 3
            case .downbeat: return 4
            case .beat: return 5
            case .resolution: return 6
            case .strongOnset: return 7
            }
        }

        /// Fenêtre étroite pour `exact`, large pour structural/soft.
        var usesTightWindow: Bool {
            switch self {
            case .downbeat, .beat, .impact: return true
            case .trackEdge, .section, .phrase, .strongOnset, .resolution: return false
            }
        }
    }

    private struct RawCandidate {
        let centerTicks: Int64
        let source: CandidateSource
        /// Composante rythmique (downbeat fort, beat, impact) §26.1.
        let rhythmic: Double
        /// Composante structurelle (frontière de phrase/section) §26.1.
        let structural: Double
        /// Composante de résolution (relâchement après impact) §26.1.
        let resolution: Double
        let confidence: Double
        let reasons: [String]
        /// Début/fin du morceau : ne peut jamais être fusionné dans un
        /// autre candidat (§28.1 : toujours ancre).
        let isProtected: Bool
    }

    private func rawCandidates(
        analysis: MusicAnalysisResult,
        durationTicks: Int64,
        impactTicks: [Int64]
    ) -> [RawCandidate] {
        var candidates: [RawCandidate] = []

        func appendIfInside(_ candidate: RawCandidate) {
            guard candidate.centerTicks >= 0, candidate.centerTicks <= durationTicks else { return }
            candidates.append(candidate)
        }

        // Début du morceau — TOUJOURS ancre (§28.1).
        candidates.append(RawCandidate(
            centerTicks: 0, source: .trackEdge,
            rhythmic: 0, structural: 1.0, resolution: 0,
            confidence: 1.0, reasons: ["Début du morceau"], isProtected: true
        ))
        // Fin absolue — TOUJOURS ancre (§28.1/§28.2).
        candidates.append(RawCandidate(
            centerTicks: durationTicks, source: .trackEdge,
            rhythmic: 0, structural: 1.0, resolution: 0,
            confidence: 1.0, reasons: ["Fin du morceau"], isProtected: true
        ))

        // Frontières de section : bords des UMS de niveau .section (§12.2).
        for unit in analysis.structuralUnits where unit.level == .section {
            appendIfInside(RawCandidate(
                centerTicks: unit.start.ticks, source: .section,
                rhythmic: 0, structural: clamp01(unit.boundaryStrengthIn),
                resolution: 0, confidence: clamp01(unit.confidence),
                reasons: ["Nouvelle section"], isProtected: false
            ))
            appendIfInside(RawCandidate(
                centerTicks: unit.end.ticks, source: .section,
                rhythmic: 0, structural: clamp01(unit.boundaryStrengthOut),
                resolution: 0, confidence: clamp01(unit.confidence),
                reasons: ["Nouvelle section"], isProtected: false
            ))
        }

        // Frontières de phrase (bords des UMS .phrase), pondérées plus
        // faiblement que les sections.
        for unit in analysis.structuralUnits where unit.level == .phrase {
            appendIfInside(RawCandidate(
                centerTicks: unit.start.ticks, source: .phrase,
                rhythmic: 0, structural: 0.6 * clamp01(unit.boundaryStrengthIn),
                resolution: 0, confidence: clamp01(unit.confidence),
                reasons: ["Frontière de phrase"], isProtected: false
            ))
            appendIfInside(RawCandidate(
                centerTicks: unit.end.ticks, source: .phrase,
                rhythmic: 0, structural: 0.6 * clamp01(unit.boundaryStrengthOut),
                resolution: 0, confidence: clamp01(unit.confidence),
                reasons: ["Frontière de phrase"], isProtected: false
            ))
        }

        // Downbeats : débuts de mesures (§20). Force = beat apparié ±50 ms.
        for bar in analysis.bars {
            let matched = analysis.beats.first { abs($0.time.ticks - bar.start.ticks) <= 3_000 }
            let strength = clamp01(matched?.strength ?? 0.7)
            appendIfInside(RawCandidate(
                centerTicks: bar.start.ticks, source: .downbeat,
                rhythmic: strength, structural: 0, resolution: 0,
                confidence: clamp01(bar.confidence),
                reasons: [strength >= 0.6 ? "Downbeat fort" : "Downbeat"],
                isProtected: false
            ))
        }

        // Beats (§19).
        for beat in analysis.beats {
            let strength = clamp01(beat.strength)
            appendIfInside(RawCandidate(
                centerTicks: beat.time.ticks, source: .beat,
                rhythmic: strength, structural: 0, resolution: 0,
                confidence: clamp01(beat.confidence),
                reasons: [strength >= 0.8 ? "Beat fort" : "Beat"],
                isProtected: false
            ))
        }

        // Impacts (§12.4 musicalEvents .impact).
        for event in analysis.musicalEvents where event.type == .impact {
            appendIfInside(RawCandidate(
                centerTicks: event.start.ticks, source: .impact,
                rhythmic: clamp01(event.salience), structural: 0, resolution: 0,
                confidence: clamp01(event.confidence),
                reasons: ["Impact probable"], isProtected: false
            ))
        }

        // Accents et onsets forts (§26.1 « accent vocal »/attaques marquées).
        for event in analysis.musicalEvents where event.type == .accent {
            appendIfInside(RawCandidate(
                centerTicks: event.start.ticks, source: .strongOnset,
                rhythmic: 0.5 * clamp01(event.salience), structural: 0, resolution: 0,
                confidence: clamp01(event.confidence),
                reasons: ["Accent fort"], isProtected: false
            ))
        }
        for event in analysis.musicalEvents
        where event.type == .onset && event.salience >= Threshold.strongOnsetSalience {
            appendIfInside(RawCandidate(
                centerTicks: event.start.ticks, source: .strongOnset,
                rhythmic: 0.4 * clamp01(event.salience), structural: 0, resolution: 0,
                confidence: clamp01(event.confidence),
                reasons: ["Attaque marquée"], isProtected: false
            ))
        }

        // Résolutions : release (événement §12.4 ou état §24) survenant
        // dans la fenêtre qui suit un impact (§26.1 « résolution »).
        for event in analysis.musicalEvents where event.type == .release {
            appendIfInside(RawCandidate(
                centerTicks: event.start.ticks, source: .resolution,
                rhythmic: 0, structural: 0, resolution: clamp01(max(event.salience, 0.5)),
                confidence: clamp01(event.confidence),
                reasons: ["Résolution après impact"], isProtected: false
            ))
        }
        for state in analysis.functionalStates where state.function == .release {
            let startTicks = state.start.ticks
            let followsImpact = impactTicks.contains {
                startTicks > $0 && startTicks - $0 <= Threshold.resolutionSearchTicks
            }
            guard followsImpact else { continue }
            appendIfInside(RawCandidate(
                centerTicks: startTicks, source: .resolution,
                rhythmic: 0, structural: 0, resolution: 0.8,
                confidence: clamp01(state.confidence),
                reasons: ["Résolution après impact"], isProtected: false
            ))
        }

        return candidates
    }

    // MARK: - Fusion des candidats co-localisés (AVANT évaluation)

    /// Fusionne les candidats **co-localisés** — séparés de moins de
    /// `Threshold.coLocationTicks` — en un candidat unique dont chaque
    /// composante est le MAXIMUM de celles du groupe.
    ///
    /// ## Pourquoi (défaut corrigé)
    ///
    /// La déduplication élisait un survivant en classant par `hierarchyRank`
    /// AVANT `finalUtility`. Au tick EXACT d'un downbeat, l'ancre de barre
    /// (rang 2) et l'ancre de beat (rang 3) sont à distance **0** — `bar.start`
    /// est littéralement `beats[k].time` — et la barre gagnait par son seul
    /// rang. Or les deux portent la même attraction (pour un downbeat,
    /// `rhythmic` = force du beat co-localisé, `structural` = 0, même fenêtre
    /// étroite : le repli 0,7 de la source `downbeat` est mort puisqu'un
    /// `bar.start` est toujours apparié) mais des CONFIANCES très
    /// différentes : la barre portait la marge inter-hypothèses de métrique
    /// (~0,03–0,10), le beat porte la cohérence des intervalles (> 0,9).
    /// Avec `uncertaintyPenalty` = 1, la pénalité valait ~0,92 sur le
    /// downbeat contre ~0,1 sur le beat : `finalUtility(downbeat)` tombait
    /// ~0,8 SOUS `finalUtility(beat)`, et c'est pourtant le downbeat qui
    /// survivait. Chaque début de mesure devenait l'ancre la plus faible du
    /// niveau beat, et le générateur évitait de couper sur le « 1 ».
    ///
    /// **Règle** : une frontière de mesure ne doit jamais valoir MOINS que
    /// le beat qu'elle remplace. À instant identique il n'y a qu'un seul
    /// point de coupe possible : les sources ne sont pas concurrentes, elles
    /// sont des INDICES CONVERGENTS sur ce point. On prend donc le maximum
    /// de chaque terme (`rhythmic`, `structural`, `resolution`) et le maximum
    /// des confiances, on garde le rang le plus fort (le plus petit) et on
    /// cumule les raisons. L'utilité fusionnée est ainsi ≥ celle de chaque
    /// membre pris isolément.
    ///
    /// La fusion a lieu AVANT `makeAnchor` : c'est le seul endroit où les
    /// composantes existent encore séparément (`EditAnchor` ne persiste que
    /// `attraction`/`inhibition`/`finalUtility` agrégées). Effet secondaire
    /// souhaitable : une seule raison « Confiance x,yz » en fin de liste
    /// (§29), au lieu d'une par membre comme le produisait le cumul aval.
    ///
    /// ## Déterminisme
    ///
    /// Le tri est un ordre total STRICT — (temps, rang, ordre de source,
    /// index de production) — donc `sorted` rend une permutation unique
    /// même s'il n'est pas stable. Le regroupement se fait par rapport au
    /// PREMIER membre du groupe et non au précédent : la largeur d'un
    /// groupe est bornée par `coLocationTicks`, sans agglomération en chaîne.
    ///
    /// En sortie, tous les centres sont deux à deux distincts (deux groupes
    /// consécutifs ont des débuts séparés de plus de `coLocationTicks`, et
    /// le représentant d'un groupe reste dans sa fenêtre) — ce qui rend au
    /// passage le tri de la passe 1 lui aussi totalement ordonné.
    private func coalesceColocated(_ candidates: [RawCandidate]) -> [RawCandidate] {
        guard candidates.count > 1 else { return candidates }

        let ordered = candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.centerTicks != rhs.element.centerTicks {
                return lhs.element.centerTicks < rhs.element.centerTicks
            }
            if lhs.element.source.hierarchyRank != rhs.element.source.hierarchyRank {
                return lhs.element.source.hierarchyRank < rhs.element.source.hierarchyRank
            }
            if lhs.element.source.mergeOrder != rhs.element.source.mergeOrder {
                return lhs.element.source.mergeOrder < rhs.element.source.mergeOrder
            }
            // Départage FINAL : ordre de production de `rawCandidates`,
            // lui-même fixe. Nécessaire — deux candidats peuvent partager temps,
            // rang ET source (un accent et une attaque marquée au même tick)
            // tout en portant des raisons différentes.
            return lhs.offset < rhs.offset
        }.map(\.element)

        var result: [RawCandidate] = []
        result.reserveCapacity(ordered.count)
        var group: [RawCandidate] = []
        for candidate in ordered {
            if let first = group.first,
               candidate.centerTicks - first.centerTicks <= Threshold.coLocationTicks,
               // Même garde que la passe 1 : début ET fin du morceau sont
               // protégés (§28.1) et ne fusionnent JAMAIS entre eux, même sur
               // un morceau dégénéré plus court que `coLocationTicks` — sans
               // quoi `buildRoot` ne trouverait plus d'ancre à `durationTicks`.
               !(candidate.isProtected && group.contains(where: { $0.isProtected })) {
                group.append(candidate)
            } else {
                if !group.isEmpty { result.append(mergeColocated(group)) }
                group = [candidate]
            }
        }
        if !group.isEmpty { result.append(mergeColocated(group)) }
        return result
    }

    /// Fusionne un groupe co-localisé NON VIDE, déjà trié par
    /// `coalesceColocated`.
    private func mergeColocated(_ group: [RawCandidate]) -> RawCandidate {
        guard var dominant = group.first else {
            preconditionFailure("mergeColocated appelé sur un groupe vide")
        }
        guard group.count > 1 else { return dominant }

        // Représentant : protégé d'abord (début/fin du morceau, §28.1), puis
        // rang le plus fort, puis ordre de source, puis instant le plus
        // précoce. Il fixe le center, la source (donc `baseKind`, le rang et
        // la largeur de fenêtre §13.1) ; les composantes, elles, viennent du
        // groupe entier.
        for candidate in group.dropFirst() where dominates(candidate, dominant) {
            dominant = candidate
        }

        var rhythmic = 0.0
        var structural = 0.0
        var resolution = 0.0
        var confidence = 0.0
        var isProtected = false
        var reasons: [String] = []
        for member in group {
            rhythmic = max(rhythmic, member.rhythmic)
            structural = max(structural, member.structural)
            resolution = max(resolution, member.resolution)
            confidence = max(confidence, member.confidence)
            isProtected = isProtected || member.isProtected
            for reason in member.reasons where !reasons.contains(reason) {
                reasons.append(reason)
            }
        }

        return RawCandidate(
            centerTicks: dominant.centerTicks,
            source: dominant.source,
            rhythmic: rhythmic,
            structural: structural,
            resolution: resolution,
            confidence: confidence,
            reasons: reasons,
            isProtected: isProtected
        )
    }

    /// Ordre de domination entre candidats co-localisés : protégé > rang le
    /// plus petit > ordre de source > instant le plus précoce.
    ///
    /// Déterminisme : deux candidats encore ex æquo après ces quatre
    /// critères partagent forcément instant ET source — donc les deux seules
    /// données que le représentant apporte (`centerTicks`, `source`). Le
    /// résultat de la fusion est alors identique quel que soit celui retenu,
    /// et la boucle appelante conserve de toute façon le premier dans
    /// l'ordre total fixé par `coalesceColocated`.
    private func dominates(_ lhs: RawCandidate, _ rhs: RawCandidate) -> Bool {
        if lhs.isProtected != rhs.isProtected { return lhs.isProtected }
        if lhs.source.hierarchyRank != rhs.source.hierarchyRank {
            return lhs.source.hierarchyRank < rhs.source.hierarchyRank
        }
        if lhs.source.mergeOrder != rhs.source.mergeOrder {
            return lhs.source.mergeOrder < rhs.source.mergeOrder
        }
        return lhs.centerTicks < rhs.centerTicks
    }

    // MARK: - Évaluation §26.3

    private func makeAnchor(
        from candidate: RawCandidate,
        configuration: ScoreConfiguration,
        durationTicks: Int64,
        beatTicks: Int64,
        impactTicks: [Int64],
        energy: AnchorCurveSampler,
        novelty: AnchorCurveSampler,
        stability: AnchorCurveSampler,
        density: AnchorCurveSampler
    ) -> EditAnchor {
        let tick = candidate.centerTicks

        // Nouveauté N à l'instant de l'ancre (§26.1).
        let noveltyValue = clamp01(novelty.value(at: tick))

        // Contraste : delta d'énergie autour de l'ancre (±1 beat).
        let contrastValue = clamp01(abs(
            energy.value(at: min(tick + beatTicks, durationTicks))
                - energy.value(at: max(tick - beatTicks, 0))
        ))

        // expectedFutureValue niveau A : bonus si l'ancre précède un impact
        // proche — anticipation (§26.3).
        var futureValue = 0.0
        for impact in impactTicks {
            let delta = impact - tick
            guard delta > 0, delta <= Threshold.anticipationTicks else { continue }
            futureValue = max(futureValue, 1.0 - Double(delta) / Double(Threshold.anticipationTicks))
        }

        // Inhibition §26.2 :
        // - note tenue approchée : stabilité S élevée + flux faible
        //   (S dérive déjà de la variance du flux) + nouveauté faible ;
        // - maintien juste après impact : fenêtre ~1 s, inhibition
        //   croissante puis décroissante (triangle culminant à 0,5 s) ;
        // - absence de changement : N très faible ;
        // - l'incertitude est traitée par `uncertaintyPenalty` ci-dessous.
        // La « coupe précédente trop proche » et le « besoin de
        // respiration » sont gérés à la SÉLECTION (overcutPenalty et règle
        // de respiration après burst dans le générateur), pas ici.
        // CORRECTIF S1 — la stabilité seule a le signe INVERSÉ sur une
        // musique à kick dominant. `stability` vaut 1 − variance locale du
        // flux : une boucle de kick régulière, qui est la matière même d'un
        // drop, a une variance de flux FAIBLE, donc une stabilité ÉLEVÉE.
        // L'ancienne formule y voyait une « note tenue » et posait donc son
        // inhibition maximale exactement là où on veut couper.
        //
        // Une note tenue, musicalement, c'est du son SANS attaques. On
        // conditionne donc `heldNote` à une densité rythmique BASSE (D,
        // §23) : porte pleine à densité nulle, fermée au-delà de 0,4. Une
        // boucle de kick (densité élevée) rend désormais heldNote = 0 ;
        // une nappe de breakdown le laisse intact.
        let stabilityValue = clamp01(stability.value(at: tick))
        let densityValue = clamp01(density.value(at: tick))
        let sustainGate = max(0, (0.4 - densityValue) / 0.4)
        let heldNote = max(0, (stabilityValue - 0.6) / 0.4)
            * max(0, (0.3 - noveltyValue) / 0.3)
            * sustainGate
        var postImpactHold = 0.0
        for impact in impactTicks {
            let delta = tick - impact
            guard delta > 0, delta <= Threshold.postImpactTicks else { continue }
            let position = Double(delta) / Double(Threshold.postImpactTicks)
            postImpactHold = max(postImpactHold, 1.0 - abs(2.0 * position - 1.0))
        }
        let noChange = max(0, (0.1 - noveltyValue) / 0.1) * 0.5

        // CORRECTIF S1 (suite) — les trois sous-termes étaient SOMMÉS sous
        // un poids unique de 1,0, donc de plage 0…2,5 face à des termes
        // d'attraction de plage 0…1 chacun : une pondération implicite
        // arbitraire, qui donnait à l'inhibition deux fois et demie le bras
        // de levier de n'importe quel indice d'attraction. Chaque sous-terme
        // porte désormais son propre poids (§26.2), et le poids global
        // `inhibition` reste disponible au-dessus pour régler l'ensemble.
        // Plages avec les valeurs de production : heldNote 0…0,5,
        // postImpactHold 0…1,0, noChange 0…0,25 — soit 1,75 dans le pire
        // cas théorique, jamais atteint (heldNote exige une densité basse,
        // postImpactHold un impact récent).
        let inhibitionComponent =
            configuration.inhibitionHeldNote * heldNote
            + configuration.inhibitionPostImpact * postImpactHold
            + configuration.inhibitionNoChange * noChange

        // Utilité §26.3 — formule exacte avec les 9 poids de
        // `ScoreConfiguration`. `overcutPenalty` est appliqué à la
        // SÉLECTION (densité de coupes déjà activées, voir
        // `DeterministicEditScoreGenerator`) : nul au niveau du champ.
        let attraction =
            configuration.rhythmicStrength * candidate.rhythmic
            + configuration.structuralStrength * candidate.structural
            + configuration.novelty * noveltyValue
            + configuration.contrast * contrastValue
            + configuration.resolutionValue * candidate.resolution
            + configuration.expectedFutureValue * futureValue
        let inhibition = configuration.inhibition * inhibitionComponent
        let uncertainty = configuration.uncertaintyPenalty * (1.0 - clamp01(candidate.confidence))
        let finalUtility = attraction - inhibition - uncertainty

        // Kind §13.1 : base par source, puis anticipatory (juste avant un
        // impact, pour les ancres non structurelles), puis conditional
        // (confiance < 0,5). `grouped` est exprimé par l'appartenance aux
        // `anchorIDs` d'un geste (GestureDetector) — les ancres restent
        // immuables.
        var kind = candidate.source.baseKind
        if kind == .exact || kind == .soft {
            let precedesImpact = impactTicks.contains {
                let delta = $0 - tick
                return delta > 0 && delta <= beatTicks
            }
            if precedesImpact { kind = .anticipatory }
        }
        if candidate.confidence < Threshold.conditionalConfidence, !candidate.isProtected {
            kind = .conditional
        }

        // Raisons §29 (français), confiance en dernier.
        var reasons = candidate.reasons
        if noveltyValue >= 0.5 { reasons.append("Nouveauté élevée") }
        if contrastValue >= 0.5 { reasons.append("Contraste élevé") }
        if kind == .anticipatory { reasons.append("Anticipation d'un impact") }
        reasons.append(Self.confidenceReason(candidate.confidence))

        // Fenêtres §13.1 : optimal ± (beat/2, borné à 60 ms minimum) pour
        // les ancres exactes ; ± beat pour structural/soft ; tolerated =
        // 2 × optimal ; JAMAIS hors [0, fin].
        let optimalHalf = candidate.source.usesTightWindow
            ? max(beatTicks / 2, Threshold.minimumOptimalHalfTicks)
            : max(beatTicks, Threshold.minimumOptimalHalfTicks)
        let toleratedHalf = 2 * optimalHalf

        return EditAnchor(
            id: UUID(),
            center: MediaTime(ticks: tick),
            optimalStart: MediaTime(ticks: max(tick - optimalHalf, 0)),
            optimalEnd: MediaTime(ticks: min(tick + optimalHalf, durationTicks)),
            toleratedStart: MediaTime(ticks: max(tick - toleratedHalf, 0)),
            toleratedEnd: MediaTime(ticks: min(tick + toleratedHalf, durationTicks)),
            kind: kind,
            hierarchyRank: candidate.source.hierarchyRank,
            attraction: attraction,
            inhibition: inhibition,
            finalUtility: finalUtility,
            confidence: clamp01(candidate.confidence),
            reasons: reasons
        )
    }

    // MARK: - Déduplication (< 60 ms, puis rétrogradation des majeures rapprochées)

    /// `lhs` est-il plus fort que `rhs` ? (protégé > rang minimal >
    /// utilité maximale > center minimal) — critère unique des deux passes.
    private func isStronger(
        _ lhs: (anchor: EditAnchor, isProtected: Bool),
        than rhs: (anchor: EditAnchor, isProtected: Bool)
    ) -> Bool {
        if lhs.isProtected != rhs.isProtected { return lhs.isProtected }
        if lhs.anchor.hierarchyRank != rhs.anchor.hierarchyRank {
            return lhs.anchor.hierarchyRank < rhs.anchor.hierarchyRank
        }
        if lhs.anchor.finalUtility != rhs.anchor.finalUtility {
            return lhs.anchor.finalUtility > rhs.anchor.finalUtility
        }
        return lhs.anchor.center.ticks < rhs.anchor.center.ticks
    }

    /// **Rétrograde** une ancre majeure perdante de la passe 2 : même
    /// identité, même instant, même utilité — mais `hierarchyRank` porté à
    /// `demotedHierarchyRank` (4), donc SORTIE de `majorAnchorIDs`
    /// (calculé par `build` sur le seul critère `hierarchyRank <= 1`).
    ///
    /// Elle cesse d'être une frontière racine imposée aux trois modes et
    /// redevient un candidat de split ORDINAIRE, soumis au plancher de
    /// chaque mode. `kind` est conservé (`.structural` reste vrai : c'est
    /// toujours une frontière structurelle, simplement pas majeure).
    private func demoted(_ anchor: EditAnchor) -> EditAnchor {
        var reasons = anchor.reasons
        // La raison de confiance §29 est TOUJOURS la dernière (voir
        // `makeAnchor`) : la mention de rétrogradation s'insère juste avant.
        reasons.insert(Self.demotionReason, at: max(reasons.count - 1, 0))
        return EditAnchor(
            id: anchor.id,
            center: anchor.center,
            optimalStart: anchor.optimalStart,
            optimalEnd: anchor.optimalEnd,
            toleratedStart: anchor.toleratedStart,
            toleratedEnd: anchor.toleratedEnd,
            kind: anchor.kind,
            hierarchyRank: Self.demotedHierarchyRank,
            attraction: anchor.attraction,
            inhibition: anchor.inhibition,
            finalUtility: anchor.finalUtility,
            confidence: anchor.confidence,
            reasons: reasons
        )
    }

    /// Copie du survivant avec les raisons cumulées (dans l'ordre des
    /// centres, sans doublon).
    private func withReasons(_ anchor: EditAnchor, _ reasons: [String]) -> EditAnchor {
        EditAnchor(
            id: anchor.id,
            center: anchor.center,
            optimalStart: anchor.optimalStart,
            optimalEnd: anchor.optimalEnd,
            toleratedStart: anchor.toleratedStart,
            toleratedEnd: anchor.toleratedEnd,
            kind: anchor.kind,
            hierarchyRank: anchor.hierarchyRank,
            attraction: anchor.attraction,
            inhibition: anchor.inhibition,
            finalUtility: anchor.finalUtility,
            confidence: anchor.confidence,
            reasons: reasons
        )
    }

    private func deduplicate(
        _ built: [(anchor: EditAnchor, isProtected: Bool)],
        majorMergeTicks: Int64
    ) -> [EditAnchor] {
        guard !built.isEmpty else { return [] }

        // Tri par center croissant ; clés secondaires déterministes.
        // (Depuis la fusion des co-localisés en amont, les centers sont deux
        // à deux distincts : ce comparateur est un ordre total STRICT, donc
        // `sorted` — qui n'est pas stable — rend une permutation unique.)
        let sorted = built.sorted { lhs, rhs in
            if lhs.anchor.center.ticks != rhs.anchor.center.ticks {
                return lhs.anchor.center.ticks < rhs.anchor.center.ticks
            }
            return isStronger(lhs, than: rhs)
        }

        // Passe 1 — regroupement en chaîne : chaque candidat à < 60 ms du
        // précédent rejoint le cluster courant. Deux ancres protégées
        // (début ET fin) ne fusionnent jamais entre elles.
        var clusters: [[(anchor: EditAnchor, isProtected: Bool)]] = []
        for item in sorted {
            if var current = clusters.last,
               let previous = current.last,
               item.anchor.center.ticks - previous.anchor.center.ticks < Threshold.mergeTicks,
               !(item.isProtected && current.contains(where: { $0.isProtected })) {
                current.append(item)
                clusters[clusters.count - 1] = current
            } else {
                clusters.append([item])
            }
        }

        // Survivant de chaque cluster : le plus fort, raisons cumulées.
        var survivors: [(anchor: EditAnchor, isProtected: Bool)] = []
        survivors.reserveCapacity(clusters.count)
        for cluster in clusters {
            let strongest = cluster.min { isStronger($0, than: $1) }!
            var mergedReasons: [String] = []
            for member in cluster {
                for reason in member.anchor.reasons where !mergedReasons.contains(reason) {
                    mergedReasons.append(reason)
                }
            }
            survivors.append((
                anchor: withReasons(strongest.anchor, mergedReasons),
                isProtected: cluster.contains { $0.isProtected }
            ))
        }

        // Passe 2 — RÉTROGRADATION (et non plus suppression) des MAJEURES
        // (rang ≤ 1) trop rapprochées.
        //
        // ## Le problème corrigé
        //
        // Deux majeures à moins du plancher FLUIDE (`majorMergeTicks` =
        // 45 000 ticks = 0,75 s) ne peuvent pas être toutes deux frontières
        // racines (§28.3.1) : `buildRoot` insère les majeures sous ce
        // plancher-là, le plus grand des trois. Il fallait donc en écarter
        // une — mais l'ancienne passe la RETIRAIT du champ
        // (`merged.remove(at:)`), imposant ainsi le plancher du mode le plus
        // LENT à un champ d'ancres PARTAGÉ par les trois modes.
        //
        // Scénario : coupure à 60,0 s (bord de section, rang 0) et retour du
        // kick à 60,4 s (frontière de phrase, rang 1). Écart 0,4 s < 0,75 s
        // → la phrase disparaissait. AUCUN des trois modes ne pouvait couper
        // sur le retour du kick, alors que 0,4 s est une case parfaitement
        // légitime en Percutant (plancher 0,25 s) comme en Équilibré (0,40 s).
        //
        // ## Le correctif
        //
        // La perdante RESTE dans le champ : elle est simplement rétrogradée
        // (`demoted`, rang 4) et sort donc de `majorAnchorIDs`. Elle redevient
        // un candidat de split ORDINAIRE, que Équilibré et Percutant peuvent
        // activer si leur propre plancher le permet, et que Fluide écartera
        // naturellement par le sien. Le champ redevient indépendant du mode ;
        // seule la sélection reste spécifique au mode.
        //
        // À noter : `DeterministicEditScoreGenerator` porte déjà un jeu
        // `demotedMajorIDs` implémentant EXACTEMENT cette sémantique
        // (réinjection en candidat individuel via `makeCandidates`), mais il
        // était rendu inatteignable par la suppression amont — sa branche est
        // documentée « normalement inatteignable ». Elle le reste : on
        // atteint le même état final, une passe plus tôt, sans `assertionFailure`.
        //
        // ## Invariant préservé (celui qu'exige `buildRoot`)
        //
        // « Deux ancres MAJEURES consécutives sont espacées d'au moins
        // `majorMergeTicks` » reste VRAI : une rétrogradée n'est plus
        // majeure, elle ne compte donc plus dans la suite des majeures.
        // Démonstration par récurrence sur `lastMajorIndex`, qui désigne
        // toujours la dernière majeure CONSERVÉE :
        //  - si l'écart au précédent est ≥ `majorMergeTicks`, on conserve —
        //    l'invariant tient directement ;
        //  - sinon, exactement une des deux est rétrogradée. Si c'est la
        //    nouvelle, la suite des majeures est inchangée. Si c'est la
        //    précédente P, la majeure conservée avant P était à ≥
        //    `majorMergeTicks` de P (hypothèse de récurrence) donc, les
        //    centres étant croissants, elle est à plus que cela de la
        //    nouvelle : l'écart ne peut que CROÎTRE.
        //
        // Enfin, une ancre PROTÉGÉE (début et fin du morceau, §28.1) n'est
        // jamais rétrogradée : elle ne peut perdre que face à une autre
        // protégée, et cette paire-là est exclue par la garde ci-dessous
        // (morceau plus court que le plancher : les deux subsistent,
        // cas §63 de la case unique).
        var merged = survivors
        var lastMajorIndex: Int?
        for index in merged.indices {
            guard merged[index].anchor.hierarchyRank <= 1 else { continue }
            if let previous = lastMajorIndex,
               merged[index].anchor.center.ticks
                   - merged[previous].anchor.center.ticks < majorMergeTicks,
               !(merged[index].isProtected && merged[previous].isProtected) {
                if isStronger(merged[previous], than: merged[index]) {
                    // La nouvelle venue perd : rétrogradée sur place.
                    // `lastMajorIndex` inchangé — la dernière majeure
                    // conservée reste `previous`.
                    let loser = merged[index]
                    merged[index] = (anchor: demoted(loser.anchor), isProtected: loser.isProtected)
                } else {
                    // La précédente perd : rétrogradée SUR PLACE (aucun
                    // retrait, donc le tri par center croissant et les
                    // indices déjà parcourus restent valides).
                    let loser = merged[previous]
                    merged[previous] = (anchor: demoted(loser.anchor), isProtected: loser.isProtected)
                    lastMajorIndex = index
                }
                continue
            }
            lastMajorIndex = index
        }

        // Tri final par center croissant (rang en clé secondaire).
        return merged.map(\.anchor).sorted { lhs, rhs in
            if lhs.center.ticks != rhs.center.ticks { return lhs.center.ticks < rhs.center.ticks }
            return lhs.hierarchyRank < rhs.hierarchyRank
        }
    }

    // MARK: - Utilitaires

    private func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// « Confiance 0,91 » (§29) — format déterministe, virgule française,
    /// sans dépendre d'une locale ni de `String(format:)`.
    private static func confidenceReason(_ confidence: Double) -> String {
        let clamped = min(max(confidence, 0), 1)
        let cents = Int((clamped * 100).rounded())
        let units = cents / 100
        let hundredths = cents % 100
        let padded = hundredths < 10 ? "0\(hundredths)" : "\(hundredths)"
        return "Confiance \(units),\(padded)"
    }
}
