//
//  SpectralFeatureExtractor.swift
//  MontageMusical
//
//  STFT vDSP branche courte (Jalon 4, spec §79) — spec §16.3 (FFT 1024,
//  hop 256, fenêtre de Hann, spectre de puissance logarithmique), §17
//  (caractéristiques bas niveau, normalisation relative au morceau), §68
//  (buffer circulaire : jamais tout le PCM en mémoire).
//

import Accelerate
import Foundation

/// Produit la `FeatureTimeline` (spec §17) à partir du flux PCM streamé par
/// `PCMDecoder`, via une STFT vDSP sur la branche courte de la
/// configuration (spec §16.3).
///
/// La consommation se fait par blocs dans un buffer glissant compacté
/// régulièrement (spec §68) : l'intégralité du PCM n'est jamais en mémoire.
/// Seules les courbes agrégées par frame sont conservées.
///
/// Convention temporelle : les frames sont **centrées** — la frame `k` est
/// centrée sur l'échantillon `k × hop` (remplissage de `fftSize/2` zéros en
/// tête et en queue). Le temps d'une frame passe par l'utilitaire unique
/// `FeatureTimeline.mediaTime(forFrame:frameRate:)` (règle transverse §9).
struct SpectralFeatureExtractor: Sendable {

    private let configuration: AnalysisConfiguration

    init(configuration: AnalysisConfiguration) {
        self.configuration = configuration
    }

    /// Extrait la timeline de caractéristiques §17 du fichier `url`.
    ///
    /// Le PCM est décodé en streaming par `decoder` (mono Float32 à
    /// `configuration.analysisSampleRate`, spec §16.2) et consommé bloc par
    /// bloc — l'annulation coopérative est gérée par le décodeur entre les
    /// blocs.
    func extract(url: URL, decoder: PCMDecoder) async throws -> FeatureTimeline {
        let branch = configuration.shortBranch
        let sampleRate = Double(configuration.analysisSampleRate)
        guard let processor = ShortBranchProcessor(
            fftSize: branch.fftSize,
            hopSize: branch.hopSize,
            sampleRate: sampleRate
        ) else {
            // Jamais atteint pour une configuration valide (.production) :
            // uniquement si vDSP refuse la taille de FFT demandée.
            throw AudioImportError.emptyOrCorruptFile
        }

        try await decoder.decode(url: url, sampleRate: sampleRate) { block in
            processor.append(block)
        }
        processor.finish()
        return processor.makeTimeline()
    }
}

// MARK: - Processeur de la branche courte

/// État de la STFT streamée. Classe locale non-Sendable : construite,
/// utilisée et libérée dans la même tâche (`extract`), jamais partagée.
private final class ShortBranchProcessor {

    // Configuration figée
    private let fftSize: Int
    private let hopSize: Int
    private let sampleRate: Double
    private let halfSize: Int
    private let dft: vDSP_DFT_Setup
    private let window: [Float]
    private let bandRanges: [ClosedRange<Int>]
    private let binFrequencies: [Float]
    /// Premier bin retenu par le centroïde de brillance (voir
    /// `centroidLowerBoundHz`). Toujours ≥ 1 : le DC reste exclu.
    private let centroidLowerBin: Int

    /// Plancher du spectre de puissance logarithmique (§16.3) — évite
    /// `log(0)` ; sa valeur exacte est neutralisée par la normalisation
    /// relative (§17).
    private static let logFloor: Float = 1e-9

