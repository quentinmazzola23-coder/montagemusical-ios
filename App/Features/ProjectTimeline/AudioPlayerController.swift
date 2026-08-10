//
//  AudioPlayerController.swift
//  MontageMusical
//
//  Lecture de la musique importée — Jalon 3.
//  Spec §16.1 : la lecture utilise le fichier ORIGINAL inchangé
//  (`audio/original.<extension>`, §11) ; aucun traitement n'est jamais
//  écrit dans ce fichier.
//

import AVFoundation
import Foundation
import Observation

/// Contrôleur de lecture audio pour la vue projet.
///
/// - `@MainActor` : tout l'état observé (`isPlaying`, `progress`) est lu par
///   SwiftUI ; les callbacks AVFoundation sont ramenés sur le main actor
///   (files `.main` + `MainActor.assumeIsolated`).
/// - `progress` est une valeur d'AFFICHAGE `0...1` (position de la barre de
///   lecture) : le passage par `Double`/secondes reste confiné à la frontière
///   AVFoundation (§9) — rien n'est persisté.
/// - `invalidate()` DOIT être appelé à la disparition de la vue
///   (`.onDisappear`) : il retire l'observateur périodique et l'observateur
///   de fin de lecture.
@MainActor
@Observable
final class AudioPlayerController {

    /// Vrai pendant la lecture — pilote le libellé Lecture/Pause du dock.
    private(set) var isPlaying = false

    /// Position de lecture `0...1` (affichage uniquement, jamais persistée).
    private(set) var progress: Double = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?

    init() {}

    // MARK: - Chargement

    /// Charge un `AVPlayer` sur l'URL LOCALE du fichier original (§16.1).
    /// Un chargement précédent est d'abord invalidé proprement.
    func load(url: URL) {
        invalidate()

        #if os(iOS)
        // Catégorie lecture : la musique reste audible même avec
        // l'interrupteur silencieux — comportement attendu d'une application
        // de montage musical. Non defini par la specification — choix
        // minimal V1.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        #endif

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // Aucune modification du fichier : lecture pure (§16.1).
        self.player = player

        // Observation périodique (10 Hz) : suffisant pour une barre de
        // position fluide sans surcharger le rendu Canvas (§67).
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            // File `.main` garantie par `queue: .main`.
            MainActor.assumeIsolated {
                self?.updateProgress(currentTime: time)
            }
        }

        // Fin de lecture : retour sobre au début, à l'arrêt.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePlaybackEnded()
            }
        }
    }

    // MARK: - Transport

    func play() {
        guard let player else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Bascule lecture/pause — action du dock et du toucher sur la waveform.
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Déplace la lecture à une position relative `0...1` (tolérance zéro :
    /// position exacte demandée, §53 esprit « exactitude temporelle »).
    func seek(to progress: Double) {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration
        guard duration.isNumeric, duration.seconds > 0 else { return }
        let clamped = min(max(progress, 0), 1)
        let target = CMTime(
            seconds: duration.seconds * clamped,
            preferredTimescale: MediaTime.canonicalTimescale
        )
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        self.progress = clamped
    }

    // MARK: - Nettoyage

    /// Retire les observateurs et libère le lecteur. À appeler à la
    /// disparition de la vue (`.onDisappear`) — un observateur périodique
    /// non retiré est une fuite AVFoundation documentée.
    func invalidate() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        progress = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    // MARK: - Privé

    private func updateProgress(currentTime: CMTime) {
        guard let item = player?.currentItem else { return }
        let duration = item.duration
        // `duration` peut être indéfinie tant que l'item n'est pas prêt.
        guard duration.isNumeric, duration.seconds > 0 else { return }
        progress = min(max(currentTime.seconds / duration.seconds, 0), 1)
    }

    /// Fin de lecture : arrêt et retour au début, sans boucle automatique.
    private func handlePlaybackEnded() {
        isPlaying = false
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        progress = 0
    }
}
