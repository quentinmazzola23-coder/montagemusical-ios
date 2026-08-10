//
//  DeterministicEditScoreGenerator.swift
//  MontageMusical
//
//  Générateur déterministe de partitions (Jalon 5, spec §28, protocole §7) :
//  - partition RACINE : début + fin + ancres majeures — COMMUNES aux trois
//    modes (§28.1/§28.3.1/§80) ;
//  - raffinement hiérarchique §28.3 : sélection gloutonne du split de gain
//    marginal maximal (file de priorité re-triée après chaque activation,
//    §28.4 : les coupes vont où le gain est maximal, pas uniformément) ;
//  - IMBRICATION GARANTIE PAR CONSTRUCTION : une SEULE séquence
//    d'activations ordonnée ; Fluide s'arrête à son plancher/seuil,
//    Équilibré CONTINUE la même séquence, puis Percutant — les frontières
//    de Fluide sont donc un sous-ensemble de celles d'Équilibré,
//    elles-mêmes sous-ensemble de celles de Percutant (§70) ;
//  - gestes §27 : les ancres d'un burst s'activent EN GROUPE (toutes ou
//    aucune) ; un groupe n'entre que dans les modes dont le plancher
//    accepte ses écarts internes ;
//  - §28.2 : résidu final jamais inférieur au plancher, fin ABSOLUE
//    conservée comme dernière frontière ;
//  - §28.3.6 (« passe globale ») : REPLIÉE dans la sélection — la
//    pénalité de surdécoupage (`overcutPenalty`, densité locale), les
//    seuils de gain par mode et les contraintes de respiration jouent le
//    rôle de la passe d'équilibrage post-sélection ; aucune passe
//    distincte après la sélection (choix niveau A documenté).
//
//  DÉTERMINISTE : aucun aléatoire hors UUID d'identité ; les égalités de
//  gain se départagent par (ticks, taille de groupe), jamais par UUID.
//
//  PERFORMANCE : chaque activation re-évalue TOUS les candidats contre
//  toutes les frontières — O(activations × candidats × frontières).
//  Acceptable pour des morceaux ≤ ~6 min (quelques milliers d'ancres) ;
//  optimisation possible plus tard : ré-évaluation LOCALE des seuls
//  candidats dont l'intervalle englobant a changé.
//

import Foundation

// MARK: - Erreurs

// Non defini par la specification — definition minimale V1.
enum EditScoreGenerationError: Error, Equatable {
    /// Morceau vide ou durée nulle/négative : interdit (§63 garantit « au
    /// moins une case » seulement pour un morceau très court non vide).
    case emptyTrack
}

// MARK: - Accès par mode à la configuration

// Non defini par la specification — accès par mode aux champs §28.2/§28.3.
extension ScoreConfiguration {

    func minimumSlotDuration(for mode: PaceMode) -> MediaTime {
        switch mode {
        case .fluid: return minimumSlotDurationFluid
        case .balanced: return minimumSlotDurationBalanced
        case .percussive: return minimumSlotDurationPercussive
        }
    }

    func targetSlotDuration(for mode: PaceMode) -> MediaTime {
        switch mode {
        case .fluid: return targetSlotDurationFluid
        case .balanced: return targetSlotDurationBalanced
        case .percussive: return targetSlotDurationPercussive
        }
    }

    func splitGainThreshold(for mode: PaceMode) -> Double {
        switch mode {
        case .fluid: return splitGainThresholdFluid
        case .balanced: return splitGainThresholdBalanced
        case .percussive: return splitGainThresholdPercussive
        }
    }
}

// MARK: - Générateur

struct DeterministicEditScoreGenerator: EditScoreGenerating, Sendable {

    /// Version du générateur (spec §61 `scoreVersion`).
    static let generatorVersion = 1

    // La fenêtre de densité locale et le facteur d'échelle de
    // l'`overcutPenalty` vivent dans `ScoreConfiguration`
    // (`overcutDensityWindow`, `overcutDensityScale`) — voir `evaluate`.

    init() {}

    // MARK: Protocole §7

