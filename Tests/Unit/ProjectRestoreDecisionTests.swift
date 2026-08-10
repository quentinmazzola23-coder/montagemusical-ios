//
//  ProjectRestoreDecisionTests.swift
//  MontageMusicalTests
//
//  Règle §60 « Restaurer : projet » — décision de réouverture au lancement,
//  isolée de l'écran d'accueil (`ProjectRestore.decision`, définie dans
//  `App/Features/ProjectList/ProjectListView.swift`).
//
//  Aucune vue n'est instanciée, aucune base n'est ouverte : la décision est
//  une fonction PURE de deux entrées — l'identifiant MÉMORISÉ (état de scène)
//  et le résumé du projet correspondant tel que le `ProjectStore` le rend
//  (`nil` s'il n'existe plus).
//
//  Les cinq situations couvertes sont exactement celles que l'écran doit
//  distinguer :
//  1. identifiant vide (l'utilisateur avait quitté vers la liste) ;
//  2. identifiant illisible (préférence corrompue, valeur d'une version
//     antérieure) ;
//  3. projet absent (supprimé depuis, base réinitialisée) ;
//  4. brouillon SANS contenu — §31 le supprime de toute façon au retour à
//     l'accueil : il ne doit JAMAIS être restauré ;
//  5. cas nominal — projet existant et non vide → réouverture.
//

import XCTest
@testable import MontageMusical

final class ProjectRestoreDecisionTests: XCTestCase {

    // MARK: - Fabrique de résumés (§31)

    /// Résumé minimal d'un projet — seuls `id` et `hasContent` pèsent sur la
    /// décision §60 ; les autres champs sont neutres.
    private func makeSummary(
        id: UUID,
        hasContent: Bool,
        status: ProjectStatus = .assembling
    ) -> ProjectSummary {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        return ProjectSummary(
            id: id,
            displayTitle: "Projet de test",
            createdAt: date,
            updatedAt: date,
            status: status,
            hasContent: hasContent
        )
    }

    // MARK: - 1. Identifiant vide

    func testEmptyIdentifierRestoresNothingAndErasesNothing() {
        // Aucun projet mémorisé : il n'y a ni projet à rouvrir, ni valeur à
        // effacer — `.none`, et surtout pas `.forget` (une écriture inutile
        // dans l'état de scène à chaque lancement).
        // `ProjectRestoreDecision.none` est écrit en toutes lettres : `.none`
        // seul se confondrait avec `Optional.none` à la résolution de types.
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: "", summary: nil),
            ProjectRestoreDecision.none,
            "Identifiant vide → aucune restauration (§60)"
        )
        // Une valeur réduite à des espaces vaut vide (jamais un UUID).
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: "   ", summary: nil),
            ProjectRestoreDecision.none
        )
    }

    // MARK: - 2. Identifiant illisible

    func testInvalidUUIDIsForgotten() {
        // Valeur qui n'est pas un UUID : elle ne désignera jamais un projet.
        // La garder ferait retenter la lecture à chaque lancement.
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: "pas-un-uuid", summary: nil),
            .forget,
            "Identifiant illisible → oublié (§60)"
        )
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: "12345", summary: nil),
            .forget
        )
    }

    // MARK: - 3. Projet absent

    func testMissingProjectIsForgotten() {
        // UUID valide, mais le `ProjectStore` ne connaît plus ce projet
        // (supprimé depuis, brouillon vide balayé §31, base réinitialisée) :
        // retour à la liste, jamais d'écran vide.
        let projectID = UUID()
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: projectID.uuidString, summary: nil),
            .forget,
            "Projet supprimé entre-temps → retour à la liste (§60)"
        )
    }

    func testSummaryOfAnotherProjectIsForgotten() {
        // Garde-fou : un résumé qui ne correspond PAS à l'identifiant
        // mémorisé ne doit jamais provoquer l'ouverture d'un autre projet.
        let storedID = UUID()
        let otherSummary = makeSummary(id: UUID(), hasContent: true)
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: storedID.uuidString, summary: otherSummary),
            .forget,
            "Résumé d'un autre projet → jamais rouvert (§60)"
        )
    }

    // MARK: - 4. Brouillon sans contenu (§31)

    func testEmptyDraftIsNeverRestored() {
        // §31 : un brouillon sans musique est supprimé au retour à l'accueil
        // et par le balayage au lancement (§69A). Le restaurer n'aurait aucun
        // sens et créerait une course avec ce balayage.
        let projectID = UUID()
        let draft = makeSummary(id: projectID, hasContent: false, status: .draft)
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: projectID.uuidString, summary: draft),
            .forget,
            "Brouillon sans contenu → jamais restauré (§60/§31)"
        )
    }

    // MARK: - 5. Cas nominal

    func testExistingProjectWithContentIsReopened() {
        let projectID = UUID()
        let summary = makeSummary(id: projectID, hasContent: true)
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: projectID.uuidString, summary: summary),
            .open(projectID),
            "Projet existant avec contenu → rouvert au lancement (§60)"
        )
    }

    func testIdentifierIsAcceptedRegardlessOfLetterCase() {
        // `UUID(uuidString:)` accepte les deux casses ; la décision doit rendre
        // l'identifiant CANONIQUE du projet, celui qui sera poussé dans le
        // chemin de navigation.
        let projectID = UUID()
        let lowercased = projectID.uuidString.lowercased()
        let summary = makeSummary(id: projectID, hasContent: true)
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: lowercased, summary: summary),
            .open(projectID)
        )
    }

    // MARK: - Décision d'un projet terminé (§60)

    func testCompletedProjectIsReopened() {
        // Un projet exporté (§60 : « dernier export réussi » restauré par
        // l'écran d'export) se rouvre comme les autres.
        let projectID = UUID()
        let summary = makeSummary(id: projectID, hasContent: true, status: .complete)
        XCTAssertEqual(
            ProjectRestore.decision(storedIdentifier: projectID.uuidString, summary: summary),
            .open(projectID)
        )
    }
}
