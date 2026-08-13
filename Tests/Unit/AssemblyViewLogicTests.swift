//
//  AssemblyViewLogicTests.swift
//  MontageMusicalTests
//
//  Tests de la logique d'écran du Jalon 7 (`AssemblyViewLogic`), extraite
//  en fonctions pures testables SANS UI :
//  - clamp de l'index de case active (§60 : valeur restaurée hors bornes) ;
//  - fenêtre du carrousel §35.3 clampée aux bornes 0 et N-1 ;
//  - dérivation des libellés du dock contextuel §36 (case vide/remplie) et
//    de sa ZONE DROITE (Jalon 10 : « Export » dans tous les cas, comme le
//    tableau §36 — seul son état actif/désactivé varie ; l'aperçu principal
//    §47.2 a son propre bouton en zone basse, §88.11/§89) ;
//  - Export désactivé quand le montage exportable est vide (réutilise
//    `readyTimeline(slots:)` du Domain avec des snapshots `ProjectSlot`) ;
//  - bornes de TOUTES les zones exportées sur la projection d'affichage
//    (`exportedZonePositions` / `exportedZoneIndexes`) et énoncé VoiceOver
//    associé.
//
//  RELECTURE ADVERSARIALE (13 août 2026) — trois familles de tests ajoutées :
//  - **zones de l'interface == runs du DOMAINE** : deux découpages en zones
//    coexistent (le domaine `readyTimeline(slots:)`, qui pilote réellement
//    l'export, et l'interface `exportedZonePositions(items:)`, qui dessine les
//    crochets §35.3 et nomme le montage). Rien ne les comparait. Une MATRICE
//    d'arrangements vérifie désormais qu'ils rendent exactement les mêmes
//    bornes et le même nombre de plans par zone — c'est la seule garantie que
//    l'utilisateur voit ce qui part vraiment ;
//  - **compte de plans faisant autorité** (`exportedSlotCount`) : il ne se
//    déduit plus de la largeur des plages d'index, qui compte les index
//    manquants ;
//  - **§64 cause du blocage** (`nothingReadyCause`) : une case REMPLIE mais non
//    prête n'appelle pas le même geste qu'une case vide, et les deux
//    vocabulaires (états d'affichage, statuts §13.3) doivent conclure pareil.
//
//  ÉCART PRODUIT — EXPORT CONCATÉNÉ DES ZONES REMPLIES (13 août 2026, demande
//  utilisateur postérieure à la spécification). Les tests d'export ont changé
//  de VERDICT, pas seulement de nom :
//  - une PREMIÈRE CASE VIDE n'empêche plus l'export dès qu'une case plus loin
//    est prête (§66 « première case vide : export désactivé » ne décrit plus
//    le produit) ;
//  - un trou ne BORNE plus le montage : les zones situées après partent aussi.
//    `exportedZonePositions` rend donc TOUTES les zones, plus seulement la
//    première.
//  Ce qui reste vrai : aucune case prête → export impossible.
//

import XCTest
@testable import MontageMusical

final class AssemblyViewLogicTests: XCTestCase {

    // MARK: - Helpers privés (portée classe — aucune collision de module)

    /// Fabrique une case snapshot du domaine. `status == nil` produit une
    /// case vide (aucune association).
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

    /// Fabrique une case d'AFFICHAGE (§35) — les durées n'importent pas pour
    /// les bornes des zones, seul l'état compte.
    private func makeItem(index: Int, state: AssemblySlotState) -> AssemblySlotItem {
        let start = Int64(index) * 60_000
        return AssemblySlotItem(
            id: UUID(),
            index: index,
            start: MediaTime(ticks: start),
            end: MediaTime(ticks: start + 60_000),
            state: state
        )
    }

    /// Suite de cases d'affichage à partir d'états, index contigus depuis 0.
    private func makeItems(_ states: [AssemblySlotState]) -> [AssemblySlotItem] {
        states.enumerated().map { makeItem(index: $0.offset, state: $0.element) }
    }

