//
//  PCMDecoder.swift
//  MontageMusical
//
//  Décodage PCM en streaming (Jalon 4, spec §79) — spec §16.2 (flux
//  d'analyse mono Float32 22 050 Hz, lecture par blocs), §68 (jamais tout
//  le PCM en mémoire), §62 (erreurs d'import existantes).
//

import AVFoundation
import CoreMedia
import Foundation

/// Décode un fichier audio en blocs PCM mono Float32 rééchantillonnés à la
/// fréquence d'analyse (spec §16.2 : 22 050 Hz pour la première
/// implémentation).
///
/// Le décodage est **en streaming** (spec §68) : seul le bloc courant est en
/// mémoire, `handler` est appelé pour chaque bloc successif, et l'annulation
/// coopérative est vérifiée entre les blocs.
///
/// Piège connu (déjà rencontré dans `WaveformExtractor`) :
/// `AVAssetReaderTrackOutput` REFUSE `AVNumberOfChannelsKey` et
/// `AVSampleRateKey` (exception Objective-C non rattrapable). C'est
/// `AVAssetReaderAudioMixOutput` qui les ACCEPTE — d'où son usage ici pour
/// obtenir directement un flux mono à la fréquence demandée.
struct PCMDecoder: Sendable {

    init() {}

    /// Décode `url` en mono Float32 à `sampleRate` et livre chaque bloc à
    /// `handler` dans l'ordre du flux.
    ///
    /// - Parameters:
    ///   - url: fichier audio local (typiquement `audio/original.<ext>` du
    ///     projet, spec §11).
    ///   - sampleRate: fréquence d'échantillonnage cible en Hz
    ///     (`AnalysisConfiguration.analysisSampleRate`, spec §16.2).
    ///   - handler: reçoit chaque bloc d'échantillons mono. Une erreur levée
    ///     par le handler interrompt proprement la lecture et est propagée.
    /// - Throws: `AudioImportError` (spec §62) ou `CancellationError`.
    func decode(
        url: URL,
        sampleRate: Double,
        handler: ([Float]) throws -> Void
    ) async throws {
        guard sampleRate > 0 else {
            throw AudioImportError.emptyOrCorruptFile
        }

        let asset = AVURLAsset(url: url)

        // Fichier protégé (DRM) → erreur dédiée (§62).
        if let isProtected = try? await asset.load(.hasProtectedContent), isProtected {
            throw AudioImportError.protectedContent
        }

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

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioImportError.emptyOrCorruptFile
        }

        // Sortie PCM Float32 mono rééchantillonnée (§16.2).
        // `AVAssetReaderAudioMixOutput` accepte `AVSampleRateKey` et
        // `AVNumberOfChannelsKey` — contrairement à
        // `AVAssetReaderTrackOutput`. Mono entrelacé = mono contigu.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: [track],
            audioSettings: audioSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioImportError.emptyOrCorruptFile
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioImportError.emptyOrCorruptFile
        }

        // Lecture par blocs successifs (§68) : `blockSamples` est réutilisé
        // entre les blocs, seul le bloc courant est en mémoire.
        var blockSamples: [Float] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            // Annulation coopérative + yield ENTRE les blocs : ne monopolise
            // jamais un thread du pool coopératif pendant tout le décodage.
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
            guard sampleCount > 0 else { continue }

            if blockSamples.count != sampleCount {
                blockSamples = [Float](repeating: 0, count: sampleCount)
            }
            let copiedBytes = sampleCount * MemoryLayout<Float>.size
            let status = blockSamples.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: copiedBytes,
                    destination: destination.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else {
                reader.cancelReading()
                throw AudioImportError.emptyOrCorruptFile
            }

            do {
                try handler(blockSamples)
            } catch {
                reader.cancelReading()
                throw error
            }
        }

        guard reader.status == .completed else {
            // `.cancelled` est impossible ici (l'annulation a déjà levé) ;
            // `.failed`/autre → fichier illisible (§62).
            throw AudioImportError.emptyOrCorruptFile
        }
    }
}
