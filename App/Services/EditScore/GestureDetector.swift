//
//  GestureDetector.swift
//  MontageMusical
//
//  Gestes de montage (Jalon 5, niveau A, spec §27) :
//  - impactHold : impact suivi de sustain/stabilité → groupe
//    [ancre d'impact, ancre de sortie de maintien ~1 MESURE après
//    (repli 1–2,25 beats quand la métrique est inconnue)] ;
//  - breathing : après un impactHold, zone SANS ancre activable, d'une
//    MESURE (repli 2 beats) ;
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
//  ÉCHELLES DE TEMPS — MESURES PLUTÔT QUE TEMPS (correctif de la critique
//  S2). Le maintien et la respiration sont désormais exprimés en MESURES,
//  pas en beats : la grammaire du genre visé (EDM/hardstyle) est en
//  mesures, et un maintien de 1 à 2,25 beats vaut 0,4 à 0,9 s à 150 BPM —
//  soit une à deux cases percutantes ordinaires, donc une « respiration »
//  imperceptible et un drop qui reçoit un plan de longueur banale. Avec la
//  mesure (1,6 s à 150 BPM en 4/4), le maintien vaut ~1 mesure et la
//  respiration ~1 mesure : le plan du drop est réellement TENU, la zone
//  protégée fait ~3,2 s. Les `BarEvent` de l'analyse (§20) fournissent la
//  durée de mesure ; en leur ABSENCE (morceau ambiant sans métrique, §63)
//  on retombe EXACTEMENT sur les valeurs historiques en temps — voir
//  `HoldGeometry.timeBased`.
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

    // MARK: - Géométrie du maintien et de la respiration (§27)

    /// Fenêtres du couple `impactHold` / `breathing`, en ticks, dérivées
    /// soit de la MESURE (cas nominal, §20 fournit les `BarEvent`), soit du
    /// beat (repli §63 : morceau sans métrique détectée).
    private struct HoldGeometry {
        /// Portée d'échantillonnage de la stabilité après l'impact
        /// (4 sondes régulières sur cette portée).
        let sustainProbeSpan: Int64
        /// Offsets, après l'impact, de la fenêtre de recherche de l'ancre
        /// de sortie du maintien.
        let exitWindowStart: Int64
        let exitWindowEnd: Int64
        /// Durée de la respiration qui suit le maintien.
        let breathingSpan: Int64

        /// Cas nominal : tout est exprimé en MESURES. Le maintien vise UNE
        /// mesure (fenêtre de sortie [3/4, 5/4] de mesure — centrée sur la
        /// mesure, tolérance ±25 % pour laisser le choix d'utilité opérer),
        /// la respiration dure UNE mesure. À 150 BPM en 4/4 (mesure =
        /// 1,6 s) : sortie dans [1,2 s ; 2,0 s], respiration de 1,6 s,
        /// zone protégée totale ~3,2 s = ~8 cases percutantes.
        static func barBased(barTicks: Int64) -> HoldGeometry {
            HoldGeometry(
                sustainProbeSpan: barTicks,
                exitWindowStart: (3 * barTicks) / 4,
                exitWindowEnd: (5 * barTicks) / 4,
                breathingSpan: barTicks
            )
        }

        /// Repli §63 — aucune mesure disponible (ambiant, métrique non
        /// détectée) : on ne fabrique PAS une mesure fictive, on reprend
        /// EXACTEMENT les valeurs historiques en temps : sonde de stabilité
        /// sur 2 beats (4 sondes au demi-beat), sortie dans
        /// [impact + 1 beat ; impact + 2,25 beats], respiration de 2 beats.
        static func timeBased(beatTicks: Int64) -> HoldGeometry {
            HoldGeometry(
                sustainProbeSpan: 2 * beatTicks,
                exitWindowStart: beatTicks,
                exitWindowEnd: (9 * beatTicks) / 4,
                breathingSpan: 2 * beatTicks
            )
        }
    }

    init() {}

    /// - Parameter configuration: sert UNIQUEMENT à connaître le plancher
    ///   de case le plus permissif des trois modes (§28.2) : les écarts
    ///   internes d'un burst doivent le respecter, sinon le geste ne serait
    ///   réalisable dans AUCUN mode (voir `burstPreAnchors`).
    func detect(
        analysis: MusicAnalysisResult,
        field: AnchorField,
        configuration: ScoreConfiguration = .production
    ) -> [EditGesture] {
        let durationTicks = analysis.duration.ticks
        guard durationTicks > 0, !field.anchors.isEmpty else { return [] }

        let beatTicks = AnchorFieldSupport.medianBeatIntervalTicks(beats: analysis.beats)
        let geometry = Self.holdGeometry(beatTicks: beatTicks, bars: analysis.bars)
        // Plancher le plus permissif des trois modes (§28.2, Percutant =
        // 0,25 s en production) : borne INFÉRIEURE des écarts internes d'un
        // burst — un groupe plus serré que ça serait `.infeasible` partout.
        let minimumBurstGapTicks = max(configuration.mostPermissiveSlotFloor.ticks, 1)
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
                impactEventTick: impact.start.ticks,
                beatTicks: beatTicks,
                events: analysis.musicalEvents,
                tension: tension,
                novelty: novelty
            ) {
                let preAnchors = burstPreAnchors(
                    before: impactTick,
                    beatTicks: beatTicks,
                    minimumGapTicks: minimumBurstGapTicks,
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
                geometry: geometry,
                durationTicks: durationTicks,
                stability: stability,
                functionalStates: analysis.functionalStates
            ),
               let exitAnchor = holdExitAnchor(
                   after: impactTick,
                   geometry: geometry,
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
                //    maintien (§27 : respiration). Durée = UNE MESURE quand
                //    la métrique est connue (§20), repli 2 beats sinon
                //    (§63) — voir `HoldGeometry`.
                let breathingEnd = min(exitAnchor.center.ticks + geometry.breathingSpan, durationTicks)
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

    /// Montée réelle vers l'impact (§25 : ne JAMAIS inventer une montée).
    ///
    /// DÉRIVATION UNIQUE (correctif de la critique, changement 2). La montée
    /// est désormais détectée une seule fois, par `CurvesAndEventsBuilder`,
    /// qui mesure l'énergie jusqu'au SOMMET de sa fenêtre — donc insensible
    /// au gap de silence de la figure canonique EDM (riser → silence → drop)
    /// — sur une fenêtre exprimée en MESURES. Quand cette détection a produit
    /// un `.buildUp` se terminant exactement sur cet impact, on la REPREND
    /// telle quelle au lieu d'en refaire une version plus faible ici.
    ///
    /// C'était le trou laissé par la fusion des chantiers : le `.buildUp`
    /// était émis mais `burstResolution` ne le voyait pas, car il refaisait
    /// sa propre mesure sur 4 temps seulement — c'est-à-dire qu'il retombait
    /// exactement dans le piège que le changement 2 corrige.
    ///
    /// REPLI, inchangé : aucun `.buildUp` apparié (analyse produite par un
    /// autre moteur, ou aucun impact détecté) → heuristique historique,
    /// moyenne de tension OU de nouveauté ≥ seuil sur les 4 beats précédant
    /// l'impact (8 échantillons au demi-beat). Ce repli est délibérément
    /// laissé à l'identique : l'élargir à la fenêtre en mesures diluerait la
    /// moyenne sur la partie calme qui précède la montée et rendrait le
    /// critère PLUS strict, l'inverse du but. Le raccourci ci-dessus est
    /// donc strictement additif — il ne peut que qualifier davantage de
    /// montées, jamais moins.
    ///
    /// - Parameters:
    ///   - impactTick: centre de l'ANCRE appariée à l'impact (base des sondes
    ///     du repli, cohérente avec les autres fenêtres du détecteur).
    ///   - impactEventTick: début de l'ÉVÉNEMENT `.impact` lui-même. Les deux
    ///     peuvent différer de `anchorMatchTicks` (60 ms), et c'est bien sur
    ///     l'événement que `CurvesAndEventsBuilder` fait finir son `.buildUp`
    ///     — à l'exact tick près (§9, invariant vérifié par
    ///     `BuildupPipelineTests`).
    private func hasGenuineRise(
        before impactTick: Int64,
        impactEventTick: Int64,
        beatTicks: Int64,
        events: [MusicalEvent],
        tension: AnchorCurveSampler,
        novelty: AnchorCurveSampler
    ) -> Bool {
        let matchesDetectedBuildUp = events.contains { event in
            event.type == .buildUp
                && event.geometry == .interval
                && event.end?.ticks == impactEventTick
        }
        if matchesDetectedBuildUp { return true }

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
    /// frontière partout — voir commentaire burst), non groupées.
    ///
    /// SÉLECTION PAR ÉCARTS DÉCROISSANTS (correctif de la critique, point 8).
    /// L'ancienne règle « les 3 ancres les PLUS PROCHES de l'impact »
    /// produisait le geste le plus serré possible : plus le burst était un
    /// vrai burst, plus ses écarts internes tombaient sous le plancher
    /// §28.2, donc `.infeasible` dans les TROIS modes — un geste détecté et
    /// jamais réalisable, qui en plus retirait ses ancres du pool
    /// individuel. Deux exigences remplacent cette règle :
    ///
    /// 1. **Réalisable quelque part** : chaque écart interne (et l'écart
    ///    final vers l'impact) est ≥ `minimumGapTicks`, le plancher du mode
    ///    le plus permissif (Percutant, 0,25 s en production). Le groupe est
    ///    donc au moins faisable en Percutant du point de vue du plancher.
    /// 2. **Écarts NON CROISSANTS vers l'impact** : en remontant le temps
    ///    depuis l'impact, chaque écart retenu doit être ≥ au précédent.
    ///    La rafale est ainsi au pire régulière, jamais RALENTISSANTE —
    ///    l'inverse d'une résolution. On accepte l'égalité (une rafale de
    ///    croches régulières est un burst parfaitement valide) : exiger la
    ///    stricte décroissance éliminerait le cas le plus fréquent en EDM.
    ///
    /// DÉPARTAGE DÉTERMINISTE : à chaque étape on prend l'ancre la PLUS
    /// TARDIVE satisfaisant la contrainte (`last(where:)` sur le champ trié
    /// par center croissant, dont les centres sont uniques après
    /// déduplication à 60 ms). Ce choix est aussi optimal pour la longueur
    /// du groupe : prendre l'ancre la plus tardive minimise l'écart courant,
    /// donc relâche au maximum la contrainte de l'étape suivante.
    private func burstPreAnchors(
        before impactTick: Int64,
        beatTicks: Int64,
        minimumGapTicks: Int64,
        field: AnchorField,
        excluding groupedAnchorIDs: Set<UUID>
    ) -> [EditAnchor] {
        let windowStart = impactTick - (5 * beatTicks) / 2
        let inWindow = field.anchors
            .filter { anchor in
                anchor.center.ticks >= windowStart
                    && anchor.center.ticks < impactTick
                    && anchor.center.ticks > 0
                    && !field.majorAnchorIDs.contains(anchor.id)
                    && !groupedAnchorIDs.contains(anchor.id)
            }
            .sorted { $0.center.ticks < $1.center.ticks }

        var chosen: [EditAnchor] = []
        var referenceTick = impactTick
        var previousGap: Int64?
        while chosen.count < Threshold.burstMaximumPreAnchors {
            // Écart exigé : le plancher permissif, et au moins l'écart déjà
            // retenu côté impact (en remontant le temps les écarts croissent
            // ⟺ ils décroissent vers l'impact).
            let requiredGap = max(minimumGapTicks, previousGap ?? minimumGapTicks)
            guard let candidate = inWindow.last(where: {
                referenceTick - $0.center.ticks >= requiredGap
            }) else { break }
            chosen.append(candidate)
            previousGap = referenceTick - candidate.center.ticks
            referenceTick = candidate.center.ticks
        }
        // `chosen` est construit de l'impact vers le passé : remise en ordre
        // chronologique.
        return Array(chosen.reversed())
    }

    /// Maintien après impact : stabilité moyenne ≥ seuil sur les 4 sondes
    /// régulières couvrant (impact, impact + portée de maintien], OU état
    /// dramaturgique `.sustain` démarrant dans cette fenêtre (§24).
    /// La portée vaut UNE MESURE quand la métrique est connue, 2 beats en
    /// repli (§63) — voir `HoldGeometry`.
    private func hasSustain(
        after impactTick: Int64,
        geometry: HoldGeometry,
        durationTicks: Int64,
        stability: AnchorCurveSampler,
        functionalStates: [FunctionalStateInterval]
    ) -> Bool {
        let probeStep = max(geometry.sustainProbeSpan / 4, 1)
        var sum = 0.0
        var count = 0
        for step in 1...4 {
            let tick = impactTick + Int64(step) * probeStep
            guard tick <= durationTicks else { break }
            sum += stability.value(at: tick)
            count += 1
        }
        if count > 0, sum / Double(count) >= Threshold.holdStabilityMean {
            return true
        }
        // Tolérance amont d'un huitième de portée : l'état `.sustain` est
        // daté au span, l'impact à la frame — ils ne coïncident pas au tick.
        return functionalStates.contains { state in
            state.function == .sustain
                && state.start.ticks >= impactTick - geometry.sustainProbeSpan / 8
                && state.start.ticks <= impactTick + geometry.sustainProbeSpan
        }
    }

    /// Ancre de sortie de maintien : centre dans la fenêtre de sortie de la
    /// `HoldGeometry` (≈ une MESURE après l'impact, repli [1 beat ;
    /// 2,25 beats]), utilité maximale (égalité → la plus précoce).
    private func holdExitAnchor(
        after impactTick: Int64,
        geometry: HoldGeometry,
        field: AnchorField,
        excluding groupedAnchorIDs: Set<UUID>
    ) -> EditAnchor? {
        let windowStart = impactTick + geometry.exitWindowStart
        let windowEnd = impactTick + geometry.exitWindowEnd
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

    // MARK: - Échelles

    /// Géométrie du maintien/respiration : MESURES quand l'analyse en
    /// fournit (§20 `BarEvent`), repli en temps sinon (§63).
    ///
    /// La durée de mesure retenue est la MÉDIANE des durées strictement
    /// positives — pas la moyenne : la dernière mesure d'un morceau est
    /// tronquée à la durée réelle (`min(start + mesure, durée)`) et une
    /// moyenne s'en trouverait biaisée vers le bas. La médiane est aussi
    /// insensible à une mesure isolée mal segmentée.
    private static func holdGeometry(beatTicks: Int64, bars: [BarEvent]) -> HoldGeometry {
        let spans = bars
            .map { $0.end.ticks - $0.start.ticks }
            .filter { $0 > 0 }
            .sorted()
        guard !spans.isEmpty else { return .timeBased(beatTicks: beatTicks) }
        let median = spans[spans.count / 2]
        // Garde-fou : une « mesure » plus courte qu'un beat est une
        // segmentation aberrante — on préfère le repli documenté.
        guard median >= beatTicks else { return .timeBased(beatTicks: beatTicks) }
        return .barBased(barTicks: median)
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
