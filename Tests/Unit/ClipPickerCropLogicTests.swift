//
//  ClipPickerCropLogicTests.swift
//  MontageMusicalTests
//
//  Logique PURE de la grille photothèque face à la géométrie verrouillée
//  (Jalon 9) :
//  - badge « recadrage potentiel » §42 : comparaison de FORMES
//    (`max/min`), donc INDÉPENDANTE de l'orientation — les métadonnées
//    PhotoKit `pixelWidth/pixelHeight` sont les dimensions ENCODÉES (un rush
//    portrait iPhone est annoncé 1920×1080) alors que la géométrie §14 porte
//    un rapport ORIENTÉ ;
//  - aperçu du crop réel §50 : cadre de rendu au rapport du projet, inscrit
//    dans la cellule carrée.
//
//  Aucun PhotoKit, aucun AVFoundation : tout est calcul pur.
//

import XCTest
import CoreGraphics
@testable import MontageMusical

final class ClipPickerCropLogicTests: XCTestCase {

    private let portraitProject = ProjectGeometry(
        aspectWidth: 9,
        aspectHeight: 16,
        orientation: .portrait,
        lockedByAssetIdentifier: "asset-portrait"
    )

    private let landscapeProject = ProjectGeometry(
        aspectWidth: 16,
        aspectHeight: 9,
        orientation: .landscape,
        lockedByAssetIdentifier: "asset-paysage"
    )

    private let squareProject = ProjectGeometry(
        aspectWidth: 1,
        aspectHeight: 1,
        orientation: .square,
        lockedByAssetIdentifier: "asset-carre"
    )

    // MARK: - §42 Badge « recadrage potentiel »

    func testNoGeometryNeverBadges() {
        // §49 : aucune case remplie → rien à comparer, aucun badge.
        XCTAssertFalse(
            ClipPickerCropLogic.requiresCrop(
                assetPixelWidth: 1440,
                assetPixelHeight: 1080,
                geometry: nil
            )
        )
    }

    func testEncodedLandscapeMetadataDoesNotBadgeInPortraitProject() {
        // RÉGRESSION corrigée au Jalon 9 : `PHAsset.pixelWidth/pixelHeight`
        // ne sont PAS orientés — un rush filmé en portrait est annoncé
        // 1920×1080. Comparé au rapport orienté 9:16 du projet, TOUT rush
        // était marqué « recadrage », y compris ceux du même cadrage.
        XCTAssertFalse(
            ClipPickerCropLogic.requiresCrop(
                assetPixelWidth: 1920,
                assetPixelHeight: 1080,
                geometry: portraitProject
            ),
            "Même forme (16/9 = 9/16 en forme) : aucun badge dans un projet 9:16"
        )
        XCTAssertFalse(
            ClipPickerCropLogic.requiresCrop(
                assetPixelWidth: 1080,
                assetPixelHeight: 1920,
                geometry: portraitProject
            ),
            "Métadonnée déjà portrait : aucun badge non plus"
        )
    }

    func testSameShapeAtEveryResolutionDoesNotBadge() {
        // 4K, 1080p et une largeur d'arrondi : même forme 16:9 → aucun badge
        // (tolérance relative de 1 %).
        for (width, height) in [(3840, 2160), (1920, 1080), (1918, 1080)] {
            XCTAssertFalse(
                ClipPickerCropLogic.requiresCrop(
                    assetPixelWidth: width,
                    assetPixelHeight: height,
                    geometry: landscapeProject
                ),
                "\(width)×\(height) partage la forme 16:9"
            )
        }
    }

    func testDifferentShapeBadgesInEitherOrientation() {
        // 4:3 (forme 1,33) face à un projet 16:9 (forme 1,78) : recadrage
        // réel §50 → badge, quelle que soit l'orientation encodée.
        XCTAssertTrue(
            ClipPickerCropLogic.requiresCrop(
                assetPixelWidth: 1440,
                assetPixelHeight: 1080,
                geometry: landscapeProject
            )
        )
        XCTAssertTrue(
            ClipPickerCropLogic.requiresCrop(
                assetPixelWidth: 1080,
                assetPixelHeight: 1440,
                geometry: landscapeProject
            ),
            "Forme identique à 4:3 même encodée en portrait"
        )
        XCTAssertTrue(
            ClipPickerCropLogic.requiresCrop(
                assetPixelWidth: 1920,
                assetPixelHeight: 1080,
                geometry: squareProject
            ),
            "16:9 dans un projet carré : formes 1,78 contre 1,00"
        )
    }

