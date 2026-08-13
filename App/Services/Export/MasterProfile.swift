//
//  MasterProfile.swift
//  MontageMusical
//
//  Sélection du profil maître d'export — spec §52 (§52.1 géométrie,
//  §52.2 clip maître technique, §52.3 cadences élevées, §52.4 colorimétrie).
//
//  Type PUR : aucune dépendance PhotoKit, aucune E/S, aucun asset réel — il
//  ne reçoit que des caractéristiques DÉJÀ mesurées (`MasterClipInfo`), ce
//  qui rend §52 testable sans média (§70 « Profil maître »).
//
//  Non defini par la specification — definition minimale V1 (la spécification
//  décrit le classement, pas les types qui le portent).
//

import CoreGraphics
import CoreMedia
import Foundation

// MARK: - Caractéristiques d'un rush exporté (§52)

/// Caractéristiques techniques d'UN rush du montage exporté (§52 : « Analyser
/// seulement les rushs du préfixe exporté » — le préfixe §51 a été remplacé par
/// la TIMELINE CONCATÉNÉE des zones remplies, la règle vaut donc pour les rushs
/// de CETTE timeline : les cases non exportées n'entrent jamais dans le
/// classement).
///
/// Toutes les valeurs sont MESURÉES sur la piste vidéo réelle (jamais des
/// métadonnées PhotoKit) et déjà ORIENTÉES (`preferredTransform` appliqué,
/// §49 étape 2) : le classement §52.2 porte sur ce que l'utilisateur voit,
/// pas sur l'orientation du capteur.
struct MasterClipInfo: Sendable, Equatable {

    /// Identifiant local PhotoKit du rush (traçabilité du clip maître).
    let assetLocalIdentifier: String

    /// Largeur ORIENTÉE (`preferredTransform` appliqué).
    let orientedWidth: Int

    /// Hauteur ORIENTÉE (`preferredTransform` appliqué).
    let orientedHeight: Int

    /// Cadence de **lecture** (§52.3 : « respecter la cadence de lecture,
    /// pas seulement la cadence de capture ralentie »).
    let nominalFrameRate: Double

    /// Capacité HDR du rush (§52.4).
    let isHDR: Bool

    /// Ordre d'apparition dans le montage exporté (runs concaténés) —
    /// départage les égalités parfaites (§52.2 point 4).
    let appearanceOrder: Int
}

// MARK: - Profil maître (§52)

/// Profil de rendu de l'export : géométrie du PROJET (§52.1) dimensionnée
/// sur le clip maître, cadence du MÊME clip maître (§52.2/§52.3) et
/// colorimétrie de sortie (§52.4).
///
/// **Résolution et cadence viennent toujours du même clip** (§52.2 : « Ne pas
/// inventer du 4K60 à partir d'un clip 4K30 et d'un autre 1080p60 ») : c'est
/// `MasterProfileSelector` qui choisit CE clip, et ce type ne fait que porter
/// le résultat.
///
/// `Codable` : le profil voyage dans `ExportResult` (contrat d'interface —
/// c'est le profil RÉELLEMENT encodé, celui que le résumé §56 doit refléter),
/// et `ExportResult` est `Codable`. La synthèse porte sur les propriétés
/// stockées, jamais sur l'initialiseur normalisant ci-dessous : un profil
/// décodé reste donc exactement celui qui a été encodé.
struct MasterProfile: Codable, Sendable, Equatable {

    /// Largeur de rendu — PAIRE (§55 : les encodeurs H.264/HEVC 4:2:0
    /// exigent des dimensions paires).
    let renderWidth: Int

    /// Hauteur de rendu — PAIRE (§55).
    let renderHeight: Int

    /// Numérateur de la durée d'image, à l'échelle `frameDurationTimescale`.
    ///
    /// La cadence est portée par une FRACTION EXACTE (et non par un `Double`)
    /// pour que 29,97 et 59,94 restent 30000/1001 et 60000/1001 (§52.3 :
    /// « préserver 29,97/59,94 ») — un arrondi à 30 ou 60 dériverait d'une
    /// image toutes les 33 secondes sur un montage long.
    let frameDurationValue: Int32

