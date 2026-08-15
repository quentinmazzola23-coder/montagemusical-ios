//
//  HybridAnalyzerFallbackTests.swift
//  MontageMusicalTests
//
//  Jalon 11 (§86) — preuve du FALLBACK, pas preuve d'un modèle.
//
//  ⛔ Rappel §29A : aucun modèle Core ML n'est entraîné ni embarqué. Ces tests
//  ne vérifient donc AUCUNE qualité d'analyse « améliorée » (il n'y a rien à
//  améliorer sans modèle). Ils vérifient exactement trois choses vérifiables :
//
//   1. `CoreMLModelRegistry` ne trouve aucun modèle embarqué → modèle `nil`,
//      version `nil` (§61 : pas de version inventée) ;
//   2. `HybridMusicAnalyzer(activationModel: nil)` produit EXACTEMENT le même
//      résultat que `DeterministicMusicAnalyzer` sur un WAV synthétique
//      (§86 : « fallback déterministe toujours disponible ») ;
//   3. un faux `BeatActivationModel` injecté ne fait PAS diverger le résultat
//      aujourd'hui, et n'est même jamais consulté — le chemin hybride est un
//      TODO documenté, pas une implémentation cachée.
//
//  Méthode (identique à `AnalysisPipelineTests`) : WAV synthétiques
//  déterministes de `TestAudioFactory`, projets DISTINCTS avec un contenu
//  audio identique octet à octet — chaque projet a son propre cache §69, donc
//  l'égalité constatée vient bien de deux analyses réelles, jamais d'un
//  retour de cache partagé.
//

import XCTest
@testable import MontageMusical

final class HybridAnalyzerFallbackTests: XCTestCase {

