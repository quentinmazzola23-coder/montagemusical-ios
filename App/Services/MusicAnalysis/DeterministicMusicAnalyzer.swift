//
//  DeterministicMusicAnalyzer.swift
//  MontageMusical
//
//  Moteur musical déterministe niveau A (§15, Jalon 4/§79) — implémente le
//  protocole `MusicAnalyzing` (§7). Enchaîne les phases §33 dans l'ordre :
//
//      1. Préparation audio      (PCM streaming + STFT + caractéristiques)
//      2. Pulsation et tempo     (onsets → hypothèses → beats/mesures)
//      3. Phrases et structure   (sync beat → similarité → nouveauté → UMS)
//      4. Montées et impacts     (courbes §23, événements §12.4, états §24)
//
//  La 5ᵉ phase §33 « Création des rythmes » est la génération des partitions
//  (Jalon 5) : elle n'est PAS publiée ici — l'interface Jalon 4 affiche donc
//  « Phase x sur 4 ».
//
//  Garanties :
//  - résultats DÉTERMINISTES, jamais factices (§0.7, §79) ;
//  - progression publiée à chaque phase, annulation coopérative entre les
//    phases, checkpoint après les phases coûteuses (§8, §63, §79) ;
//  - cache complet → retour immédiat ; invalidation par empreinte audio +
//    version moteur + configuration (§69) ;
//  - cas limites §63 : morceau très court → résultat minimal valide (racine
//    seule) ; enveloppe plate (ambiant §72) → aucune hypothèse rythmique,
//    beats vides, structure par nouveauté seulement ; tempo ambigu →
//    plusieurs hypothèses conservées avec leurs probabilités.
//

import Foundation

// Non defini par la specification — definition minimale V1.
struct DeterministicMusicAnalyzer: MusicAnalyzing, Sendable {

    /// Version du moteur déterministe (§61, §69) — incrémenter à chaque
    /// changement de comportement d'analyse.
    /// v2 : garde `minimumOnsetsForTempo` (§63) — un signal quasi vide
    /// n'engendre plus d'hypothèse rythmique fantôme.
    static let engineVersion = 2

    /// Nombre minimal d'onsets détectés (§18) pour tenter une estimation de
    /// tempo (§19.1). Une périodicité exige plusieurs événements réels ;
    /// en dessous, aucune hypothèse (§63 : « rythme très faible → partition
    /// structurelle seulement », §0.7 : jamais de contenu inventé). Aligné
    /// sur `BeatSyncFeatureExtractor.minimumBeatsForGrid` (4) : moins de
    /// 4 beats ne formeraient de toute façon jamais de grille alignée.
    static let minimumOnsetsForTempo = 4

    /// Identifiant sentinelle quand AUCUNE hypothèse rythmique n'existe
    /// (§63 : rythme très faible/non métrique). `selectedRhythmHypothesisID`
    /// est non optionnel dans le schéma §12 ; ce zéro-UUID déterministe
    /// signale « aucune sélection » sans inventer d'hypothèse (§0.7).
    static let noHypothesisID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private let cache: AnalysisCache
    private let fileStore: ProjectFileStore
    private let logger = AppLogger(category: .analysis)

    init(cache: AnalysisCache, fileStore: ProjectFileStore) {
        self.cache = cache
        self.fileStore = fileStore
    }

    // MARK: - MusicAnalyzing (§7)