    func generateScores(
        from analysis: MusicAnalysisResult,
        configuration: ScoreConfiguration
    ) throws -> EditScoreFamily {
        let durationTicks = analysis.duration.ticks
        guard durationTicks > 0 else { throw EditScoreGenerationError.emptyTrack }

        // 1. Champ d'ancres §26 + gestes §27. Sans pulsation (§63 ambiant),
        //    le champ ne contient naturellement que structure/nouveauté :
        //    la partition reste structurelle, aucun beat n'est inventé.
        let field = AnchorFieldBuilder().build(from: analysis, configuration: configuration)
        let gestures = GestureDetector().detect(analysis: analysis, field: field)
        let anchorsByID = Dictionary(uniqueKeysWithValues: field.anchors.map { ($0.id, $0) })

        // Zones sans coupe : intérieur strict d'un maintien (impactHold,
        // un seul plan tenu) et d'une respiration (§27 breathing).
        let noCutZones: [(start: Int64, end: Int64)] = gestures
            .filter { $0.type == .impactHold || $0.type == .breathing }
            .map { ($0.start.ticks, $0.end.ticks) }
            .filter { $0.0 < $0.1 }

        // 2. Partition racine §28.3.1 : début + fin + majeures, commune aux
        //    trois modes.
        var boundaries: [Boundary] = []
        var demotedMajorIDs = Set<UUID>()
        buildRoot(
            field: field,
            durationTicks: durationTicks,
            fluidFloorTicks: configuration.minimumSlotDurationFluid.ticks,
            boundaries: &boundaries,
            demotedMajorIDs: &demotedMajorIDs
        )

        // 3. Candidats de split : groupes de gestes (toutes ou aucune,
        //    §27/§70) puis ancres individuelles restantes.
        var candidates = makeCandidates(
            field: field,
            gestures: gestures,
            anchorsByID: anchorsByID,
            noCutZones: noCutZones,
            demotedMajorIDs: demotedMajorIDs,
            durationTicks: durationTicks
        )

        // 4. Séquence d'activations UNIQUE, traversée par les trois modes
        //    dans l'ordre Fluide → Équilibré → Percutant (§28.3/§70).
        var activatedBurstEnds: [Int64] = []
        var scores: [PaceMode: EditScore] = [:]
        for mode in PaceMode.allCases {
            let stage = StageParameters(
                floorTicks: configuration.minimumSlotDuration(for: mode).ticks,
                targetSeconds: configuration.targetSlotDuration(for: mode).seconds,
                gainThreshold: configuration.splitGainThreshold(for: mode)
            )
            refine(
                stage: stage,
                configuration: configuration,
                durationTicks: durationTicks,
                boundaries: &boundaries,
                candidates: &candidates,
                activatedBurstEnds: &activatedBurstEnds
            )
            scores[mode] = finalizeScore(
                mode: mode,
                boundaries: boundaries,
                stage: stage,
                field: field,
                gestures: gestures,
                durationTicks: durationTicks
            )
        }

        return EditScoreFamily(
            analysisVersion: analysis.version,
            fluid: scores[.fluid]!,
            balanced: scores[.balanced]!,
            percussive: scores[.percussive]!
        )
    }

    // MARK: - Types internes

    private struct Boundary {
        let ticks: Int64
        let anchorID: UUID
    }

    private struct SplitCandidate {
        /// Ancres du candidat, triées par center croissant. Un candidat
        /// individuel en contient une ; un groupe de geste, toutes.
        let anchors: [EditAnchor]
        let isBurst: Bool
        /// Instant de résolution du burst (fin du geste) — sert à la règle
        /// de respiration §28.1.
        let burstEndTicks: Int64?
    }

    private struct StageParameters {
        let floorTicks: Int64
        let targetSeconds: Double
        let gainThreshold: Double
    }

    // MARK: - Racine §28.3.1

