//
//  AutomaticTitle.swift
//  MontageMusical
//
//  Titre automatique de projet — format spec §10.
//

import Foundation

/// Titre automatique d'un projet (spec §10) :
///
/// ```text
/// Projet du 10 août 2026 • 11:24
/// ```
///
/// Déterministe : locale `fr_FR` et calendrier grégorien explicites, jamais
/// `Locale.current` (la langue initiale de l'application est le français,
/// spec préambule). Formats fixes `d MMMM yyyy` (jour sans zéro initial)
/// et `HH:mm` (heure sur deux chiffres).
///
/// - Parameters:
///   - date: instant de création du projet.
///   - timeZone: fuseau utilisé pour le rendu ; par défaut celui de
///     l'appareil (le titre reflète l'heure locale de création).
///     // Non defini par la specification — definition minimale V1 :
///     paramètre d'injection pour des tests déterministes.
func automaticProjectTitle(date: Date, timeZone: TimeZone = .current) -> String {
    let locale = Locale(identifier: "fr_FR")
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    calendar.timeZone = timeZone

    let dayFormatter = DateFormatter()
    dayFormatter.locale = locale
    dayFormatter.calendar = calendar
    dayFormatter.timeZone = timeZone
    dayFormatter.dateFormat = "d MMMM yyyy"

    let timeFormatter = DateFormatter()
    timeFormatter.locale = locale
    timeFormatter.calendar = calendar
    timeFormatter.timeZone = timeZone
    timeFormatter.dateFormat = "HH:mm"

    return "Projet du \(dayFormatter.string(from: date)) • \(timeFormatter.string(from: date))"
}
