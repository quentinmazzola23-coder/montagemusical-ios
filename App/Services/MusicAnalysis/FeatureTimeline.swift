//
//  FeatureTimeline.swift
//  MontageMusical
//
//  Timeline de caractéristiques bas niveau (Jalon 4, spec §79) — spec §17
//  (caractéristiques), §16.3 (branche courte FFT 1024 / hop 256), §9
//  (temps canonique en ticks MediaTime).
//

import Foundation

// Non defini par la specification — definition minimale V1 (niveau A).
/// Caractéristiques bas niveau par frame de la branche courte (spec §17).
///
/// Toutes les séries ont exactement la même longueur (une valeur par frame,
/// cadence `frameRate`). Les valeurs `rms`, `bandEnergies`, `spectralFlux`
/// et `bandFlux` sont **normalisées relativement au morceau** (spec §17
/// dernier alinéa : médiane/quantiles — un master fort ne doit pas être
/// constamment culminant). Le centroïde reste en Hz absolus.
///
/// `Codable` est ajouté pour le checkpoint de phase (§8, §63, §79
/// « annulable/reprenable au niveau des phases »).
struct FeatureTimeline: Sendable, Codable {

    /// Cadence des frames en frames/s — branche courte :
    /// 22 050 / 256 = 86,1328125 (spec §16.2, §16.3).
    let frameRate: Double

    /// Durée couverte par la timeline, en ticks canoniques (spec §9),
    /// dérivée du nombre d'échantillons PCM réellement consommés (§28.1 —
    /// le nombre de frames surestimerait la durée de 1 à `hopSize`
    /// échantillons).
    let duration: MediaTime

    /// RMS relatif par frame (spec §17).
    let rms: [Float]

    /// Énergie par bande : `[5 bandes §17][frame]` —
    /// 20–120, 120–500, 500–2 000, 2 000–8 000, 8 000–Nyquist Hz.
    let bandEnergies: [[Float]]

    /// Flux spectral global redressé demi-onde (spec §17).
    let spectralFlux: [Float]

    /// Flux spectral par bande (spec §17, §18) — mêmes bandes que
    /// `bandEnergies`.
    let bandFlux: [[Float]]

    /// Centroïde spectral en Hz (spec §17) — non normalisé.
    let spectralCentroid: [Float]
}

extension FeatureTimeline {

    /// Bornes basses des bandes initiales recommandées (spec §17), en Hz.
    /// La borne haute de chaque bande est la borne basse de la suivante ;
    /// la dernière bande monte jusqu'à Nyquist.
    static let bandLowerBoundsHz: [Double] = [20, 120, 500, 2_000, 8_000]

    /// Nombre de bandes (spec §17) : 5.
    static var bandCount: Int { bandLowerBoundsHz.count }

    /// Nombre de frames de la timeline.
    var frameCount: Int { rms.count }

    /// **SEULE** conversion frame → ticks de tout le moteur d'analyse
    /// (règle transverse Jalon 4, spec §9) :
    /// `ticks = round(frameIndex / frameRate × 60 000)`, arrondi ,5
    /// supérieur — la même règle constante que `MediaTime.roundedDivision`.
    ///
    /// Tous les temps dérivés d'un index de frame (onsets, beats, durée)
    /// DOIVENT passer par cette fonction : jamais de conversion locale.
    static func mediaTime(forFrame frameIndex: Int, frameRate: Double) -> MediaTime {
        precondition(frameRate > 0, "frameRate doit être strictement positif")
        return MediaTime(seconds: Double(frameIndex) / frameRate)
    }

    /// Surcharge pour un index de frame FRACTIONNAIRE (phase de peigne,
    /// lag interpolé, beat raffiné) — même règle transverse Jalon 4 :
    /// `ticks = round(frame / frameRate × 60 000)`, arrondi ,5 supérieur
    /// via `MediaTime(seconds:)` (règle constante de `roundedDivision`).
    /// Les fichiers du moteur DOIVENT appeler cette surcharge plutôt que
    /// de dupliquer une formule de conversion locale.
    static func mediaTime(forFrame frame: Double, frameRate: Double) -> MediaTime {
        precondition(frameRate > 0, "frameRate doit être strictement positif")
        return MediaTime(seconds: frame / frameRate)
    }
}