    /// Début + fin toujours frontières (§28.1). Les majeures intérieures
    /// s'insèrent par (rang croissant, utilité décroissante, temps
    /// croissant) tant qu'elles respectent le plancher FLUIDE (le plus
    /// grand des trois) : la racine est commune aux trois modes.
    ///
    /// GARDE-FOU : depuis la fusion AMONT des paires de majeures trop
    /// proches (`AnchorFieldBuilder.deduplicate`, fenêtre = plancher
    /// fluide), deux majeures survivantes sont toujours espacées d'au
    /// moins ce plancher — la branche de rétrogradation est donc
    /// normalement INATTEIGNABLE. Elle est conservée en garde-fou
    /// (assertion en debug, rétrogradation silencieuse en release) pour
    /// que `majorAnchorIDs` ne puisse jamais désigner une ancre absente
    /// des trois modes (§28.1).
    private func buildRoot(
        field: AnchorField,
        durationTicks: Int64,
        fluidFloorTicks: Int64,
        boundaries: inout [Boundary],
        demotedMajorIDs: inout Set<UUID>
    ) {
        guard let startAnchor = field.anchors.first(where: { $0.center.ticks == 0 }),
              let endAnchor = field.anchors.last(where: { $0.center.ticks == durationTicks }) else {
            // Défensif : le champ garantit début/fin pour toute durée > 0.
            return
        }
        boundaries = [
            Boundary(ticks: 0, anchorID: startAnchor.id),
            Boundary(ticks: durationTicks, anchorID: endAnchor.id),
        ]

        let interiorMajors = field.anchors
            .filter {
                field.majorAnchorIDs.contains($0.id)
                    && $0.center.ticks > 0
                    && $0.center.ticks < durationTicks
            }
            .sorted { lhs, rhs in
                if lhs.hierarchyRank != rhs.hierarchyRank { return lhs.hierarchyRank < rhs.hierarchyRank }
                if lhs.finalUtility != rhs.finalUtility { return lhs.finalUtility > rhs.finalUtility }
                return lhs.center.ticks < rhs.center.ticks
            }
        for major in interiorMajors {
            let tick = major.center.ticks
            let insertionIndex = insertionIndexOf(tick, in: boundaries)
            guard insertionIndex > 0, insertionIndex < boundaries.count + 1 else { continue }
            let previous = boundaries[insertionIndex - 1].ticks
            let next = insertionIndex < boundaries.count ? boundaries[insertionIndex].ticks : durationTicks
            if tick - previous >= fluidFloorTicks, next - tick >= fluidFloorTicks {
                boundaries.insert(Boundary(ticks: tick, anchorID: major.id), at: insertionIndex)
            } else if tick != previous, tick != next {
                // Inatteignable depuis la fusion amont des majeures
                // (voir doc ci-dessus) — signalé en debug, rétrogradé en
                // candidat ordinaire en release (comportement sûr).
                assertionFailure("""
                    Majeure à \(tick) ticks sous le plancher fluide malgré \
                    la fusion amont — invariant AnchorFieldBuilder violé.
                    """)
                demotedMajorIDs.insert(major.id)
            }
        }
    }

    // MARK: - Candidats

    private func makeCandidates(
        field: AnchorField,
        gestures: [EditGesture],
        anchorsByID: [UUID: EditAnchor],
        noCutZones: [(start: Int64, end: Int64)],
        demotedMajorIDs: Set<UUID>,
        durationTicks: Int64
    ) -> [SplitCandidate] {
        var candidates: [SplitCandidate] = []
        var groupMemberIDs = Set<UUID>()

        func strictlyInsideZone(_ tick: Int64) -> Bool {
            noCutZones.contains { tick > $0.start && tick < $0.end }
        }

        // Groupes de gestes (§27) : toutes les ancres ensemble, ou aucune.
        for gesture in gestures where !gesture.anchorIDs.isEmpty {
            let members = gesture.anchorIDs
                .compactMap { anchorsByID[$0] }
                .sorted { $0.center.ticks < $1.center.ticks }
            guard !members.isEmpty else { continue }
            groupMemberIDs.formUnion(members.map(\.id))
            // Défensif : un groupe dont une ancre tombe dans une zone sans
            // coupe d'un AUTRE geste n'est pas activable (les bords d'un
            // maintien sont exclus de son intérieur strict).
            guard !members.contains(where: { strictlyInsideZone($0.center.ticks) }) else { continue }
            candidates.append(SplitCandidate(
                anchors: members,
                isBurst: gesture.type == .burstResolution,
                burstEndTicks: gesture.type == .burstResolution ? gesture.end.ticks : nil
            ))
        }

        // Ancres individuelles : non majeures (sauf rétrogradées), non
        // membres d'un groupe, hors zones sans coupe, strictement
        // intérieures au morceau (§28.1 : pas de frontière hors morceau).
        for anchor in field.anchors {
            let tick = anchor.center.ticks
            guard tick > 0, tick < durationTicks else { continue }
            let isMajor = field.majorAnchorIDs.contains(anchor.id)
            guard !isMajor || demotedMajorIDs.contains(anchor.id) else { continue }
            guard !groupMemberIDs.contains(anchor.id) else { continue }
            guard !strictlyInsideZone(tick) else { continue }
            candidates.append(SplitCandidate(anchors: [anchor], isBurst: false, burstEndTicks: nil))
        }

        return candidates
    }

    // MARK: - Raffinement §28.3/§28.4