    /// Borne basse du centroïde de brillance (défaut S1 de la critique).
    ///
    /// Le centroïde §17 servait à mesurer la BRILLANCE, et il alimente 40 %
    /// de la courbe de tension (`CurvesAndEventsBuilder.tensionCurve`).
    /// Calculé sur tout le spectre et pondéré par la PUISSANCE linéaire, il
    /// était en réalité dominé par la fondamentale du kick : sur un kick
    /// distordu il valait ~270 Hz dans un drop contre ~800 Hz dans un
    /// breakdown, c'est-à-dire qu'il DESCENDAIT quand la musique devenait la
    /// plus brillante. Signe inversé, et donc courbe de tension inversée.
    ///
    /// Deux corrections combinées, toutes deux usuelles en MIR percussive :
    /// 1. écarter la zone grave, où vivent la fondamentale du kick et la
    ///    basse (20-200 Hz) — c'est de l'énergie, pas de la brillance ;
    /// 2. pondérer par la MAGNITUDE et non par la puissance, pour qu'une
    ///    seule composante très forte ne puisse plus écraser la somme.
    ///
    /// 200 Hz à 22 050 Hz / FFT 1 024 (largeur de bin 21,53 Hz) tombe au
    /// bin 9,29, donc premier bin retenu = 10 = 215,3 Hz. La bande 0
    /// (20-120 Hz) et le bas de la bande 1 sont ainsi exclus ; l'énergie du
    /// grave reste disponible ailleurs, dans `bandEnergies[0]`, qui est ce
    /// que lit le suivi de mesure (§20).
    private static let centroidLowerBoundHz: Double = 200

    // Buffer glissant (§68) : compacté dès que le préfixe consommé grossit.
    private var buffer: [Float]
    private var readOffset = 0
    private static let compactionThreshold = 1 << 16

    /// Nombre d'échantillons PCM RÉELLEMENT reçus du décodeur (hors
    /// remplissages de tête/queue des frames centrées) — source de la durée
    /// §28.1 : `mediaTime(forFrame: frameCount)` dépasserait la vraie
    /// longueur de 1 à `hopSize` échantillons.
    private var consumedSampleCount = 0

    // Tampons de travail réutilisés frame après frame
    private var windowed: [Float]
    private var splitReal: [Float]
    private var splitImag: [Float]
    private var outputReal: [Float]
    private var outputImag: [Float]
    private var power: [Float]
    private var logPower: [Float]
    private var previousLogPower: [Float]
    private var hasPreviousFrame = false

    // Séries de sortie (une valeur par frame — courbes agrégées, §68)
    private var rms: [Float] = []
    private var bandEnergies: [[Float]]
    private var globalFlux: [Float] = []
    private var bandFlux: [[Float]]
    private var centroid: [Float] = []

    init?(fftSize: Int, hopSize: Int, sampleRate: Double) {
        guard fftSize > 0, fftSize % 2 == 0, hopSize > 0, sampleRate > 0,
              let setup = vDSP_DFT_zrop_CreateSetup(
                nil,
                vDSP_Length(fftSize),
                vDSP_DFT_Direction.FORWARD
              ) else {
            return nil
        }
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.sampleRate = sampleRate
        self.halfSize = fftSize / 2
        self.dft = setup

        // Fenêtre de Hann (spec §16.3) via vDSP.
        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        self.window = hann

        // Bandes §17 : bornes Hz → index de bins de la branche courte.
        let nyquist = sampleRate / 2
        let bandCount = FeatureTimeline.bandCount
        var ranges: [ClosedRange<Int>] = []
        ranges.reserveCapacity(bandCount)
        for band in 0..<bandCount {
            let lowHz = FeatureTimeline.bandLowerBoundsHz[band]
            let highHz = band + 1 < bandCount
                ? FeatureTimeline.bandLowerBoundsHz[band + 1]
                : nyquist
            var lowBin = Int((lowHz * Double(fftSize) / sampleRate).rounded(.up))
            var highBin = Int((highHz * Double(fftSize) / sampleRate).rounded(.down))
            lowBin = min(max(lowBin, 1), halfSize)
            highBin = min(max(highBin, lowBin), halfSize)
            ranges.append(lowBin...highBin)
        }
        self.bandRanges = ranges

        var frequencies = [Float](repeating: 0, count: halfSize + 1)
        for bin in 0...halfSize {
            frequencies[bin] = Float(Double(bin) * sampleRate / Double(fftSize))
        }
        self.binFrequencies = frequencies

        // Borne basse du centroïde de brillance (§17, défaut S1). Arrondi
        // vers le haut pour ne jamais inclure un bin sous la borne, plancher
        // à 1 (DC exclu), plafond à halfSize pour rester valide même sur une
        // configuration exotique où 200 Hz dépasserait Nyquist.
        let rawCentroidBin = (Self.centroidLowerBoundHz * Double(fftSize) / sampleRate).rounded(.up)
        self.centroidLowerBin = min(max(Int(rawCentroidBin), 1), halfSize)

        // Frames centrées : remplissage initial de fftSize/2 zéros.
        self.buffer = [Float](repeating: 0, count: halfSize)

        self.windowed = [Float](repeating: 0, count: fftSize)
        self.splitReal = [Float](repeating: 0, count: halfSize)
        self.splitImag = [Float](repeating: 0, count: halfSize)
        self.outputReal = [Float](repeating: 0, count: halfSize)
        self.outputImag = [Float](repeating: 0, count: halfSize)
        self.power = [Float](repeating: 0, count: halfSize + 1)
        self.logPower = [Float](repeating: 0, count: halfSize + 1)
        self.previousLogPower = [Float](repeating: 0, count: halfSize + 1)
        self.bandEnergies = Array(repeating: [], count: bandCount)
        self.bandFlux = Array(repeating: [], count: bandCount)
    }

