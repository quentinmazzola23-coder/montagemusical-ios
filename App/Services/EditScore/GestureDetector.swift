//
//  GestureDetector.swift
//  MontageMusical
//
//  Gestes de montage (Jalon 5, niveau A, spec §27) :
//  - impactHold : impact suivi de sustain/stabilité → groupe
//    [ancre d'impact, ancre de sortie de maintien ~1–2 beats après] ;
//  - breathing : après un impactHold, zone SANS ancre activable ;
//  - burstResolution : montée de tension N/T vers un impact → groupe
//    cohérent de 2–4 ancres serrées juste avant l'impact (+ l'impact
//    lui-même quand il n'est pas une ancre majeure) — un burst est ajouté
//    comme un GROUPE, jamais par points isolés (§27) ;
//  - simpleAccent : impact isolé sans montée ni maintien.
//
//  Les quatre autres types V1 (§27) — acceleration, motifEcho, variation,
//  reset — ne sont PAS générés par le niveau A : leur détection exige la
//  similarité de motifs et les embeddings du moteur avancé (§15 niveau B).
//  Les cas de l'énumération existent, ce détecteur ne les émet simplement
//  jamais ; aucun geste factice n'est inventé (§0.7).
//
//  DÉTERMINISTE : itération des impacts par temps croissant, sélections
//  par (utilité, ticks) — jamais par UUID.
//

import Foundation

// Non defini par la specification — definition minimale V1.
struct GestureDetector: Sendable {

    /// Seuils déterministes du niveau A (heuristiques documentées).
    private enum Threshold {
        /// Appariement impact → ancre (l'impact peut avoir été fusionné
        /// dans une ancre plus forte à < 60 ms).
        static let anchorMatchTicks: Int64 = 3_600
        /// Tension/nouveauté moyenne minimale sur la fenêtre précédant
        /// l'impact pour qualifier une montée (§25 : montée réelle).
        static let burstRiseMean = 0.35
        /// Stabilité moyenne minimale après l'impact pour un maintien.
        static let holdStabilityMean = 0.45
        /// Nombre maximal d'ancres serrées avant l'impact d'un burst.
        static let burstMaximumPreAnchors = 3
    }

    init() {}

    func detect(analysis: MusicAnalysisResult, field: AnchorField) -> [EditGesture] {
        let durationTicks = analysis.duration.ticks
        guard durationTicks > 0, !field.anchors.isEmpty else { return [] }

        let beatTicks = AnchorFieldSupport.medianBeatIntervalTicks(beats: analysis.beats)
        let tension = AnchorCurveSampler(analysis.continuousCurves.tension)
        let novelty = AnchorCurveSampler(analysis.continuousCurves.novelty)
        let stability = AnchorCurveSampler(analysis.continuousCurves.stability)

        let impacts = analysis.musicalEvents
            .filter { $0.type == .impact && $0.start.ticks >= 0 && $0.start.ticks <= durationTicks }
            .sorted { $0.start.ticks < $1.start.ticks }

        var gestures: [EditGesture] = []
        var groupedAnchorIDs = Set<UUID>()

        for impact in impacts {
            guard let impactAnchor = nearestAnchor(to: impact.start.ticks, in: field.anchors),
                  !groupedAnchorIDs.contains(impactAnchor.id) else { continue }
            let impactTick = impactAnchor.center.ticks

            // 1. burstResolution — montée N/T réelle vers l'impact (§25 :
            //    jamais de montée inventée) + au moins 2 ancres serrées.
            if hasGenuineRise(
                before: impactTick,
                beatTicks: beatTicks,
                tension: tension,
                novelty: novelty
            ) {
                let preAnchors = burstPreAnchors(
                    before: impactTick,
                    beatTicks: beatTicks,
                    field: field,
                    excluding: groupedAnchorIDs
                )
                if preAnchors.count >= 2 {
                    // L'impact rejoint le groupe seulement s'il n'est pas
                    // une ancre MAJEURE : une majeure est frontière dans
                    // les trois modes (§28.1), l'inclure briserait la règle
                    // « toutes ou aucune » du groupe (§27/§70) pour les
                    // modes où le burst ne passe pas le plancher.
                    var memberIDs = preAnchors.map(\.id)
                    if !field.majorAnchorIDs.contains(impactAnchor.id) {
                        memberIDs.append(impactAnchor.id)
                    }
                    gestures.append(EditGesture(
                        id: UUID(),
                        type: .burstResolution,
                        start: preAnchors[0].center,
                        end: impactAnchor.center,
                        anchorIDs: memberIDs
                    ))
                    groupedAnchorIDs.formUnion(memberIDs)
                    groupedAnchorIDs.insert(impactAnchor.id)
                    continue
                }
            }

            // 2. impactHold — impact suivi de sustain/stabilité.
            if hasSustain(
                after: impactTick,
                beatTicks: beatTicks,
                durationTicks: durationTicks,
                stability: stability,
                functionalStates: analysis.functionalStates
            ),
               let exitAnchor = holdExitAnchor(
                   after: impactTick,
                   beatTicks: beatTicks,
                   field: field,
                   excluding: groupedAnchorIDs
               ) {
                let memberIDs = [impactAnchor.id, exitAnchor.id]
                gestures.append(EditGesture(
                    id: UUID(),
                    type: .impactHold,
                    start: impactAnchor.center,
                    end: exitAnchor.center,
                    anchorIDs: memberIDs
                ))
                groupedAnchorIDs.formUnion(memberIDs)

                // 3. breathing — zone sans ancre activable après le
                //    maintien (§27 : respiration).
                let breathingEnd = min(exitAnchor.center.ticks + 2 * beatTicks, durationTicks)
                if breathingEnd > exitAnchor.center.ticks {
                    gestures.append(EditGesture(
                        id: UUID(),
                        type: .breathing,
                        start: exitAnchor.center,
                        end: MediaTime(ticks: breathingEnd),
                        anchorIDs: []
                    ))
                }
                continue
            }

            // 4. simpleAccent — impact isolé, sans montée ni maintien.
            gestures.append(EditGesture(
                id: UUID(),
                type: .simpleAccent,
                start: impactAnchor.center,
                end: impactAnchor.center,
                anchorIDs: [impactAnchor.id]
            ))
            groupedAnchorIDs.insert(impactAnchor.id)
        }

        return gestures.sorted { lhs, rhs in
            if lhs.start.ticks != rhs.start.ticks { return lhs.start.ticks < rhs.start.ticks }
            return lhs.type.rawValue < rhs.type.rawValue
        }
    }

