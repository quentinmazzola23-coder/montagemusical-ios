import XCTest
@testable import MontageMusical

/// Test de fumée du Jalon 0 (spec §75 : « test vide passant »).
final class SmokeTests: XCTestCase {
    func testSmoke() {
        XCTAssertTrue(true)
    }

    func testAppLoggerCategoriesExist() {
        // Vérifie que le module se lie et que les catégories §5/§69A existent.
        XCTAssertEqual(AppLogger.Category.app.rawValue, "app")
        XCTAssertEqual(AppLogger.Category.analysis.rawValue, "analysis")
        XCTAssertEqual(AppLogger.Category.media.rawValue, "media")
        XCTAssertEqual(AppLogger.Category.export.rawValue, "export")
    }
}
