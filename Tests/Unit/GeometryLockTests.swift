//
//  GeometryLockTests.swift
//  MontageMusicalTests
//
//  Géométrie du projet (Jalon 9) — calculs PURS :
//  - `GeometryLock.geometry` (§49 : dimensions orientées, rapport simplifié
//    par PGCD, orientation) ;
//  - `GeometryLock.cropToFillTransform` (§50 : crop-to-fill centré,
//    `scale = max(...)` appliqué APRÈS `preferredTransform`) ;
//  - `GeometryLock.renderSize` (rapport verrouillé respecté, dimensions
//    paires obligatoires à l'encodage §55).
//
//  AUCUN AVFoundation réel : les `CGAffineTransform` sont construites à la
//  main (identité, rotation portrait exacte, miroir) — les tests sont
//  déterministes et n'ouvrent aucun fichier ni aucun asset.
//

import XCTest
import CoreGraphics
@testable import MontageMusical

final class GeometryLockTests: XCTestCase {

    /// `preferredTransform` d'un rush filmé en portrait sur iPhone : rotation
    /// de 90° EXACTE (coefficients entiers — aucune erreur flottante,
    /// contrairement à `CGAffineTransform(rotationAngle: .pi / 2)`).
    /// Un buffer 1920×1080 s'affiche alors en 1080×1920.
    private func portraitTransform(bufferHeight: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: bufferHeight, ty: 0)
    }

    // MARK: - §49 Géométrie verrouillée par le premier rush

    func testLandscapeIdentityLocksSixteenByNine() {
        let geometry = GeometryLock.geometry(
            naturalWidth: 1920,
            naturalHeight: 1080,
            preferredTransform: .identity,
            assetIdentifier: "asset-A"
        )

        XCTAssertEqual(geometry.aspectWidth, 16)
        XCTAssertEqual(geometry.aspectHeight, 9)
        XCTAssertEqual(geometry.orientation, .landscape)
        XCTAssertEqual(
            geometry.lockedByAssetIdentifier, "asset-A",
            "§14 : la géométrie mémorise le rush qui l'a verrouillée"
        )
    }

    func testPortraitPreferredTransformLocksNineBySixteen() {
        // §49 étape 2 : les dimensions ORIENTÉES, jamais `naturalSize` brut —
        // un rush portrait a un buffer 1920×1080 et s'affiche en 1080×1920.
        let geometry = GeometryLock.geometry(
            naturalWidth: 1920,
            naturalHeight: 1080,
            preferredTransform: portraitTransform(bufferHeight: 1080),
            assetIdentifier: "asset-portrait"
        )

        XCTAssertEqual(geometry.aspectWidth, 9)
        XCTAssertEqual(geometry.aspectHeight, 16)
        XCTAssertEqual(geometry.orientation, .portrait)
    }

    func testPortraitRotationInRadiansAlsoLocksNineBySixteen() {
        // Même résultat avec une rotation exprimée en radians : l'arrondi au
        // pixel absorbe les 1e-13 de la trigonométrie flottante.
        let geometry = GeometryLock.geometry(
            naturalWidth: 1920,
            naturalHeight: 1080,
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 2),
            assetIdentifier: "asset-portrait"
        )

        XCTAssertEqual(geometry.aspectWidth, 9)
        XCTAssertEqual(geometry.aspectHeight, 16)
        XCTAssertEqual(geometry.orientation, .portrait)
    }

    func testSquareLocksOneByOne() {
        let geometry = GeometryLock.geometry(
            naturalWidth: 1080,
            naturalHeight: 1080,
            preferredTransform: .identity,
            assetIdentifier: "asset-square"
        )

        XCTAssertEqual(geometry.aspectWidth, 1)
        XCTAssertEqual(geometry.aspectHeight, 1)
        XCTAssertEqual(
            geometry.orientation, .square,
            "§49 : « vertical, horizontal, carré ou autre » — le carré est un cas normal"
        )
    }

    func testFourKSimplifiesToSixteenByNineThroughGCD() {
        // §49 étape 3 : rapport SIMPLIFIÉ (PGCD 240) — la métadonnée
        // d'affichage d'un 4K est 16:9, pas 3840:2160.
        let geometry = GeometryLock.geometry(
            naturalWidth: 3840,
            naturalHeight: 2160,
            preferredTransform: .identity,
            assetIdentifier: "asset-4k"
        )

        XCTAssertEqual(geometry.aspectWidth, 16)
        XCTAssertEqual(geometry.aspectHeight, 9)
        XCTAssertEqual(geometry.orientation, .landscape)
    }

    func testFourThreeSourceLocksFourByThree() {
        // §49 : « Ne pas limiter à 9:16/16:9 » — un 4:3 est verrouillé tel quel.
        let geometry = GeometryLock.geometry(
            naturalWidth: 1440,
            naturalHeight: 1080,
            preferredTransform: .identity,
            assetIdentifier: "asset-43"
        )

        XCTAssertEqual(geometry.aspectWidth, 4)
        XCTAssertEqual(geometry.aspectHeight, 3)
        XCTAssertEqual(geometry.orientation, .landscape)
    }

    func testMirroredTransformKeepsDimensionsAndRatio() {
        // Un miroir horizontal (caméra frontale) ne change pas les dimensions
        // orientées : le rapport reste 16:9.
        let geometry = GeometryLock.geometry(
            naturalWidth: 1920,
            naturalHeight: 1080,
            preferredTransform: CGAffineTransform(scaleX: -1, y: 1),
            assetIdentifier: "asset-mirror"
        )

        XCTAssertEqual(geometry.aspectWidth, 16)
        XCTAssertEqual(geometry.aspectHeight, 9)
        XCTAssertEqual(geometry.orientation, .landscape)
    }

    func testDegenerateSizeFallsBackToSquareRatio() {
        // Garde-fou documenté : dimension nulle → 1:1 carré, jamais un
        // rapport « 0:x » ni une division par zéro.
        let geometry = GeometryLock.geometry(
            naturalWidth: 0,
            naturalHeight: 1080,
            preferredTransform: .identity,
            assetIdentifier: "asset-corrompu"
        )

        XCTAssertEqual(geometry.aspectWidth, 1)
        XCTAssertEqual(geometry.aspectHeight, 1)
        XCTAssertEqual(geometry.orientation, .square)
        XCTAssertEqual(geometry.lockedByAssetIdentifier, "asset-corrompu")
    }

    // MARK: - §50 Crop-to-fill centré

    func testLandscapeSourceInPortraitRenderFillsHeightAndStaysCentered() {
        // Rush 16:9 dans un projet 9:16 (§50 : « Les rushs d'un rapport
        // différent restent autorisés »). La HAUTEUR doit remplir le rendu
        // (débordement latéral rogné), jamais l'inverse : aucune bande noire.
        let naturalSize = CGSize(width: 1920, height: 1080)
        let renderSize = CGSize(width: 1080, height: 1920)

        let transform = GeometryLock.cropToFillTransform(
            naturalSize: naturalSize,
            preferredTransform: .identity,
            renderSize: renderSize
        )

        let placed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        XCTAssertEqual(
            placed.height, renderSize.height, accuracy: 0.5,
            "La hauteur remplit EXACTEMENT le rendu (scale = max, §50)"
        )
        XCTAssertGreaterThan(
            placed.width, renderSize.width,
            "La largeur déborde et sera rognée — crop-to-fill, pas fit"
        )

        // Le centre de la source tombe au centre du rendu (centrage §50).
        let sourceCenter = CGPoint(x: naturalSize.width / 2, y: naturalSize.height / 2)
            .applying(transform)
        XCTAssertEqual(sourceCenter.x, renderSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(sourceCenter.y, renderSize.height / 2, accuracy: 0.5)

        // Débordement réparti à parts égales de chaque côté.
        XCTAssertEqual(
            placed.minX, renderSize.width - placed.maxX, accuracy: 0.5,
            "Autant de pixels rognés à gauche qu'à droite"
        )
    }

    func testIdenticalSourceAndRenderProducesIdentityTransform() {
        let size = CGSize(width: 1920, height: 1080)

        let transform = GeometryLock.cropToFillTransform(
            naturalSize: size,
            preferredTransform: .identity,
            renderSize: size
        )

        // scale = 1 et translation nulle → transformation identité.
        XCTAssertEqual(transform.a, 1, accuracy: 0.0001, "scale x = 1")
        XCTAssertEqual(transform.d, 1, accuracy: 0.0001, "scale y = 1")
        XCTAssertEqual(transform.b, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.c, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.tx, 0, accuracy: 0.0001, "aucune translation")
        XCTAssertEqual(transform.ty, 0, accuracy: 0.0001, "aucune translation")
    }

    func testSquareSourceInLandscapeRenderFillsWidthAndStaysCentered() {
        // Rush carré dans un projet 16:9 : c'est la LARGEUR qui remplit.
        let naturalSize = CGSize(width: 1080, height: 1080)
        let renderSize = CGSize(width: 1920, height: 1080)

        let transform = GeometryLock.cropToFillTransform(
            naturalSize: naturalSize,
            preferredTransform: .identity,
            renderSize: renderSize
        )

        let placed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        XCTAssertEqual(placed.width, renderSize.width, accuracy: 0.5)
        XCTAssertGreaterThan(placed.height, renderSize.height, "Haut et bas rognés")

        let sourceCenter = CGPoint(x: naturalSize.width / 2, y: naturalSize.height / 2)
            .applying(transform)
        XCTAssertEqual(sourceCenter.x, renderSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(sourceCenter.y, renderSize.height / 2, accuracy: 0.5)
    }

    func testPreferredTransformIsAppliedBeforeScaling() {
        // L'ORDRE compte (§50 : « centrer APRÈS application de
        // preferredTransform ») : un rush portrait (buffer 1920×1080, rotation
        // 90°) dans un rendu 9:16 remplit EXACTEMENT le cadre — scale 1.
        // Si l'échelle était calculée sur le buffer non orienté, le rush
        // serait agrandi ~1,78× et le cadrage serait faux.
        let naturalSize = CGSize(width: 1920, height: 1080)
        let renderSize = CGSize(width: 1080, height: 1920)

        let transform = GeometryLock.cropToFillTransform(
            naturalSize: naturalSize,
            preferredTransform: portraitTransform(bufferHeight: 1080),
            renderSize: renderSize
        )

        let placed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        XCTAssertEqual(placed.width, renderSize.width, accuracy: 0.5)
        XCTAssertEqual(placed.height, renderSize.height, accuracy: 0.5)
        XCTAssertEqual(placed.origin.x, 0, accuracy: 0.5, "Aucun débordement : scale = 1")
        XCTAssertEqual(placed.origin.y, 0, accuracy: 0.5)

        let sourceCenter = CGPoint(x: naturalSize.width / 2, y: naturalSize.height / 2)
            .applying(transform)
        XCTAssertEqual(sourceCenter.x, renderSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(sourceCenter.y, renderSize.height / 2, accuracy: 0.5)
    }

    // MARK: - Dimensions de rendu (rapport + parité)

    func testRenderSizeKeepsLockedAspectWithEvenDimensions() {
        // Propriétés vérifiées (jamais une valeur arbitraire) :
        // 1. le rapport de la géométrie VERROUILLÉE est respecté (§52.1) ;
        // 2. les deux dimensions sont PAIRES (§55, encodage 4:2:0) ;
        // 3. le rendu est inscrit dans le clip maître — jamais d'agrandissement
        //    au-delà de sa résolution réelle (§52.2).
        let cases: [(aspectWidth: Int, aspectHeight: Int, masterWidth: Int, masterHeight: Int)] = [
            (16, 9, 1920, 1080),   // maître au rapport du projet
            (9, 16, 1080, 1920),
            (9, 16, 1920, 1080),   // §50 : rush paysage dans un projet vertical
            (16, 9, 1080, 1920),
            (1, 1, 1920, 1080),
            (4, 3, 3840, 2160),
            (9, 16, 1000, 1000),   // valeur brute impaire (562,5) → arrondie paire
            (16, 9, 1281, 721)     // dimensions maîtres impaires
        ]

        for testCase in cases {
            let geometry = ProjectGeometry(
                aspectWidth: testCase.aspectWidth,
                aspectHeight: testCase.aspectHeight,
                orientation: testCase.aspectHeight > testCase.aspectWidth ? .portrait : .landscape,
                lockedByAssetIdentifier: "asset-A"
            )

            let renderSize = GeometryLock.renderSize(
                for: geometry,
                masterWidth: testCase.masterWidth,
                masterHeight: testCase.masterHeight
            )

            let label = "\(testCase.aspectWidth):\(testCase.aspectHeight)"
                + " dans \(testCase.masterWidth)×\(testCase.masterHeight)"

            // 2. Parité (§55).
            XCTAssertEqual(
                renderSize.width.truncatingRemainder(dividingBy: 2), 0,
                "Largeur paire obligatoire — \(label)"
            )
            XCTAssertEqual(
                renderSize.height.truncatingRemainder(dividingBy: 2), 0,
                "Hauteur paire obligatoire — \(label)"
            )
            XCTAssertGreaterThan(renderSize.width, 0, label)
            XCTAssertGreaterThan(renderSize.height, 0, label)

            // 1. Rapport respecté (à l'arrondi de parité près : au plus un
            // pixel sur chaque dimension).
            let expectedRatio = Double(testCase.aspectWidth) / Double(testCase.aspectHeight)
            let actualRatio = Double(renderSize.width) / Double(renderSize.height)
            XCTAssertEqual(
                actualRatio, expectedRatio, accuracy: 0.005,
                "Rapport verrouillé respecté (§52.1) — \(label)"
            )

            // 3. Inscrit dans le maître (tolérance : l'arrondi pair peut
            // ajouter un pixel).
            XCTAssertLessThanOrEqual(
                Double(renderSize.width), Double(testCase.masterWidth) + 1,
                "Aucun agrandissement au-delà du maître — \(label)"
            )
            XCTAssertLessThanOrEqual(
                Double(renderSize.height), Double(testCase.masterHeight) + 1,
                "Aucun agrandissement au-delà du maître — \(label)"
            )
        }
    }

    func testRenderSizeMatchesMasterWhenAspectsAgree() {
        // Cas nominal : maître 16:9 dans un projet 16:9 → le rendu EST la
        // résolution du maître, sans perte.
        let geometry = ProjectGeometry(
            aspectWidth: 16,
            aspectHeight: 9,
            orientation: .landscape,
            lockedByAssetIdentifier: "asset-A"
        )

        let renderSize = GeometryLock.renderSize(for: geometry, masterWidth: 3840, masterHeight: 2160)

        XCTAssertEqual(renderSize.width, 3840)
        XCTAssertEqual(renderSize.height, 2160)
    }

    func testRenderSizeGuardsAgainstDegenerateInput() {
        // Garde-fou : aucune dimension nulle ni NaN ne sort de la fonction.
        let geometry = ProjectGeometry(
            aspectWidth: 0,
            aspectHeight: 0,
            orientation: .square,
            lockedByAssetIdentifier: "asset-A"
        )

        let renderSize = GeometryLock.renderSize(for: geometry, masterWidth: 0, masterHeight: 0)

        XCTAssertGreaterThanOrEqual(renderSize.width, 2)
        XCTAssertGreaterThanOrEqual(renderSize.height, 2)
        XCTAssertEqual(renderSize.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(renderSize.height.truncatingRemainder(dividingBy: 2), 0)
    }
}
