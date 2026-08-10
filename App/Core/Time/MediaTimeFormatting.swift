//
//  MediaTimeFormatting.swift
//  MontageMusical
//
//  Affichage au centième de seconde, virgule décimale française (spec §9).
//  L'arrondi au centième est un arrondi d'AFFICHAGE : la valeur affichée
//  n'est jamais réinjectée dans les calculs de frontières.
//

import Foundation

extension MediaTime {

    /// Durée courte « 1,20 s » (§35.2) : secondes et centièmes d'AFFICHAGE
    /// (arrondi au centième le plus proche, virgule française), jamais
    /// réinjectés dans un calcul (§9). Utilisée pour les stats §34
    /// (moyenne/minimum/maximum des cases).
    var shortDurationString: String {
        let centiseconds = max(0, Self.roundedDivision(ticks, dividedBy: 600))
        let seconds = centiseconds / 100
        let fraction = centiseconds % 100
        return "\(seconds),\(fraction < 10 ? "0" : "")\(fraction) s"
    }
}

extension MediaTime {

    /// Chaîne d'affichage au centième de seconde, format français.
    ///
    /// - `"mm:ss,cc"` en dessous d'une heure (exemple spec : 8,431764 s
    ///   → `"00:08,43"`) ;
    /// - `"h:mm:ss,cc"` à partir d'une heure ;
    /// - virgule décimale française garantie par construction manuelle de la
    ///   chaîne (aucune dépendance à `Locale.current`) ;
    /// - arrondi au centième **le plus proche** avec propagation de la
    ///   retenue : 59,995 s et plus s'affichent `"01:00,00"`.
    ///
    /// AVERTISSEMENT : précision d'affichage uniquement. Ne jamais parser
    /// cette chaîne pour reconstruire une frontière (spec §9 : « ne jamais
    /// reconstruire une frontière en additionnant des durées affichées »).
    var displayString: String {
        // 1 centième de seconde = 600 ticks. Arrondi au centième le plus
        // proche avec la règle constante (,5 arrondi supérieur).
        let signedCentiseconds = Self.roundedDivision(ticks, dividedBy: 600)

        // Les temps négatifs n'existent pas dans le produit (timestamps
        // absolus) mais peuvent apparaître transitoirement via `-` ;
        // ils sont affichés avec un préfixe « - ».
        let isNegative = signedCentiseconds < 0
        let totalCentiseconds = isNegative ? -signedCentiseconds : signedCentiseconds

        // Décomposition entière — la retenue est gérée naturellement :
        // 5 999,5 cs arrondi à 6 000 cs = 60 s pile = "01:00,00".
        let centiseconds = totalCentiseconds % 100
        let totalSeconds = totalCentiseconds / 100
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        let sign = isNegative ? "-" : ""
        let core = "\(Self.padded(minutes)):\(Self.padded(seconds)),\(Self.padded(centiseconds))"
        if hours >= 1 {
            return "\(sign)\(hours):\(core)"
        }
        return "\(sign)\(core)"
    }

    /// Remplissage à deux chiffres, construction manuelle (indépendant de
    /// toute locale).
    private static func padded(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