    /// Dénominateur (timescale) de la durée d'image.
    let frameDurationTimescale: Int32

    /// Cadence de rendu en images par seconde, PLAFONNÉE à 60 (§52.3).
    /// Valeur dérivée de la fraction exacte ci-dessus — jamais saisie à part.
    let frameRate: Double

    /// Sortie HDR (§52.4) : vrai seulement si TOUS les rushs exportés (toutes
    /// zones confondues) sont HDR ; un mélange HDR/SDR impose une sortie SDR
    /// cohérente.
    let isHDR: Bool

    /// Durée d'une image, à poser telle quelle sur
    /// `AVMutableVideoComposition.frameDuration` (frontière §9).
    var frameDuration: CMTime {
        CMTime(value: CMTimeValue(frameDurationValue), timescale: frameDurationTimescale)
    }

    /// Taille de rendu, à poser telle quelle sur
    /// `AVMutableVideoComposition.renderSize`.
    var renderSize: CGSize {
        CGSize(width: renderWidth, height: renderHeight)
    }

    /// Nombre de pixels rendus par image — base de l'estimation de taille §57.
    var pixelCount: Int { renderWidth * renderHeight }

    /// Construit un profil à partir d'une cadence BRUTE : la cadence est
    /// normalisée (plafond 60 §52.3, fractions NTSC préservées) et les
    /// dimensions sont forcées paires (§55).
    ///
    /// C'est le SEUL initialiseur : `frameRate` ne peut donc jamais
    /// contredire `frameDuration`.
    init(renderWidth: Int, renderHeight: Int, frameRate nominalFrameRate: Double, isHDR: Bool) {
        let cadence = Self.normalizedCadence(nominalFrameRate: nominalFrameRate)
        self.renderWidth = Self.evenDimension(renderWidth)
        self.renderHeight = Self.evenDimension(renderHeight)
        self.frameDurationValue = cadence.value
        self.frameDurationTimescale = cadence.timescale
        self.frameRate = Double(cadence.timescale) / Double(cadence.value)
        self.isHDR = isHDR
    }
}

// MARK: - Cadences (§52.3)

extension MasterProfile {

    /// Plafond V1 : 60 i/s (§52.3 : « ne pas exporter à 120/240 i/s », « ne
    /// pas appliquer de flux optique »).
    static let maximumFrameRate: Double = 60

    /// Cadence de repli si la piste ne déclare aucune cadence exploitable
    /// (0, NaN, négative) : 30 i/s. Cas jamais attendu — une piste vidéo
    /// lisible déclare sa cadence. Non defini par la specification —
    /// choix minimal V1.
    static let fallbackFrameRate: Int32 = 30

    /// Plancher de cadence CRÉDIBLE : 1 image par seconde.
    ///
    /// Garde-fou de piste corrompue : une cadence minuscule (0,000001 i/s)
    /// donnerait une durée d'image de 60 000 000 000 ticks — très au-delà
    /// d'`Int32`, donc un PIÈGE à `Int32(_:)` (crash arithmétique en
    /// production).
    /// Sous 1 i/s aucune cadence n'est exploitable pour un montage : la
    /// valeur est ramenée au plancher, et la conversion est bornée en plus
    /// (ceinture et bretelles). Non defini par la specification — choix
    /// minimal V1.
    static let minimumFrameRate: Double = 1

    /// Tolérance absolue de reconnaissance d'une cadence ENTIÈRE.
    /// 29,97 s'écarte de 30 de 0,03 : la tolérance doit rester bien en
    /// dessous, sans quoi une cadence NTSC serait arrondie (§52.3 l'interdit).
    private static let integerRateTolerance: Double = 0.005

    /// Tolérance de reconnaissance de la famille NTSC (`n × 1000/1001`).
    private static let ntscRateTolerance: Double = 0.01

