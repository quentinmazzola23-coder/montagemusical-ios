//
//  WaveformExtractor.swift
//  MontageMusical
//
//  Waveform simple (Jalon 3, spec §78) — spec §16.2 (flux d'analyse mono
//  Float32, normalisation d'analyse non destructive), §68 (lecture par
//  blocs : jamais tout le PCM en mémoire), §69A (jamais de waveform dans
//  les logs).
//

import AVFoundation
import CoreMedia
import Foundation

/// Extrait une waveform d'affichage : pics maximaux par bin, normalisés
/// dans `0...1` (spec §16.2, §78).
///
/// Le fichier audio est UNIQUEMENT lu — la normalisation est une
/// normalisation d'analyse non destructive, jamais écrite dans le fichier
/// original (§16.2). La lecture se fait par blocs `CMSampleBuffer`
/// successifs : l'intégralité du PCM n'est jamais en mémoire (§68) et
/// l'annulation coopérative est vérifiée entre les blocs.
struct WaveformExtractor: Sendable {

    init() {}

    /// Pics normalisés `0...1` sur `binCount` bins.
    ///
    /// - Parameters:
    ///   - audioURL: fichier audio local (typiquement
    ///     `audio/original.<ext>` du projet, §11).
    ///   - binCount: nombre de bins de sortie (défaut 200). Le tableau
    ///     retourné contient exactement `binCount` valeurs.
    /// - Returns: pour chaque bin, le pic d'amplitude `|échantillon|`
    ///   maximal, normalisé par le pic global du morceau (silence → 0).
    func waveform(for audioURL: URL, binCount: Int = 200) async throws -> [Float] {
        guard binCount > 0 else { return [] }

        let asset = AVURLAsset(url: audioURL)

        // Piste audio décodable requise — mêmes erreurs §62 que l'import.
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioImportError.noDecodableAudioTrack
        }
        guard let track = audioTracks.first else {
            throw AudioImportError.noDecodableAudioTrack
        }

        // Fréquence d'échantillonnage source : la sortie mono conserve la
        // fréquence native (aucun rééchantillonnage nécessaire pour des
        // pics d'affichage).
        let formatDescriptions: [CMFormatDescription]
        let loadedDuration: CMTime
        do {
            formatDescriptions = try await track.load(.formatDescriptions)
            loadedDuration = try await asset.load(.duration)
        } catch {
            throw AudioImportError.emptyOrCorruptFile
        }
        guard let formatDescription = formatDescriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mSampleRate > 0 else {
            throw AudioImportError.emptyOrCorruptFile
        }
        guard let duration = MediaTime(cmTime: loadedDuration), duration.ticks > 0 else {
            throw AudioImportError.emptyOrCorruptFile
        }

        // Nombre de canaux source. `AVAssetReaderTrackOutput` REFUSE
        // `AVNumberOfChannelsKey` (exception Objective-C non rattrapable) :
        // la sortie conserve les canaux natifs entrelacés, le « mixage »
        // mono se fait au binning (pic sur tous les canaux d'une frame).
        let channelCount = max(Int(asbd.mChannelsPerFrame), 1)

        // Nombre total de FRAMES estimé (durée conteneur × fréquence) — sert
        // uniquement à répartir les frames dans les bins (indices bornés).
        // Un conteneur VBR peut surestimer : recalage en fin de passe.
        let totalFrameEstimate = Int64((duration.seconds * asbd.mSampleRate).rounded())
        guard totalFrameEstimate > 0 else {
            throw AudioImportError.emptyOrCorruptFile
        }

        // Sortie PCM Float32 entrelacé, canaux natifs (§16.2), par blocs (§68).
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioImportError.emptyOrCorruptFile
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioImportError.emptyOrCorruptFile
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioImportError.emptyOrCorruptFile
        }

        // Pic maximal par bin, en une passe. Seul le bloc courant est en
        // mémoire (§68) ; `blockSamples` est réutilisé entre les blocs.
        var peaks = [Float](repeating: 0, count: binCount)
        var frameIndex: Int64 = 0
        var blockSamples: [Float] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            // Annulation coopérative + yield entre les blocs : ne monopolise
            // jamais un thread du pool coopératif pendant tout le décodage
            // d'un long morceau.
            do {
                try Task.checkCancellation()
            } catch {
                reader.cancelReading()
                throw error
            }
            await Task.yield()

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = byteCount / MemoryLayout<Float>.size
            let frameCount = sampleCount / channelCount
            guard frameCount > 0 else { continue }

            if blockSamples.count < sampleCount {
                blockSamples = [Float](repeating: 0, count: sampleCount)
            }
            let status = blockSamples.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: destination.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else {
                reader.cancelReading()
                throw AudioImportError.emptyOrCorruptFile
            }

            // Pic par FRAME : maximum de |échantillon| sur les canaux
            // entrelacés, binné par index de frame.
            for frame in 0..<frameCount {
                var magnitude: Float = 0
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    magnitude = max(magnitude, abs(blockSamples[base + channel]))
                }
                let rawBin = (frameIndex + Int64(frame)) * Int64(binCount) / totalFrameEstimate
                let bin = Int(min(max(rawBin, 0), Int64(binCount - 1)))
                if magnitude > peaks[bin] {
                    peaks[bin] = magnitude
                }
            }
            frameIndex += Int64(frameCount)
        }

        guard reader.status == .completed else {
            // `.cancelled` est impossible ici (l'annulation a déjà levé) ;
            // `.failed`/autre → fichier illisible.
            throw AudioImportError.emptyOrCorruptFile
        }

        // Recalage VBR : si le flux réel est plus court que l'estimation du
        // conteneur (MP3 VBR), étirer les bins remplis sur toute la largeur
        // pour éviter une waveform tronquée à droite.
        if frameIndex > 0, frameIndex < totalFrameEstimate {
            let lastBin = Int(min(
                (frameIndex - 1) * Int64(binCount) / totalFrameEstimate,
                Int64(binCount - 1)
            ))
            if lastBin >= 0, lastBin < binCount - 1 {
                var stretched = [Float](repeating: 0, count: binCount)
                let filledCount = Int64(lastBin + 1)
                for index in 0..<binCount {
                    let source = Int(Int64(index) * filledCount / Int64(binCount))
                    stretched[index] = peaks[min(source, lastBin)]
                }
                peaks = stretched
            }
        }

        // Normalisation d'affichage 0...1 : pics rapportés au pic global du
        // morceau. Silence (pic global nul) → tous les bins restent à 0.
        // Non destructive : rien n'est écrit dans le fichier (§16.2).
        let globalPeak = peaks.max() ?? 0
        if globalPeak > .ulpOfOne {
            for index in peaks.indices {
                peaks[index] = min(peaks[index] / globalPeak, 1)
            }
        }
        return peaks
    }
}