    private var rootURL: URL!
    private var fileStore: ProjectFileStore!
    private var cache: AnalysisCache!
    private var deterministic: DeterministicMusicAnalyzer!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "HybridAnalyzerFallbackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        fileStore = ProjectFileStore(rootURL: rootURL)
        cache = AnalysisCache(fileStore: fileStore)
        deterministic = DeterministicMusicAnalyzer(cache: cache, fileStore: fileStore)
    }

    override func tearDownWithError() throws {
        deterministic = nil
        cache = nil
        fileStore = nil
        if let rootURL, FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    // MARK: - Helpers

    /// Fréquence d'échantillonnage des WAV de test (le flux d'analyse
    /// rééchantillonne à 22 050 Hz — §16.2).
    private static let wavSampleRate = 44_100

    /// Durée des WAV de test.
    private static let seconds = 10.0

    /// Écrit une fois le click track de référence (128 BPM, 10 s) et renvoie
    /// son URL — toutes les analyses comparées partent des MÊMES octets.
    private func writeSharedClickTrack() throws -> URL {
        let sourceURL = rootURL.appending(path: "click-source.wav")
        try TestAudioFactory.writeWav(
            samples: TestAudioFactory.clickTrack(
                bpm: 128,
                seconds: Self.seconds,
                sampleRate: Self.wavSampleRate
            ),
            sampleRate: Self.wavSampleRate,
            to: sourceURL
        )
        return sourceURL
    }

    /// Crée un projet (arbre §11) contenant une copie du WAV fourni.
    private func makeProject(copyOf sourceURL: URL) throws -> ImportedAudio {
        let projectID = UUID()
        try fileStore.createDirectories(for: projectID)
        let audioURL = fileStore
            .subdirectoryURL(.audio, for: projectID)
            .appending(path: "original.wav")
        try FileManager.default.copyItem(at: sourceURL, to: audioURL)
        return ImportedAudio(
            projectID: projectID,
            relativePath: "audio/original.wav",
            originalFilename: "original.wav",
            duration: MediaTime(seconds: Self.seconds),
            fileExtension: "wav"
        )
    }

    /// Collecteur thread-safe des phases §33 publiées.
    private final class PhaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [AnalysisPhase] = []
        func append(_ progress: AnalysisProgress) {
            lock.lock()
            phases.append(progress.phase)
            lock.unlock()
        }
        var all: [AnalysisPhase] {
            lock.lock()
            defer { lock.unlock() }
            return phases
        }
    }

    /// Faux modèle d'activation — UNIQUEMENT dans les tests (§29A : jamais de
    /// modèle simulé dans la cible iOS). Il renvoie des activations nulles et
    /// compte ses appels : le test vérifie que ce compteur reste à **zéro**,
    /// c'est-à-dire que `HybridMusicAnalyzer` ne consulte aujourd'hui aucun
    /// modèle, même quand on lui en fournit un.
    ///
    /// Le compteur vit dans un ACTEUR : `predict` est asynchrone, et
    /// verrouiller un `NSLock` depuis un contexte async est interdit en
    /// Swift 6 (« instance method 'lock' is unavailable from asynchronous
    /// contexts »).
    private actor CallCounter {
        private var calls = 0
        func increment() { calls += 1 }
        var count: Int { calls }
    }

    private final class RecordingActivationModel: BeatActivationModel, Sendable {
        private let counter = CallCounter()

        func predictCallCount() async -> Int {
            await counter.count
        }

        func predict(features: ModelInputFeatures) async throws -> BeatActivations {
            await counter.increment()
            let zeros = [Float](repeating: 0, count: max(features.frameCount, 1))
            return BeatActivations(
                beat: zeros,
                downbeat: zeros,
                frameRate: features.frameRate
            )
        }
    }

    /// Égalité STRICTE hors identifiants (les UUID sont régénérés à chaque
    /// analyse ; tout le reste doit coïncider : ticks exacts §9, flottants à
    /// 1e-9 près).
    private func assertIdenticalAnalysis(
        _ produced: MusicAnalysisResult,
        _ reference: MusicAnalysisResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(produced.version, reference.version, file: file, line: line)
        // `version` est la version de SCHÉMA du résultat (§12), pas celle du
        // moteur : le fallback produit le même document, et le jour où le
        // chemin hybride existera il devra produire le MÊME schéma — seule la
        // version de moteur, tracée ailleurs, aura le droit de bouger.
        XCTAssertEqual(
            produced.version, DeterministicMusicAnalyzer.analysisSchemaVersion,
            "Le résultat doit porter la version de SCHÉMA d'analyse",
            file: file, line: line
        )
        XCTAssertEqual(produced.duration.ticks, reference.duration.ticks, file: file, line: line)

        // Tempo retenu — cœur de l'exigence §86 (fallback = même pulsation).
        let producedSelected = try XCTUnwrap(
            produced.rhythmHypotheses.first { $0.id == produced.selectedRhythmHypothesisID },
            "Hypothèse retenue introuvable (résultat hybride)", file: file, line: line
        )
        let referenceSelected = try XCTUnwrap(
            reference.rhythmHypotheses.first { $0.id == reference.selectedRhythmHypothesisID },
            "Hypothèse retenue introuvable (résultat déterministe)", file: file, line: line
        )
        XCTAssertEqual(
            producedSelected.tempoBPM, referenceSelected.tempoBPM, accuracy: 1e-9,
            "Le tempo retenu doit être IDENTIQUE au moteur déterministe", file: file, line: line
        )
        XCTAssertEqual(
            producedSelected.probability, referenceSelected.probability, accuracy: 1e-9,
            file: file, line: line
        )
        XCTAssertEqual(
            produced.rhythmHypotheses.count, reference.rhythmHypotheses.count,
            "Mêmes hypothèses conservées (§63)", file: file, line: line
        )

        // Beats en TICKS exacts (§9) — l'assertion la plus directe du §86.
        XCTAssertEqual(
            produced.beats.count, reference.beats.count,
            "Mêmes beats attendus sans modèle", file: file, line: line
        )
        for (producedBeat, referenceBeat) in zip(produced.beats, reference.beats) {
            XCTAssertEqual(producedBeat.time.ticks, referenceBeat.time.ticks, file: file, line: line)
            XCTAssertEqual(producedBeat.strength, referenceBeat.strength, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(producedBeat.confidence, referenceBeat.confidence, accuracy: 1e-9, file: file, line: line)
        }

        XCTAssertEqual(produced.bars.count, reference.bars.count, file: file, line: line)

        // Structure, événements, courbes et confiances : rien ne doit bouger.
        XCTAssertEqual(
            produced.structuralUnits.count, reference.structuralUnits.count,
            file: file, line: line
        )
        for (producedUnit, referenceUnit) in zip(produced.structuralUnits, reference.structuralUnits) {
            XCTAssertEqual(producedUnit.level, referenceUnit.level, file: file, line: line)
            XCTAssertEqual(producedUnit.start.ticks, referenceUnit.start.ticks, file: file, line: line)
            XCTAssertEqual(producedUnit.end.ticks, referenceUnit.end.ticks, file: file, line: line)
        }
        XCTAssertEqual(produced.musicalEvents.count, reference.musicalEvents.count, file: file, line: line)
        for (producedEvent, referenceEvent) in zip(produced.musicalEvents, reference.musicalEvents) {
            XCTAssertEqual(producedEvent.type, referenceEvent.type, file: file, line: line)
            XCTAssertEqual(producedEvent.start.ticks, referenceEvent.start.ticks, file: file, line: line)
            XCTAssertEqual(producedEvent.end?.ticks, referenceEvent.end?.ticks, file: file, line: line)
        }
        XCTAssertEqual(
            produced.continuousCurves.energy.count, reference.continuousCurves.energy.count,
            file: file, line: line
        )
        for (producedPoint, referencePoint) in zip(
            produced.continuousCurves.energy,
            reference.continuousCurves.energy
        ) {
            XCTAssertEqual(producedPoint.time.ticks, referencePoint.time.ticks, file: file, line: line)
            XCTAssertEqual(producedPoint.value, referencePoint.value, accuracy: 1e-9, file: file, line: line)
        }
        XCTAssertEqual(
            produced.analysisConfidence.overall, reference.analysisConfidence.overall, accuracy: 1e-9,
            "Aucune confiance recalibrée sans modèle (§86)", file: file, line: line
        )
        XCTAssertEqual(
            produced.analysisConfidence.rhythm, reference.analysisConfidence.rhythm, accuracy: 1e-9,
            file: file, line: line
        )
        XCTAssertEqual(
            produced.analysisConfidence.structure, reference.analysisConfidence.structure, accuracy: 1e-9,
            file: file, line: line
        )
        XCTAssertEqual(
            produced.analysisConfidence.functions, reference.analysisConfidence.functions, accuracy: 1e-9,
            file: file, line: line
        )
    }

    // MARK: - (1) Registre : aucun modèle embarqué, aucune version (§29A, §61)

    func testRegistryFindsNoEmbeddedModelAndReportsNoVersion() throws {
        // Bundle de l'application (cas de production).
        XCTAssertFalse(
            CoreMLModelRegistry.isBeatDownbeatModelEmbedded(),
            "Aucun modèle Core ML ne doit être embarqué (§29A : jamais de fichier modèle factice)"
        )
        XCTAssertNil(
            CoreMLModelRegistry.embeddedResourceURL(for: CoreMLModelRegistry.beatDownbeatDescriptor)
        )
        XCTAssertNil(
            CoreMLModelRegistry.beatActivationModel(),
            "La fabrique doit renvoyer nil en l'absence de modèle — aucun chargement factice"
        )
        XCTAssertNil(
            CoreMLModelRegistry.beatActivationModelVersion(),
            "§61 : sans modèle, la version du modèle Core ML est nil, jamais une chaîne inventée"
        )

        // Bundle des tests : même constat (aucune ressource glissée par un
        // fixture de test).
        let testBundle = Bundle(for: type(of: self))
        XCTAssertFalse(CoreMLModelRegistry.isBeatDownbeatModelEmbedded(in: testBundle))
        XCTAssertNil(CoreMLModelRegistry.beatActivationModel(in: testBundle))
        XCTAssertNil(CoreMLModelRegistry.beatActivationModelVersion(in: testBundle))

        // Le chemin hybride est déclaré non implémenté dans le code lui-même.
        XCTAssertFalse(
            HybridMusicAnalyzer.isHybridPathImplemented,
            "Jalon 11 non terminé : le chemin hybride ne doit pas se déclarer implémenté"
        )
    }

    // MARK: - (2) Sans modèle : résultat identique au déterministe (§86)

    func testHybridWithoutModelProducesExactlyDeterministicResult() async throws {
        let sourceURL = try writeSharedClickTrack()
        let referenceAudio = try makeProject(copyOf: sourceURL)
        let hybridAudio = try makeProject(copyOf: sourceURL)

        // Le modèle vient du registre : aujourd'hui, c'est nil.
        let activationModel = CoreMLModelRegistry.beatActivationModel()
        XCTAssertNil(activationModel)
        let hybrid = HybridMusicAnalyzer(deterministic: deterministic, activationModel: activationModel)
        XCTAssertFalse(hybrid.hasActivationModel)

        let referenceLog = PhaseLog()
        let reference = try await deterministic.analyze(
            audio: referenceAudio,
            configuration: .production
        ) { referenceLog.append($0) }

        let hybridLog = PhaseLog()
        let produced = try await hybrid.analyze(
            audio: hybridAudio,
            configuration: .production
        ) { hybridLog.append($0) }

        // Le résultat, champ par champ.
        try assertIdenticalAnalysis(produced, reference)

        // La progression §33 aussi : le fallback transmet le closure tel quel,
        // l'utilisateur voit exactement les mêmes phases.
        XCTAssertEqual(
            hybridLog.all, referenceLog.all,
            "Le fallback doit republier exactement les phases §33 du moteur déterministe"
        )

        // Contrôle de non-trivialité : ce click track 128 BPM produit bien une
        // analyse RICHE — sinon l'égalité ci-dessus comparerait deux résultats
        // vides et ne prouverait rien.
        XCTAssertGreaterThan(
            produced.beats.count, 10,
            "Le click track doit produire de vrais beats, sinon la comparaison est vide de sens"
        )
    }

    // MARK: - (3) Avec un faux modèle : AUCUNE divergence, modèle non consulté

    func testHybridWithInjectedModelStillMatchesDeterministicAndNeverCallsIt() async throws {
        let sourceURL = try writeSharedClickTrack()
        let referenceAudio = try makeProject(copyOf: sourceURL)
        let hybridAudio = try makeProject(copyOf: sourceURL)

        let fakeModel = RecordingActivationModel()
        let hybrid = HybridMusicAnalyzer(deterministic: deterministic, activationModel: fakeModel)
        XCTAssertTrue(hybrid.hasActivationModel, "Le modèle de test doit bien être injecté")

        let reference = try await deterministic.analyze(
            audio: referenceAudio,
            configuration: .production
        ) { _ in }
        let produced = try await hybrid.analyze(
            audio: hybridAudio,
            configuration: .production
        ) { _ in }

        // Documentation exécutable de l'état du Jalon 11 : la présence d'un
        // modèle ne change RIEN aujourd'hui, parce que le décodeur hybride
        // (§19.2, post-traitement hors modèle) n'est pas écrit. Le jour où il
        // le sera, CE test devra être remplacé par une comparaison A/B réelle
        // (§86) — sa rupture sera le signal que le chemin hybride existe.
        try assertIdenticalAnalysis(produced, reference)

        // Et la preuve directe qu'aucun chemin hybride caché ne s'exécute :
        // `predict` n'est jamais appelé.
        let predictCallCount = await fakeModel.predictCallCount()
        XCTAssertEqual(
            predictCallCount, 0,
            "Aucune inférence ne doit avoir lieu : le chemin hybride est un TODO (§29A)"
        )
    }
}