    // MARK: - Détections

    /// Montée réelle : moyenne de tension OU de nouveauté ≥ seuil sur les
    /// 4 beats précédant l'impact (8 échantillons au demi-beat).
    private func hasGenuineRise(
        before impactTick: Int64,
        beatTicks: Int64,
        tension: AnchorCurveSampler,
        novelty: AnchorCurveSampler
    ) -> Bool {
        let halfBeat = max(beatTicks / 2, 1)
        var tensionSum = 0.0
        var noveltySum = 0.0
        var count = 0
        for step in 1...8 {
            let tick = impactTick - Int64(step) * halfBeat
            guard tick >= 0 else { break }
            tensionSum += tension.value(at: tick)
            noveltySum += novelty.value(at: tick)
            count += 1
        }
        guard count >= 4 else { return false }
        let mean = max(tensionSum, noveltySum) / Double(count)
        return mean >= Threshold.burstRiseMean
    }

    /// Ancres serrées juste avant l'impact : centres dans
    /// [impact − 2,5 beats, impact), non majeures (une majeure est déjà
    /// frontière partout — voir commentaire burst), non groupées. Les
    /// `burstMaximumPreAnchors` plus proches de l'impact, triées par temps
    /// croissant.
    private func burstPreAnchors(
        before impactTick: Int64,
        beatTicks: Int64,
        field: AnchorField,
        excluding groupedAnchorIDs: Set<UUID>
    ) -> [EditAnchor] {
        let windowStart = impactTick - (5 * beatTicks) / 2
        let inWindow = field.anchors.filter { anchor in
            anchor.center.ticks >= windowStart
                && anchor.center.ticks < impactTick
                && anchor.center.ticks > 0
                && !field.majorAnchorIDs.contains(anchor.id)
                && !groupedAnchorIDs.contains(anchor.id)
        }
        // Les plus proches de l'impact (centres décroissants), puis remise
        // en ordre chronologique.
        let nearest = inWindow
            .sorted { $0.center.ticks > $1.center.ticks }
            .prefix(Threshold.burstMaximumPreAnchors)
        return nearest.sorted { $0.center.ticks < $1.center.ticks }
    }

    /// Maintien après impact : stabilité moyenne ≥ seuil sur (impact,
    /// impact + 2 beats], OU état dramaturgique `.sustain` démarrant dans
    /// cette fenêtre (§24).
    private func hasSustain(
        after impactTick: Int64,
        beatTicks: Int64,
        durationTicks: Int64,
        stability: AnchorCurveSampler,
        functionalStates: [FunctionalStateInterval]
    ) -> Bool {
        let halfBeat = max(beatTicks / 2, 1)
        var sum = 0.0
        var count = 0
        for step in 1...4 {
            let tick = impactTick + Int64(step) * halfBeat
            guard tick <= durationTicks else { break }
            sum += stability.value(at: tick)
            count += 1
        }
        if count > 0, sum / Double(count) >= Threshold.holdStabilityMean {
            return true
        }
        return functionalStates.contains { state in
            state.function == .sustain
                && state.start.ticks >= impactTick - beatTicks / 4
                && state.start.ticks <= impactTick + 2 * beatTicks
        }
    }

    /// Ancre de sortie de maintien : centre dans [impact + 1 beat,
    /// impact + 2,25 beats], utilité maximale (égalité → la plus précoce).
    private func holdExitAnchor(
        after impactTick: Int64,
        beatTicks: Int64,
        field: AnchorField,
        excluding groupedAnchorIDs: Set<UUID>
    ) -> EditAnchor? {
        let windowStart = impactTick + beatTicks
        let windowEnd = impactTick + (9 * beatTicks) / 4
        let inWindow = field.anchors.filter { anchor in
            anchor.center.ticks >= windowStart
                && anchor.center.ticks <= windowEnd
                && !groupedAnchorIDs.contains(anchor.id)
        }
        return inWindow.min { lhs, rhs in
            if lhs.finalUtility != rhs.finalUtility { return lhs.finalUtility > rhs.finalUtility }
            return lhs.center.ticks < rhs.center.ticks
        }
    }

    /// Ancre la plus proche d'un instant (± 60 ms) — recherche binaire sur
    /// les centres (le champ est trié par center croissant).
    private func nearestAnchor(to tick: Int64, in anchors: [EditAnchor]) -> EditAnchor? {
        guard !anchors.isEmpty else { return nil }
        var low = 0
        var high = anchors.count - 1
        while low < high {
            let mid = (low + high) / 2
            if anchors[mid].center.ticks < tick { low = mid + 1 } else { high = mid }
        }
        var best = anchors[low]
        var bestDistance = abs(best.center.ticks - tick)
        if low > 0 {
            let previous = anchors[low - 1]
            let distance = abs(previous.center.ticks - tick)
            if distance < bestDistance {
                best = previous
                bestDistance = distance
            }
        }
        return bestDistance <= Threshold.anchorMatchTicks ? best : nil
    }
}
