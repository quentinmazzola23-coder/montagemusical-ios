//
//  PreviewCacheKeyTests.swift
//  MontageMusicalTests
//
//  Clé et cache de prévisualisation (Jalon 9) — contrat §48 :
//  « mettre en cache la composition tant que les associations ne changent
//  pas », et invalidation « si une association change / si la géométrie
//  change lors du premier rush / si un asset devient indisponible ».
//
//  Trois familles de tests :
//  - `scopeKey` : les trois portées §47 (case / segment continu / montage
//    complet) sont des compositions DIFFÉRENTES, jamais interchangeables ;
//  - `fingerprint` : change dès qu'un élément du montage change (association,
//    rush, statut, frontière de case, géométrie) et RESTE IDENTIQUE pour un
//    même état reconstruit — sans quoi le cache ne servirait jamais ;
//  - `PreviewCache` : rangement, relecture, éviction LRU bornée, et
//    invalidation limitée à UN projet.
//
//  Tests PUREMENT déterministes : aucun média, aucun fichier, aucun accès
//  PhotoKit. Les instantanés sont construits à la main avec des
//  identifiants FIXES (deux constructions successives doivent donner la
//  même empreinte), et les compositions mises en cache sont des
//  `AVMutableComposition` vides — un objet, pas un média.
//

import AVFoundation
import XCTest
@testable import MontageMusical

@MainActor
final class PreviewCacheKeyTests: XCTestCase {

    // MARK: - Identifiants fixes (helpers privés de classe)

    /// Identifiants stables : une empreinte ne doit changer que parce que le
    /// MONTAGE change, jamais parce que le test a tiré un nouvel UUID.
    private enum Fixture {
        static let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        static let otherProjectID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        static let slotAID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        static let slotBID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
        static let assignmentAID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
        static let assignmentBID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        static let otherAssignmentID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000009")!
    }

    private func makeAssignment(
        id: UUID,
        assetIdentifier: String,
        status: ClipAssignmentStatus = .ready
    ) -> ClipAssignmentSnapshot {
        ClipAssignmentSnapshot(id: id, assetLocalIdentifier: assetIdentifier, status: status)
    }

    private func makeSlot(
        id: UUID,
        index: Int,
        startTicks: Int64,
        endTicks: Int64,
        assignment: ClipAssignmentSnapshot?
    ) -> ProjectSlot {
        ProjectSlot(
            id: id,
            index: index,
            start: MediaTime(ticks: startTicks),
            end: MediaTime(ticks: endTicks),
            assignment: assignment
        )
    }

    /// Montage de référence : deux cases jointives (§28.1), toutes deux
    /// prêtes, sans géométrie verrouillée.
    ///
    /// Chaque paramètre isole EXACTEMENT une cause d'invalidation §48.
    private func makeSnapshot(
        projectID: UUID = Fixture.projectID,
        firstAssignmentID: UUID = Fixture.assignmentAID,
        firstAssetIdentifier: String = "asset-A",
        firstStatus: ClipAssignmentStatus = .ready,
        firstSlotEndTicks: Int64 = 1_000,
        secondAssignment: Bool = true,
        geometry: ProjectGeometry? = nil
    ) -> ProjectSnapshot {
        let first = makeSlot(
            id: Fixture.slotAID,
            index: 0,
            startTicks: 0,
            endTicks: firstSlotEndTicks,
            assignment: makeAssignment(
                id: firstAssignmentID,
                assetIdentifier: firstAssetIdentifier,
                status: firstStatus
            )
        )
        let second = makeSlot(
            id: Fixture.slotBID,
            index: 1,
            startTicks: firstSlotEndTicks,
            endTicks: 2_000,
            assignment: secondAssignment
                ? makeAssignment(id: Fixture.assignmentBID, assetIdentifier: "asset-B")
                : nil
        )
        return ProjectSnapshot(projectID: projectID, slots: [first, second], geometry: geometry)
    }

