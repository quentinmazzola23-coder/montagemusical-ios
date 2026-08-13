//
//  ExportSummaryLogicTests.swift
//  MontageMusicalTests
//
//  Tests de la logique PURE d'affichage du résumé avant export (Jalon 10,
//  `ExportSummaryLogic`) — aucune vue n'est instanciée :
//  - bloc §56 verbatim : « 2160 × 3840 », « Vertical • 60 i/s • SDR »,
//    « 12 plans • 18,43 s » ;
//  - libellés d'orientation français (vertical / horizontal / carré) ;
//  - libellé colorimétrique HDR/SDR (§52.4) ;
//  - cadence §52.3 : une cadence FRACTIONNAIRE reste fractionnaire —
//    29,97 s'affiche « 29,97 i/s », jamais « 30 i/s » ;
//  - messages d'issue : §57 espace insuffisant, §66 fichier conservé,
//    §64 erreur d'export, §8.1 interruption en arrière-plan ;
//  - pourcentage de progression §58 (borné, jamais extrapolé) et dérivation
//    PURE des phases terminales ;
//  - §60/§8.1 : un export RESTAURÉ depuis `exports/` après relance ne
//    s'annonce pas comme un export qui vient d'aboutir (titre et message
//    distincts, passé explicite) ;
//  - ÉCART PRODUIT (13 août 2026) : ce qui part VRAIMENT — l'export concatène
//    TOUTES les zones remplies, les cases vides étant supprimées du montage
//    (vidéo et musique). Une zone garde la formulation de plage
//    (« Plans 28 à 50 », « Plan 28 » au singulier) ; à partir de deux, le
//    résumé §56 annonce « 19 plans en 2 zones » et liste les plages
//    (« 28–35, 40–50 »), avec une mention honnête des jonctions.
//
//  Le calcul des dimensions orientées d'un rush a DISPARU avec le calcul de
//  profil propre à la vue (Jalon 10) : le profil §52 vient désormais d'une
//  source unique, `ProjectExporter.masterProfile(project:)` — plus rien à
//  tester ici de ce côté.
//
//  RELECTURE ADVERSARIALE (13 août 2026) — trois familles de tests ajoutées :
//  - **§66 export TRONQUÉ** (`divergence`, `readyTitle/readyMessage(origin:)`,
//    `truncatedExportMessage`) : un fichier qui ne contient pas le montage
//    annoncé n'est plus présenté comme un succès plein. Le message dit ce qui
//    a été écrit, pourquoi, et quoi faire ;
//  - **compte de plans faisant autorité** : `exportedPlansLabel` reçoit le
//    nombre de plans au lieu de le redériver de la largeur des plages d'index
//    (les deux divergent dès qu'un index manque dans une zone) ;
//  - **§64 cause du blocage** : « Remplissez au moins une case » n'est plus la
//    réponse universelle — une case remplie mais non prête s'attend ou se
//    remplace.
//

import XCTest
@testable import MontageMusical

final class ExportSummaryLogicTests: XCTestCase {

    // MARK: - Dimensions (§56)

    func testDimensionsLabelMatchesSpecificationBlock() {
        // §56 verbatim : « 2160 × 3840 ».
        XCTAssertEqual(
            ExportSummaryLogic.dimensionsLabel(width: 2160, height: 3840),
            "2160 × 3840"
        )
    }

    // MARK: - Orientation (§49, §56)

    func testOrientationLabelIsVerticalWhenHeightExceedsWidth() {
        // §56 verbatim : « Vertical ».
        XCTAssertEqual(
            ExportSummaryLogic.orientationLabel(width: 2160, height: 3840),
            "Vertical"
        )
    }

    func testOrientationLabelIsHorizontalWhenWidthExceedsHeight() {
        XCTAssertEqual(
            ExportSummaryLogic.orientationLabel(width: 3840, height: 2160),
            "Horizontal"
        )
    }

    func testOrientationLabelIsSquareWhenDimensionsAreEqual() {
        // §49 : « Le premier rush peut être vertical, horizontal, carré ou
        // autre. Ne pas limiter à 9:16/16:9. »
        XCTAssertEqual(
            ExportSummaryLogic.orientationLabel(width: 1080, height: 1080),
            "Carré"
        )
    }

    func testOrientationLabelFromLockedProjectOrientation() {
        XCTAssertEqual(ExportSummaryLogic.orientationLabel(.portrait), "Vertical")
        XCTAssertEqual(ExportSummaryLogic.orientationLabel(.landscape), "Horizontal")
        XCTAssertEqual(ExportSummaryLogic.orientationLabel(.square), "Carré")
    }

    // MARK: - Colorimétrie (§52.4)

    func testColorLabelDistinguishesHDRFromSDR() {
        XCTAssertEqual(ExportSummaryLogic.colorLabel(isHDR: true), "HDR")
        XCTAssertEqual(ExportSummaryLogic.colorLabel(isHDR: false), "SDR")
    }

    // MARK: - Cadence (§52.3)