    /// Active, tant qu'il en existe, le candidat de gain marginal maximal
    /// (recalculé après CHAQUE activation — l'équivalent d'une file de
    /// priorité re-triée). L'étape s'arrête quand plus aucun split ne
    /// respecte le plancher du mode OU que le meilleur gain passe sous le
    /// seuil du mode (§28.3). Les candidats restants sont repris tels
    /// quels par l'étape suivante : imbrication par construction (§70).
    private func refine(
        stage: StageParameters,
        configuration: ScoreConfiguration,
        durationTicks: Int64,
        boundaries: inout [Boundary],
        candidates: inout [SplitCandidate],
        activatedBurstEnds: inout [Int64]
    ) {
        while true {
            var bestIndex: Int?
            var bestGain = 0.0
            var fullyActiveIndices: [Int] = []

            for index in candidates.indices {
                let evaluation = evaluate(
                    candidates[index],
                    boundaries: boundaries,
                    stage: stage,
                    configuration: configuration,
                    burstEnds: activatedBurstEnds,
                    durationTicks: durationTicks
                )
                switch evaluation {
                case .fullyActive:
                    fullyActiveIndices.append(index)
                case .infeasible:
                    continue
                case .gain(let gain):
                    guard gain >= stage.gainThreshold else { continue }
                    if let currentBest = bestIndex {
                        let current = candidates[currentBest]
                        let challenger = candidates[index]
                        if gain > bestGain
                            || (gain == bestGain
                                && (challenger.anchors[0].center.ticks < current.anchors[0].center.ticks
                                    || (challenger.anchors[0].center.ticks == current.anchors[0].center.ticks
                                        && challenger.anchors.count > current.anchors.count))) {
                            bestIndex = index
                            bestGain = gain
                        }
                    } else {
                        bestIndex = index
                        bestGain = gain
                    }
                }
            }

            // Élagage des candidats déjà entièrement actifs (groupes dont
            // toutes les ancres sont des majeures déjà frontières).
            for index in fullyActiveIndices.reversed() {
                if let best = bestIndex, index < best { bestIndex = best - 1 }
                candidates.remove(at: index)
            }

            guard let index = bestIndex else { return }
            let candidate = candidates[index]
            for anchor in candidate.anchors {
                let tick = anchor.center.ticks
                let insertionIndex = insertionIndexOf(tick, in: boundaries)
                let alreadyActive = insertionIndex > 0
                    && boundaries[insertionIndex - 1].ticks == tick
                if !alreadyActive {
                    boundaries.insert(Boundary(ticks: tick, anchorID: anchor.id), at: insertionIndex)
                }
            }
            if candidate.isBurst, let end = candidate.burstEndTicks {
                activatedBurstEnds.append(end)
            }
            candidates.remove(at: index)
        }
    }

    private enum CandidateEvaluation {
        case fullyActive
        case infeasible
        case gain(Double)
    }

