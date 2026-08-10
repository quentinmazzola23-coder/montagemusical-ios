//
//  AudioPlayerController.swift
//  MontageMusical
//
//  Lecture de la musique importée — Jalon 3.
//  Spec §16.1 : la lecture utilise le fichier ORIGINAL inchangé
//  (`audio/original.<extension>`, §11) ; aucun traitement n'est jamais
//  écrit dans ce fichier.
//
//  Jalon 7 (§35.1 « lecture par toucher sur l'aperçu ») : lecture d'un
//  PASSAGE MUSICAL borné (`playSegment(from:to:)` / `stopSegment()`) —
//  seek exact puis pause automatique à la fin du passage. Le §47.1
//  complet (vidéo + musique) arrive avec la preview du Jalon 9.
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

    /// Fin du passage musical en cours (§35.1) — `nil` en lecture pleine
    /// piste. Comparée en ticks canoniques par l'observateur périodique.
    @ObservationIgnored private var segmentEnd: MediaTime?

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
        // Lecture PLEINE PISTE (waveform de `ProjectView`) : tout passage
        // musical en cours est oublié — jamais de pause automatique
        // inattendue en pleine écoute.
        segmentEnd = nil
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

    // MARK: - Passage musical d'une case (Jalon 7, §35.1)

    /// Lit le PASSAGE MUSICAL d'une case : seek EXACT sur `start`
    /// (tolérance zéro, §53) puis lecture avec pause automatique à `end` —
    /// l'observateur périodique existant (10 Hz) compare la position à
    /// `segmentEnd` en ticks canoniques (§9). Le dépassement maximal est
    /// donc ~100 ms : tolérance d'AFFICHAGE V1, aucune frontière
    /// persistée n'en dépend.
    ///
    /// La lecture ne démarre qu'APRÈS la fin du seek (API asynchrone) :
    /// jamais un instant de l'ancien passage audible. Un second appel ou
    /// `stopSegment()` pendant le seek invalide la lecture en attente
    /// (garde `segmentEnd == end`).
    func playSegment(from start: MediaTime, to end: MediaTime) {
        guard let player else { return }
        guard end.ticks > start.ticks else { return }
        segmentEnd = end
        isPlaying = true
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        // Même pattern que l'observateur périodique : le handler
        // AVFoundation arrive sur une file interne — retour explicite sur
        // la file principale avant de toucher l'état (`assumeIsolated`).
        // `AudioPlayerController` est @MainActor donc implicitement
        // `Sendable` : la capture faible est sûre.
        player.seek(
            to: start.cmTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Passage remplacé/arrêté pendant le seek : ne pas
                    // lancer une lecture périmée.
                    guard self.segmentEnd == end, self.isPlaying else { return }
                    guard finished else {
                        // Seek interrompu par AVFoundation sans nouvelle
                        // commande : resynchroniser l'état affiché — jamais
                        // d'icône pause sans son.
                        self.isPlaying = false
                        self.segmentEnd = nil
                        return
                    }
                    self.player?.play()
                }
            }
        }
    }

    /// Arrête le passage musical en cours (changement de case, sortie
    /// d'écran, second toucher sur l'aperçu). Sans effet destructeur si
    /// aucun passage n'est en cours.
    func stopSegment() {
        segmentEnd = nil
        pause()
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
        segmentEnd = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    // MARK: - Privé

    private func updateProgress(currentTime: CMTime) {
        // Pause automatique à la fin du passage musical (§35.1) —
        // comparaison en ticks canoniques (§9 : `Double`/`CMTime` confinés
        // à la frontière AVFoundation).
        if let segmentEnd,
           let current = MediaTime(cmTime: currentTime),
           current.ticks >= segmentEnd.ticks {
            self.segmentEnd = nil
            pause()
        }
        guard let item = player?.currentItem else { return }
        let duration = item.duration
        // `duration` peut être indéfinie tant que l'item n'est pas prêt.
        guard duration.isNumeric, duration.seconds > 0 else { return }
        progress = min(max(currentTime.seconds / duration.seconds, 0), 1)
    }

    /// Fin de lecture : arrêt et retour au début, sans boucle automatique.
    /// (Couvre aussi un passage musical dont `end` serait la fin du
    /// morceau.)
    private func handlePlaybackEnded() {
        isPlaying = false
        segmentEnd = nil
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        progress = 0
    }
}
