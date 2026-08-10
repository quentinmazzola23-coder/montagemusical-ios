//
//  MediaTime.swift
//  MontageMusical
//
//  Temps média canonique de l'application (spécification §9).
//  Fichier source unique du contrat MediaTime — écrit par l'agent Temps.
//

import Foundation

/// Temps média canonique (spec §9).
///
/// `MediaTime` est la **seule vérité temporelle persistée** de l'application.
/// Il représente un instant absolu depuis le début de la musique, ou une durée,
/// exprimé en **ticks entiers** à l'échelle canonique de 60 000 ticks par seconde.
///
/// Règles absolues (spec §9) :
/// - `1 seconde = 60 000 ticks` ;
/// - les timestamps sont **absolus** depuis le début de la musique ;
/// - la durée d'une case est **toujours** calculée par `end - start`,
///   jamais persistée ;
/// - **aucun arrondi cumulatif** : toute accumulation se fait par addition
///   de ticks entiers, jamais par addition de secondes flottantes ;
/// - le centième de seconde est une précision **d'affichage**, jamais une
///   précision de calcul ;
/// - `Double` n'est autorisé qu'aux frontières (import, AVFoundation,
///   affichage), **jamais** comme vérité persistée ;
/// - ne jamais reconstruire une frontière en additionnant des durées
///   affichées.
struct MediaTime: Codable, Hashable, Comparable, Sendable {

    /// Échelle canonique : 60 000 ticks par seconde.
    ///
    /// 60 000 est divisible par 24, 25, 30, 50, 60 et 100, et le tick NTSC
    /// est exact : une image 29,97 (1001/30000 s) vaut exactement 2002 ticks,
    /// une image 59,94 (1001/60000 s) vaut exactement 1001 ticks.
    static let canonicalTimescale: Int32 = 60_000

    /// Nombre de ticks. Seule valeur stockée et persistée (via `Codable`).
    let ticks: Int64

    /// Initialisation exacte à partir de ticks entiers. Aucune perte.
    init(ticks: Int64) {
        self.ticks = ticks
    }

    /// Instant zéro (début de la musique).
    static let zero = MediaTime(ticks: 0)

    /// Conversion depuis des secondes `Double` — **usage frontière uniquement**
    /// (valeur importée d'une API externe, saisie, etc.).
    ///
    /// Arrondit au tick le plus proche, **,5 arrondi supérieur** — même règle
    /// constante que `roundedDivision` (spec §9 dernière règle).
    /// Ne jamais utiliser ce constructeur dans une boucle d'accumulation :
    /// additionner des `MediaTime` en ticks.
    init(seconds: Double) {
        // round-half-up(x) == floor(x + 1/2)
        self.init(ticks: Int64(((seconds * Double(Self.canonicalTimescale)) + 0.5).rounded(.down)))
    }

    /// Valeur dérivée en secondes `Double` — **frontières et affichage
    /// uniquement**. Jamais persistée, jamais réinjectée dans les calculs
    /// de frontières.
    var seconds: Double {
        Double(ticks) / Double(Self.canonicalTimescale)
    }

    // MARK: - Comparable

    /// Comparaison exacte par ticks entiers.
    static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        lhs.ticks < rhs.ticks
    }

    // MARK: - Arithmétique exacte

    /// Addition exacte en ticks (aucun arrondi cumulatif possible).
    static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        MediaTime(ticks: lhs.ticks + rhs.ticks)
    }

    /// Soustraction exacte en ticks. La durée d'une case est `end - start`.
    static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        MediaTime(ticks: lhs.ticks - rhs.ticks)
    }
}

// MARK: - Règle d'arrondi constante (interne)

extension MediaTime {

    /// Division entière arrondie au plus proche, **,5 arrondi supérieur**
    /// (règle d'arrondi constante exigée par la spec §9 dernière règle et §53).
    ///
    /// Utilisée par toutes les conversions (timescales étrangères, grille
    /// d'images, centièmes d'affichage) afin qu'une même valeur soit toujours
    /// arrondie de la même façon.
    ///
    /// - Parameters:
    ///   - numerator: numérateur (peut être négatif).
    ///   - denominator: dénominateur strictement positif.
    /// - Returns: `floor(numerator / denominator + 0.5)` calculé en entiers exacts.
    static func roundedDivision(_ numerator: Int64, dividedBy denominator: Int64) -> Int64 {
        precondition(denominator > 0, "Le dénominateur doit être strictement positif")
        // Division plancher exacte, puis ,5 arrondi supérieur via le reste.
        // Aucune multiplication : aucun débordement possible, quel que soit
        // le couple (numerator, denominator).
        var quotient = numerator / denominator
        var remainder = numerator % denominator
        if remainder < 0 {
            quotient -= 1 // division plancher pour les valeurs négatives
            remainder += denominator
        }
        // fraction >= 1/2 ⟺ 2·remainder >= denominator ⟺ remainder >= denominator − remainder
        if remainder >= denominator - remainder {
            quotient += 1
        }
        return quotient
    }
}