    /// Le MÊME arrangement vu des deux côtés : cases du domaine
    /// (`ProjectSlot`, ce que l'export lit) et cases d'affichage
    /// (`AssemblySlotItem`, ce que l'écran dessine). Les index et les durées
    /// sont identiques des deux côtés — seule la dérivation d'état diffère,
    /// et c'est précisément ce qu'on veut comparer.
    private func makeArrangement(
        _ statuses: [ClipAssignmentStatus?],
        firstIndex: Int = 0
    ) -> (slots: [ProjectSlot], items: [AssemblySlotItem]) {
        var slots: [ProjectSlot] = []
        var items: [AssemblySlotItem] = []
        var startTicks: Int64 = 0
        for (position, status) in statuses.enumerated() {
            let index = firstIndex + position
            slots.append(makeSlot(
                index: index,
                startTicks: startTicks,
                endTicks: startTicks + 45_000,
                status: status
            ))
            items.append(AssemblySlotItem(
                id: slots[position].id,
                index: index,
                start: MediaTime(ticks: startTicks),
                end: MediaTime(ticks: startTicks + 45_000),
                state: AssemblySlotState.from(assignmentStatusRaw: status?.rawValue)
            ))
            startTicks += 45_000
        }
        return (slots, items)
    }

    /// Matrice d'arrangements couvrant tout ce qui peut arriver à une case :
    /// vide, en cours (§44), prête, bloquée (§64, §3.8), aux extrémités comme
    /// au milieu, en une zone comme en plusieurs.
    private var arrangements: [[ClipAssignmentStatus?]] {
        [
            [],
            [nil],
            [.ready],
            [.downloading],
            [nil, .ready],
            [.ready, nil],
            [.ready, nil, .ready],
            [.ready, .ready, nil, .ready, .ready],
            [.downloading, .ready],
            [nil, .resolving, .unavailable],
            [.ready, .ready, .tooShort, .ready],
            [nil, .ready, .ready, nil, .ready, .ready],
            [.ready, .unavailable, .ready, .downloading, .ready, nil, .ready],
            [.tooShort, .resolving, .downloading, .unavailable, nil],
            [.ready, .ready, .ready, .ready]
        ]
    }

    // MARK: - Clamp de l'index actif (§60)

