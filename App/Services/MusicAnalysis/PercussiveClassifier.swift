//
//  PercussiveClassifier.swift
//  MontageMusical
//
//  Classification des onsets en familles percussives.
//
//  POURQUOI
//  --------
//  Le moteur produisait une dramaturgie (sections, phrases, tension,
//  nouveauté, montées, gestes) dont AUCUNE n'a jamais été validée à
//  l'oreille (§74). Le pivot du 16 août 2026 la met de côté : les partitions
//  ne sont plus des interprétations, ce sont des CALAGES. Une partition par
//  famille de frappe, et chaque coupe tombe exactement sur une frappe de
//  cette famille. Ce que le moteur promet devient donc vérifiable en une
//  écoute, ce qui n'était pas le cas de « cette section est une
//  accumulation ».
//
//  CE SUR QUOI REPOSE LA CLASSIFICATION
//  ------------------------------------
//  Rien de neuf n'est calculé : `FeatureTimeline` porte déjà le flux
//  spectral par bande (§17, 5 bandes linéaires 20 / 120 / 500 / 2 000 /
//  8 000 Hz → Nyquist), et `OnsetDetector` a déjà retenu, pour chaque
//  onset, la frame où il culmine. Le profil de flux sur ces 5 bandes à cette
//  frame suffit à séparer les trois familles visées :
//
//  - **kick** — l'énergie d'attaque est concentrée dans le grave. En EDM la
//    bande 0 (20-120 Hz) porte le kick ET la basse, mais la BASSE ne produit
//    pas de flux : elle est tenue, le flux mesure les variations. Un pic de
//    flux dans la bande 0 est donc une attaque de grave, pas une note tenue.
//  - **hat** — l'inverse : tout en haut (bandes 3-4, ≥ 2 kHz), presque rien
//    dans le grave.
//  - **snare** (caisse claire, clap) — LARGE BANDE par nature : du corps
//    dans les médiums (bandes 1-2) et du bruit dans l'aigu, sans la
//    concentration extrême du kick ni celle du charley.
//
//  Les seuils sont des proportions du flux total de la frame, donc
//  insensibles au niveau absolu et au mastering — un master écrasé et un
//  master dynamique donnent les mêmes proportions.
//

import Foundation

/// Famille percussive d'une frappe.
///
/// Trois cas seulement, et volontairement pas de `unknown` : toute frappe
/// doit tomber quelque part, sinon elle disparaîtrait des trois partitions
/// et l'utilisateur perdrait une coupe sans jamais savoir pourquoi. La
/// classe la moins spécifique (`snare`) sert de rattachement par défaut,
/// et c'est un choix assumé — voir `classify`.
enum PercussiveClass: String, Codable, Sendable, CaseIterable {
    /// Grave : grosse caisse, kick distordu.
    case kick
    /// Médium large bande : caisse claire, clap, rimshot.
    case snare
    /// Aigu : charley, shaker, cymbale.
    case hat
}

/// Classification déterministe d'un onset à partir de son profil de flux.
struct PercussiveClassifier: Sendable {

    /// Seuils, en PROPORTION du flux total de la frame — jamais en valeur
    /// absolue, pour rester indépendants du niveau de mastering.
    private enum Threshold {
        /// Part du grave (bande 0) au-delà de laquelle la frappe est un kick.
        /// 0,45 : un kick de hardstyle dépasse largement, une caisse claire
        /// avec du corps reste en dessous.
        static let kickLowShare = 0.45
        /// Part de l'aigu (bandes 3 + 4) au-delà de laquelle la frappe est un
        /// charley, À CONDITION que le grave soit négligeable.
        static let hatHighShare = 0.55
        /// Part maximale de grave tolérée pour un charley. Un charley qui
        /// sonne en même temps qu'un kick n'est pas un charley isolable : la
        /// frappe est alors attribuée au kick, qui est l'événement dominant
        /// à l'oreille.
        static let hatMaximumLowShare = 0.20
        /// Flux total minimal pour que les proportions aient un sens. En
        /// dessous, la frame est du bruit de fond : on ne CLASSE PAS au
        /// hasard, on rattache au défaut.
        static let significantFlux = 1e-6
    }

    init() {}

    /// Classe d'une frappe située à `frame` dans la timeline.
    ///
    /// - Note: hors bornes ou flux négligeable → `.snare`, le rattachement
    ///   par défaut. Aucun onset n'est jamais perdu.
    func classify(frame: Int, features: FeatureTimeline) -> PercussiveClass {
        let bands = features.bandFlux
        guard bands.count == FeatureTimeline.bandCount else { return .snare }

        var perBand = [Double](repeating: 0, count: bands.count)
        var total = 0.0
        for (index, series) in bands.enumerated() {
            guard frame >= 0, frame < series.count else { return .snare }
            let value = max(Double(series[frame]), 0)
            perBand[index] = value
            total += value
        }
        guard total > Threshold.significantFlux else { return .snare }

        let lowShare = perBand[0] / total
        let highShare = (perBand[3] + perBand[4]) / total

        // Ordre d'évaluation : le grave d'abord. Une frappe qui a un fort
        // contenu grave EST perçue comme un kick, même si elle porte aussi
        // du bruit d'aigu — ce qui est le cas de tout kick distordu.
        if lowShare >= Threshold.kickLowShare { return .kick }
        if highShare >= Threshold.hatHighShare, lowShare <= Threshold.hatMaximumLowShare {
            return .hat
        }
        return .snare
    }

    /// Classe chaque onset, en retrouvant sa frame depuis son temps.
    ///
    /// La conversion passe par la SEULE règle du moteur
    /// (`FeatureTimeline.mediaTime(forFrame:frameRate:)`, §9) prise à
    /// l'envers, puis bornée : un onset produit à partir de cette même
    /// timeline retombe toujours sur une frame valide.
    func classify(
        onsets: [OnsetEvent],
        features: FeatureTimeline
    ) -> [(onset: OnsetEvent, percussiveClass: PercussiveClass)] {
        let frameCount = features.rms.count
        guard frameCount > 0, features.frameRate > 0 else {
            return onsets.map { ($0, .snare) }
        }
        return onsets.map { onset in
            let raw = (onset.time.seconds * features.frameRate).rounded()
            let frame = min(max(Int(raw), 0), frameCount - 1)
            return (onset, classify(frame: frame, features: features))
        }
    }
}
