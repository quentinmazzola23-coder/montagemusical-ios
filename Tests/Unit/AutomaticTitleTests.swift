//
//  AutomaticTitleTests.swift
//  MontageMusicalTests
//
//  Titre automatique de projet — format spec §10 exact :
//  « Projet du 10 août 2026 • 11:24 » (fr_FR, d MMMM yyyy • HH:mm).
//

import XCTest
@testable import MontageMusical

final class AutomaticTitleTests: XCTestCase {

    /// Date fixe construite par `DateComponents` (calendrier grégorien,
    /// fuseau explicite Europe/Paris) — aucun recours à l'horloge ni au
    /// fuseau de la machine de test.
    private func parisDate(
        year: Int, month: Int, day: Int, hour: Int, minute: Int
    ) throws -> (date: Date, timeZone: TimeZone) {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
        return (date, timeZone)
    }

    /// Exemple exact de la spec §10 : 10 août 2026 à 11:24.
    func testSpecExampleAugustTenth2026() throws {
        let (date, timeZone) = try parisDate(
            year: 2026, month: 8, day: 10, hour: 11, minute: 24
        )
        XCTAssertEqual(
            automaticProjectTitle(date: date, timeZone: timeZone),
            "Projet du 10 août 2026 • 11:24"
        )
    }

    /// 1er janvier 2027 à 09:05 — vérifie le jour sans zéro initial (« 1 »,
    /// pas « 01 ») et l'heure/minute avec zéro initial (« 09:05 »).
    func testJanuaryFirstPaddingRules() throws {
        let (date, timeZone) = try parisDate(
            year: 2027, month: 1, day: 1, hour: 9, minute: 5
        )
        XCTAssertEqual(
            automaticProjectTitle(date: date, timeZone: timeZone),
            "Projet du 1 janvier 2027 • 09:05"
        )
    }
}