    func testClampNegativeIndexReturnsZero() {
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(-3, slotCount: 5), 0)
    }

    func testClampBeyondLastReturnsLastIndex() {
        // §60 : la valeur restaurée peut dépasser si les cases ont changé
        // (duplication, migration) — jamais d'indexation hors bornes.
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(99, slotCount: 5), 4)
    }

    func testClampInRangeIndexIsUnchanged() {
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(2, slotCount: 5), 2)
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(0, slotCount: 5), 0)
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(4, slotCount: 5), 4)
    }

    func testClampWithoutSlotsReturnsZero() {
        XCTAssertEqual(AssemblyViewLogic.clampedActiveIndex(7, slotCount: 0), 0)
    }

    // MARK: - Fenêtre du carrousel (§35.3)

    func testWindowRangeInMiddleIsPreviousActiveNext() {
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 2, slotCount: 5),
            1...3
        )
    }

    func testWindowRangeAtFirstSlotClampsLowerBoundToZero() {
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 0, slotCount: 5),
            0...1
        )
    }

    func testWindowRangeAtLastSlotClampsUpperBoundToLastIndex() {
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 4, slotCount: 5),
            3...4
        )
    }

    func testWindowRangeWithSingleSlotIsZeroToZero() {
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 0, slotCount: 1),
            0...0
        )
    }

    func testWindowRangeWithoutSlotsIsZeroToZero() {
        // Cas dégénéré : jamais de plage invalide (lowerBound > upperBound
        // ferait planter `ClosedRange`).
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 3, slotCount: 0),
            0...0
        )
    }

    func testWindowRangeClampsOutOfRangeActiveIndex() {
        // Index actif hors bornes (restauration §60) : la fenêtre est
        // celle du dernier index valide.
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: 42, slotCount: 3),
            1...2
        )
        XCTAssertEqual(
            AssemblyViewLogic.windowRange(activeIndex: -5, slotCount: 3),
            0...1
        )
    }

    // MARK: - Libellés du dock contextuel (§36)

    func testDockLabelsForEmptySlotShowAddVideoWithRequiredDuration() {
        // 72 000 ticks = 1,2 s → « 1,20 s » (§35.2, `shortDurationString`).
        let labels = AssemblyViewLogic.dockLabels(
            activeState: .empty,
            requiredDuration: MediaTime(ticks: 72_000)
        )

        XCTAssertEqual(labels.left, "Projets")
        XCTAssertEqual(labels.center, "+ Vidéo • 1,20 s")
        XCTAssertEqual(labels.right, "Export")
    }

    func testDockLabelsForReadySlotShowReplace() {
        let labels = AssemblyViewLogic.dockLabels(
            activeState: .ready,
            requiredDuration: MediaTime(ticks: 72_000)
        )

        XCTAssertEqual(labels.left, "Projets")
        XCTAssertEqual(labels.center, "Remplacer")
        XCTAssertEqual(labels.right, "Export")
    }

    func testDockLabelsForEveryAssignedStateShowReplace() {
        // §36 : dès qu'une association existe — même non prête
        // (resolving, downloading §44, unavailable §64, tooShort) — la
        // case est « remplie » : le centre propose « Remplacer ».
        let assignedStates: [AssemblySlotState] = [
            .resolving, .downloading, .unavailable, .tooShort
        ]
        for state in assignedStates {
            let labels = AssemblyViewLogic.dockLabels(
                activeState: state,
                requiredDuration: MediaTime(ticks: 30_000)
            )
            XCTAssertEqual(labels.center, "Remplacer", "état : \(state)")
            XCTAssertEqual(labels.left, "Projets", "état : \(state)")
            XCTAssertEqual(labels.right, "Export", "état : \(state)")
        }
    }

    // MARK: - Zone droite du dock (§36, Jalon 10)

    func testDockRightZoneAlwaysShowsExport() {
        // Jalon 10 : l'écran d'export existe — la zone droite porte
        // « Export » dans TOUS les états, exactement comme le tableau §36.
        // Seul son ÉTAT (actif/désactivé) varie, ce que décrit
        // `isExportEnabled` ; l'aperçu principal §47.2 a migré vers son
        // propre bouton en zone basse (§88.11/§89).
        for state in [AssemblySlotState.empty, .ready, .downloading, .unavailable, .tooShort, .resolving] {
            let labels = AssemblyViewLogic.dockLabels(
                activeState: state,
                requiredDuration: MediaTime(ticks: 72_000)
            )
            XCTAssertEqual(labels.right, "Export", "état : \(state)")
            XCTAssertEqual(labels.left, "Projets", "état : \(state)")
        }
    }

    func testDockKeepsExactlyThreeZonesWhateverTheState() {
        // §36 : « maximum trois zones importantes » — seul le CENTRE change
        // avec l'état de la case.
        let empty = AssemblyViewLogic.dockLabels(
            activeState: .empty,
            requiredDuration: MediaTime(ticks: 72_000)
        )
        let filled = AssemblyViewLogic.dockLabels(
            activeState: .ready,
            requiredDuration: MediaTime(ticks: 72_000)
        )

        XCTAssertEqual(empty.left, filled.left, "Zone gauche inchangée")
        XCTAssertEqual(empty.right, filled.right, "Zone droite inchangée")
        XCTAssertNotEqual(empty.center, filled.center, "Seule la zone centrale bascule")
        XCTAssertEqual(filled.right, "Export")
    }

    // MARK: - Export désactivé si le montage exportable est vide (§51)

    func testExportDisabledWithoutAnySlot() {
        XCTAssertFalse(AssemblyViewLogic.isExportEnabled(slots: []))
        XCTAssertFalse(AssemblyViewLogic.isExportEnabled(items: []))
    }

    func testExportEnabledWhenFirstSlotIsEmptyButALaterSlotIsReady() {
        // ÉCART PRODUIT — LE test qui a changé de verdict.
        // Avant : « première case vide : export désactivé » (§66).
        // Maintenant : l'export porte sur toutes les zones remplies, où
        // qu'elles commencent — les cases 1 et 2 forment ce montage.
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000)
        ]

        XCTAssertTrue(AssemblyViewLogic.isExportEnabled(slots: slots))
        XCTAssertTrue(
            AssemblyViewLogic.isExportEnabled(items: makeItems([.empty, .ready, .ready]))
        )
    }

    func testExportEnabledWithAnEmptyFirstSlotAndTwoZones() {
        // ÉCART PRODUIT (13 août 2026) — le cas de la demande, en miniature :
        // première case VIDE, puis DEUX zones séparées par un trou. L'export
        // concatène les deux : il est actif, et les deux variantes de
        // `isExportEnabled` doivent l'accorder.
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: nil),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 135_000),
            makeSlot(index: 3, startTicks: 135_000, endTicks: 180_000, status: nil),
            makeSlot(index: 4, startTicks: 180_000, endTicks: 225_000),
            makeSlot(index: 5, startTicks: 225_000, endTicks: 270_000)
        ]
        let items = makeItems([.empty, .ready, .ready, .empty, .ready, .ready])

        XCTAssertTrue(AssemblyViewLogic.isExportEnabled(slots: slots))
        XCTAssertTrue(AssemblyViewLogic.isExportEnabled(items: items))
        // Les DEUX zones sont exportées : 4 plans en 2 morceaux, aucune case
        // prête omise.
        XCTAssertEqual(AssemblyViewLogic.exportedZonePositions(items: items), [1...2, 4...5])
        XCTAssertEqual(
            AssemblyViewLogic.exportedZonePositions(items: items).reduce(0) { $0 + $1.count },
            4
        )
    }

    func testExportDisabledWhenNoSlotIsReady() {
        // Seule raison restante de désactiver l'export (§51 : « export
        // désactivé si le résultat est vide ») — aucun état non prêt ne
        // fabrique un montage : ni vide, ni en cours (§44), ni bloquant
        // (§64, §3.8).
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000, status: .downloading),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: nil),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 150_000, status: .unavailable),
            makeSlot(index: 3, startTicks: 150_000, endTicks: 195_000, status: .tooShort),
            makeSlot(index: 4, startTicks: 195_000, endTicks: 240_000, status: .resolving)
        ]

        XCTAssertFalse(AssemblyViewLogic.isExportEnabled(slots: slots))
        XCTAssertFalse(
            AssemblyViewLogic.isExportEnabled(
                items: makeItems([.downloading, .empty, .unavailable, .tooShort, .resolving])
            )
        )
    }

    func testExportEnabledWhenFirstSlotIsReady() {
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000, status: nil)
        ]

        XCTAssertTrue(AssemblyViewLogic.isExportEnabled(slots: slots))
    }

    func testExportEnabledDespiteAGapInTheMiddle() {
        // ÉCART PRODUIT : un trou ne borne plus rien — les cases 0, 1 et 3
        // partent toutes, en deux zones.
        let slots = [
            makeSlot(index: 0, startTicks: 0, endTicks: 45_000),
            makeSlot(index: 1, startTicks: 45_000, endTicks: 90_000),
            makeSlot(index: 2, startTicks: 90_000, endTicks: 120_000, status: nil),
            makeSlot(index: 3, startTicks: 120_000, endTicks: 165_000)
        ]

        XCTAssertTrue(AssemblyViewLogic.isExportEnabled(slots: slots))
        XCTAssertEqual(
            AssemblyViewLogic.exportedZonePositions(
                items: makeItems([.ready, .ready, .empty, .ready])
            ),
            [0...1, 3...3]
        )
    }

    func testBothExportEnabledVariantsAgreeOnEveryArrangement() {
        // La variante « items » (dock §36, bouton d'aperçu §47.2) et la
        // variante « snapshots » (source du domaine) doivent rendre le MÊME
        // verdict : sans cela, le dock proposerait un export que l'écran
        // suivant refuserait.
        for statuses in arrangements {
            let arrangement = makeArrangement(statuses)
            XCTAssertEqual(
                AssemblyViewLogic.isExportEnabled(slots: arrangement.slots),
                AssemblyViewLogic.isExportEnabled(items: arrangement.items),
                "arrangement : \(statuses)"
            )
        }
    }

    // MARK: - Zones de l'INTERFACE == runs du DOMAINE (relecture 13 août 2026)

    func testInterfaceZonesMatchDomainRunsOnEveryArrangement() {
        // LE test qui manquait : deux découpages en zones coexistent — celui du
        // DOMAINE (`readyTimeline(slots:)`, qui décide de ce qui est
        // réellement encodé) et celui de l'INTERFACE
        // (`exportedZoneIndexes(items:)`, qui dessine les crochets §35.3 et
        // nomme le montage « Plans 28 à 50 »). Ils sont écrits séparément :
        // rien n'obligeait le second à suivre le premier. S'ils divergeaient,
        // l'utilisateur verrait des zones qui ne partent pas — ou n'en verrait
        // pas qui partent.
        for statuses in arrangements {
            let arrangement = makeArrangement(statuses)
            let domainRuns = readyTimeline(slots: arrangement.slots).runs
            let interfaceZones = AssemblyViewLogic.exportedZoneIndexes(items: arrangement.items)

            XCTAssertEqual(
                interfaceZones.count,
                domainRuns.count,
                "nombre de zones — arrangement : \(statuses)"
            )
            XCTAssertEqual(
                interfaceZones,
                domainRuns.map { $0.startIndex...$0.endIndex },
                "bornes des zones — arrangement : \(statuses)"
            )
            // Même nombre de plans PAR zone : deux découpages peuvent partager
            // leurs bornes et ne pas contenir le même nombre de cases.
            let interfacePositions = AssemblyViewLogic.exportedZonePositions(items: arrangement.items)
            XCTAssertEqual(
                interfacePositions.map(\.count),
                domainRuns.map(\.slotCount),
                "plans par zone — arrangement : \(statuses)"
            )
            // Et le même TOTAL, celui qui s'affiche (§56).
            XCTAssertEqual(
                AssemblyViewLogic.exportedSlotCount(items: arrangement.items),
                readyTimeline(slots: arrangement.slots).slotCount,
                "total de plans — arrangement : \(statuses)"
            )
        }
    }

    func testInterfaceZonesMatchDomainRunsWhenIndexesDoNotStartAtZero() {
        // L'exemple de la demande commence à la case 28 : la traduction
        // position → index ne doit pas décaler les zones de l'interface par
        // rapport aux runs du domaine.
        for statuses in arrangements {
            let arrangement = makeArrangement(statuses, firstIndex: 28)
            XCTAssertEqual(
                AssemblyViewLogic.exportedZoneIndexes(items: arrangement.items),
                readyTimeline(slots: arrangement.slots).runs.map { $0.startIndex...$0.endIndex },
                "arrangement : \(statuses)"
            )
        }
    }

    // MARK: - Compte de plans faisant autorité (relecture 13 août 2026)

    func testExportedSlotCountIsTheNumberOfReadySlots() {
        XCTAssertEqual(AssemblyViewLogic.exportedSlotCount(items: []), 0)
        XCTAssertEqual(
            AssemblyViewLogic.exportedSlotCount(
                items: makeItems([.empty, .downloading, .unavailable, .tooShort, .resolving])
            ),
            0
        )
        XCTAssertEqual(
            AssemblyViewLogic.exportedSlotCount(
                items: makeItems([.ready, .ready, .empty, .ready])
            ),
            3
        )
    }

    func testAuthoritativeCountIgnoresMissingIndexesInsideAZone() {
        // LE cas qui séparait les deux comptes : les index d'une zone ne sont
        // pas contigus (28, 29, 31). La LARGEUR de la plage d'index vaut 4,
        // alors que la zone ne contient que 3 plans — c'est le nombre de PLANS
        // qui doit être annoncé, jamais la largeur de l'intervalle.
        let items = [
            makeItem(index: 28, state: .ready),
            makeItem(index: 29, state: .ready),
            makeItem(index: 31, state: .ready),
            makeItem(index: 32, state: .empty),
            makeItem(index: 34, state: .ready)
        ]
        let zones = AssemblyViewLogic.exportedZoneIndexes(items: items)

        XCTAssertEqual(zones, [28...31, 34...34])
        XCTAssertEqual(zones.reduce(0) { $0 + $1.count }, 5, "la largeur des plages compte 5…")
        XCTAssertEqual(AssemblyViewLogic.exportedSlotCount(items: items), 4, "…mais il n'y a que 4 plans")

        // L'énoncé VoiceOver dit le compte FAISANT AUTORITÉ, pas la largeur.
        XCTAssertEqual(
            AssemblyViewLogic.spokenExportedZones(
                zones: zones,
                slotCount: AssemblyViewLogic.exportedSlotCount(items: items)
            ),
            "4 plans exportables en 2 zones"
        )
    }

    // MARK: - §64 : pourquoi rien n'est prêt (relecture 13 août 2026)

    func testNothingReadyCauseDistinguishesEmptyFromFilledButNotReady() {
        // §64 : une case REMPLIE mais non prête n'appelle pas le même geste
        // qu'une case vide — attendre ou remplacer, jamais « remplissez ».
        XCTAssertEqual(
            AssemblyViewLogic.nothingReadyCause(items: makeItems([.empty, .empty])),
            .nothingFilled
        )
        XCTAssertEqual(
            AssemblyViewLogic.nothingReadyCause(items: makeItems([.empty, .downloading])),
            .pending
        )
        XCTAssertEqual(
            AssemblyViewLogic.nothingReadyCause(items: makeItems([.resolving])),
            .pending
        )
        XCTAssertEqual(
            AssemblyViewLogic.nothingReadyCause(items: makeItems([.unavailable, .empty])),
            .blocked
        )
        XCTAssertEqual(
            AssemblyViewLogic.nothingReadyCause(items: makeItems([.tooShort])),
            .blocked
        )
        XCTAssertEqual(
            AssemblyViewLogic.nothingReadyCause(items: makeItems([.downloading, .unavailable])),
            .pendingAndBlocked
        )
    }

    func testNothingReadyCauseAgreesBetweenItemsAndSnapshots() {
        // Le résumé §56 lit un instantané, l'écran d'assemblage lit des états
        // d'affichage : les deux doivent conseiller le MÊME geste pour la même
        // situation, sinon l'utilisateur reçoit deux consignes contradictoires
        // à un écran d'intervalle.
        for statuses in arrangements {
            let arrangement = makeArrangement(statuses)
            XCTAssertEqual(
                AssemblyViewLogic.nothingReadyCause(items: arrangement.items),
                ExportSummaryLogic.nothingReadyCause(slots: arrangement.slots),
                "arrangement : \(statuses)"
            )
        }
    }

    // MARK: - Bornes des zones exportées (écart produit, §35.3)

    func testZonePositionsAreEmptyWhenNothingIsReady() {
        XCTAssertTrue(AssemblyViewLogic.exportedZonePositions(items: []).isEmpty)
        XCTAssertTrue(
            AssemblyViewLogic.exportedZonePositions(
                items: makeItems([.empty, .downloading, .unavailable])
            ).isEmpty
        )
    }

    func testFirstZoneStartsAtTheFirstReadySlotWhereverItIs() {
        // L'exemple de la demande : cases 28 à 50 remplies (ici 3 à 5).
        let items = makeItems([.empty, .empty, .downloading, .ready, .ready, .ready, .empty])
        XCTAssertEqual(AssemblyViewLogic.exportedZonePositions(items: items), [3...5])
    }

    func testEveryZoneIsExportedNotOnlyTheFirst() {
        // ÉCART PRODUIT (13 août 2026) — verdict INVERSÉ : avant, seule la
        // première zone comptait. Les deux zones partent désormais, mises bout
        // à bout ; aucune case prête n'est omise.
        let items = makeItems([.ready, .ready, .empty, .ready, .ready, .ready])
        XCTAssertEqual(AssemblyViewLogic.exportedZonePositions(items: items), [0...1, 3...5])
    }

    func testZonesFollowTheExampleOfTheRequest() {
        // 28..35 prêtes, 36..39 vides, 40..50 prêtes (index 0-based) →
        // 8 + 11 = 19 plans en 2 zones.
        var states = [AssemblySlotState](repeating: .empty, count: 51)
        for index in 28...35 { states[index] = .ready }
        for index in 40...50 { states[index] = .ready }
        let zones = AssemblyViewLogic.exportedZonePositions(items: makeItems(states))

        XCTAssertEqual(zones, [28...35, 40...50])
        XCTAssertEqual(zones.reduce(0) { $0 + $1.count }, 19)
    }

    func testZoneOfASingleReadySlot() {
        let items = makeItems([.empty, .ready, .tooShort])
        XCTAssertEqual(AssemblyViewLogic.exportedZonePositions(items: items), [1...1])
    }

    func testASingleZoneCoversTheWholeProjectWhenEverySlotIsReady() {
        let items = makeItems([.ready, .ready, .ready, .ready])
        XCTAssertEqual(AssemblyViewLogic.exportedZonePositions(items: items), [0...3])
    }

    func testEveryNonReadyStateSplitsTheZones() {
        // Aucun état intermédiaire n'est « presque prêt » : résolution,
        // téléchargement §44, indisponible §64 et trop courte §3.8 coupent la
        // zone exactement comme une case vide — et sont supprimés du montage.
        for state in [AssemblySlotState.empty, .resolving, .downloading, .unavailable, .tooShort] {
            let items = makeItems([.ready, state, .ready])
            XCTAssertEqual(
                AssemblyViewLogic.exportedZonePositions(items: items),
                [0...0, 2...2],
                "état interrupteur : \(state)"
            )
        }
    }

    func testZoneIndexesUseSlotIndexesNotArrayPositions() {
        // Les crochets de la mini-timeline et les libellés parlent en INDEX de
        // case, jamais en position de tableau : la traduction est explicite.
        // Ici les index commencent à 10 — les positions restent 0…4.
        let states: [AssemblySlotState] = [.empty, .ready, .ready, .empty, .ready]
        let items = states.enumerated().map { makeItem(index: 10 + $0.offset, state: $0.element) }

        XCTAssertEqual(AssemblyViewLogic.exportedZonePositions(items: items), [1...2, 4...4])
        XCTAssertEqual(AssemblyViewLogic.exportedZoneIndexes(items: items), [11...12, 14...14])
    }

    // MARK: - Énoncé VoiceOver des zones (§39)

    func testSpokenExportedZonesIsNilWhenNothingIsExported() {
        XCTAssertNil(AssemblyViewLogic.spokenExportedZones(zones: [], slotCount: 0))
    }

    func testSpokenSingleZoneKeepsTheRangeWording() {
        // « plans 28 à 50 exportables » à partir des index 27…49 (0-based).
        XCTAssertEqual(
            AssemblyViewLogic.spokenExportedZones(zones: [27...49], slotCount: 23),
            "plans 28 à 50 exportables"
        )
    }

    func testSpokenSingleZoneIsSingularForASingleSlot() {
        XCTAssertEqual(
            AssemblyViewLogic.spokenExportedZones(zones: [27...27], slotCount: 1),
            "plan 28 exportable"
        )
    }

    func testSpokenSeveralZonesAnnounceTotalPlansAndZoneCount() {
        // §39 : l'exemple de la demande — 8 + 11 plans en deux morceaux. Le
        // crochet dessiné est invisible pour VoiceOver : la valeur doit dire
        // COMBIEN de plans partent et en COMBIEN de zones.
        XCTAssertEqual(
            AssemblyViewLogic.spokenExportedZones(zones: [27...34, 39...49], slotCount: 19),
            "19 plans exportables en 2 zones"
        )
        XCTAssertEqual(
            AssemblyViewLogic.spokenExportedZones(zones: [0...0, 2...2, 4...4], slotCount: 3),
            "3 plans exportables en 3 zones"
        )
    }

    func testSpokenSingleZoneIsDefensiveAboutNegativeIndexes() {
        // Index négatif (jamais attendu) : jamais « plan 0 ».
        XCTAssertEqual(
            AssemblyViewLogic.spokenExportedZones(zones: [(-4)...(-4)], slotCount: 1),
            "plan 1 exportable"
        )
    }
}
