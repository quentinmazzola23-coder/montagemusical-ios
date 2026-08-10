//
//  MasterProfileTests.swift
//  MontageMusicalTests
//
//  Tests unitaires obligatoires — spécification §70, bloc « Profil maître »
//  COMPLET : 1080p60 homogène ; 4K60 + 1080p60 ; 4K30 + 1080p60 sans
//  invention de 4K60 ; mélange vertical/horizontal ; HDR homogène ;
//  HDR + SDR ; 120 i/s plafonné à 60. Compléments : 29,97 et 59,94
//  préservées (§52.3), égalité parfaite départagée par l'ordre d'apparition
//  (§52.2), cadence dégénérée bornée, liste vide.
//
//  §52.4/§55 — la sortie HDR est DÉSACTIVÉE en V1
//  (`MasterProfileSelector.allowsHDROutput == false`) : aucun preset §55 ne
//  la garantit, et rien n'a pu être vérifié sur matériel HDR. Les tests
//  décrivent donc ce que l'application PRODUIT (SDR cohérent, tone mapping
//  explicite), jamais ce qu'elle aimerait produire.
//
//  AUCUN média, AUCUNE AVFoundation : `MasterClipInfo` porte des
//  caractéristiques déjà mesurées — les tests sont déterministes et
//  n'ouvrent aucun fichier.
//

import XCTest
@testable import MontageMusical

final class MasterProfileTests: XCTestCase {

    // MARK: - Helpers

    /// Géométrie verrouillée du projet (§14, §49) — rapport déjà simplifié.
    private func makeGeometry(
        aspectWidth: Int,
        aspectHeight: Int,
        orientation: ProjectOrientation
    ) -> ProjectGeometry {
        ProjectGeometry(
            aspectWidth: aspectWidth,
            aspectHeight: aspectHeight,
            orientation: orientation,
            lockedByAssetIdentifier: "asset-lock"
        )
    }

    private func makeClip(
        _ identifier: String,
        width: Int,
        height: Int,
        frameRate: Double,
        isHDR: Bool = false,
        order: Int
    ) -> MasterClipInfo {
        MasterClipInfo(
            assetLocalIdentifier: identifier,
            orientedWidth: width,
            orientedHeight: height,
            nominalFrameRate: frameRate,
            isHDR: isHDR,
            appearanceOrder: order
        )
    }

    private var landscapeGeometry: ProjectGeometry {
        makeGeometry(aspectWidth: 16, aspectHeight: 9, orientation: .landscape)
    }

    private var portraitGeometry: ProjectGeometry {
        makeGeometry(aspectWidth: 9, aspectHeight: 16, orientation: .portrait)
    }

    // MARK: - §70 : 1080p60 homogène

    func testHomogeneous1080p60ProducesFullHD60Profile() {
        let clips = [
            makeClip("a", width: 1920, height: 1080, frameRate: 60, order: 0),
            makeClip("b", width: 1920, height: 1080, frameRate: 60, order: 1),
            makeClip("c", width: 1920, height: 1080, frameRate: 60, order: 2)
        ]

        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)

        XCTAssertEqual(profile?.renderWidth, 1920)
        XCTAssertEqual(profile?.renderHeight, 1080)
        XCTAssertEqual(profile?.frameRate ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(profile?.frameDurationValue, 1)
        XCTAssertEqual(profile?.frameDurationTimescale, 60)
        XCTAssertEqual(profile?.isHDR, false)
    }

    // MARK: - §70 : 4K60 + 1080p60

    func testFourK60WinsOverFullHD60() {
        let clips = [
            makeClip("fullhd", width: 1920, height: 1080, frameRate: 60, order: 0),
            makeClip("uhd", width: 3840, height: 2160, frameRate: 60, order: 1)
        ]

        let master = MasterProfileSelector.selectMasterClip(clips: clips, geometry: landscapeGeometry)
        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)

