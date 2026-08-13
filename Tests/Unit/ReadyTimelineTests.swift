//
//  ReadyTimelineTests.swift
//  MontageMusicalTests
//
//  Timeline exportable — CHANGEMENT PRODUIT qui remplace le « segment
//  exportable » (lui-même successeur du « préfixe exportable » §51). Contrat
//  complet en tête de `ExportModels.swift`.
//
//  Remplace `ReadySegmentTests.swift`. Le bloc §70 « Préfixe exportable » est
//  conservé cas par cas (toutes remplies ; première vide ; trou au milieu ;
//  asset downloading ; asset unavailable ; cases remplies après le trou non
//  déplacées), mais DEUX verdicts sont désormais inversés :
//
//      §51    : première case vide → aucun export possible.
//      Étape 1: première case vide → le PREMIER segment prêt EST le montage.
//      Étape 2: première case vide → toutes les zones remplies sont
//               exportées, CONCATÉNÉES ; les cases vides sont supprimées,
//               vidéo ET musique.
//
//  S'y ajoutent les cas propres à la concaténation : plusieurs runs (aucune
//  zone remplie n'est abandonnée), position de composition cumulée, durée =
//  SOMME des durées des cases prêtes, continuité à l'intérieur d'un run et
//  absence de trou aux jonctions — le tout en TICKS exacts, sans AVFoundation.
//
//  DEUX EXIGENCES DE MÉTHODE, tirées d'une relecture adversariale :
//
//  1. **On teste ce que la PRODUCTION appelle.** L'export et l'aperçu
//     consomment `ReadyTimeline.placements` / `.musicInsertions` : ce sont
//     donc ELLES qui sont vérifiées ici, avec des littéraux calculés à la
//     main — pas seulement `compositionStart(of:)`, qui n'en est qu'une
//     lecture ponctuelle.
//  2. **Les fixtures ont des durées INÉGALES.** Un montage où toutes les
//     cases durent 30 000 ticks masque toute erreur de cumul (décaler d'une
//     case ou d'un run donne le même résultat qu'un cumul correct dans trop de
//     cas). Les cases PAIRES durent ici 30 000 ticks et les IMPAIRES 20 000.
//

import XCTest
@testable import MontageMusical

final class ReadyTimelineTests: XCTestCase {

    // MARK: - Helper

    /// Fabrique une case snapshot. `status == nil` produit une case vide
    /// (aucune association).
    private func makeSlot(
        index: Int,
        startTicks: Int64,
        endTicks: Int64,
        status: ClipAssignmentStatus? = .ready
    ) -> ProjectSlot {
        let assignment: ClipAssignmentSnapshot? = status.map { status in
            ClipAssignmentSnapshot(
                id: UUID(),
                assetLocalIdentifier: "asset-\(index)",
                status: status
            )
        }
        return ProjectSlot(
            id: UUID(),
            index: index,
            start: MediaTime(ticks: startTicks),
            end: MediaTime(ticks: endTicks),
            assignment: assignment
        )
    }

    /// Durée d'une case du montage de référence, en ticks (§9) : **30 000
    /// (0,5 s) pour un index PAIR, 20 000 (1/3 s) pour un index IMPAIR**.
    ///
    /// Des durées INÉGALES sont indispensables : avec des cases toutes égales,
    /// un cumul décalé d'une case — ou d'un run entier — produit très souvent
    /// la même valeur qu'un cumul correct, et le test reste vert.
    private static func durationTicks(ofSlotAt index: Int) -> Int64 {
        index.isMultiple(of: 2) ? 30_000 : 20_000
    }

    /// Début ABSOLU de la case `index` : les cases pavent la musique sans trou
    /// (§28.1), donc `start(i) = somme des durées des cases précédentes`. Une
    /// PAIRE de cases (une paire + une impaire) dure 50 000 ticks, d'où
    /// `start(i) = (i / 2) × 50 000 (+ 30 000 si i est impair)`.
    private static func startTicks(ofSlotAt index: Int) -> Int64 {
        Int64(index / 2) * 50_000 + (index.isMultiple(of: 2) ? 0 : 30_000)
    }

    /// Montage de `count` cases JOINTIVES aux durées inégales ci-dessus,
    /// pavant la musique sans trou (§28.1). `readyIndexes` dit lesquelles sont
    /// prêtes ; les autres sont VIDES.
    private func makeMontage(count: Int, ready readyIndexes: Set<Int>) -> [ProjectSlot] {
        (0..<count).map { index in
            makeSlot(
                index: index,
                startTicks: Self.startTicks(ofSlotAt: index),
                endTicks: Self.startTicks(ofSlotAt: index) + Self.durationTicks(ofSlotAt: index),
                status: readyIndexes.contains(index) ? ClipAssignmentStatus.ready : nil
            )
        }
    }

