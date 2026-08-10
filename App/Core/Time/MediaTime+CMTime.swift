//
//  MediaTime+CMTime.swift
//  MontageMusical
//
//  Pont vers CoreMedia (spec §9 : conversion vers CMTime seulement aux
//  frontières AVFoundation) et collage sur la grille d'images (spec §53 :
//  le rendu vidéo utilise l'image la plus proche).
//

#if canImport(CoreMedia)
import CoreMedia

extension MediaTime {

    /// Représentation `CMTime` à l'échelle canonique — **frontière
    /// AVFoundation uniquement**. Conversion exacte, sans perte.
    var cmTime: CMTime {
        CMTime(value: CMTimeValue(ticks), timescale: Self.canonicalTimescale)
    }

    /// Conversion depuis un `CMTime` de timescale quelconque vers le tick
    /// canonique le plus proche (règle constante : au plus proche,
    /// ,5 arrondi supérieur).
    ///
    /// Calcul entier exact : `ticks = round(value × 60000 / timescale)`,
    /// fraction réduite par le PGCD avant multiplication, sans passage par
    /// `Double` (aucune perte de précision intermédiaire). Un `CMTime` de
    /// timescale 60 000 est converti sans aucune perte (round-trip exact).
    ///
    /// Échoue (`nil`) pour un `CMTime` non numérique (invalide, indéfini,
    /// infini) ou dont la conversion déborderait `Int64` — aucun zéro
    /// fabriqué silencieusement (invariants §10.1 « endTicks > startTicks »
    /// et §28.1 « pas de durée nulle » protégés).
    init?(cmTime: CMTime) {
        guard cmTime.isNumeric, cmTime.timescale > 0 else { return nil }
        let canonical = Int64(Self.canonicalTimescale)
        let timescale = Int64(cmTime.timescale)
        let divisor = Self.greatestCommonDivisor(canonical, timescale)
        let factor = canonical / divisor
        let reducedTimescale = timescale / divisor
        let (numerator, overflow) = Int64(cmTime.value).multipliedReportingOverflow(by: factor)
        guard !overflow else { return nil }
        self.init(ticks: Self.roundedDivision(numerator, dividedBy: reducedTimescale))
    }

    /// PGCD d'Euclide (entrées strictement positives).
    private static func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
#endif

extension MediaTime {

    /// Colle cet instant sur la frontière d'image rendue la plus proche
    /// (spec §9 dernière règle, §53).
    ///
    /// La règle d'arrondi est **constante** : multiple de `frameDuration`
    /// le plus proche, ,5 arrondi supérieur. Une même valeur d'entrée produit
    /// donc toujours la même frontière d'image, quel que soit le contexte.
    ///
    /// Exemple : sur une grille 29,97 (`frameDuration` = 2002 ticks),
    /// 3003 ticks (exactement 1,5 image) est collé sur 4004 ticks (image 2).
    ///
    /// - Parameter frameDuration: durée d'une image en ticks (> 0),
    ///   par exemple 2002 ticks pour 29,97 i/s, 1001 ticks pour 59,94 i/s.
    /// - Returns: l'instant aligné sur la grille d'images.
    func nearestFrameBoundary(frameDuration: MediaTime) -> MediaTime {
        precondition(frameDuration.ticks > 0, "La durée d'image doit être strictement positive")
        let frameIndex = Self.roundedDivision(ticks, dividedBy: frameDuration.ticks)
        return MediaTime(ticks: frameIndex * frameDuration.ticks)
    }
}