    func testIntegerFrameRateHasNoDecimals() {
        // §56 verbatim : « 60 i/s ».
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(60), "60 i/s")
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(30), "30 i/s")
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(25), "25 i/s")
    }

    func testFractionalFrameRateKeepsItsHundredths() {
        // §52.3 : « préserver 29,97/59,94 lorsque le clip maître utilise une
        // cadence fractionnaire » — afficher « 30 » mentirait sur le fichier
        // produit.
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(29.97), "29,97 i/s")
        XCTAssertNotEqual(ExportSummaryLogic.frameRateLabel(29.97), "30 i/s")
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(59.94), "59,94 i/s")
    }

    func testNTSCFrameRatesMeasuredByAVFoundationKeepTheirHundredths() {
        // Valeurs réellement lues sur une piste NTSC : 30000/1001 et
        // 60000/1001 — l'arrondi d'affichage au centième doit produire
        // « 29,97 » et « 59,94 », jamais « 30 » ni « 60 ».
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(30_000.0 / 1_001.0), "29,97 i/s")
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(60_000.0 / 1_001.0), "59,94 i/s")
        // 24000/1001 = 23,976… → arrondi au centième le plus proche.
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(24_000.0 / 1_001.0), "23,98 i/s")
    }

    func testTrailingZeroOfHundredthsIsDropped() {
        // « 30,5 » et non « 30,50 » : une décimale suffit quand le centième
        // est nul.
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(30.5), "30,5 i/s")
    }

    func testUnusableFrameRateShowsNoFabricatedValue() {
        // Cadence absente ou incohérente : jamais un « 0 i/s » qui donnerait
        // une fausse impression de mesure.
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(0), "— i/s")
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(-12), "— i/s")
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(.nan), "— i/s")
        XCTAssertEqual(ExportSummaryLogic.frameRateLabel(.infinity), "— i/s")
    }

    // MARK: - Ligne technique (§56)

    func testTechnicalLineMatchesSpecificationBlock() {
        // §56 verbatim : « Vertical • 60 i/s • SDR ».
        XCTAssertEqual(
            ExportSummaryLogic.technicalLine(
                width: 2160,
                height: 3840,
                frameRate: 60,
                isHDR: false
            ),
            "Vertical • 60 i/s • SDR"
        )
    }

    func testTechnicalLineReportsHDRAndFractionalRate() {
        XCTAssertEqual(
            ExportSummaryLogic.technicalLine(
                width: 3840,
                height: 2160,
                frameRate: 29.97,
                isHDR: true
            ),
            "Horizontal • 29,97 i/s • HDR"
        )
    }

    // MARK: - Plans et durée (§56)

    func testPlanCountAgreesInNumber() {
        XCTAssertEqual(ExportSummaryLogic.planCountLabel(0), "0 plan")
        XCTAssertEqual(ExportSummaryLogic.planCountLabel(1), "1 plan")
        XCTAssertEqual(ExportSummaryLogic.planCountLabel(12), "12 plans")
    }

    func testPlansAndDurationMatchSpecificationBlock() {
        // §56 verbatim : « 12 plans • 18,43 s ».
        // 18,43 s = 1 105 800 ticks (60 000 ticks/s, §9).
        let duration = MediaTime(ticks: 1_105_800)
        XCTAssertEqual(
            ExportSummaryLogic.plansAndDurationLabel(slotCount: 12, duration: duration),
            "12 plans • 18,43 s"
        )
    }

    // MARK: - Plage d'une zone (1-based)

    func testPlanRangeLabelIsOneBasedLikeTheRestOfTheInterface() {
        // L'exemple de la demande : cases 27…49 en mémoire (0-based) →
        // « Plans 28 à 50 » à l'écran, comme « Plan X sur N » (§35.1).
        XCTAssertEqual(
            ExportSummaryLogic.planRangeLabel(startIndex: 27, endIndex: 49),
            "Plans 28 à 50"
        )
        XCTAssertEqual(
            ExportSummaryLogic.planRangeLabel(startIndex: 0, endIndex: 11),
            "Plans 1 à 12"
        )
    }

    func testPlanRangeLabelIsSingularForASingleSlot() {
        // Jamais « Plans 28 à 28 ».
        XCTAssertEqual(ExportSummaryLogic.planRangeLabel(startIndex: 27, endIndex: 27), "Plan 28")
        XCTAssertEqual(ExportSummaryLogic.planRangeLabel(startIndex: 0, endIndex: 0), "Plan 1")
    }

    func testPlanRangeLabelIsDefensiveAboutOrderAndNegativeIndexes() {
        // Bornes inversées ou négatives (jamais attendues) : jamais « Plan 0 »
        // ni une plage à l'envers.
        XCTAssertEqual(ExportSummaryLogic.planRangeLabel(startIndex: 9, endIndex: 4), "Plans 5 à 10")
        XCTAssertEqual(ExportSummaryLogic.planRangeLabel(startIndex: -3, endIndex: -3), "Plan 1")
    }

    func testPlanRangeAndCountDescribeTheSameZone() {
        // Cohérence du bloc §56 : « 23 plans » et « Plans 28 à 50 » doivent
        // décrire le même montage — sinon l'utilisateur lit deux vérités.
        let startIndex = 27
        let endIndex = 49
        let count = endIndex - startIndex + 1
        XCTAssertEqual(ExportSummaryLogic.planCountLabel(count), "23 plans")
        XCTAssertEqual(
            ExportSummaryLogic.planRangeLabel(startIndex: startIndex, endIndex: endIndex),
            "Plans 28 à 50"
        )
    }

    // MARK: - Zones exportées (écart produit du 13 août 2026)

    func testExportedPlansLabelIsNilWithoutAnyZone() {
        // Aucune case prête : il n'y a rien à nommer — l'écran affiche alors
        // « Aucun plan n'est encore prêt. » (§66), pas une plage vide.
        XCTAssertNil(ExportSummaryLogic.exportedPlansLabel(zones: [], slotCount: 0))
        XCTAssertNil(ExportSummaryLogic.zoneRangesLabel(zones: []))
        XCTAssertNil(ExportSummaryLogic.spokenZoneRanges(zones: []))
    }

    func testExportedPlansLabelKeepsTheRangeWordingForASingleZone() {
        // Une seule zone : le montage est d'un seul tenant, la plage le décrit
        // exactement — formulation CONSERVÉE (« Plans 28 à 50 »).
        XCTAssertEqual(
            ExportSummaryLogic.exportedPlansLabel(zones: [27...49], slotCount: 23),
            "Plans 28 à 50"
        )
        // Et rien n'est listé en petit : la ligne au-dessus le dit déjà.
        XCTAssertNil(ExportSummaryLogic.zoneRangesLabel(zones: [27...49]))
    }

    func testExportedPlansLabelOfAZoneMadeOfASinglePlan() {
        XCTAssertEqual(
            ExportSummaryLogic.exportedPlansLabel(zones: [27...27], slotCount: 1),
            "Plan 28"
        )
        XCTAssertEqual(
            ExportSummaryLogic.exportedPlansLabel(zones: [0...0], slotCount: 1),
            "Plan 1"
        )
    }

    func testExportedPlansLabelUsesTheAuthoritativeCountNotTheRangeWidth() {
        // RELECTURE (13 août 2026) : le compte venait de la somme des LARGEURS
        // des intervalles d'index. Ici la première zone couvre les index 28 à
        // 31 mais ne contient que 3 plans (l'index 30 n'existe pas) : la ligne
        // « N plans » du résumé §56 et cette ligne-ci doivent annoncer le même
        // nombre — celui du domaine, passé en paramètre.
        XCTAssertEqual(
            ExportSummaryLogic.exportedPlansLabel(zones: [27...30, 33...33], slotCount: 4),
            "4 plans en 2 zones"
        )
        XCTAssertNotEqual(
            ExportSummaryLogic.exportedPlansLabel(zones: [27...30, 33...33], slotCount: 4),
            "5 plans en 2 zones"
        )
    }

    func testExportedPlansLabelCountsAllZonesFromTwo() {
        // L'exemple de la demande : cases 28..35 et 40..50 prêtes (index
        // 27…34 et 39…49) → 8 + 11 = 19 plans, en 2 zones. Une plage unique
        // mentirait : les cases 36 à 39 ne sont PAS dans le fichier.
        XCTAssertEqual(
            ExportSummaryLogic.exportedPlansLabel(zones: [27...34, 39...49], slotCount: 19),
            "19 plans en 2 zones"
        )
        XCTAssertEqual(
            ExportSummaryLogic.exportedPlansLabel(zones: [0...0, 2...2, 6...8], slotCount: 5),
            "5 plans en 3 zones"
        )
        // Accord au singulier des DEUX nombres.
        XCTAssertEqual(ExportSummaryLogic.zoneCountLabel(0), "0 zone")
        XCTAssertEqual(ExportSummaryLogic.zoneCountLabel(1), "1 zone")
        XCTAssertEqual(ExportSummaryLogic.zoneCountLabel(4), "4 zones")
        XCTAssertEqual(
            ExportSummaryLogic.plansAndZonesLabel(slotCount: 1, zoneCount: 1),
            "1 plan en 1 zone"
        )
    }

    func testZoneRangesAreListedOneBasedFromTwoZones() {
        // La liste en petit sous le résumé : « 28–35, 40–50 » (1-based, tiret
        // demi-cadratin), une zone d'un seul plan s'écrit sans plage.
        XCTAssertEqual(
            ExportSummaryLogic.zoneRangesLabel(zones: [27...34, 39...49]),
            "28–35, 40–50"
        )
        XCTAssertEqual(
            ExportSummaryLogic.zoneRangesLabel(zones: [0...0, 4...6]),
            "1, 5–7"
        )
    }

    func testSpokenZoneRangesReplaceDashesWithWords() {
        // §39 : le tiret et les virgules ne se lisent pas — VoiceOver reçoit
        // des mots, comme pour le « × » du bloc §56.
        let spoken = ExportSummaryLogic.spokenZoneRanges(zones: [27...34, 39...49])
        XCTAssertEqual(spoken, "plans 28 à 35, puis plans 40 à 50")
        XCTAssertFalse(spoken?.contains("–") ?? true, spoken ?? "")
        XCTAssertEqual(
            ExportSummaryLogic.spokenZoneRanges(zones: [0...0, 4...6]),
            "plan 1, puis plans 5 à 7"
        )
    }

    func testPartialExportNoticeSaysWhatIsDroppedAndWhatIsKept() {
        // Le montage ne contient QUE les plans prêts ; le projet, lui, n'est
        // pas touché (§89 : « elle déplace des plans après un trou » vise le
        // PROJET, pas le fichier exporté). Le texte ne promet plus que « rien
        // n'est déplacé » : dans le fichier, les zones suivantes sont bien
        // avancées — c'est la demande.
        let notice = ExportSummaryLogic.partialExportNotice
        XCTAssertTrue(notice.contains("plans prêts"), notice)
        XCTAssertTrue(notice.contains("cases vides"), notice)
        XCTAssertTrue(notice.contains("projet reste intact"), notice)
        XCTAssertFalse(notice.contains("rien n'est déplacé"), notice)
        XCTAssertFalse(notice.contains("Seul le début"), notice)
    }

    func testConcatenationNoticeIsHonestAboutTheMusicJump() {
        // Mention honnête et SOBRE : elle décrit le comportement demandé, sans
        // alarmer — ni « attention », ni « erreur », ni « problème ».
        let notice = ExportSummaryLogic.concatenationNotice
        XCTAssertTrue(notice.contains("bout à bout"), notice)
        XCTAssertTrue(notice.contains("musique"), notice)
        for alarming in ["Attention", "erreur", "problème", "risque"] {
            XCTAssertFalse(
                notice.lowercased().contains(alarming.lowercased()),
                "Formulation alarmante : \(notice)"
            )
        }
        // Une phrase courte : le résumé §56 reste un écran d'information.
        XCTAssertLessThan(notice.count, 120, notice)
    }

    func testNothingReadyMessagesNameTheGestureThatUnblocksTheExport() {
        // §66 relu par l'écart produit : n'importe quelle case remplie suffit
        // — ce n'est plus « la première » qu'il faut nommer.
        XCTAssertTrue(ExportSummaryLogic.nothingReadyTitle.contains("Aucun plan"))
        let hint = ExportSummaryLogic.nothingReadyHint(.nothingFilled)
        XCTAssertTrue(hint.contains("au moins une case"), hint)
        XCTAssertFalse(hint.contains("première case"), hint)
    }

    // MARK: - §64 : le geste dépend de la CAUSE (relecture 13 août 2026)

    func testNothingReadyCauseIsDerivedFromAssignmentStatuses() {
        func slot(_ index: Int, _ status: ClipAssignmentStatus?) -> ProjectSlot {
            ProjectSlot(
                id: UUID(),
                index: index,
                start: MediaTime(ticks: Int64(index) * 45_000),
                end: MediaTime(ticks: Int64(index + 1) * 45_000),
                assignment: status.map {
                    ClipAssignmentSnapshot(id: UUID(), assetLocalIdentifier: "a\(index)", status: $0)
                }
            )
        }

        XCTAssertEqual(ExportSummaryLogic.nothingReadyCause(slots: []), .nothingFilled)
        XCTAssertEqual(
            ExportSummaryLogic.nothingReadyCause(slots: [slot(0, nil), slot(1, nil)]),
            .nothingFilled
        )
        // Une case PRÊTE ne compte pas comme une cause de blocage : ce chemin
        // n'est atteint que lorsqu'il n'y en a aucune.
        XCTAssertEqual(
            ExportSummaryLogic.nothingReadyCause(slots: [slot(0, .downloading), slot(1, nil)]),
            .pending
        )
        XCTAssertEqual(
            ExportSummaryLogic.nothingReadyCause(slots: [slot(0, .resolving)]),
            .pending
        )
        XCTAssertEqual(
            ExportSummaryLogic.nothingReadyCause(slots: [slot(0, .unavailable)]),
            .blocked
        )
        XCTAssertEqual(
            ExportSummaryLogic.nothingReadyCause(slots: [slot(0, .tooShort)]),
            .blocked
        )
        XCTAssertEqual(
            ExportSummaryLogic.nothingReadyCause(slots: [slot(0, .downloading), slot(1, .tooShort)]),
            .pendingAndBlocked
        )
    }

    func testEachCauseNamesADifferentGesture() {
        // §64 : « Remplissez au moins une case » était la réponse universelle,
        // y compris quand toutes les cases étaient REMPLIES mais non prêtes —
        // le mauvais geste. Chaque cause nomme désormais le sien.
        let filled = ExportSummaryLogic.nothingReadyHint(.nothingFilled)
        let pending = ExportSummaryLogic.nothingReadyHint(.pending)
        let blocked = ExportSummaryLogic.nothingReadyHint(.blocked)
        let both = ExportSummaryLogic.nothingReadyHint(.pendingAndBlocked)

        XCTAssertTrue(filled.contains("Remplissez"), filled)
        XCTAssertTrue(pending.contains("attendez"), pending)
        XCTAssertFalse(pending.contains("Remplissez"), pending)
        XCTAssertTrue(blocked.contains("remplacez"), blocked)
        XCTAssertTrue(both.contains("attendez") && both.contains("remplacez"), both)

        // Quatre gestes, quatre phrases distinctes — écran ET VoiceOver.
        let hints = [filled, pending, blocked, both]
        XCTAssertEqual(Set(hints).count, hints.count, "Deux causes partagent le même message")
        let shortHints = [
            ExportSummaryLogic.nothingReadyShortHint(.nothingFilled),
            ExportSummaryLogic.nothingReadyShortHint(.pending),
            ExportSummaryLogic.nothingReadyShortHint(.blocked),
            ExportSummaryLogic.nothingReadyShortHint(.pendingAndBlocked)
        ]
        XCTAssertEqual(Set(shortHints).count, shortHints.count)
        for shortHint in shortHints {
            // Hint d'un bouton (§39) : une phrase, pas un paragraphe.
            XCTAssertLessThan(shortHint.count, 100, shortHint)
        }
    }

    func testDurationUsesHundredthsOfADisplayRoundingOnly() {
        // 8,431764 s (exemple §9) → « 8,43 s » : le centième est une
        // précision d'AFFICHAGE, jamais réinjectée dans un calcul.
        let duration = MediaTime(ticks: 505_906) // 8,4317666… s
        XCTAssertEqual(ExportSummaryLogic.durationLabel(duration), "8,43 s")
    }

    func testDurationOfOneMinuteOrMoreUsesTimestampForm() {
        // Au-delà d'une minute, « 184,32 s » serait illisible : forme
        // horodatée §9 « mm:ss,cc ».
        let ninetySeconds = MediaTime(ticks: 60_000 * 90)
        XCTAssertEqual(ExportSummaryLogic.durationLabel(ninetySeconds), "01:30,00")
        XCTAssertEqual(
            ExportSummaryLogic.plansAndDurationLabel(slotCount: 150, duration: ninetySeconds),
            "150 plans • 01:30,00"
        )

        // Juste en dessous d'une minute : forme courte conservée.
        let justUnderOneMinute = MediaTime(ticks: 60_000 * 60 - 1)
        XCTAssertEqual(ExportSummaryLogic.durationLabel(justUnderOneMinute), "60,00 s")
    }

    // MARK: - VoiceOver (§39)

    func testSpokenSummaryReplacesSymbolsWithWords() {
        // §39 : « × » et « • » ne se lisent pas — VoiceOver reçoit des mots.
        let spoken = ExportSummaryLogic.spokenSummary(
            width: 2160,
            height: 3840,
            frameRate: 29.97,
            isHDR: false,
            slotCount: 12,
            duration: MediaTime(ticks: 1_105_800)
        )

        XCTAssertTrue(spoken.contains("2160 par 3840"), spoken)
        XCTAssertTrue(spoken.contains("Vertical"), spoken)
        XCTAssertTrue(spoken.contains("29,97 images par seconde"), spoken)
        XCTAssertTrue(spoken.contains("SDR"), spoken)
        XCTAssertTrue(spoken.contains("12 plans"), spoken)
        // Forme parlée d'une durée (§39) : « 18 virgule 43 secondes ».
        XCTAssertTrue(spoken.contains("18 virgule 43 secondes"), spoken)
        XCTAssertFalse(spoken.contains("×"), spoken)
        XCTAssertFalse(spoken.contains("•"), spoken)
    }

    func testSpokenEssentialsStillAnnouncePlansAndDuration() {
        // §56 : profil technique indisponible → l'essentiel reste dit.
        let spoken = ExportSummaryLogic.spokenEssentials(
            slotCount: 1,
            duration: MediaTime(ticks: 72_000)
        )
        XCTAssertTrue(spoken.contains("1 plan"), spoken)
        XCTAssertTrue(spoken.contains("1 virgule 20 seconde"), spoken)
    }

    // MARK: - Progression (§58)

    func testPercentLabelIsAnIntegerBoundedToZeroHundred() {
        XCTAssertEqual(ExportSummaryLogic.percentLabel(0), "0 %")
        XCTAssertEqual(ExportSummaryLogic.percentLabel(0.5), "50 %")
        XCTAssertEqual(ExportSummaryLogic.percentLabel(1), "100 %")
        // Bornes : une valeur hors 0…1 (rappel tardif, arrondi flottant) ne
        // produit jamais « -12 % » ni « 180 % ».
        XCTAssertEqual(ExportSummaryLogic.percentLabel(-0.4), "0 %")
        XCTAssertEqual(ExportSummaryLogic.percentLabel(1.8), "100 %")
    }

    func testPercentLabelRoundsToTheNearestInteger() {
        XCTAssertEqual(ExportSummaryLogic.percentLabel(0.126), "13 %")
        XCTAssertEqual(ExportSummaryLogic.percentLabel(0.994), "99 %")
    }

    func testPercentLabelNeverShowsAFabricatedValueForANonFiniteProgress() {
        // Progression non finie (jamais attendue) : 0 %, pas « nan % ».
        XCTAssertEqual(ExportSummaryLogic.percentLabel(.nan), "0 %")
        XCTAssertEqual(ExportSummaryLogic.percentLabel(.infinity), "0 %")
    }

    // MARK: - Espace insuffisant (§57, §66)

    func testStorageMessageStatesRequiredAndAvailableSizesAndWhatToDo() {
        // §57 : « refuser proprement si insuffisant » — le message dit la
        // taille attendue, l'espace restant, et ce qu'il faut faire.
        let required: Int64 = 3_000_000_000
        let available: Int64 = 900_000_000
        let message = ExportSummaryLogic.storageMessage(
            requiredBytes: required,
            availableBytes: available
        )

        XCTAssertTrue(message.contains(ExportSummaryLogic.byteCountString(required)), message)
        XCTAssertTrue(message.contains(ExportSummaryLogic.byteCountString(available)), message)
        XCTAssertTrue(message.contains("Libérez de l'espace"), message)
        // §57 : « ne pas supprimer le projet » — c'est dit à l'utilisateur.
        XCTAssertTrue(message.contains("Votre projet est conservé"), message)
    }

    func testByteCountStringClampsNegativeValues() {
        // Valeur négative (jamais attendue) : jamais « -1 Mo » affiché.
        XCTAssertEqual(
            ExportSummaryLogic.byteCountString(-1_000_000),
            ExportSummaryLogic.byteCountString(0)
        )
        XCTAssertFalse(ExportSummaryLogic.byteCountString(-1_000_000).contains("-"))
    }

    // MARK: - Fichier conservé (§66, §40)

    func testFileKeptMessagesAlwaysSayTheFileIsKept() {
        // §66 : « Photos refusé : conserver temporairement l'export et
        // proposer d'autoriser l'accès ou partager via feuille système ».
        let denied = ExportSummaryLogic.fileKeptMessage(.photosDenied)
        XCTAssertTrue(denied.contains("conservé"), denied)
        XCTAssertTrue(denied.contains("Réglages"), denied)
        XCTAssertTrue(denied.contains("partagez"), denied)

        // Échec d'écriture (photothèque pleine…) : les Réglages n'y
        // changeraient rien — ils ne sont donc pas proposés.
        let failed = ExportSummaryLogic.fileKeptMessage(.photosFailed)
        XCTAssertTrue(failed.contains("conservé"), failed)
        XCTAssertTrue(failed.contains("partagez"), failed)
        XCTAssertFalse(failed.contains("Réglages"), failed)
    }

    // MARK: - Messages d'erreur (§64, §66)

    func testErrorMessageUsesTheLocalizedDescriptionOfAnExportError() throws {
        // §64 : le message d'`ExportError` est déjà rédigé pour l'utilisateur
        // et dit quoi faire — l'écran ne le reformule pas.
        let error = ExportError.emptyPrefix
        let description = try XCTUnwrap(error.errorDescription)
        XCTAssertEqual(ExportSummaryLogic.message(for: error), description)
        // §66 : la raison du refus est DITE, jamais un écran muet — et elle
        // doit nommer le geste RÉELLEMENT attendu. Depuis l'écart produit,
        // n'importe quelle case suffit à débloquer l'export : le message ne
        // doit donc plus désigner « la première case ».
        XCTAssertTrue(
            description.contains("au moins une case"),
            "Le refus doit nommer le geste qui débloque l'export : \(description)"
        )
        XCTAssertFalse(
            description.contains("première case"),
            "Formulation périmée (préfixe) : n'importe quelle case débloque l'export — \(description)"
        )
    }

    func testUnknownErrorFallsBackOnANeutralInterruptionMessage() {
        struct OpaqueError: Error {}
        XCTAssertEqual(
            ExportSummaryLogic.message(for: OpaqueError()),
            ExportSummaryLogic.genericInterruptionMessage
        )
        // §66 : « interruption : projet intact » — le repli le dit.
        XCTAssertTrue(ExportSummaryLogic.genericInterruptionMessage.contains("intact"))
    }

    // MARK: - Arrière-plan (§8.1)

    func testBackgroundInterruptionIsAnnouncedAsAnInterruptionNeverASuccess() {
        // §8.1 : « ne jamais annoncer un export réussi avant confirmation
        // effective » ; §58 : « annoncer l'interruption et permettre de
        // recommencer ».
        let message = ExportSummaryLogic.backgroundInterruptionMessage
        XCTAssertTrue(message.contains("interrompu"), message)
        XCTAssertTrue(message.contains("recommencer"), message)
        XCTAssertTrue(message.contains("intact"), message)
        XCTAssertFalse(message.lowercased().contains("réussi"), message)

        // §8.1 : la consigne affichée pendant l'encodage.
        XCTAssertEqual(
            ExportSummaryLogic.keepAppOpenNotice,
            "Gardez l'application ouverte pendant l'export."
        )
    }

    // MARK: - Phases terminales (§57, §58, §66)

    func testTerminalPhaseDistinguishesCancellationStorageAndFailure() {
        // Chemin unique partagé par le refus de démarrage et par l'issue de
        // l'encodage : les deux ne peuvent pas diverger.
        XCTAssertEqual(ExportSummaryLogic.terminalPhase(for: .cancelled), .cancelled)

        XCTAssertEqual(
            ExportSummaryLogic.terminalPhase(
                for: .insufficientStorage(requiredBytes: 42, availableBytes: 7)
            ),
            .insufficientStorage(requiredBytes: 42, availableBytes: 7)
        )

        // §66 (relu par l'écart produit : aucune case prête → rien à
        // exporter) — un démarrage refusé est ANNONCÉ, jamais confondu avec
        // un succès antérieur.
        XCTAssertEqual(
            ExportSummaryLogic.terminalPhase(for: .emptyPrefix),
            .failed(message: ExportSummaryLogic.message(for: ExportError.emptyPrefix))
        )
    }

    // MARK: - Issue disponible : export récent vs export RESTAURÉ (§60, §8.1)

    func testRestoredExportIsAnnouncedDifferentlyFromAFreshOne() {
        // §60 : après relance, le fichier d'`exports/` est retrouvé et
        // reproposé (partage §66, Photos §40/§55). §8.1 interdit qu'il soit
        // annoncé comme un export qui vient d'aboutir : titre ET message
        // doivent différer.
        XCTAssertEqual(ExportSummaryLogic.readyTitle(origin: .fresh), "Montage prêt")
        XCTAssertEqual(ExportSummaryLogic.readyTitle(origin: .restored), "Montage déjà exporté")
        XCTAssertNotEqual(
            ExportSummaryLogic.readyTitle(origin: .restored),
            ExportSummaryLogic.readyTitle(origin: .fresh),
            "Un export restauré ne porte jamais le titre d'un export qui vient de finir (§8.1)"
        )
        XCTAssertNotEqual(
            ExportSummaryLogic.readyMessage(origin: .restored),
            ExportSummaryLogic.readyMessage(origin: .fresh)
        )

        // Le message restauré SITUE l'export dans le passé — c'est ce qui
        // empêche de le lire comme une réussite immédiate.
        XCTAssertTrue(
            ExportSummaryLogic.readyMessage(origin: .restored).contains("session précédente"),
            "Le message dit que l'export date d'avant (§60)"
        )
        // Les deux messages nomment les gestes possibles (§40/§55/§66).
        for origin in [ExportSummaryLogic.ReadyOrigin.restored, .fresh] {
            let message = ExportSummaryLogic.readyMessage(origin: origin)
            XCTAssertTrue(message.contains("Photos"), "L'enregistrement dans Photos est nommé")
            XCTAssertFalse(message.isEmpty)
        }
        // Trois origines, trois icônes (§39 : l'état n'est pas porté par le
        // seul texte).
        let images = [
            ExportSummaryLogic.readySystemImage(origin: .fresh),
            ExportSummaryLogic.readySystemImage(origin: .restored),
            ExportSummaryLogic.readySystemImage(
                origin: .truncated(Self.truncatedDivergence)
            )
        ]
        XCTAssertEqual(Set(images).count, 3, "Trois origines, trois icônes")
    }

    // MARK: - §66 : export TRONQUÉ (relecture adversariale du 13 août 2026)

    /// Profil §52 de comparaison (même initialiseur que l'export : cadence
    /// normalisée, dimensions paires).
    private static func profile(width: Int, height: Int, frameRate: Double, isHDR: Bool) -> MasterProfile {
        MasterProfile(
            renderWidth: width,
            renderHeight: height,
            frameRate: frameRate,
            isHDR: isHDR
        )
    }

    /// Écart type : 19 plans annoncés, 12 écrits (un rush devenu indisponible
    /// pendant l'encodage §66).
    private static let truncatedDivergence = ExportSummaryLogic.ExportDivergence(
        announcedSlotCount: 19,
        producedSlotCount: 12,
        announcedDuration: MediaTime(ticks: 60_000 * 19),
        producedDuration: MediaTime(ticks: 60_000 * 12),
        announcedProfile: nil,
        producedProfile: nil
    )

    func testNoDivergenceWhenTheFileMatchesWhatWasAnnounced() {
        // Cas NORMAL : ce qui a été annoncé a été écrit — aucun écart, donc
        // aucun message d'alerte (l'export est un succès plein).
        XCTAssertNil(
            ExportSummaryLogic.divergence(
                announcedSlotCount: 19,
                announcedDuration: MediaTime(ticks: 570_000),
                announcedProfile: nil,
                producedSlotCount: 19,
                producedDuration: MediaTime(ticks: 570_000),
                producedProfile: nil
            )
        )
    }

    func testATruncatedExportIsDetectedOnPlanCountAndDuration() {
        // §66 « asset en téléchargement : export limité avant lui » : le
        // fichier contient MOINS que ce qui a été validé — c'est mesurable, et
        // c'est mesuré.
        let divergence = ExportSummaryLogic.divergence(
            announcedSlotCount: 19,
            announcedDuration: MediaTime(ticks: 570_000),
            announcedProfile: nil,
            producedSlotCount: 12,
            producedDuration: MediaTime(ticks: 360_000),
            producedProfile: nil
        )
        XCTAssertNotNil(divergence)
        XCTAssertTrue(divergence?.hasFewerSlots ?? false)
        XCTAssertTrue(divergence?.hasDifferentDuration ?? false)
        XCTAssertFalse(divergence?.hasDifferentProfile ?? true, "Aucun profil connu : rien à comparer")
    }

    func testADifferentProfileAloneIsAlreadyADivergence() {
        // §52/§56 : la ligne technique annoncée décrivait le montage complet.
        // Si le clip maître retenu change, le fichier n'a plus la résolution
        // promise — même avec le bon nombre de plans.
        let announced = Self.profile(width: 2160, height: 3840, frameRate: 60, isHDR: true)
        let produced = Self.profile(width: 1080, height: 1920, frameRate: 30, isHDR: false)
        let divergence = ExportSummaryLogic.divergence(
            announcedSlotCount: 19,
            announcedDuration: MediaTime(ticks: 570_000),
            announcedProfile: announced,
            producedSlotCount: 19,
            producedDuration: MediaTime(ticks: 570_000),
            producedProfile: produced
        )
        XCTAssertNotNil(divergence)
        XCTAssertFalse(divergence?.hasFewerSlots ?? true)
        XCTAssertTrue(divergence?.hasDifferentProfile ?? false)
    }

    func testAnUnknownProducedProfileNeverInventsADivergence() {
        // On ne compare jamais l'annonce à une valeur inconnue : un profil
        // « différent » inventé serait exactement le mensonge que ce correctif
        // supprime.
        XCTAssertNil(
            ExportSummaryLogic.divergence(
                announcedSlotCount: 5,
                announcedDuration: MediaTime(ticks: 300_000),
                announcedProfile: Self.profile(width: 1080, height: 1920, frameRate: 30, isHDR: false),
                producedSlotCount: 5,
                producedDuration: MediaTime(ticks: 300_000),
                producedProfile: nil
            )
        )
    }

    func testTruncatedMessageSaysWhatWasWrittenWhyAndWhatToDo() {
        // §66 + §8.1 : les trois informations, dans cet ordre. Le fichier
        // n'est jamais présenté comme perdu, et le projet est dit intact.
        let message = ExportSummaryLogic.truncatedExportMessage(Self.truncatedDivergence)

        // 1. Ce qui a été écrit, et ce qui avait été annoncé.
        XCTAssertTrue(message.contains("12 plans"), message)
        XCTAssertTrue(message.contains("19 plans"), message)
        // 2. Pourquoi.
        XCTAssertTrue(message.contains("indisponible"), message)
        // 3. Quoi faire.
        XCTAssertTrue(message.contains("relancez l'export"), message)
        XCTAssertTrue(message.contains("intact"), message)
        // §8.1 : jamais présenté comme un succès plein.
        XCTAssertFalse(message.lowercased().contains("votre montage est exporté"), message)
    }

    func testTruncatedMessageNamesBothProfilesWhenTheyDiffer() {
        let announced = Self.profile(width: 2160, height: 3840, frameRate: 60, isHDR: true)
        let produced = Self.profile(width: 1080, height: 1920, frameRate: 30, isHDR: false)
        let divergence = ExportSummaryLogic.ExportDivergence(
            announcedSlotCount: 19,
            producedSlotCount: 19,
            announcedDuration: MediaTime(ticks: 570_000),
            producedDuration: MediaTime(ticks: 570_000),
            announcedProfile: announced,
            producedProfile: produced
        )
        let message = ExportSummaryLogic.truncatedExportMessage(divergence)

        XCTAssertTrue(message.contains("1080 × 1920"), message)
        XCTAssertTrue(message.contains("2160 × 3840"), message)
        XCTAssertTrue(message.contains("HDR"), message)
        XCTAssertTrue(message.contains("SDR"), message)
        // Aucun plan perdu : le geste proposé n'est pas « attendre le retour
        // d'une vidéo », c'est simplement de pouvoir relancer.
        XCTAssertFalse(message.contains("de nouveau disponible"), message)
        // …et rien ne compare « 19 plans » à « 19 plans » : la phrase qui n'a
        // rien à dire n'est pas écrite.
        XCTAssertFalse(message.contains("au lieu des"), message)
        // « Incomplet » serait faux : aucun plan ne manque.
        XCTAssertEqual(
            ExportSummaryLogic.readyTitle(origin: .truncated(divergence)),
            "Export différent de l'annonce"
        )
    }

    func testATruncatedExportIsNeverAnnouncedAsAFullSuccess() {
        // LE défaut corrigé : la phase `ready` disait « Votre montage est
        // exporté. » quel que soit le contenu du fichier.
        let origin = ExportSummaryLogic.ReadyOrigin.truncated(Self.truncatedDivergence)

        XCTAssertEqual(ExportSummaryLogic.readyTitle(origin: origin), "Export incomplet")
        XCTAssertNotEqual(
            ExportSummaryLogic.readyTitle(origin: origin),
            ExportSummaryLogic.readyTitle(origin: .fresh)
        )
        XCTAssertNotEqual(
            ExportSummaryLogic.readyMessage(origin: origin),
            ExportSummaryLogic.freshReadyMessage
        )
        XCTAssertFalse(origin.isRestored, "Un export tronqué vient bien de se terminer (§60)")
    }

    func testTechnicalSummaryReadsLikeTheSummaryBlock() {
        // §56 : la même façon de dire un profil, en une ligne — pour comparer
        // deux profils dans une phrase sans inventer un second vocabulaire.
        XCTAssertEqual(
            ExportSummaryLogic.technicalSummary(
                Self.profile(width: 2160, height: 3840, frameRate: 60, isHDR: false)
            ),
            "2160 × 3840 • Vertical • 60 i/s • SDR"
        )
    }
}
