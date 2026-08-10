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
    /// Ancres triées par `center` croissant, centres uniques (déduplication
    /// à 60 ms près ; les paires de MAJEURES — rang ≤ 1 — fusionnent dès
    /// qu'elles sont à moins du plancher fluide §28.2 l'une de l'autre,
    /// voir `deduplicate`).
    let anchors: [EditAnchor]

    /// Début + fin + frontières de section/phrase (`hierarchyRank` ≤ 1).
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
    }

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
        let impactTicks = analysis.musicalEvents
            .filter { $0.type == .impact && $0.start.ticks >= 0 && $0.start.ticks <= durationTicks }
            .map(\.start.ticks)
            .sorted()

        // 1. Candidats bruts (toutes sources §26.1).
        let candidates = rawCandidates(
            analysis: analysis,
            durationTicks: durationTicks,
            impactTicks: impactTicks
        )

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
                stability: stability
            )
            built.append((anchor, candidate.isProtected))
        }

        // 3. Déduplication : candidats à < 60 ms fusionnés, puis paires de
        //    MAJEURES à moins du plancher fluide fusionnées (garde le plus
        //    fort, raisons cumulées) — tri final par center croissant.
        let deduplicated = deduplicate(
            built,
            majorMergeTicks: configuration.minimumSlotDurationFluid.ticks
        )

        // 4. Majeures : début + fin + rang ≤ 1 (sections, phrases).
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

    // MARK: - Évaluation §26.3

    private func makeAnchor(
        from candidate: RawCandidate,
        configuration: ScoreConfiguration,
        durationTicks: Int64,
        beatTicks: Int64,
        impactTicks: [Int64],
        energy: AnchorCurveSampler,
        novelty: AnchorCurveSampler,
        stability: AnchorCurveSampler
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
        let stabilityValue = clamp01(stability.value(at: tick))
        let heldNote = max(0, (stabilityValue - 0.6) / 0.4)
            * max(0, (0.3 - noveltyValue) / 0.3)
        var postImpactHold = 0.0
        for impact in impactTicks {
            let delta = tick - impact
            guard delta > 0, delta <= Threshold.postImpactTicks else { continue }
            let position = Double(delta) / Double(Threshold.postImpactTicks)
            postImpactHold = max(postImpactHold, 1.0 - abs(2.0 * position - 1.0))
        }
        let noChange = max(0, (0.1 - noveltyValue) / 0.1) * 0.5
        let inhibitionComponent = heldNote + postImpactHold + noChange

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

    // MARK: - Déduplication (< 60 ms, puis paires de majeures < plancher fluide)

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

        // Passe 2 — fusion élargie des PAIRES de MAJEURES (rang ≤ 1) :
        // deux majeures à moins du plancher fluide (§28.2) l'une de
        // l'autre ne peuvent pas être toutes deux frontières racines
        // (§28.3.1) ; garder les deux forcerait l'aval à rétrograder la
        // plus faible et rendrait `majorAnchorIDs` incohérent (une
        // « majeure » absente d'un mode, §28.1). Fusion ICI : la plus
        // forte survit, raisons cumulées — toute majeure du champ reste
        // ainsi « dans les trois modes » (§28.1). Début et fin (protégées)
        // ne fusionnent jamais entre elles (morceau plus court que le
        // plancher : les deux subsistent, cas §63 d'une case unique).
        // Par induction, deux majeures survivantes consécutives sont
        // toujours espacées d'au moins `majorMergeTicks`.
        var merged: [(anchor: EditAnchor, isProtected: Bool)] = []
        merged.reserveCapacity(survivors.count)
        var lastMajorIndex: Int?
        for item in survivors {
            if item.anchor.hierarchyRank <= 1,
               let index = lastMajorIndex,
               item.anchor.center.ticks - merged[index].anchor.center.ticks < majorMergeTicks,
               !(item.isProtected && merged[index].isProtected) {
                let existing = merged[index]
                var mergedReasons = existing.anchor.reasons
                for reason in item.anchor.reasons where !mergedReasons.contains(reason) {
                    mergedReasons.append(reason)
                }
                let pairProtected = existing.isProtected || item.isProtected
                if isStronger(existing, than: item) {
                    merged[index] = (withReasons(existing.anchor, mergedReasons), pairProtected)
                    // `lastMajorIndex` inchangé : le center ne bouge pas.
                } else {
                    // Le nouveau venu survit : retirer l'ancien (les
                    // éventuelles non-majeures intermédiaires restent),
                    // l'ajout en fin conserve le tri par center croissant.
                    merged.remove(at: index)
                    merged.append((withReasons(item.anchor, mergedReasons), pairProtected))
                    lastMajorIndex = merged.count - 1
                }
                continue
            }
            merged.append(item)
            if item.anchor.hierarchyRank <= 1 { lastMajorIndex = merged.count - 1 }
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