    func analyze(
        audio: ImportedAudio,
        configuration: AnalysisConfiguration,
        progress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> MusicAnalysisResult {
        let projectID = audio.projectID
        let url = fileStore.directory(for: projectID).appending(path: audio.relativePath)

        // Empreintes (§69) : audio + version moteur + configuration pour le
        // résultat COMME pour le checkpoint — un changement de configuration
        // invalide les deux.
        let audioFingerprint = try cache.audioFingerprint(url: url)
        let configFingerprint = Self.configurationFingerprint(configuration)
        if let cached = cache.load(
            projectID: projectID,
            fingerprint: audioFingerprint,
            engineVersion: Self.engineVersion,
            configurationFingerprint: configFingerprint
        ) {
            // Cache complet → résultat immédiat, aucune phase relancée (§69).
            return cached
        }
        let checkpointFingerprint = "\(audioFingerprint)#\(configFingerprint)"
        var checkpoint = cache.loadCheckpoint(projectID: projectID, fingerprint: checkpointFingerprint)
        if checkpoint?.engineVersion != Self.engineVersion {
            checkpoint = nil
        }

        // ============================================================
        // Phase 1 §33 — « Préparation audio »
        // ============================================================
        progress(AnalysisProgress(phase: .audioPreparation, completedPhases: []))
        try Task.checkCancellation()

        let features: FeatureTimeline
        if let restored = Self.restoredFeatures(from: checkpoint) {
            // Reprise §8.1/§63 : phase 1 déjà terminée pour cette empreinte.
            features = restored
        } else {
            let extractor = SpectralFeatureExtractor(configuration: configuration)
            features = try await extractor.extract(url: url, decoder: PCMDecoder())
            let phase1 = AnalysisCheckpoint(
                fingerprint: checkpointFingerprint,
                engineVersion: Self.engineVersion,
                completedPhases: [AnalysisPhase.audioPreparation.rawValue],
                featureTimelineData: try Self.encodeFeatures(features),
                rhythmData: nil
            )
            try cache.saveCheckpoint(phase1, projectID: projectID)
            checkpoint = phase1
        }
        try Task.checkCancellation()

        // Morceau très court (§63) : pas assez de frames pour la moindre
        // pulsation → résultat minimal VALIDE (racine seule), phases
        // restantes publiées pour une progression honnête, aucun contenu
        // inventé (§0.7).
        if features.rms.count < 8 || features.duration.ticks <= 0 {
            progress(AnalysisProgress(phase: .pulseAndTempo, completedPhases: [.audioPreparation]))
            progress(AnalysisProgress(
                phase: .phrasesAndStructure,
                completedPhases: [.audioPreparation, .pulseAndTempo]
            ))
            progress(AnalysisProgress(
                phase: .buildUpsAndImpacts,
                completedPhases: [.audioPreparation, .pulseAndTempo, .phrasesAndStructure]
            ))
            let minimal = Self.minimalResult(duration: features.duration)
            try cache.save(
                minimal,
                projectID: projectID,
                fingerprint: audioFingerprint,
                engineVersion: Self.engineVersion,
                configurationFingerprint: configFingerprint
            )
            cache.clearCheckpoint(projectID: projectID)
            return minimal
        }

        // ============================================================
        // Phase 2 §33 — « Pulsation et tempo »
        // ============================================================
        progress(AnalysisProgress(phase: .pulseAndTempo, completedPhases: [.audioPreparation]))
        try Task.checkCancellation()

        // Les onsets sont toujours recalculés (déterministes et peu coûteux
        // une fois les caractéristiques en mémoire) — seuls tempo/beats
        // passent par le checkpoint.
        let (onsets, envelope) = OnsetDetector().detectOnsets(features: features)

        let rhythmHypotheses: [RhythmHypothesis]
        let selectedRhythmHypothesisID: UUID
        let beats: [BeatEvent]
        let bars: [BarEvent]
        let downbeatConfidence: Double

        if let restored = Self.restoredRhythm(from: checkpoint) {
            // Reprise : phase 2 déjà terminée pour cette empreinte.
            rhythmHypotheses = restored.hypotheses
            selectedRhythmHypothesisID = restored.selectedHypothesisID
            beats = restored.beats
            bars = restored.bars
            downbeatConfidence = restored.downbeatConfidence
        } else {
            // Garde §63/§0.7 : un unique événement ne définit AUCUNE
            // pulsation. Sans elle, sur « silence + impact isolé » (§12.4,
            // test h), le détendançage de l'enveloppe creuse un piédestal
            // négatif autour de l'impact dont l'autocorrélation présente un
            // pic parasite minuscule (≈ 0,02, vérifié numériquement) :
            // l'estimateur en tirait une hypothèse fantôme (~109 BPM,
            // probabilité 1), le suivi §19.1.5 propageait des beats fantômes
            // depuis l'impact sur le silence (pénalité quasi nulle à la
            // période exacte), la grille de spans commençait donc À l'impact
            // et celui-ci tombait dans le span 0 — invisible pour
            // `detectImpacts`, qui exige un span précédent pour mesurer la
            // montée. Avec moins de `minimumOnsetsForTempo` onsets : aucune
            // hypothèse, la grille de repli 0,5 s couvre le morceau entier
            // et l'impact réel est détecté (§12.4).
            let hypotheses = onsets.count >= Self.minimumOnsetsForTempo
                ? TempoEstimator().estimate(
                    envelope: envelope,
                    envelopeRate: features.frameRate
                )
                : []
            if let best = hypotheses.first {
                let tracked = BeatTracker().track(
                    hypothesis: best,
                    envelope: envelope,
                    envelopeRate: features.frameRate,
                    features: features
                )
                // L'hypothèse retenue (raffinée par le suivi) remplace sa
                // version brute ; les hypothèses NON retenues restent avec
                // leurs probabilités (§63 : tempo ambigu → conserver
                // plusieurs hypothèses).
                var merged = hypotheses
                if let index = merged.firstIndex(where: { $0.id == tracked.hypothesis.id }) {
                    merged[index] = tracked.hypothesis
                } else {
                    merged.insert(tracked.hypothesis, at: 0)
                }
                rhythmHypotheses = merged
                selectedRhythmHypothesisID = tracked.hypothesis.id
                beats = tracked.beats
                bars = tracked.bars
                downbeatConfidence = tracked.downbeatConfidence
            } else {
                // Enveloppe plate (ambiant, §72/§63) : aucune hypothèse,
                // beats vides acceptés — structure par nouveauté seulement.
                rhythmHypotheses = []
                selectedRhythmHypothesisID = Self.noHypothesisID
                beats = []
                bars = []
                downbeatConfidence = 0
            }
            let featureData: Data
            if let existing = checkpoint?.featureTimelineData {
                featureData = existing
            } else {
                featureData = try Self.encodeFeatures(features)
            }
            let phase2 = AnalysisCheckpoint(
                fingerprint: checkpointFingerprint,
                engineVersion: Self.engineVersion,
                completedPhases: [
                    AnalysisPhase.audioPreparation.rawValue,
                    AnalysisPhase.pulseAndTempo.rawValue,
                ],
                featureTimelineData: featureData,
                rhythmData: try Self.encodeRhythm(RhythmCheckpointPayload(
                    hypotheses: rhythmHypotheses,
                    selectedHypothesisID: selectedRhythmHypothesisID,
                    beats: beats,
                    bars: bars,
                    downbeatConfidence: downbeatConfidence
                ))
            )
            try cache.saveCheckpoint(phase2, projectID: projectID)
        }
        try Task.checkCancellation()

        // ============================================================
        // Phase 3 §33 — « Phrases et structure »
        // ============================================================
        progress(AnalysisProgress(
            phase: .phrasesAndStructure,
            completedPhases: [.audioPreparation, .pulseAndTempo]
        ))
        try Task.checkCancellation()

        let beatSync = BeatSyncFeatureExtractor().compute(
            features: features,
            beats: beats,
            onsets: onsets
        )
        let structuralUnits = StructureBuilder().build(
            duration: features.duration,
            beats: beats,
            bars: bars,
            beatSync: beatSync
        )
        try Task.checkCancellation()

        // ============================================================
        // Phase 4 §33 — « Montées et impacts »
        // ============================================================
        progress(AnalysisProgress(
            phase: .buildUpsAndImpacts,
            completedPhases: [.audioPreparation, .pulseAndTempo, .phrasesAndStructure]
        ))
        try Task.checkCancellation()

        let curvesAndEvents = CurvesAndEventsBuilder().build(
            features: features,
            beatSync: beatSync,
            beats: beats,
            bars: bars,
            onsets: onsets,
            structuralUnits: structuralUnits
        )
        try Task.checkCancellation()

        // ============================================================
        // Assemblage + cache
        // ============================================================
        let confidence = Self.confidenceBreakdown(
            rhythmHypotheses: rhythmHypotheses,
            selectedID: selectedRhythmHypothesisID,
            downbeatConfidence: downbeatConfidence,
            boundaries: beatSync.boundaries,
            structuralUnits: structuralUnits,
            functionalStates: curvesAndEvents.functionalStates
        )
        let result = MusicAnalysisResult(
            version: Self.engineVersion,
            duration: features.duration,
            rhythmHypotheses: rhythmHypotheses,
            selectedRhythmHypothesisID: selectedRhythmHypothesisID,
            beats: beats,
            bars: bars,
            structuralUnits: structuralUnits,
            functionalStates: curvesAndEvents.functionalStates,
            musicalEvents: curvesAndEvents.events,
            eventRelations: curvesAndEvents.relations,
            continuousCurves: curvesAndEvents.curves,
            analysisConfidence: confidence
        )
        try cache.save(
            result,
            projectID: projectID,
            fingerprint: audioFingerprint,
            engineVersion: Self.engineVersion,
            configurationFingerprint: configFingerprint
        )
        cache.clearCheckpoint(projectID: projectID)

        // Dernière publication : les 4 phases du Jalon 4 sont terminées
        // (la phase « Création des rythmes » arrive au Jalon 5).
        progress(AnalysisProgress(
            phase: .buildUpsAndImpacts,
            completedPhases: [.audioPreparation, .pulseAndTempo, .phrasesAndStructure, .buildUpsAndImpacts]
        ))
        logger.info("Analyse terminée : \(beats.count) beats, \(structuralUnits.count) unités structurelles")
        return result
    }

    // MARK: - Empreinte de configuration (§69)

    /// Empreinte déterministe de la configuration d'analyse — la
    /// configuration invalide le checkpoint mais pas le fichier audio (§69 :
    /// invalider uniquement la couche nécessaire).
    private static func configurationFingerprint(_ configuration: AnalysisConfiguration) -> String {
        "sr\(configuration.analysisSampleRate)" +
        "-s\(configuration.shortBranch.fftSize).\(configuration.shortBranch.hopSize)" +
        "-m\(configuration.mediumBranch.fftSize).\(configuration.mediumBranch.hopSize)" +
        "-l\(configuration.longBranch.fftSize).\(configuration.longBranch.hopSize)" +
        "-w\(configuration.window.rawValue)"
    }

    // MARK: - Encodage des checkpoints (phases 1 et 2)

    /// Miroir `Codable` du rythme suivi (phase 2). `FeatureTimeline` est
    /// déjà `Codable` (agent DSP) — encodage binaire direct via property
    /// list ; `[Float]` est `Codable`, suffisant niveau A.
    private struct RhythmCheckpointPayload: Codable {
        let hypotheses: [RhythmHypothesis]
        let selectedHypothesisID: UUID
        let beats: [BeatEvent]
        let bars: [BarEvent]
        let downbeatConfidence: Double
    }

    private static func encodeFeatures(_ features: FeatureTimeline) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(features)
    }