    private func makeGeometry() -> ProjectGeometry {
        ProjectGeometry(
            aspectWidth: 9,
            aspectHeight: 16,
            orientation: .portrait,
            lockedByAssetIdentifier: "asset-A"
        )
    }

    /// Composition mise en cache — objet AVFoundation VIDE : aucun fichier,
    /// aucune piste, aucun décodage. Seule son IDENTITÉ est vérifiée.
    private func makeComposition() -> CachedComposition {
        CachedComposition(asset: AVMutableComposition(), videoComposition: nil)
    }

    private func makeKey(
        projectID: UUID = Fixture.projectID,
        scopeKey: String,
        fingerprint: String = "empreinte"
    ) -> PreviewCacheKey {
        PreviewCacheKey(
            projectID: projectID,
            scopeKey: scopeKey,
            assignmentsFingerprint: fingerprint
        )
    }

    // MARK: - Portées §47

    /// Les trois portées §47 décrivent trois compositions différentes : leurs
    /// clés ne doivent JAMAIS se confondre (sinon l'aperçu d'une case
    /// resservirait le montage complet).
    func testScopeKeyDistinguishesTheThreeScopes() {
        let slotKey = PreviewCacheKey.scopeKey(for: .slot(Fixture.slotAID))
        let prefixKey = PreviewCacheKey.scopeKey(for: .contiguousPrefix)
        let completeKey = PreviewCacheKey.scopeKey(for: .complete)

        XCTAssertEqual(Set([slotKey, prefixKey, completeKey]).count, 3)
    }

    /// Deux cases différentes = deux aperçus locaux différents (§47.1).
    func testScopeKeyDistinguishesTwoSlots() {
        XCTAssertNotEqual(
            PreviewCacheKey.scopeKey(for: .slot(Fixture.slotAID)),
            PreviewCacheKey.scopeKey(for: .slot(Fixture.slotBID))
        )
    }

    /// Stabilité : une même portée redonne toujours la même identité — sans
    /// quoi aucune entrée ne serait jamais retrouvée.
    func testScopeKeyIsStableForTheSameScope() {
        XCTAssertEqual(
            PreviewCacheKey.scopeKey(for: .slot(Fixture.slotAID)),
            PreviewCacheKey.scopeKey(for: .slot(Fixture.slotAID))
        )
        XCTAssertEqual(
            PreviewCacheKey.scopeKey(for: .contiguousPrefix),
            PreviewCacheKey.scopeKey(for: .contiguousPrefix)
        )
        XCTAssertEqual(
            PreviewCacheKey.scopeKey(for: .complete),
            PreviewCacheKey.scopeKey(for: .complete)
        )
    }

    // MARK: - Empreinte du montage §48

    /// Contrat §48 : « tant que les associations ne changent pas ». Un même
    /// état de montage reconstruit doit redonner LA MÊME empreinte, sinon le
    /// cache manquerait à chaque ouverture.
    func testFingerprintIsStableForAnIdenticalSnapshot() {
        let first = PreviewCacheKey.fingerprint(for: makeSnapshot())
        let second = PreviewCacheKey.fingerprint(for: makeSnapshot())

        XCTAssertEqual(first, second)
    }

    /// §48 : « une association change » — même rush, mais association
    /// remplacée (identité différente).
    func testFingerprintChangesWhenAssignmentIdentityChanges() {
        XCTAssertNotEqual(
            PreviewCacheKey.fingerprint(for: makeSnapshot()),
            PreviewCacheKey.fingerprint(for: makeSnapshot(firstAssignmentID: Fixture.otherAssignmentID))
        )
    }

    /// §48 : « une association change » — autre rush dans la même case.
    func testFingerprintChangesWhenAssetChanges() {
        XCTAssertNotEqual(
            PreviewCacheKey.fingerprint(for: makeSnapshot()),
            PreviewCacheKey.fingerprint(for: makeSnapshot(firstAssetIdentifier: "asset-Z"))
        )
    }