    /// Gain §28.3 :
    /// ```text
    /// splitGain = score(left) + score(right) + anchorUtility
    ///           − score(original) − addedCutCost
    /// ```
    /// où `score(intervalle) = −((durée − cible)/cible)²` récompense les
    /// durées proches de la cible du mode et pénalise les extrêmes.
    /// `anchorUtility` = utilité finale §26.3 de l'ancre, diminuée de
    /// l'`overcutPenalty` : pénalité croissante avec la densité locale de
    /// coupes déjà activées (§28.1 : limiter les plans très courts
    /// consécutifs, ne pas épuiser les micro-ancres avant un climax).
    /// Généralisé aux groupes : toutes les frontières du geste comptées
    /// ensemble (§28.3.4 : subdivisions groupées).
    private func evaluate(
        _ candidate: SplitCandidate,
        boundaries: [Boundary],
        stage: StageParameters,
        configuration: ScoreConfiguration,
        burstEnds: [Int64],
        durationTicks: Int64
    ) -> CandidateEvaluation {
        let activeTicks = boundaries.map(\.ticks)
        let inserted = candidate.anchors.filter { anchor in
            let index = insertionIndexOf(anchor.center.ticks, in: boundaries)
            return !(index > 0 && boundaries[index - 1].ticks == anchor.center.ticks)
        }
        guard !inserted.isEmpty else { return .fullyActive }

        // §28.1 : pas de frontière hors morceau ; respiration après burst
        // (prochaine coupe ≥ 2 × plancher du mode après la résolution).
        for anchor in inserted {
            let tick = anchor.center.ticks
            guard tick > 0, tick < durationTicks else { return .infeasible }
            for end in burstEnds where tick > end && tick - end < 2 * stage.floorTicks {
                return .infeasible
            }
        }

        // §28.1 — respiration d'un burst CANDIDAT (règle symétrique de la
        // précédente, qui ne protège que les bursts DÉJÀ activés des coupes
        // futures) : activer un burst exige que sa zone de respiration
        // (fin, fin + 2 × plancher) soit déjà libre de toute frontière
        // ACTIVE. La fin absolue du morceau compte comme frontière active :
        // un burst qui résout sans place pour respirer avant la fin est
        // refusé.
        if candidate.isBurst, let burstEnd = candidate.burstEndTicks {
            for tick in activeTicks where tick > burstEnd && tick - burstEnd < 2 * stage.floorTicks {
                return .infeasible
            }
        }

        // Plancher du mode : chaque nouvelle case ≥ plancher (§28.2).
        let insertedTicks = inserted.map(\.center.ticks)
        let merged = (activeTicks + insertedTicks).sorted()
        for tick in insertedTicks {
            guard let position = binarySearchIndex(of: tick, in: merged),
                  position > 0, position < merged.count - 1 else { return .infeasible }
            guard tick - merged[position - 1] >= stage.floorTicks,
                  merged[position + 1] - tick >= stage.floorTicks else { return .infeasible }
        }

        // Δ de score des intervalles affectés.
        var gain = 0.0
        for pairIndex in 0..<max(activeTicks.count - 1, 0) {
            let start = activeTicks[pairIndex]
            let end = activeTicks[pairIndex + 1]
            let inside = insertedTicks.filter { $0 > start && $0 < end }
            guard !inside.isEmpty else { continue }
            gain += intervalCost(end - start, targetSeconds: stage.targetSeconds)
            var previous = start
            for tick in inside.sorted() + [end] {
                gain -= intervalCost(tick - previous, targetSeconds: stage.targetSeconds)
                previous = tick
            }
        }

        // Utilité des ancres insérées − overcutPenalty − coût de coupe.
        // Fenêtre de densité et facteur d'échelle configurables
        // (`ScoreConfiguration.overcutDensityWindow` / `.overcutDensityScale`).
        for anchor in inserted {
            let tick = anchor.center.ticks
            let localDensity = activeTicks
                .filter { abs($0 - tick) <= configuration.overcutDensityWindow.ticks }
                .count
            let overcut = configuration.overcutPenalty
                * Double(max(0, localDensity - 2))
                * configuration.overcutDensityScale
            gain += anchor.finalUtility - overcut - configuration.addedCutCost
        }

        return .gain(gain)
    }

    /// Coût d'un intervalle : carré de l'écart relatif à la durée cible du
    /// mode (les durées extrêmes — très longues ou très courtes — divergent
    /// quadratiquement).
    private func intervalCost(_ durationTicks: Int64, targetSeconds: Double) -> Double {
        let seconds = Double(durationTicks) / Double(MediaTime.canonicalTimescale)
        let relative = (seconds - targetSeconds) / targetSeconds
        return relative * relative
    }

    // MARK: - Finalisation par mode