    /// Normalise une cadence de lecture en fraction EXACTE (§52.3) :
    ///
    /// 1. cadence entière (24, 25, 30, 50, 60…) → `1 / n` ;
    /// 2. cadence NTSC fractionnaire (23,976 / 29,97 / 59,94 = `n × 1000/1001`)
    ///    → `1001 / (1000 × n)` — la fraction est PRÉSERVÉE, jamais arrondie
    ///    à l'entier voisin ;
    /// 3. plafond 60 (§52.3) : une cadence supérieure est ramenée à 60, en
    ///    CONSERVANT la famille — 120 → 60, 119,88 → 59,94 ;
    /// 4. cadence exotique (25,5…) → fraction sur l'échelle canonique 60 000
    ///    (§9), plafonnée en haut (60 i/s) ET en bas (`minimumFrameRate`) :
    ///    une piste corrompue annonçant 0,001 i/s ne produit jamais une durée
    ///    d'image hors `Int32`.
    ///
    /// - Returns: `value/timescale` = durée d'UNE image.
    static func normalizedCadence(nominalFrameRate: Double) -> (value: Int32, timescale: Int32) {
        guard nominalFrameRate.isFinite, nominalFrameRate > 0 else {
            return (1, fallbackFrameRate) // piste sans cadence exploitable
        }

        // 1. Cadence entière.
        let rounded = nominalFrameRate.rounded()
        if abs(nominalFrameRate - rounded) <= integerRateTolerance, rounded >= 1 {
            let capped = min(rounded, maximumFrameRate) // §52.3 : 120/240 → 60
            return (1, Int32(capped))
        }

        // 2. Famille NTSC : `rate = base × 1000/1001`.
        let ntscBase = (nominalFrameRate * 1001.0 / 1000.0).rounded()
        if abs(nominalFrameRate * 1001.0 / 1000.0 - ntscBase) <= ntscRateTolerance, ntscBase >= 1 {
            // §52.3 : 119,88 est plafonné à 59,94 — la famille fractionnaire
            // du clip maître est conservée, jamais convertie en 60 rond.
            let cappedBase = min(ntscBase, maximumFrameRate)
            return (1001, Int32(1000 * cappedBase))
        }

        // 3. Cadence exotique : fraction sur l'échelle canonique §9.
        // La cadence est BORNÉE des deux côtés avant division : plafond §52.3
        // en haut, `minimumFrameRate` en bas (piste corrompue). La valeur
        // finale est en plus écrêtée à `Int32.max` — aucune conversion
        // `Int32(_:)` ne peut déborder.
        let canonical = Double(MediaTime.canonicalTimescale)
        let boundedRate = min(max(nominalFrameRate, minimumFrameRate), maximumFrameRate)
        let value = max(canonical / maximumFrameRate, (canonical / boundedRate).rounded())
        return (Int32(min(value, Double(Int32.max))), MediaTime.canonicalTimescale)
    }

    /// Cadence NORMALISÉE (plafonnée §52.3) d'une cadence brute — critère 2
    /// du classement §52.2. Deux clips 120 i/s et 60 i/s sont donc à
    /// ÉGALITÉ de cadence : le plafond s'applique avant le classement.
    static func cappedFrameRate(_ nominalFrameRate: Double) -> Double {
        let cadence = normalizedCadence(nominalFrameRate: nominalFrameRate)
        return Double(cadence.timescale) / Double(cadence.value)
    }

    /// Arrondi au multiple de 2 le plus proche, minimum 2 (§55).
    /// Même règle que `GeometryLock.evenDimension` (privée là-bas) — les
    /// dimensions arrivent déjà paires de `GeometryLock.renderSize` ; cette
    /// garde protège les constructions directes (tests, futurs appelants).
    private static func evenDimension(_ value: Int) -> Int {
        guard value > 0 else { return 2 }
        return max(2, Int((Double(value) / 2).rounded()) * 2)
    }
}

// MARK: - Sélection du clip maître (§52.2)