    private static func restoredFeatures(from checkpoint: AnalysisCheckpoint?) -> FeatureTimeline? {
        guard
            let checkpoint,
            checkpoint.completedPhases.contains(AnalysisPhase.audioPreparation.rawValue),
            let data = checkpoint.featureTimelineData,
            let features = try? PropertyListDecoder().decode(FeatureTimeline.self, from: data),
            features.frameRate > 0
        else {
            return nil
        }
        return features
    }

    private static func encodeRhythm(_ payload: RhythmCheckpointPayload) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(payload)
    }

    private static func restoredRhythm(from checkpoint: AnalysisCheckpoint?) -> RhythmCheckpointPayload? {
        guard
            let checkpoint,
            checkpoint.completedPhases.contains(AnalysisPhase.pulseAndTempo.rawValue),
            let data = checkpoint.rhythmData,
            let payload = try? PropertyListDecoder().decode(RhythmCheckpointPayload.self, from: data)
        else {
            return nil
        }
        return payload
    }

    // MARK: - Résultat minimal (§63 : morceau très court)

    /// Résultat minimal VALIDE : racine seule, aucune hypothèse, aucun
    /// événement — jamais de contenu inventé (§0.7).
    private static func minimalResult(duration: MediaTime) -> MusicAnalysisResult {
        let rootUnits: [StructuralUnit]
        if duration.ticks > 0 {
            rootUnits = [StructuralUnit(
                id: UUID(),
                parentID: nil,
                level: .globalArc,
                start: .zero,
                end: duration,
                repetitionGroupID: nil,
                boundaryStrengthIn: 1,
                boundaryStrengthOut: 1,
                descriptors: MusicalDescriptorVector(
                    energy: 0, rhythmicDensity: 0, tension: 0, novelty: 0,
                    stability: 0, regularity: 0, vocalPresence: 0, bassPresence: 0
                ),
                confidence: 0.5
            )]
        } else {
            rootUnits = []
        }
        return MusicAnalysisResult(
            version: engineVersion,
            duration: duration,
            rhythmHypotheses: [],
            selectedRhythmHypothesisID: noHypothesisID,
            beats: [],
            bars: [],
            structuralUnits: rootUnits,
            functionalStates: [],
            musicalEvents: [],
            eventRelations: [],
            continuousCurves: ContinuousCurves(
                energy: [], density: [], tension: [], novelty: [],
                stability: [], regularity: [], vocalPresence: [], bassPresence: []
            ),
            analysisConfidence: ConfidenceBreakdown(overall: 0.1, rhythm: 0, structure: 0.1, functions: 0)
        )
    }

    // MARK: - Confiances réelles par domaine

    /// Confiances calculées depuis les valeurs réellement mesurées — jamais
    /// de confiance décorative (§0.7, §29).
    private static func confidenceBreakdown(
        rhythmHypotheses: [RhythmHypothesis],
        selectedID: UUID,
        downbeatConfidence: Double,
        boundaries: [StructuralBoundary],
        structuralUnits: [StructuralUnit],
        functionalStates: [FunctionalStateInterval]
    ) -> ConfidenceBreakdown {
        let rhythm: Double
        if let selected = rhythmHypotheses.first(where: { $0.id == selectedID }) {
            rhythm = min(max(selected.probability * (0.5 + 0.5 * downbeatConfidence), 0), 1)
        } else {
            rhythm = 0
        }
        let structure: Double
        if boundaries.isEmpty {
            structure = structuralUnits.count > 1 ? 0.3 : 0.2
        } else {
            structure = min(
                boundaries.reduce(0.0) { $0 + $1.confidence } / Double(boundaries.count),
                1
            )
        }
        let functions = functionalStates.isEmpty
            ? 0
            : functionalStates.reduce(0.0) { $0 + $1.confidence } / Double(functionalStates.count)
        let overall = min(max(0.4 * rhythm + 0.4 * structure + 0.2 * functions, 0), 1)
        return ConfidenceBreakdown(
            overall: overall,
            rhythm: rhythm,
            structure: structure,
            functions: functions
        )
    }
}