    deinit {
        vDSP_DFT_DestroySetup(dft)
    }

    /// Ajoute un bloc PCM et traite toutes les frames complètes disponibles.
    func append(_ block: [Float]) {
        consumedSampleCount += block.count
        buffer.append(contentsOf: block)
        processAvailableFrames()
        compactIfNeeded()
    }

    /// Clôture du flux : remplissage de queue (frames centrées) puis
    /// traitement des dernières frames.
    func finish() {
        buffer.append(contentsOf: [Float](repeating: 0, count: halfSize))
        processAvailableFrames()
    }

    /// Assemble la timeline finale, normalisée relativement au morceau
    /// (spec §17 dernier alinéa) — passe unique après le streaming.
    func makeTimeline() -> FeatureTimeline {
        let frameRate = sampleRate / Double(hopSize)
        return FeatureTimeline(
            frameRate: frameRate,
            // Durée = échantillons PCM réellement consommés (§28.1 :
            // `mediaTime(forFrame: frameCount)` dépasserait le PCM réel de
            // 1 à `hopSize` échantillons à cause de l'arrondi de la
            // dernière frame). Conversion Double → ticks à cette SEULE
            // frontière (§9), règle d'arrondi constante de
            // `MediaTime(seconds:)`. `frameCount` reste la longueur des
            // courbes.
            duration: MediaTime(seconds: Double(consumedSampleCount) / sampleRate),
            rms: Self.normalizedRelative(rms),
            bandEnergies: bandEnergies.map(Self.normalizedRelative),
            spectralFlux: Self.normalizedRelative(globalFlux),
            bandFlux: bandFlux.map(Self.normalizedRelative),
            spectralCentroid: centroid // reste en Hz (§17)
        )
    }

    // MARK: - Boucle de frames

    private func processAvailableFrames() {
        while buffer.count - readOffset >= fftSize {
            processFrame(at: readOffset)
            readOffset += hopSize
        }
    }