        XCTAssertEqual(master?.assetLocalIdentifier, "uhd", "§52.2 critère 1 : plus de pixels orientés")
        XCTAssertEqual(profile?.renderWidth, 3840)
        XCTAssertEqual(profile?.renderHeight, 2160)
        XCTAssertEqual(profile?.frameRate ?? 0, 60, accuracy: 1e-9)
    }

    // MARK: - §70 : 4K30 + 1080p60 SANS invention de 4K60 (test central §52.2)

    func testFourK30AndFullHD60NeverInventFourK60() {
        let clips = [
            makeClip("uhd30", width: 3840, height: 2160, frameRate: 30, order: 0),
            makeClip("fullhd60", width: 1920, height: 1080, frameRate: 60, order: 1)
        ]

        let master = MasterProfileSelector.selectMasterClip(clips: clips, geometry: landscapeGeometry)
        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)

        // §52.2 : « Prendre la résolution et la cadence d'un MÊME clip
        // maître. Ne pas inventer du 4K60 à partir d'un clip 4K30 et d'un
        // autre 1080p60. » Le clip 4K30 gagne au critère 1 (pixels) : sa
        // cadence de 30 i/s suit, elle n'est PAS remplacée par le 60 i/s de
        // l'autre clip.
        XCTAssertEqual(master?.assetLocalIdentifier, "uhd30")
        XCTAssertEqual(profile?.renderWidth, 3840)
        XCTAssertEqual(profile?.renderHeight, 2160)
        XCTAssertEqual(profile?.frameRate ?? 0, 30, accuracy: 1e-9)
        XCTAssertNotEqual(profile?.frameRate ?? 0, 60, "4K60 inventé — interdit par §52.2")
    }

    // MARK: - §70 : mélange vertical/horizontal (§52.1)

    func testMixedOrientationsAlwaysRenderInProjectGeometry() {
        // Projet VERTICAL (§49 : verrouillé par le premier rush) contenant un
        // rush paysage 4K — beaucoup plus défini, mais d'un rapport
        // incompatible.
        let clips = [
            makeClip("portrait", width: 1080, height: 1920, frameRate: 30, order: 0),
            makeClip("paysage4k", width: 3840, height: 2160, frameRate: 30, order: 1)
        ]

        let master = MasterProfileSelector.selectMasterClip(clips: clips, geometry: portraitGeometry)
        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: portraitGeometry)

        // §52.2 premier filtre : seuls les clips au rapport COMPATIBLE sont
        // candidats — le rush paysage est écarté malgré ses pixels.
        XCTAssertEqual(master?.assetLocalIdentifier, "portrait")
        // §52.1 : « Toujours celle du projet, définie par le premier rush ».
        XCTAssertEqual(profile?.renderWidth, 1080)
        XCTAssertEqual(profile?.renderHeight, 1920)
    }

    func testNoCompatibleAspectFallsBackToHighestResolutionInLockedGeometry() {
        // §52.2 : « Si aucun clip n'a un rapport exactement compatible,
        // utiliser le clip de plus haute résolution et rendre dans la
        // géométrie verrouillée. » Projet CARRÉ, deux rushs 16:9.
        let squareGeometry = makeGeometry(aspectWidth: 1, aspectHeight: 1, orientation: .square)
        let clips = [
            makeClip("fullhd", width: 1920, height: 1080, frameRate: 30, order: 0),
            makeClip("uhd", width: 3840, height: 2160, frameRate: 30, order: 1)
        ]

        let master = MasterProfileSelector.selectMasterClip(clips: clips, geometry: squareGeometry)
        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: squareGeometry)

        XCTAssertEqual(master?.assetLocalIdentifier, "uhd")
        XCTAssertEqual(profile?.renderWidth, 2160, "rendu CARRÉ (géométrie verrouillée §52.1)")
        XCTAssertEqual(profile?.renderHeight, 2160)
    }

    // MARK: - §70 : HDR homogène / HDR + SDR (§52.4)

    func testAllHDRClipsStillProduceSDRProfileInV1() {
        let clips = [
            makeClip("a", width: 1920, height: 1080, frameRate: 30, isHDR: true, order: 0),
            makeClip("b", width: 1920, height: 1080, frameRate: 30, isHDR: true, order: 1)
        ]

        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)

        // §52.4 autorise le HDR quand TOUS les rushs sont HDR, mais §55
        // impose `AVAssetExportSession` et ses presets : aucun ne GARANTIT la
        // sortie HDR, et le chemin n'a pas pu être vérifié sur matériel réel.
        // V1 rend donc en SDR cohérent avec tone mapping EXPLICITE plutôt que
        // d'annoncer un HDR non garanti (§52.4 : « ne pas se fier à un
        // comportement implicite non testé »).
        XCTAssertFalse(MasterProfileSelector.allowsHDROutput, "V1 : sortie HDR désactivée")
        XCTAssertEqual(profile?.isHDR, false)
    }

    func testHDRCapabilityStillRanksClipsEvenWithoutHDROutput() {
        // La capacité HDR reste un CRITÈRE de classement (§52.2 point 3) :
        // seule la SORTIE est contrainte par `allowsHDROutput`.
        let clips = [
            makeClip("sdr", width: 1920, height: 1080, frameRate: 30, isHDR: false, order: 0),
            makeClip("hdr", width: 1920, height: 1080, frameRate: 30, isHDR: true, order: 1)
        ]

        XCTAssertEqual(
            MasterProfileSelector.selectMasterClip(clips: clips, geometry: landscapeGeometry)?
                .assetLocalIdentifier,
            "hdr"
        )
    }

    func testMixedHDRAndSDRProducesSDRProfileToo() {
        let clips = [
            makeClip("hdr", width: 3840, height: 2160, frameRate: 30, isHDR: true, order: 0),
            makeClip("sdr", width: 1920, height: 1080, frameRate: 30, isHDR: false, order: 1)
        ]

        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)

        // §52.4 : « mélange HDR/SDR → sortie SDR cohérente » — même si le
        // clip MAÎTRE (4K, retenu au critère 1) est HDR.
        XCTAssertEqual(profile?.isHDR, false)
    }

    func testAllSDRClipsProduceSDRProfile() {
        let clips = [
            makeClip("a", width: 1920, height: 1080, frameRate: 30, order: 0),
            makeClip("b", width: 1920, height: 1080, frameRate: 30, order: 1)
        ]

        XCTAssertEqual(
            MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)?.isHDR,
            false
        )
    }

    // MARK: - §70 : 120 i/s plafonné à 60 (§52.3)

    func testHighFrameRateIsCappedToSixty() {
        let clips = [makeClip("slowmo", width: 1920, height: 1080, frameRate: 120, order: 0)]

        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)

        XCTAssertEqual(profile?.frameRate ?? 0, 60, accuracy: 1e-9, "§52.3 : plafond V1 à 60 i/s")
        XCTAssertEqual(profile?.frameDurationValue, 1)
        XCTAssertEqual(profile?.frameDurationTimescale, 60)
    }

    func testTwoHundredFortyFramesPerSecondIsCappedToSixty() {
        let clips = [makeClip("slowmo", width: 1920, height: 1080, frameRate: 240, order: 0)]

        XCTAssertEqual(
            MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)?.frameRate ?? 0,
            60,
            accuracy: 1e-9
        )
    }

    func testCappedFrameRateMakesHighRatesTieAtSixty() {
        // §52.2 critère 2 : la cadence comparée est celle PLAFONNÉE — un
        // 120 i/s ne « bat » donc pas un 60 i/s ; c'est l'ordre d'apparition
        // qui départage (critère 4).
        let clips = [
            makeClip("soixante", width: 1920, height: 1080, frameRate: 60, order: 0),
            makeClip("cent-vingt", width: 1920, height: 1080, frameRate: 120, order: 1)
        ]

        let master = MasterProfileSelector.selectMasterClip(clips: clips, geometry: landscapeGeometry)

        XCTAssertEqual(master?.assetLocalIdentifier, "soixante")
    }

    // MARK: - §52.3 : cadences fractionnaires PRÉSERVÉES

    func testNTSC2997IsPreservedAndNotRoundedToThirty() {
        // Cadence telle que la rapporte AVFoundation pour du NTSC.
        let clips = [makeClip("ntsc", width: 1920, height: 1080, frameRate: 29.97003, order: 0)]

        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)

        XCTAssertEqual(profile?.frameDurationValue, 1001, "§52.3 : 30000/1001, jamais 1/30")
        XCTAssertEqual(profile?.frameDurationTimescale, 30_000)
        XCTAssertEqual(profile?.frameRate ?? 0, 30_000.0 / 1001.0, accuracy: 1e-9)
        XCTAssertNotEqual(profile?.frameRate ?? 0, 30, accuracy: 0.001, "29,97 arrondi à 30 — interdit")
    }

    func testNTSC5994IsPreserved() {
        let clips = [makeClip("ntsc", width: 1920, height: 1080, frameRate: 59.94006, order: 0)]

        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)

        XCTAssertEqual(profile?.frameDurationValue, 1001)
        XCTAssertEqual(profile?.frameDurationTimescale, 60_000)
        XCTAssertEqual(profile?.frameRate ?? 0, 60_000.0 / 1001.0, accuracy: 1e-9)
    }

    func testNTSC11988IsCappedToFractionalFiftyNineNinetyFour() {
        // §52.3 : un 119,88 i/s est plafonné SANS quitter la famille NTSC —
        // 59,94, pas 60 rond.
        let clips = [makeClip("ntsc-slowmo", width: 1920, height: 1080, frameRate: 119.88, order: 0)]

        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)

        XCTAssertEqual(profile?.frameDurationValue, 1001)
        XCTAssertEqual(profile?.frameDurationTimescale, 60_000)
        XCTAssertEqual(profile?.frameRate ?? 0, 60_000.0 / 1001.0, accuracy: 1e-9)
    }

    // MARK: - Cadences dégénérées : jamais de piège arithmétique

    func testTinyFrameRateIsFlooredInsteadOfOverflowingInt32() {
        // Piste corrompue annonçant une cadence minuscule : sans plancher, la
        // durée d'image (60 000 / 0,000001 tick) dépasserait `Int32` et
        // `Int32(_:)` planterait. La cadence est ramenée au plancher crédible
        // (1 i/s) et la fraction reste convertible.
        for rate in [0.000001, 0.001, 0.5] {
            let cadence = MasterProfile.normalizedCadence(nominalFrameRate: rate)
            XCTAssertGreaterThan(cadence.value, 0, "cadence \(rate)")
            XCTAssertEqual(
                Double(cadence.timescale) / Double(cadence.value),
                MasterProfile.minimumFrameRate,
                accuracy: 1e-6,
                "cadence \(rate) ramenée au plancher"
            )
        }
    }

    func testUnusableFrameRatesFallBackWithoutCrashing() {
        // 0, négative, NaN, infinie : repli documenté à 30 i/s.
        for rate in [0, -30, Double.nan, Double.infinity] {
            let cadence = MasterProfile.normalizedCadence(nominalFrameRate: rate)
            XCTAssertEqual(cadence.value, 1, "cadence \(rate)")
            XCTAssertEqual(cadence.timescale, MasterProfile.fallbackFrameRate, "cadence \(rate)")
        }
    }

    func testExoticFrameRateStaysOnTheCanonicalTimescale() {
        // Cadence exotique (ni entière, ni NTSC) : fraction sur l'échelle
        // canonique §9, toujours convertible en `Int32`.
        let cadence = MasterProfile.normalizedCadence(nominalFrameRate: 25.5)

        XCTAssertEqual(cadence.timescale, MediaTime.canonicalTimescale)
        XCTAssertEqual(
            Double(cadence.timescale) / Double(cadence.value),
            25.5,
            accuracy: 0.01
        )
    }

    func testIntegerRatesAreExact() {
        for rate in [24.0, 25.0, 30.0, 50.0, 60.0] {
            let clips = [makeClip("r", width: 1920, height: 1080, frameRate: rate, order: 0)]
            let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: landscapeGeometry)
            XCTAssertEqual(profile?.frameDurationValue, 1, "cadence \(rate)")
            XCTAssertEqual(profile?.frameDurationTimescale, Int32(rate), "cadence \(rate)")
        }
    }

    // MARK: - §52.2 critère 4 : égalité parfaite → ordre d'apparition

    func testPerfectTieIsResolvedByAppearanceOrder() {
        // Deux clips STRICTEMENT identiques (pixels, cadence, HDR), fournis
        // dans l'ordre inverse de leur apparition : c'est le premier APPARU
        // qui doit gagner, quel que soit l'ordre du tableau.
        let clips = [
            makeClip("second", width: 1920, height: 1080, frameRate: 30, order: 1),
            makeClip("premier", width: 1920, height: 1080, frameRate: 30, order: 0)
        ]

        let master = MasterProfileSelector.selectMasterClip(clips: clips, geometry: landscapeGeometry)

        XCTAssertEqual(master?.assetLocalIdentifier, "premier")
    }

    func testHDRBreaksTieBeforeAppearanceOrder() {
        // §52.2 critère 3 : à pixels et cadence égaux, le clip HDR prime —
        // même s'il apparaît plus tard.
        let clips = [
            makeClip("sdr", width: 1920, height: 1080, frameRate: 30, isHDR: false, order: 0),
            makeClip("hdr", width: 1920, height: 1080, frameRate: 30, isHDR: true, order: 1)
        ]

        let master = MasterProfileSelector.selectMasterClip(clips: clips, geometry: landscapeGeometry)

        XCTAssertEqual(master?.assetLocalIdentifier, "hdr")
    }

    // MARK: - Liste vide

    func testEmptyClipListProducesNoProfile() {
        XCTAssertNil(MasterProfileSelector.selectMaster(clips: [], geometry: landscapeGeometry))
        XCTAssertNil(MasterProfileSelector.selectMasterClip(clips: [], geometry: landscapeGeometry))
    }

    // MARK: - Dimensions PAIRES (§55)

    func testRenderDimensionsAreAlwaysEven() {
        // Rapport 3:5 sur un maître de hauteur impaire : les deux dimensions
        // rendues doivent rester paires (exigence des encodeurs 4:2:0 §55).
        let geometry = makeGeometry(aspectWidth: 3, aspectHeight: 5, orientation: .portrait)
        let clips = [makeClip("odd", width: 1077, height: 1795, frameRate: 30, order: 0)]

        let profile = MasterProfileSelector.selectMaster(clips: clips, geometry: geometry)

        XCTAssertEqual((profile?.renderWidth ?? 1) % 2, 0)
        XCTAssertEqual((profile?.renderHeight ?? 1) % 2, 0)
    }
}