    private func finalizeScore(
        mode: PaceMode,
        boundaries: [Boundary],
        stage: StageParameters,
        field: AnchorField,
        gestures: [EditGesture],
        durationTicks: Int64
    ) -> EditScore {
        var modeBoundaries = boundaries

        // §28.2 — résidu final. Par construction le raffinement ne crée
        // jamais de dernière case sous le plancher (chaque activation le
        // vérifie) : cette passe est défensive.
        // FUSION UNIQUEMENT (retrait de la frontière fautive) : retirer une
        // frontière d'un mode préserve l'imbrication Fluide ⊆ Équilibré ⊆
        // Percutant (§70 — le sous-ensemble reste un sous-ensemble), alors
        // que DÉPLACER la frontière créerait un tick propre à un seul mode
        // et briserait l'invariant central. L'imbrication §70 prime : le
        // déplacement autorisé par §28.2 est déjà satisfait par
        // construction en AMONT (chaque activation vérifie le plancher) —
        // aucune branche de déplacement ici. La fin ABSOLUE reste la
        // dernière frontière ; un morceau plus court que le plancher garde
        // sa case unique (§63 : au moins une case).
        while modeBoundaries.count >= 3,
              durationTicks - modeBoundaries[modeBoundaries.count - 2].ticks < stage.floorTicks {
            let last = modeBoundaries[modeBoundaries.count - 2]
            if field.majorAnchorIDs.contains(last.anchorID) {
                // Jamais déplacer/supprimer une majeure (§28.1) —
                // inatteignable : la racine respecte le plancher fluide.
                break
            }
            modeBoundaries.remove(at: modeBoundaries.count - 2)
        }

        // Gestes §27 filtrés PAR MODE : un geste à ancres n'appartient à la
        // partition que si TOUTES ses ancres sont des frontières ACTIVES du
        // mode (« toutes ou aucune », §27/§70 — un burst refusé par le
        // plancher fluide ne doit pas figurer dans la partition fluide).
        // Cas particulier : une respiration (§27 breathing) n'a AUCUNE
        // ancre propre — le détecteur l'émet immédiatement après un
        // impactHold et la fait DÉMARRER exactement à l'ancre de sortie du
        // maintien (breathing.start == impactHold.end) : elle suit donc son
        // geste parent, conservée seulement si cet impactHold est actif
        // dans le mode. Re-tri par (start, type) — même ordre déterministe
        // que le détecteur.
        let activeAnchorIDs = Set(modeBoundaries.map(\.anchorID))
        let anchoredGestures = gestures.filter { gesture in
            !gesture.anchorIDs.isEmpty
                && gesture.anchorIDs.allSatisfy { activeAnchorIDs.contains($0) }
        }
        let breathingGestures = gestures.filter { gesture in
            gesture.type == .breathing && anchoredGestures.contains { parent in
                parent.type == .impactHold && parent.end.ticks == gesture.start.ticks
            }
        }
        let modeGestures = (anchoredGestures + breathingGestures).sorted { lhs, rhs in
            if lhs.start.ticks != rhs.start.ticks { return lhs.start.ticks < rhs.start.ticks }
            return lhs.type.rawValue < rhs.type.rawValue
        }

        // Cases §13.2 : frontières consécutives, ancres réelles, geste
        // englobant éventuel (la case appartient au geste quand elle est
        // contenue dans sa fenêtre temporelle — maintien, burst,
        // respiration). Seuls les gestes DU MODE sont candidats : une case
        // ne référence jamais un geste absent de sa partition.
        var slots: [EditSlotDefinition] = []
        slots.reserveCapacity(max(modeBoundaries.count - 1, 0))
        for index in 0..<max(modeBoundaries.count - 1, 0) {
            let entry = modeBoundaries[index]
            let exit = modeBoundaries[index + 1]
            let gestureID = modeGestures.first { gesture in
                gesture.start.ticks < gesture.end.ticks
                    && gesture.start.ticks <= entry.ticks
                    && exit.ticks <= gesture.end.ticks
            }?.id
            slots.append(EditSlotDefinition(
                id: UUID(),
                index: index,
                start: MediaTime(ticks: entry.ticks),
                end: MediaTime(ticks: exit.ticks),
                entryAnchorID: entry.anchorID,
                exitAnchorID: exit.anchorID,
                gestureID: gestureID
            ))
        }

        // Statistiques de durée (calculées, jamais persistées comme vérité
        // indépendante §13.2).
        let durations = slots.map { $0.end.ticks - $0.start.ticks }
        let total = durations.reduce(Int64(0), +)
        let average = durations.isEmpty
            ? MediaTime.zero
            : MediaTime(ticks: MediaTime.roundedDivision(total, dividedBy: Int64(durations.count)))
        return EditScore(
            mode: mode,
            slots: slots,
            gestures: modeGestures,
            averageDuration: average,
            minimumDuration: MediaTime(ticks: durations.min() ?? 0),
            maximumDuration: MediaTime(ticks: durations.max() ?? 0)
        )
    }

    // MARK: - Recherches binaires

    /// Premier index dont le tick est STRICTEMENT supérieur à `tick`
    /// (= index d'insertion qui préserve le tri).
    private func insertionIndexOf(_ tick: Int64, in boundaries: [Boundary]) -> Int {
        var low = 0
        var high = boundaries.count
        while low < high {
            let mid = (low + high) / 2
            if boundaries[mid].ticks <= tick { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func binarySearchIndex(of tick: Int64, in sortedTicks: [Int64]) -> Int? {
        var low = 0
        var high = sortedTicks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if sortedTicks[mid] == tick { return mid }
            if sortedTicks[mid] < tick { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }
}