    private func compactIfNeeded() {
        if readOffset >= Self.compactionThreshold {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
    }

    private func processFrame(at offset: Int) {
        // RMS (fenêtre brute) + fenêtrage de Hann via vDSP.
        var frameRMS: Float = 0
        buffer.withUnsafeBufferPointer { pointer in
            let frame = pointer.baseAddress! + offset
            vDSP_rmsqv(frame, 1, &frameRMS, vDSP_Length(fftSize))
            window.withUnsafeBufferPointer { windowPointer in
                windowed.withUnsafeMutableBufferPointer { destination in
                    vDSP_vmul(
                        frame, 1,
                        windowPointer.baseAddress!, 1,
                        destination.baseAddress!, 1,
                        vDSP_Length(fftSize)
                    )
                }
            }
        }
        rms.append(frameRMS)

        // Désentrelacement pair/impair → format split complex zrop.
        windowed.withUnsafeBufferPointer { windowedPointer in
            windowedPointer.baseAddress!.withMemoryRebound(
                to: DSPComplex.self,
                capacity: halfSize
            ) { complexPointer in
                splitReal.withUnsafeMutableBufferPointer { realPointer in
                    splitImag.withUnsafeMutableBufferPointer { imagPointer in
                        var split = DSPSplitComplex(
                            realp: realPointer.baseAddress!,
                            imagp: imagPointer.baseAddress!
                        )
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
            }
        }

        // FFT réelle vDSP (branche courte, spec §16.3).
        splitReal.withUnsafeBufferPointer { inputReal in
            splitImag.withUnsafeBufferPointer { inputImag in
                outputReal.withUnsafeMutableBufferPointer { outReal in
                    outputImag.withUnsafeMutableBufferPointer { outImag in
                        vDSP_DFT_Execute(
                            dft,
                            inputReal.baseAddress!,
                            inputImag.baseAddress!,
                            outReal.baseAddress!,
                            outImag.baseAddress!
                        )
                    }
                }
            }
        }

        // Spectre de puissance, bins 0...halfSize. Empaquetage zrop :
        // DC dans outputReal[0], Nyquist dans outputImag[0].
        power[0] = outputReal[0] * outputReal[0]
        power[halfSize] = outputImag[0] * outputImag[0]
        for bin in 1..<halfSize {
            power[bin] = outputReal[bin] * outputReal[bin]
                + outputImag[bin] * outputImag[bin]
        }
        // Spectre de puissance logarithmique (spec §16.3).
        for bin in 0...halfSize {
            logPower[bin] = log(power[bin] + Self.logFloor)
        }

        // Énergie par bande (puissance linéaire, spec §17).
        for (band, range) in bandRanges.enumerated() {
            var sum: Float = 0
            for bin in range { sum += power[bin] }
            bandEnergies[band].append(sum)
        }

        // Flux spectral : différence redressée demi-onde entre spectres
        // logarithmiques consécutifs (spec §17), global et par bande (§18).
        if hasPreviousFrame {
            var total: Float = 0
            for bin in 0...halfSize {
                total += max(logPower[bin] - previousLogPower[bin], 0)
            }
            globalFlux.append(total)
            for (band, range) in bandRanges.enumerated() {
                var sum: Float = 0
                for bin in range {
                    sum += max(logPower[bin] - previousLogPower[bin], 0)
                }
                bandFlux[band].append(sum)
            }
        } else {
            globalFlux.append(0)
            for band in bandRanges.indices {
                bandFlux[band].append(0)
            }
        }
        swap(&previousLogPower, &logPower)
        hasPreviousFrame = true

        // Centroïde de BRILLANCE en Hz (spec §17, corrigé — défaut S1).
        // Pondération par la MAGNITUDE (racine de la puissance) et non par
        // la puissance, sur les bins au-dessus de 200 Hz uniquement : voir
        // `centroidLowerBoundHz` pour la démonstration du signe inversé.
        var weighted: Float = 0
        var total: Float = 0
        for bin in centroidLowerBin...halfSize {
            let magnitude = sqrt(power[bin])
            weighted += binFrequencies[bin] * magnitude
            total += magnitude
        }
        centroid.append(total > 1e-12 ? weighted / total : 0)
    }

    // MARK: - Normalisation relative au morceau (spec §17)

    /// Normalise une série par son quantile 0,95 (spec §17 : médiane,
    /// quantiles — un master fort ne doit pas être constamment culminant).
    /// Séries éparses (quantile ≈ 0) : repli sur le maximum ; silence
    /// intégral : série inchangée (zéros). Entièrement déterministe.
    private static func normalizedRelative(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return values }
        let sorted = values.sorted()
        let quantileIndex = Int((Double(sorted.count - 1) * 0.95).rounded())
        var scale = sorted[quantileIndex]
        if scale <= 1e-9 {
            scale = sorted[sorted.count - 1] // maximum
        }
        guard scale > 1e-9 else { return values }
        return values.map { $0 / scale }
    }
}
