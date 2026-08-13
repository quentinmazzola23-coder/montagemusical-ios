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
//  - ÉCART PRODUIT (11 août 2026) : plage des plans exportés
//    (« Plans 28 à 50 », « Plan 28 » au singulier) — l'export porte sur le
//    SEGMENT continu rempli, où qu'il commence : le résumé §56 doit dire
//    LESQUELS partent, pas seulement combien.
//
//  Le calcul des dimensions orientées d'un rush a DISPARU avec le calcul de
//  profil propre à la vue (Jalon 10) : le profil §52 vient désormais d'une
//  source unique, `ProjectExporter.masterProfile(project:)` — plus rien à
//  tester ici de ce côté.
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

    // MARK: - Plage des plans exportés (écart produit du 11 août 2026)

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

    func testPlanRangeAndCountDescribeTheSameSegment() {
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

    func testPartialExportNoticeSaysNothingIsMovedNorLost() {
        // §51 : « les clips ultérieurs ne sont jamais déplacés » ; §89 :
        // « elle déplace des plans après un trou » est une régression
        // interdite — l'écart produit ne change rien à cela, et le message
        // le dit.
        let notice = ExportSummaryLogic.partialExportNotice
        XCTAssertTrue(notice.contains("conservé"), notice)
        XCTAssertTrue(notice.contains("déplacé"), notice)
        // Le texte ne promet plus que l'export commence au DÉBUT du projet.
        XCTAssertFalse(notice.contains("Seul le début"), notice)
    }

    func testNothingReadyMessagesNameTheGestureThatUnblocksTheExport() {
        // §66 relu par l'écart produit : n'importe quelle case remplie suffit
        // — ce n'est plus « la première » qu'il faut nommer.
        XCTAssertTrue(ExportSummaryLogic.nothingReadyTitle.contains("Aucun plan"))
        XCTAssertTrue(
            ExportSummaryLogic.nothingReadyHint.contains("au moins une case"),
            ExportSummaryLogic.nothingReadyHint
        )
        XCTAssertFalse(
            ExportSummaryLogic.nothingReadyHint.contains("première case"),
            ExportSummaryLogic.nothingReadyHint
        )
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
        // doit nommer le geste RÉELLEMENT attendu. Depuis l'écart produit du
        // 11 août 2026, n'importe quelle case suffit à débloquer l'export :
        // le message ne doit donc plus désigner « la première case ».
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
        XCTAssertEqual(ExportSummaryLogic.readyTitle(isRestored: false), "Montage prêt")
        XCTAssertEqual(ExportSummaryLogic.readyTitle(isRestored: true), "Montage déjà exporté")
        XCTAssertNotEqual(
            ExportSummaryLogic.readyTitle(isRestored: true),
            ExportSummaryLogic.readyTitle(isRestored: false),
            "Un export restauré ne porte jamais le titre d'un export qui vient de finir (§8.1)"
        )
        XCTAssertNotEqual(
            ExportSummaryLogic.readyMessage(isRestored: true),
            ExportSummaryLogic.readyMessage(isRestored: false)
        )

        // Le message restauré SITUE l'export dans le passé — c'est ce qui
        // empêche de le lire comme une réussite immédiate.
        XCTAssertTrue(
            ExportSummaryLogic.readyMessage(isRestored: true).contains("session précédente"),
            "Le message dit que l'export date d'avant (§60)"
        )
        // Les deux messages nomment les gestes possibles (§40/§55/§66).
        for isRestored in [true, false] {
            let message = ExportSummaryLogic.readyMessage(isRestored: isRestored)
            XCTAssertTrue(message.contains("Photos"), "L'enregistrement dans Photos est nommé")
            XCTAssertFalse(message.isEmpty)
        }
    }
}