/// Choix du profil maître d'export (§52).
///
/// Entrée : les rushs RÉELLEMENT exportés uniquement — c'est-à-dire ceux de la
/// TIMELINE concaténée des zones remplies, dans l'ordre du montage (§52 :
/// « Analyser seulement les rushs du préfixe exporté », lu après le
/// remplacement du préfixe §51) — et la géométrie VERROUILLÉE du projet
/// (§14, §49).
enum MasterProfileSelector {

    /// Tolérance RELATIVE de compatibilité de rapport (§52.2 : « les clips
    /// dont le rapport est compatible avec la géométrie »).
    ///
    /// 0,5 % absorbe l'arrondi des dimensions orientées (une rotation exacte
    /// peut produire 1080,0000000000001) sans jamais confondre deux cadrages
    /// réellement différents : 16:9 (1,778) et 4:3 (1,333) restent
    /// incompatibles, 1920×1080 et 1918×1080 restent compatibles.
    static let aspectTolerance: Double = 0.005

    /// **Sortie HDR — désactivée en V1 (§52.4, §55).**
    ///
    /// §52.4 autorise une sortie HDR quand « tous les rushs [sont]
    /// compatibles HDR », mais §55 impose de passer par
    /// `AVAssetExportSession` et ses PRESETS : aucun preset ne GARANTIT le
    /// transfert HLG/PQ ni le 10 bits en sortie — il n'existe aucun réglage
    /// public de fonction de transfert sur une session à preset, et rien ici
    /// n'a pu être vérifié sur matériel HDR réel (projet généré sous
    /// Windows).
    ///
    /// Annoncer « HDR » dans le résumé §56 sans pouvoir le garantir serait
    /// exactement le « comportement implicite non testé » que §52.4 interdit.
    /// V1 rend donc TOUJOURS en SDR Rec.709 avec le tone mapping EXPLICITE
    /// déjà implémenté (`ProjectExporter.makeVideoComposition` renseigne les
    /// trois propriétés colorimétriques) : un montage entièrement HDR reçoit
    /// le même traitement qu'un mélange HDR/SDR — « sortie SDR cohérente ».
    ///
    /// Le classement §52.2 continue d'utiliser la capacité HDR des rushs
    /// (critère 3) : seule la SORTIE est contrainte. Le jour où l'export
    /// passera à `AVAssetReader`/`AVAssetWriter` (§55 : « prévoir une V2
    /// export […] sauf blocage constaté » — le blocage est constaté ici),
    /// basculer cette constante suffira.
    static let allowsHDROutput = false

    /// Profil maître du montage exporté (§52), ou `nil` si aucun clip n'est
    /// fourni (timeline vide → export désactivé §66 : il n'y a rien à
    /// profiler).
    ///
    /// - §52.1 : la géométrie est TOUJOURS celle du projet — le clip maître
    ///   ne fait que DIMENSIONNER ce rapport (`GeometryLock.renderSize`) ;
    /// - §52.2 : résolution ET cadence proviennent du MÊME clip maître ;
    /// - §52.4 : la sortie est SDR en V1 (`allowsHDROutput`), même quand tous
    ///   les rushs sont HDR.
    static func selectMaster(clips: [MasterClipInfo], geometry: ProjectGeometry) -> MasterProfile? {
        guard let master = selectMasterClip(clips: clips, geometry: geometry) else { return nil }

        // §52.1 : rapport du PROJET, dimensionné sur le clip maître.
        let renderSize = GeometryLock.renderSize(
            for: geometry,
            masterWidth: master.orientedWidth,
            masterHeight: master.orientedHeight
        )

        // §52.4 : le HDR se décide sur TOUT le montage exporté, pas sur le
        // seul clip maître — un unique rush SDR, dans n'importe quelle zone,
        // imposerait déjà une sortie SDR. En V1
        // la condition est de toute façon écrasée par `allowsHDROutput`
        // (voir la constante) : la sortie est SDR, tone mapping explicite.
        let isEveryClipHDR = !clips.isEmpty && clips.allSatisfy(\.isHDR)

        return MasterProfile(
            renderWidth: Int(renderSize.width.rounded()),
            renderHeight: Int(renderSize.height.rounded()),
            // §52.2 : la cadence vient du MÊME clip que la résolution.
            frameRate: master.nominalFrameRate,
            isHDR: allowsHDROutput && isEveryClipHDR
        )
    }