    /// §48 : « un asset devient indisponible » — le statut fait partie de
    /// l'empreinte, une composition construite sur une case `ready` ne peut
    /// pas resservir pour une case devenue `unavailable`.
    func testFingerprintChangesWhenStatusChanges() {
        let ready = PreviewCacheKey.fingerprint(for: makeSnapshot())
        let downloading = PreviewCacheKey.fingerprint(for: makeSnapshot(firstStatus: .downloading))
        let unavailable = PreviewCacheKey.fingerprint(for: makeSnapshot(firstStatus: .unavailable))

        XCTAssertEqual(Set([ready, downloading, unavailable]).count, 3)
    }

    /// §48 : « le rythme change avant verrouillage » — une frontière de case
    /// déplacée change les plages insérées, donc la composition.
    func testFingerprintChangesWhenSlotBoundaryChanges() {
        XCTAssertNotEqual(
            PreviewCacheKey.fingerprint(for: makeSnapshot()),
            PreviewCacheKey.fingerprint(for: makeSnapshot(firstSlotEndTicks: 1_200))
        )
    }

    /// §48 : « la géométrie change lors du premier rush » — la taille de
    /// rendu et les transformations §50 en dépendent entièrement.
    func testFingerprintChangesWhenGeometryIsLocked() {
        XCTAssertNotEqual(
            PreviewCacheKey.fingerprint(for: makeSnapshot(geometry: nil)),
            PreviewCacheKey.fingerprint(for: makeSnapshot(geometry: makeGeometry()))
        )
    }

    /// Une case vidée interrompt le segment exportable : l'empreinte doit le
    /// voir.
    func testFingerprintChangesWhenSlotBecomesEmpty() {
        XCTAssertNotEqual(
            PreviewCacheKey.fingerprint(for: makeSnapshot()),
            PreviewCacheKey.fingerprint(for: makeSnapshot(secondAssignment: false))
        )
    }

    /// CHANGEMENT PRODUIT : l'aperçu principal porte sur le SEGMENT continu
    /// de cases prêtes, qui peut commencer n'importe où. Deux montages dont le
    /// segment n'a PAS le même `musicStart` produisent des compositions
    /// différentes (décalage `slot.start - musicStart` différent, portion de
    /// musique différente) : la clé de cache doit les distinguer.
    ///
    /// C'est ce que garantit `fingerprint`, sans que la clé ait besoin de
    /// porter le segment : le segment se déduit entièrement des statuts et des
    /// frontières, tous deux déjà couverts.
    func testFingerprintDistinguishesTwoDifferentReadySegments() {
        // Cases 0 et 1 prêtes → segment [0, 1], musicStart = 0.
        let wholeMontage = makeSnapshot()
        // Case 0 en téléchargement → segment [1] seul, musicStart = 1 000.
        let shiftedSegment = makeSnapshot(firstStatus: .downloading)

        XCTAssertEqual(wholeMontage.contiguousReadySegment.musicStart, MediaTime(ticks: 0))
        XCTAssertEqual(shiftedSegment.contiguousReadySegment.musicStart, MediaTime(ticks: 1_000))
        XCTAssertNotEqual(
            PreviewCacheKey(scope: .contiguousPrefix, snapshot: wholeMontage),
            PreviewCacheKey(scope: .contiguousPrefix, snapshot: shiftedSegment)
        )
    }

    /// La clé complète combine les trois composantes : projet, portée,
    /// empreinte. Deux projets ne partagent JAMAIS une entrée, même à
    /// montage identique.
    func testKeyCombinesProjectScopeAndFingerprint() {
        let snapshot = makeSnapshot()
        let key = PreviewCacheKey(scope: .contiguousPrefix, snapshot: snapshot)

        XCTAssertEqual(key.projectID, Fixture.projectID)
        XCTAssertEqual(key.scopeKey, PreviewCacheKey.scopeKey(for: .contiguousPrefix))
        XCTAssertEqual(key.assignmentsFingerprint, PreviewCacheKey.fingerprint(for: snapshot))

        let otherProjectKey = PreviewCacheKey(
            scope: .contiguousPrefix,
            snapshot: makeSnapshot(projectID: Fixture.otherProjectID)
        )
        XCTAssertNotEqual(key, otherProjectKey)
    }