    func testDocumentedLimitSameShapeOppositeOrientationIsNotBadged() {
        // LIMITE ASSUMÉE (§42) : un paysage 16:9 dans un projet 9:16 a la
        // MÊME forme — sans l'orientation réelle du rush (indisponible sans
        // décoder la vidéo, interdit par §42), le badge ne peut pas
        // l'affirmer. C'est l'aperçu du crop réel §50 qui le montre
        // visuellement.
        XCTAssertFalse(
            ClipPickerCropLogic.requiresCrop(
                assetPixelWidth: 1920,
                assetPixelHeight: 1080,
                geometry: portraitProject
            )
        )
    }

    func testMissingMetadataNeverBadges() {
        // Métadonnée absente (0) : ne rien affirmer — aucun badge faux.
        XCTAssertFalse(
            ClipPickerCropLogic.requiresCrop(
                assetPixelWidth: 0,
                assetPixelHeight: 1080,
                geometry: landscapeProject
            )
        )
        XCTAssertFalse(
            ClipPickerCropLogic.requiresCrop(
                assetPixelWidth: 1920,
                assetPixelHeight: 0,
                geometry: landscapeProject
            )
        )
    }

    // MARK: - §50 Aperçu du crop réel dans la cellule

    func testPreviewSizeWithoutGeometryStaysSquare() {
        // §49 : aucune géométrie verrouillée → rendu carré (comportement
        // Jalon 8 conservé).
        let size = ClipPickerCropLogic.previewSize(side: 120, geometry: nil)

        XCTAssertEqual(size.width, 120, accuracy: 0.001)
        XCTAssertEqual(size.height, 120, accuracy: 0.001)
    }

    func testPreviewSizeUsesLockedPortraitRatio() {
        let size = ClipPickerCropLogic.previewSize(side: 160, geometry: portraitProject)

        XCTAssertEqual(size.height, 160, accuracy: 0.001, "Portrait : hauteur pleine")
        XCTAssertEqual(size.width, 90, accuracy: 0.001, "160 × 9/16")
    }

    func testPreviewSizeUsesLockedLandscapeRatio() {
        let size = ClipPickerCropLogic.previewSize(side: 160, geometry: landscapeProject)

        XCTAssertEqual(size.width, 160, accuracy: 0.001, "Paysage : largeur pleine")
        XCTAssertEqual(size.height, 90, accuracy: 0.001, "160 × 9/16")
    }

    func testPreviewSizeForSquareGeometryFillsTheCell() {
        let size = ClipPickerCropLogic.previewSize(side: 100, geometry: squareProject)

        XCTAssertEqual(size.width, 100, accuracy: 0.001)
        XCTAssertEqual(size.height, 100, accuracy: 0.001)
    }

    func testPreviewSizeNeverExceedsTheCell() {
        // Le cadre s'INSCRIT dans la cellule : jamais de débordement de la
        // grille (§42), quelle que soit la géométrie verrouillée.
        let geometries = [portraitProject, landscapeProject, squareProject]
        for geometry in geometries {
            let size = ClipPickerCropLogic.previewSize(side: 84, geometry: geometry)
            XCTAssertLessThanOrEqual(size.width, 84.001)
            XCTAssertLessThanOrEqual(size.height, 84.001)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    // MARK: - Forme

    func testShapeIsOrientationIndependent() {
        XCTAssertEqual(
            ClipPickerCropLogic.shape(width: 16, height: 9),
            ClipPickerCropLogic.shape(width: 9, height: 16),
            accuracy: 0.000_001
        )
        XCTAssertEqual(ClipPickerCropLogic.shape(width: 1, height: 1), 1, accuracy: 0.000_001)
    }
}