    // MARK: - Aucune case prête → timeline vide (export désactivé)

    func testNoReadySlotReturnsAnEmptyTimeline() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: .downloading),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000, status: .unavailable)
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertTrue(timeline.isEmpty)
        XCTAssertTrue(timeline.runs.isEmpty)
        XCTAssertEqual(timeline.slotCount, 0)
        XCTAssertEqual(timeline.duration, .zero)
        XCTAssertTrue(timeline.allSlots.isEmpty)
        XCTAssertEqual(timeline, ReadyTimeline.empty)
    }

    func testProjectWithoutSlotsReturnsAnEmptyTimeline() {
        XCTAssertEqual(readyTimeline(slots: []), ReadyTimeline.empty)
        XCTAssertTrue(ReadyTimeline.empty.isEmpty)
        XCTAssertEqual(ReadyTimeline.empty.duration, .zero)
    }

    /// Un run VIDE est impossible par construction : c'est ce qui rend
    /// `musicStart` / `startIndex` non optionnels.
    func testAnEmptyRunCannotBeBuilt() {
        XCTAssertNil(ReadyRun(slots: []))
    }

    // MARK: - §70 : toutes remplies → UN SEUL run

    func testAllSlotsReadyProduceASingleRun() throws {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertEqual(timeline.runs.count, 1, "aucun trou → une seule zone remplie")
        let run = try XCTUnwrap(timeline.runs.first)
        // Égalité complète des structs : les cases retournées conservent
        // leurs temps absolus (aucun recompactage possible).
        XCTAssertEqual(run.slots, slots)
        XCTAssertEqual(run.startIndex, 0)
        XCTAssertEqual(run.endIndex, 2)
        XCTAssertEqual(run.musicStart, MediaTime(ticks: 0))
        XCTAssertEqual(run.musicEnd, MediaTime(ticks: 150_000))
        // Montage sans trou : la durée vaut la fin absolue — c'est l'ancien
        // comportement §51, conservé quand TOUTES les cases sont prêtes.
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 150_000))
        XCTAssertEqual(timeline.slotCount, 3)
        XCTAssertEqual(timeline.allSlots, slots)

        // La propriété du snapshot délègue au même algorithme.
        let snapshot = ProjectSnapshot(projectID: UUID(), slots: slots, geometry: nil)
        XCTAssertEqual(snapshot.readyTimeline.allSlots.map(\.id), slots.map(\.id))
    }

    // MARK: - §70 « première vide » — la timeline commence au PREMIER RUN

    /// LE comportement du premier écart produit, CONSERVÉ : la case 0 est
    /// vide, les cases 1 à 3 sont prêtes → le montage commence à la case 1 et
    /// tombe à l'instant `.zero` de la composition.
    func testFirstSlotEmptyMakesTheTimelineStartAtTheFirstRun() throws {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000),
            makeSlot(index: 3, startTicks: 150_000, endTicks: 200_000)
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertFalse(timeline.isEmpty, "une première case vide n'interdit plus l'export")
        XCTAssertEqual(timeline.runs.count, 1)
        let run = try XCTUnwrap(timeline.runs.first)
        XCTAssertEqual(run.slots, [slots[1], slots[2], slots[3]])
        XCTAssertEqual(run.startIndex, 1)
        XCTAssertEqual(run.musicStart, MediaTime(ticks: 45_000), "le montage ne commence plus à 0")
        // La case 0 n'est PAS exportée, et aucune case n'a été déplacée pour
        // combler son absence : temps ABSOLUS intacts.
        XCTAssertFalse(timeline.allSlots.contains { $0.id == slots[0].id })
        XCTAssertEqual(timeline.allSlots.map(\.start.ticks), [45_000, 90_000, 150_000])
        // Le premier plan ouvre le montage.
        XCTAssertEqual(timeline.compositionStart(of: slots[1]), MediaTime.zero)
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 155_000))
    }

    // MARK: - FORME DE L'EXEMPLE DE L'UTILISATEUR : 8 plans + 4 trous + 11 plans

    /// 51 cases jointives aux durées INÉGALES (30 000 ticks si l'index est
    /// pair, 20 000 s'il est impair), cases d'INDEX 28…35 et 40…50 prêtes,
    /// cases d'index 36…39 VIDES.
    ///
    /// NUMÉROTATION (convention en tête d'ExportModels.swift) : ces nombres
    /// sont des **index 0-based**, pas les numéros de plan affichés. La
    /// fixture reproduit la FORME de l'exemple de la demande — 8 plans, 4
    /// cases vides, 11 plans — avec des valeurs calculées à la main sur des
    /// durées inégales ; à l'écran, ces cases s'annoncent « plans 29 à 36 » et
    /// « plans 41 à 51 » (index + 1, §35.1). L'exemple de la demande lui-même
    /// (« plans 28 à 35 et 40 à 50 ») porte sur les index 27…34 et 39…49 : le
    /// décalage d'un index est SANS effet sur ce qui est vérifié ici (runs,
    /// concaténation, durées), et le conserver évite de réécrire des dizaines
    /// de littéraux calculés à la main.
    ///
    /// Valeurs calculées à la main (60 000 ticks/s, §9) — une paire de cases
    /// consécutives dure 50 000 ticks, donc `start(i) = (i / 2) × 50 000`
    /// (+ 30 000 si `i` est impair) :
    /// - run 1 : cases 28…35, 8 plans, `musicStart` = 14 × 50 000 = 700 000,
    ///   `musicEnd` = 18 × 50 000 = 900 000, durée = 4 × 30 000 + 4 × 20 000
    ///   = 200 000 ;
    /// - run 2 : cases 40…50, 11 plans, `musicStart` = 20 × 50 000 =
    ///   1 000 000, `musicEnd` = 1 250 000 + 30 000 = 1 280 000, durée =
    ///   6 × 30 000 + 5 × 20 000 = 280 000 ;
    /// - montage = 19 plans, durée = 200 000 + 280 000 = **480 000 ticks** ;
    /// - la portion de musique des cases 36…39 (2 × 30 000 + 2 × 20 000 =
    ///   100 000 ticks) N'EXISTE PAS dans le fichier exporté — et
    ///   480 000 + 100 000 = 580 000 = 1 280 000 − 700 000, ce qui referme le
    ///   compte.
    private var montageWithTwoRuns: [ProjectSlot] {
        makeMontage(count: 51, ready: Set(28...35).union(Set(40...50)))
    }

    func testTwoRunsAreBothExportedAndConcatenated() throws {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        XCTAssertEqual(timeline.runs.count, 2, "les DEUX zones remplies sont exportées")
        XCTAssertEqual(timeline.runs[0].slots.map(\.index), Array(28...35))
        XCTAssertEqual(timeline.runs[1].slots.map(\.index), Array(40...50))
        XCTAssertEqual(timeline.runs[0].slotCount, 8)
        XCTAssertEqual(timeline.runs[1].slotCount, 11)
        // Bornes musicales ABSOLUES des deux zones, calculées à la main.
        XCTAssertEqual(timeline.runs[0].musicStart, MediaTime(ticks: 700_000))
        XCTAssertEqual(timeline.runs[0].musicEnd, MediaTime(ticks: 900_000))
        XCTAssertEqual(timeline.runs[1].musicStart, MediaTime(ticks: 1_000_000))
        XCTAssertEqual(timeline.runs[1].musicEnd, MediaTime(ticks: 1_280_000))
        // Nombre TOTAL de plans exportés — 8 + 11, la forme de l'exemple.
        XCTAssertEqual(timeline.slotCount, 19)
        XCTAssertEqual(timeline.allSlots.map(\.index), Array(28...35) + Array(40...50))
    }

    func testTwoRunsDurationIsTheSumOfTheReadySlotDurations() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        // Durée = SOMME des durées des cases prêtes, et NON
        // `dernière.end - première.start` (= 1 280 000 − 700 000 = 580 000).
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 480_000))
        XCTAssertEqual(timeline.duration.ticks, 10 * 30_000 + 9 * 20_000)
        XCTAssertNotEqual(
            timeline.duration,
            MediaTime(ticks: 1_280_000 - 700_000),
            "les 4 cases vides (100 000 ticks) sont SUPPRIMÉES, musique comprise"
        )
        // Contrôle direct : la somme des durées de chaque case exportée.
        let summedTicks = timeline.allSlots.reduce(Int64(0)) { $0 + $1.duration.ticks }
        XCTAssertEqual(timeline.duration.ticks, summedTicks)
    }

    func testSecondRunStartsRightAfterTheFirstOne() throws {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        // Position du run 2 = somme des durées des cases du run 1 (200 000),
        // et NON l'écart musical entre les deux zones (300 000).
        XCTAssertEqual(timeline.compositionStart(ofRun: 0), .zero)
        XCTAssertEqual(timeline.compositionStart(ofRun: 1), MediaTime(ticks: 200_000))
        XCTAssertEqual(timeline.compositionStart(ofRun: 1).ticks, 4 * 30_000 + 4 * 20_000)
        // `runStarts` fait le même calcul en un parcours : c'est lui qu'utilise
        // l'assemblage, il ne doit jamais diverger.
        XCTAssertEqual(timeline.runStarts, [MediaTime(ticks: 0), MediaTime(ticks: 200_000)])

        // Bornes hors plage : jamais de valeur inventée.
        XCTAssertEqual(timeline.compositionStart(ofRun: -1), .zero)
        XCTAssertEqual(timeline.compositionStart(ofRun: 2), timeline.duration)
    }

    func testCompositionStartOfTheUserExampleSlots() throws {
        let slots = montageWithTwoRuns
        let timeline = readyTimeline(slots: slots)

        // Première case du montage : instant zéro.
        XCTAssertEqual(timeline.compositionStart(of: slots[28]), MediaTime.zero)
        // Dernière case du run 1 : 200 000 − 20 000 (sa propre durée).
        XCTAssertEqual(timeline.compositionStart(of: slots[35]), MediaTime(ticks: 180_000))
        // Première case du run 2 : elle suit IMMÉDIATEMENT la case 35.
        XCTAssertEqual(timeline.compositionStart(of: slots[40]), MediaTime(ticks: 200_000))
        // Dernière case : 480 000 − 30 000 (sa propre durée).
        XCTAssertEqual(timeline.compositionStart(of: slots[50]), MediaTime(ticks: 450_000))

        // Fin du dernier plan == durée du montage : aucune dérive cumulative
        // après 19 cases et une jonction (§9, ticks entiers).
        let lastStart = try XCTUnwrap(timeline.compositionStart(of: slots[50]))
        XCTAssertEqual(lastStart + slots[50].duration, timeline.duration)
    }

    // MARK: - LE calcul du produit : `placements` et `musicInsertions`

    /// **Le test qui manquait.** L'export (`ProjectExporter.assemble`) et
    /// l'aperçu (`PreviewBuilder.makeTimelineComposition`) ne consomment plus
    /// `compositionStart(of:)` case par case : ils lisent `placements`. C'est
    /// donc cette liste — dans son ORDRE et dans ses VALEURS — qui doit être
    /// vérifiée, sans quoi un décalage d'un run entier passerait inaperçu.
    ///
    /// Les 19 positions sont écrites en toutes lettres, cumulées à la main :
    /// run 1 depuis 0, run 2 depuis 200 000, en alternant 30 000 et 20 000.
    func testPlacementsGiveEveryHandComputedPosition() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        let placements = timeline.placements

        XCTAssertEqual(placements.count, 19)
        XCTAssertEqual(placements.map(\.slot.index), Array(28...35) + Array(40...50))
        XCTAssertEqual(placements.map(\.compositionStart.ticks), [
            // Run 1 (cases 28…35) : 30 000 / 20 000 en alternance depuis 0.
            0, 30_000, 50_000, 80_000, 100_000, 130_000, 150_000, 180_000,
            // Run 2 (cases 40…50) : reprise à 200 000, jamais à 300 000
            // (l'écart musical des cases vides est SUPPRIMÉ).
            200_000, 230_000, 250_000, 280_000, 300_000, 330_000, 350_000,
            380_000, 400_000, 430_000, 450_000
        ])
        XCTAssertEqual(placements.map(\.duration.ticks), [
            30_000, 20_000, 30_000, 20_000, 30_000, 20_000, 30_000, 20_000,
            30_000, 20_000, 30_000, 20_000, 30_000, 20_000, 30_000, 20_000,
            30_000, 20_000, 30_000
        ])
        // Chaque case commence là où la précédente finit, jonction comprise,
        // et la dernière ferme exactement le montage.
        XCTAssertEqual(
            placements.dropLast().map(\.compositionEnd),
            placements.dropFirst().map(\.compositionStart)
        )
        XCTAssertEqual(placements.last?.compositionEnd, timeline.duration)
        // `compositionStart(of:)` n'est qu'une lecture de cette liste.
        XCTAssertEqual(
            placements.map { timeline.compositionStart(of: $0.slot) },
            placements.map { Optional($0.compositionStart) }
        )
    }

    /// UNE portion de musique par zone remplie, avec ses bornes ABSOLUES dans
    /// le morceau et sa position dans le montage — l'autre moitié du calcul
    /// que l'export et l'aperçu consomment tels quels.
    func testMusicInsertionsAreOnePortionPerZoneWithAbsoluteSourceBounds() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        XCTAssertEqual(timeline.musicInsertions, [
            MusicInsertion(
                sourceStart: MediaTime(ticks: 700_000),   // début de la case 28
                duration: MediaTime(ticks: 200_000),      // 8 cases du run 1
                compositionStart: .zero
            ),
            MusicInsertion(
                sourceStart: MediaTime(ticks: 1_000_000), // début de la case 40
                duration: MediaTime(ticks: 280_000),      // 11 cases du run 2
                compositionStart: MediaTime(ticks: 200_000)
            )
        ])
        // Les portions sont JOINTIVES dans la composition : la musique n'a
        // aucun trou, elle SAUTE de 900 000 à 1 000 000 dans le morceau.
        XCTAssertEqual(
            timeline.musicInsertions.map { ($0.compositionStart + $0.duration).ticks },
            [200_000, 480_000]
        )
        // Une portion par run, jamais une par case.
        XCTAssertEqual(timeline.musicInsertions.count, timeline.runs.count)
    }

    /// Une case NON exportée n'a aucun instant de composition — l'appelant ne
    /// doit pas pouvoir en inventer un.
    func testCompositionStartOfANonExportedSlotIsNil() {
        let slots = montageWithTwoRuns
        let timeline = readyTimeline(slots: slots)

        XCTAssertNil(timeline.compositionStart(of: slots[0]), "case vide avant le montage")
        XCTAssertNil(timeline.compositionStart(of: slots[37]), "case vide entre deux runs")
        XCTAssertNil(
            timeline.compositionStart(
                of: makeSlot(index: 28, startTicks: 840_000, endTicks: 870_000)
            ),
            "case d'un autre montage : identité différente"
        )
    }

    // MARK: - Continuité : écarts d'origine DANS un run, aucun trou ENTRE runs

    /// À l'intérieur d'un run, l'écart entre deux cases consécutives est
    /// rigoureusement celui de la musique ; À LA JONCTION entre deux runs,
    /// l'écart musical est au contraire SUPPRIMÉ.
    ///
    /// Tout est écrit en littéraux ABSOLUS, des deux côtés. La version
    /// précédente de ce test comparait `currentStart - previousStart` à
    /// `current.start - previous.start` : la position du run s'y simplifiait
    /// des deux côtés, si bien que le test serait resté vert même avec des
    /// runs posés n'importe où.
    func testPositionsInsideARunKeepTheOriginalSpacing() {
        let slots = montageWithTwoRuns
        let timeline = readyTimeline(slots: slots)

        // Deux cases VOISINES du run 1 : mêmes 30 000 ticks d'écart dans la
        // musique (750 000 → 780 000) et dans le montage (50 000 → 80 000).
        XCTAssertEqual(slots[30].start, MediaTime(ticks: 750_000))
        XCTAssertEqual(slots[31].start, MediaTime(ticks: 780_000))
        XCTAssertEqual(timeline.compositionStart(of: slots[30]), MediaTime(ticks: 50_000))
        XCTAssertEqual(timeline.compositionStart(of: slots[31]), MediaTime(ticks: 80_000))

        // Écart INÉGAL suivant : la case 31 dure 20 000, pas 30 000.
        XCTAssertEqual(timeline.compositionStart(of: slots[32]), MediaTime(ticks: 100_000))

        // À LA JONCTION : 120 000 ticks séparent les cases 35 et 40 dans la
        // musique (880 000 → 1 000 000), 20 000 seulement dans le montage
        // (180 000 → 200 000) — c'est-à-dire la seule durée de la case 35.
        XCTAssertEqual(slots[35].start, MediaTime(ticks: 880_000))
        XCTAssertEqual(slots[40].start, MediaTime(ticks: 1_000_000))
        XCTAssertEqual(timeline.compositionStart(of: slots[35]), MediaTime(ticks: 180_000))
        XCTAssertEqual(timeline.compositionStart(of: slots[40]), MediaTime(ticks: 200_000))
    }

    /// Entre deux runs, AUCUN trou : le run suivant commence exactement là où
    /// le précédent finit — c'est ce qui garantit qu'aucun écran noir n'est
    /// ajouté et que les instructions de rendu couvrent `[0, durée]`.
    func testRunsAreJoinedWithoutAnyGap() throws {
        let timeline = readyTimeline(slots: makeMontage(
            count: 20,
            ready: Set([1, 2, 3]).union(Set([7, 8])).union(Set([15]))
        ))

        var expectedNextStart = MediaTime.zero
        for slot in timeline.allSlots {
            let start = try XCTUnwrap(timeline.compositionStart(of: slot))
            XCTAssertEqual(start, expectedNextStart, "plan \(slot.index) jointif au précédent")
            expectedNextStart = start + slot.duration
        }
        // Le dernier plan finit EXACTEMENT à la durée du montage.
        XCTAssertEqual(expectedNextStart, timeline.duration)
    }

    // MARK: - Trois runs, runs d'une seule case

    func testThreeRunsIncludingSingleSlotRuns() throws {
        // Cases prêtes : 1-2 / 5 / 9-10-11 → trois zones, dont une d'UNE case.
        let timeline = readyTimeline(slots: makeMontage(
            count: 13,
            ready: Set([1, 2]).union(Set([5])).union(Set([9, 10, 11]))
        ))

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[1, 2], [5], [9, 10, 11]])
        XCTAssertEqual(timeline.slotCount, 6)
        // 20 000 + 30 000 | 20 000 | 20 000 + 30 000 + 20 000 = 140 000.
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 140_000))
        XCTAssertEqual(timeline.runStarts.map(\.ticks), [0, 50_000, 70_000])

        // Un run d'UNE case a des bornes cohérentes.
        let single = timeline.runs[1]
        XCTAssertEqual(single.slotCount, 1)
        XCTAssertEqual(single.startIndex, 5)
        XCTAssertEqual(single.endIndex, 5)
        XCTAssertEqual(single.musicStart, MediaTime(ticks: 130_000))
        XCTAssertEqual(single.musicEnd, MediaTime(ticks: 150_000))
        XCTAssertEqual(single.duration, MediaTime(ticks: 20_000))
        XCTAssertEqual(single.offset(of: single.slots[0]), .zero)
    }

    /// DERNIÈRE case prête : le run est clos par la fin du montage, jamais
    /// perdu (c'est le cas que l'oubli d'un `flush` final ferait sauter).
    func testRunEndingOnTheLastSlotIsKept() {
        let timeline = readyTimeline(slots: makeMontage(count: 4, ready: [3]))

        XCTAssertEqual(timeline.runs.count, 1)
        XCTAssertEqual(timeline.allSlots.map(\.index), [3])
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 20_000), "case impaire")
        XCTAssertEqual(timeline.runs[0].musicStart, MediaTime(ticks: 80_000))
    }

    // MARK: - §70 : trou au milieu / cases après le trou

    /// §66 « trou au milieu » : la zone suivante n'est plus ABANDONNÉE, elle
    /// est CONCATÉNÉE — et ses cases ne sont pas déplacées d'un tick dans le
    /// montage (leurs temps musicaux restent absolus).
    func testGapInMiddleKeepsBothSidesWithoutMovingAnySlot() throws {
        let afterGapA = makeSlot(index: 3, startTicks: 120_000, endTicks: 165_000)
        let afterGapB = makeSlot(index: 4, startTicks: 165_000, endTicks: 210_000)
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil),
            afterGapA,
            afterGapB
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[0, 1], [3, 4]])
        XCTAssertEqual(timeline.slotCount, 4)
        // Durée = 45 000 + 45 000 + 45 000 + 45 000 : la case 2 (30 000 ticks)
        // est supprimée du montage, musique comprise.
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 180_000))
        // Structs d'origine intacts (index et temps absolus préservés, §3.12).
        XCTAssertEqual(timeline.runs[1].slots, [afterGapA, afterGapB])
        XCTAssertEqual(afterGapA.start, MediaTime(ticks: 120_000))
        // …mais leur POSITION dans le montage suit immédiatement la case 1.
        XCTAssertEqual(timeline.compositionStart(of: afterGapA), MediaTime(ticks: 90_000))
        XCTAssertEqual(timeline.compositionStart(of: afterGapB), MediaTime(ticks: 135_000))
    }

    // MARK: - §70 : statuts non prêts — TOUS exclus, aucun n'ouvre un run

    /// `resolving`, `downloading`, `unavailable` et `tooShort` ne sont jamais
    /// exportés : chacun FERME le run en cours, exactement comme une case vide.
    func testEveryNonReadyStatusIsExcludedAndSplitsTheTimeline() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 10_000),
            makeSlot(index: 1, startTicks: 10_000, endTicks: 20_000, status: .resolving),
            makeSlot(index: 2, startTicks: 20_000, endTicks: 30_000),
            makeSlot(index: 3, startTicks: 30_000, endTicks: 40_000, status: .downloading),
            makeSlot(index: 4, startTicks: 40_000, endTicks: 50_000),
            makeSlot(index: 5, startTicks: 50_000, endTicks: 60_000, status: .unavailable),
            makeSlot(index: 6, startTicks: 60_000, endTicks: 70_000),
            makeSlot(index: 7, startTicks: 70_000, endTicks: 80_000, status: .tooShort),
            makeSlot(index: 8, startTicks: 80_000, endTicks: 90_000)
        ]

        let timeline = readyTimeline(slots: slots)

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[0], [2], [4], [6], [8]])
        XCTAssertEqual(timeline.slotCount, 5)
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 50_000))
        XCTAssertFalse(
            timeline.allSlots.contains { $0.assignment?.status != .ready },
            "aucune case non prête n'entre dans le montage"
        )
    }

    // MARK: - Cases dans le désordre → triées par index

    func testUnorderedSlotsAreSortedByIndexBeforeAnyDecision() {
        let slot1 = makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000)
        let empty2 = makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil)
        let slot3 = makeSlot(index: 3, startTicks: 120_000, endTicks: 150_000)
        let slot4 = makeSlot(index: 4, startTicks: 150_000, endTicks: 200_000)
        let empty0 = makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil)

        // Collection donnée dans un ordre arbitraire : le tri par index doit
        // précéder le découpage en runs, sinon les zones seraient fausses.
        let timeline = readyTimeline(slots: [slot4, empty2, slot1, slot3, empty0])

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[1], [3, 4]])
        XCTAssertEqual(timeline.allSlots.map(\.id), [slot1.id, slot3.id, slot4.id])
        XCTAssertEqual(timeline.compositionStart(of: slot1), MediaTime.zero)
        XCTAssertEqual(timeline.compositionStart(of: slot3), MediaTime(ticks: 45_000))
        XCTAssertEqual(timeline.compositionStart(of: slot4), MediaTime(ticks: 75_000))
    }

    // MARK: - Troncature §66 (utilisée par l'export)

    /// La troncature garde les `n` premières cases DU MONTAGE : le run coupé
    /// est raccourci et les runs suivants sont ABANDONNÉS (décision
    /// documentée — le montage livré doit rester celui qui a été annoncé).
    func testTruncationCutsInsideARunAndDropsTheFollowingRuns() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        // 10 cases conservées : les 8 du run 1, puis 2 du run 2.
        let truncated = timeline.truncated(toFirst: 10)

        XCTAssertEqual(truncated.runs.count, 2)
        XCTAssertEqual(truncated.runs[0].slots.map(\.index), Array(28...35))
        XCTAssertEqual(truncated.runs[1].slots.map(\.index), [40, 41])
        XCTAssertEqual(truncated.slotCount, 10)
        // 200 000 (run 1) + 30 000 (case 40) + 20 000 (case 41).
        XCTAssertEqual(truncated.duration, MediaTime(ticks: 250_000))
        // Les cases conservées n'ont pas bougé : même position qu'avant.
        XCTAssertEqual(
            truncated.compositionStart(of: truncated.allSlots[9]),
            timeline.compositionStart(of: timeline.allSlots[9])
        )
    }

    func testTruncationOnARunBoundaryDropsTheFollowingRunsEntirely() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        let truncated = timeline.truncated(toFirst: 8)

        XCTAssertEqual(truncated.runs.count, 1, "le second run est abandonné")
        XCTAssertEqual(truncated.slotCount, 8)
        XCTAssertEqual(truncated.duration, MediaTime(ticks: 200_000))
    }

    func testTruncationBoundsAreSafe() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        XCTAssertEqual(timeline.truncated(toFirst: 0), .empty)
        XCTAssertEqual(timeline.truncated(toFirst: -3), .empty)
        XCTAssertEqual(timeline.truncated(toFirst: 19), timeline)
        XCTAssertEqual(timeline.truncated(toFirst: 999), timeline)
    }

    // MARK: - Invariant de RUN : index consécutifs ET cases jointives

    /// Deux cases prêtes d'index CONSÉCUTIFS mais NON JOINTIVES forment DEUX
    /// runs, pas un seul.
    ///
    /// C'est l'invariant qui rend `ReadyRun.duration` (`musicEnd -
    /// musicStart`) égale à la somme des durées des cases du run — la durée
    /// qui est annoncée (§56), estimée (§57) et encodée (portion de musique).
    /// Sans cette fermeture, le run [4, 5] ci-dessous durerait 70 000 ticks
    /// pour 50 000 ticks de vidéo : la musique dépasserait l'image de
    /// 20 000 ticks, silencieusement.
    func testTwoConsecutiveIndexesThatDoNotTouchFormTwoRuns() {
        let first = makeSlot(index: 4, startTicks: 100_000, endTicks: 130_000)
        let second = makeSlot(index: 5, startTicks: 150_000, endTicks: 170_000)

        let timeline = readyTimeline(slots: [first, second])

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[4], [5]])
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 50_000), "30 000 + 20 000")
        XCTAssertNotEqual(
            timeline.duration,
            MediaTime(ticks: 70_000),
            "170 000 − 100 000 inclurait les 20 000 ticks de vide entre les deux cases"
        )
        XCTAssertEqual(timeline.placements.map(\.compositionStart.ticks), [0, 30_000])
        // Deux zones ⇒ deux portions de musique, prélevées à leurs temps
        // ABSOLUS respectifs : le vide de la musique n'est pas encodé.
        XCTAssertEqual(timeline.musicInsertions, [
            MusicInsertion(
                sourceStart: MediaTime(ticks: 100_000),
                duration: MediaTime(ticks: 30_000),
                compositionStart: .zero
            ),
            MusicInsertion(
                sourceStart: MediaTime(ticks: 150_000),
                duration: MediaTime(ticks: 20_000),
                compositionStart: MediaTime(ticks: 30_000)
            )
        ])
    }

    /// Deux cases prêtes JOINTIVES mais d'index NON consécutifs (une case a
    /// été retirée de la partition sans que les temps bougent) forment elles
    /// aussi deux runs : l'ordre du montage est celui des index, un saut
    /// d'index n'est pas une continuité.
    func testTwoTouchingSlotsWithNonConsecutiveIndexesFormTwoRuns() {
        let first = makeSlot(index: 4, startTicks: 100_000, endTicks: 130_000)
        let second = makeSlot(index: 6, startTicks: 130_000, endTicks: 150_000)

        let timeline = readyTimeline(slots: [first, second])

        XCTAssertEqual(timeline.runs.map { $0.slots.map(\.index) }, [[4], [6]])
        XCTAssertEqual(timeline.slotCount, 2)
        XCTAssertEqual(timeline.duration, MediaTime(ticks: 50_000))
        // Les cases restent JOINTIVES dans le montage : deux runs ne créent
        // aucun trou, ils changent seulement le découpage de la musique.
        XCTAssertEqual(timeline.placements.map(\.compositionStart.ticks), [0, 30_000])
    }

    /// L'invariant vaut pour CHAQUE run de la fixture de référence.
    func testEveryRunDurationEqualsTheSumOfItsSlotDurations() {
        let timeline = readyTimeline(slots: montageWithTwoRuns)

        for run in timeline.runs {
            XCTAssertEqual(
                run.duration.ticks,
                run.slots.reduce(Int64(0)) { $0 + $1.duration.ticks },
                "run \(run.startIndex)…\(run.endIndex)"
            )
        }
    }

    // MARK: - Propriété : AUCUNE case prête n'est jamais omise

    /// Les six états possibles d'une case : vide, puis les cinq statuts.
    private static let everySlotState: [ClipAssignmentStatus?] = [
        nil, .ready, .resolving, .downloading, .unavailable, .tooShort
    ]

    /// Matrice EXHAUSTIVE d'arrangements : de 0 à 6 cases, chacune prenant
    /// tour à tour les six états ci-dessus (55 987 montages). Elle contient
    /// donc par construction les trous en tête, au milieu et en fin, les trous
    /// CONSÉCUTIFS, les runs d'une seule case, les montages entièrement prêts
    /// et les montages sans aucune case prête.
    private func forEachArrangement(_ body: ([ProjectSlot]) -> Void) {
        for count in 0...6 {
            var arrangements = 1
            for _ in 0..<count { arrangements *= Self.everySlotState.count }

            for code in 0..<arrangements {
                var remaining = code
                var slots: [ProjectSlot] = []
                slots.reserveCapacity(count)
                for index in 0..<count {
                    let state = Self.everySlotState[remaining % Self.everySlotState.count]
                    remaining /= Self.everySlotState.count
                    slots.append(makeSlot(
                        index: index,
                        startTicks: Self.startTicks(ofSlotAt: index),
                        endTicks: Self.startTicks(ofSlotAt: index)
                            + Self.durationTicks(ofSlotAt: index),
                        status: state
                    ))
                }
                body(slots)
            }
        }
    }

    /// Test de PROPRIÉTÉ sur toute la matrice.
    ///
    /// L'invariant central tient en une ligne — « aucune case prête n'est
    /// omise, aucune autre n'entre » : `allSlots` est EXACTEMENT la suite des
    /// cases `ready` triées par index. Il est vérifié sur le tableau donné ET
    /// sur le tableau INVERSÉ : le tri par index précède toute décision de
    /// découpage.
    ///
    /// Deux invariants de durée l'accompagnent sur la même matrice, parce
    /// qu'ils portent la même promesse produite : le montage dure la somme des
    /// durées des cases prêtes, et chaque run dure la somme des durées de SES
    /// cases (c'est cette dernière égalité qui rend la portion de musique d'un
    /// run exacte).
    func testEveryArrangementKeepsExactlyTheReadySlotsSortedByIndex() {
        forEachArrangement { slots in
            let readySlots = slots.filter { $0.assignment?.status == .ready }
            let timeline = readyTimeline(slots: slots)

            XCTAssertEqual(timeline.allSlots.map(\.id), readySlots.map(\.id))
            XCTAssertEqual(
                readyTimeline(slots: Array(slots.reversed())).allSlots.map(\.id),
                readySlots.map(\.id),
                "tableau désordonné : le tri par index précède le découpage"
            )
            XCTAssertEqual(
                timeline.duration.ticks,
                readySlots.reduce(Int64(0)) { $0 + $1.duration.ticks }
            )
            for run in timeline.runs {
                XCTAssertEqual(
                    run.duration.ticks,
                    run.slots.reduce(Int64(0)) { $0 + $1.duration.ticks },
                    "run \(run.startIndex)…\(run.endIndex) : durée ≠ somme de ses cases"
                )
            }
        }
    }
}