    // MARK: - Cache §48

    func testStoredCompositionIsReturnedForTheSameKey() {
        let cache = PreviewCache()
        let key = makeKey(scopeKey: "prefix")
        let composition = makeComposition()

        cache.store(composition, for: key)

        XCTAssertTrue(cache.composition(for: key)?.asset === composition.asset)
    }

    func testUnknownKeyReturnsNil() {
        let cache = PreviewCache()
        cache.store(makeComposition(), for: makeKey(scopeKey: "prefix"))

        XCTAssertNil(cache.composition(for: makeKey(scopeKey: "complete")))
    }

    /// §67/§68 : la mémoire est bornée. Au-delà de la capacité, l'entrée la
    /// plus anciennement utilisée disparaît — jamais une perte de données,
    /// la composition est reconstruite à la demande.
    func testEvictsTheLeastRecentlyUsedEntryBeyondCapacity() {
        let cache = PreviewCache()
        let keys = (0...PreviewCache.capacity).map { makeKey(scopeKey: "slot:\($0)") }
        for key in keys {
            cache.store(makeComposition(), for: key)
        }

        XCTAssertNil(cache.composition(for: keys[0]), "La plus ancienne entrée doit être évincée")
        for key in keys.dropFirst() {
            XCTAssertNotNil(cache.composition(for: key))
        }
    }

    /// Un accès rafraîchit la position LRU : l'aperçu qu'on relit ne se fait
    /// pas évincer par un aperçu local ponctuel.
    func testReadingAnEntryProtectsItFromEviction() {
        let cache = PreviewCache()
        let keys = (0..<PreviewCache.capacity).map { makeKey(scopeKey: "slot:\($0)") }
        for key in keys {
            cache.store(makeComposition(), for: key)
        }

        // La plus ancienne est relue : elle redevient la plus récente.
        XCTAssertNotNil(cache.composition(for: keys[0]))
        cache.store(makeComposition(), for: makeKey(scopeKey: "complete"))

        XCTAssertNotNil(cache.composition(for: keys[0]), "L'entrée relue doit survivre")
        XCTAssertNil(cache.composition(for: keys[1]), "La suivante devient la plus ancienne")
    }

    /// §48/§65 : filet de sécurité par projet — invalider un projet ne touche
    /// jamais les compositions d'un autre projet.
    func testInvalidateAllIsLimitedToOneProject() {
        let cache = PreviewCache()
        let target = makeKey(projectID: Fixture.projectID, scopeKey: "prefix")
        let targetSlot = makeKey(projectID: Fixture.projectID, scopeKey: "slot:1")
        let other = makeKey(projectID: Fixture.otherProjectID, scopeKey: "prefix")
        cache.store(makeComposition(), for: target)
        cache.store(makeComposition(), for: targetSlot)
        cache.store(makeComposition(), for: other)

        cache.invalidateAll(projectID: Fixture.projectID)

        XCTAssertNil(cache.composition(for: target))
        XCTAssertNil(cache.composition(for: targetSlot))
        XCTAssertNotNil(cache.composition(for: other), "Les autres projets ne sont pas touchés")
    }

    /// Une composition invalidée est RECONSTRUITE, jamais ressuscitée : la
    /// même clé peut être re-rangée juste après une invalidation.
    func testStoringAgainAfterInvalidationWorks() {
        let cache = PreviewCache()
        let key = makeKey(scopeKey: "prefix")
        cache.store(makeComposition(), for: key)
        cache.invalidateAll(projectID: Fixture.projectID)

        let rebuilt = makeComposition()
        cache.store(rebuilt, for: key)

        XCTAssertTrue(cache.composition(for: key)?.asset === rebuilt.asset)
    }
}