    /// Clip maître retenu (§52.2), ou `nil` si la liste est vide.
    ///
    /// Exposé séparément de `selectMaster` : le résumé avant export (§56) et
    /// les tests §70 ont besoin de savoir QUEL rush a été retenu, information
    /// que le profil (dimensions + cadence) ne porte plus une fois calculé.
    ///
    /// Deux étapes, dans l'ordre de la spécification :
    /// 1. **filtre de rapport** — « Parmi les clips dont le rapport est
    ///    compatible avec la géométrie » ; si AUCUN clip n'est compatible,
    ///    §52.2 impose de « utiliser le clip de plus haute résolution et
    ///    rendre dans la géométrie verrouillée » : le classement s'applique
    ///    alors à TOUS les clips ;
    /// 2. **classement lexicographique** §52.2 : pixels orientés, cadence de
    ///    lecture plafonnée à 60, HDR, ordre d'apparition.
    static func selectMasterClip(clips: [MasterClipInfo], geometry: ProjectGeometry) -> MasterClipInfo? {
        guard !clips.isEmpty else { return nil } // §66 : aucune zone remplie

        let compatible = clips.filter { isAspectCompatible($0, geometry: geometry) }
        let candidates = compatible.isEmpty ? clips : compatible

        // `min(by:)` avec l'ordre §52.2 : le premier des ex æquo est conservé,
        // mais le critère 4 (ordre d'apparition) rend déjà le résultat
        // indépendant de l'ordre du tableau.
        return candidates.min(by: isRankedBefore)
    }

    /// Classement lexicographique §52.2 — `true` si `lhs` prime sur `rhs` :
    /// 1. nombre de pixels ORIENTÉS (décroissant) ;
    /// 2. cadence de lecture PLAFONNÉE à 60 (décroissante, §52.3) ;
    /// 3. capacité HDR (HDR avant SDR) ;
    /// 4. ordre d'apparition (croissant) — départage total, donc résultat
    ///    déterministe.
    static func isRankedBefore(_ lhs: MasterClipInfo, _ rhs: MasterClipInfo) -> Bool {
        let leftPixels = lhs.orientedWidth * lhs.orientedHeight
        let rightPixels = rhs.orientedWidth * rhs.orientedHeight
        if leftPixels != rightPixels { return leftPixels > rightPixels }

        let leftRate = MasterProfile.cappedFrameRate(lhs.nominalFrameRate)
        let rightRate = MasterProfile.cappedFrameRate(rhs.nominalFrameRate)
        // Comparaison à tolérance : 59,94005994 et 59,94005994 issues de deux
        // mesures flottantes différentes doivent rester ÉGALES.
        if abs(leftRate - rightRate) > 1e-6 { return leftRate > rightRate }

        if lhs.isHDR != rhs.isHDR { return lhs.isHDR }

        return lhs.appearanceOrder < rhs.appearanceOrder
    }

    /// Compatibilité de rapport entre un clip ORIENTÉ et la géométrie
    /// verrouillée du projet (§52.2, premier filtre).
    ///
    /// Un clip dégénéré (dimension nulle) n'est jamais « compatible » : il
    /// ne peut pas dimensionner le rendu.
    static func isAspectCompatible(_ clip: MasterClipInfo, geometry: ProjectGeometry) -> Bool {
        guard clip.orientedWidth > 0, clip.orientedHeight > 0,
              geometry.aspectWidth > 0, geometry.aspectHeight > 0 else {
            return false
        }
        let clipRatio = Double(clip.orientedWidth) / Double(clip.orientedHeight)
        let projectRatio = Double(geometry.aspectWidth) / Double(geometry.aspectHeight)
        return abs(clipRatio - projectRatio) <= projectRatio * aspectTolerance
    }
}
