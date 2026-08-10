//
//  BeatActivationModel.swift
//  MontageMusical
//
//  Protocole du modèle d'activation beats/downbeats — spec §19.2 (verbatim)
//  et §29A (« BeatDownbeatModel »).
//
//  ⛔ JALON 11 — NON TERMINÉ (§29A « Interdiction »).
//  Ce fichier ne contient QUE le contrat : aucun modèle, aucun poids, aucune
//  règle heuristique déguisée en modèle. Tant qu'aucun modèle entraîné dont
//  la licence et les données sont validées n'est embarqué, AUCUN type de ce
//  fichier n'a d'implémentation de production (voir `CoreMLModelRegistry`,
//  qui renvoie toujours `nil` aujourd'hui, et `HybridMusicAnalyzer`, qui
//  délègue intégralement au moteur déterministe).
//
//  Frontière §19.2 : « Le post-traitement doit rester séparé du modèle afin
//  de pouvoir comparer plusieurs décodeurs. » Le modèle produit donc UNIQUEMENT
//  des probabilités par frame. Le peak picking, l'estimation de phase, la
//  programmation dynamique et la conversion frames → `MediaTime` restent hors
//  de ce protocole (ils appartiennent au décodeur, cf. §19.1.5 côté
//  déterministe).
//

import Foundation

// MARK: - Protocole (spec §19.2, verbatim)

protocol BeatActivationModel: Sendable {
    func predict(features: ModelInputFeatures) async throws -> BeatActivations
}

// MARK: - Entrée du modèle

// Non defini par la specification — definition minimale V1.
/// Entrée du modèle (§29A « BeatDownbeatModel » : « entrée : log-spectrogramme
/// ou Mel-spectrogramme »), décrite en frames afin qu'un adaptateur Core ML
/// puisse la convertir sans ambiguïté (aplatissement row-major
/// `[frame][bin]` → `MLMultiArray`) le jour où un modèle existe.
///
/// Aucune valeur par défaut de `frameRate`/`sampleRate` n'est fournie : ces
/// deux grandeurs dépendent de `AnalysisConfiguration` (§16.2, §16.3) et
/// doivent être transmises telles qu'elles ont réellement servi au calcul du
/// spectrogramme — le décodeur en a besoin pour reconvertir les frames en
/// temps absolu (§9).
struct ModelInputFeatures: Sendable, Equatable {

    /// Représentation spectrale fournie (§29A : log-spectrogramme OU
    /// Mel-spectrogramme). Le modèle entraîné impose laquelle ; le champ
    /// existe pour qu'un décalage entre l'entraînement et l'inférence soit
    /// détectable au lieu d'être silencieux.
    enum Representation: String, Sendable, Codable {
        case logSpectrogram
        case melSpectrogram
    }

    /// Nature des valeurs de `frames`.
    let representation: Representation

    /// Spectrogramme par frames : `frames[t][bin]`, toutes les frames ayant
    /// le même nombre de bins (`binCount`). Vide = aucune frame analysable.
    let frames: [[Float]]

    /// Frames par seconde (= `sampleRate / hopSize` de la branche utilisée,
    /// §16.3). Nécessaire au post-traitement pour repasser en temps absolu.
    let frameRate: Double

    /// Fréquence d'échantillonnage du flux d'analyse en Hz (§16.2 : 22 050 Hz
    /// pour la première implémentation).
    let sampleRate: Int

    init(
        representation: Representation,
        frames: [[Float]],
        frameRate: Double,
        sampleRate: Int
    ) {
        self.representation = representation
        self.frames = frames
        self.frameRate = frameRate
        self.sampleRate = sampleRate
    }

    /// Nombre de frames temporelles.
    var frameCount: Int { frames.count }

    /// Nombre de bins fréquentiels par frame (0 si aucune frame).
    var binCount: Int { frames.first?.count ?? 0 }

    /// Vrai si toutes les frames ont le même nombre de bins et que les
    /// cadences sont strictement positives — un adaptateur Core ML doit
    /// refuser une entrée non rectangulaire plutôt que de la tronquer.
    var isWellFormed: Bool {
        guard frameRate > 0, sampleRate > 0, !frames.isEmpty else { return false }
        let bins = binCount
        return bins > 0 && frames.allSatisfy { $0.count == bins }
    }
}

// MARK: - Sortie du modèle

// Non defini par la specification — definition minimale V1.
/// Sortie du modèle (§19.2 : « probabilités par frame pour : beat ;
/// downbeat ; éventuellement position métrique »).
///
/// Ce type ne porte AUCUN beat décodé : pas de `MediaTime`, pas de tempo, pas
/// de mesure. La conversion activations → `[BeatEvent]`/`[BarEvent]` est le
/// travail du décodeur, volontairement hors modèle (§19.2).
struct BeatActivations: Sendable, Equatable {

    /// Probabilité de beat par frame, dans `0...1`, indexée comme
    /// `ModelInputFeatures.frames`.
    let beat: [Float]

    /// Probabilité de downbeat par frame, même indexation que `beat`.
    let downbeat: [Float]

    /// Position métrique par frame — OPTIONNELLE (§19.2 : « éventuellement
    /// position métrique »). Quand elle existe :
    /// `metricalPosition[t][p]` = probabilité que la frame `t` occupe la
    /// position `p` du cycle métrique. `nil` = le modèle ne la produit pas ;
    /// jamais un tableau rempli de valeurs arbitraires pour « faire comme si ».
    let metricalPosition: [[Float]]?

    /// Frames par seconde des activations (identique à
    /// `ModelInputFeatures.frameRate` sauf si le modèle sous-échantillonne
    /// temporellement — auquel cas c'est CETTE valeur qui fait foi pour le
    /// décodeur).
    let frameRate: Double

    init(
        beat: [Float],
        downbeat: [Float],
        metricalPosition: [[Float]]? = nil,
        frameRate: Double
    ) {
        self.beat = beat
        self.downbeat = downbeat
        self.metricalPosition = metricalPosition
        self.frameRate = frameRate
    }

    /// Nombre de frames d'activation.
    var frameCount: Int { beat.count }

    /// Vrai si les vecteurs de sortie sont cohérents entre eux : même
    /// longueur, cadence positive. Un décodeur doit le vérifier avant
    /// d'interpréter des probabilités (§0.7 : jamais de contenu inventé à
    /// partir d'une sortie incohérente).
    var isWellFormed: Bool {
        guard frameRate > 0, !beat.isEmpty, downbeat.count == beat.count else { return false }
        if let metricalPosition {
            guard metricalPosition.count == beat.count else { return false }
        }
        return true
    }
}
