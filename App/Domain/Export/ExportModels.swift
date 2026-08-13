//
//  ExportModels.swift
//  MontageMusical
//
//  Portées de prévisualisation (spec §47, verbatim), portée d'export,
//  snapshots de projet et SEGMENT EXPORTABLE.
//
//  ═══════════════════════════════════════════════════════════════════════
//  CHANGEMENT PRODUIT — le SEGMENT remplace le PRÉFIXE (remplace §51)
//  ═══════════════════════════════════════════════════════════════════════
//
//  **Ce qui change et pourquoi.** §51 (« Préfixe exportable ») faisait partir
//  l'export de la case 0 : `contiguousReadyPrefix` s'arrêtait au premier trou
//  et rendait l'export IMPOSSIBLE dès que la PREMIÈRE case était vide — même
//  si vingt cases plus loin étaient prêtes. Sur demande EXPLICITE de
//  l'utilisateur, POSTÉRIEURE à la spécification, l'export porte désormais sur
//  le SEGMENT CONTINU de cases prêtes, **où qu'il commence**.
//  Exemple donné par l'utilisateur : cases 28 à 50 remplies → l'export
//  contient ces 23 plans.
//
//  **Règle exacte** (implémentée par `contiguousReadySegment(slots:)`) :
//  1. trier les cases par index ;
//  2. trouver la PREMIÈRE case dont l'association est `ready` ;
//  3. avancer tant que les cases suivantes sont `ready` ; s'arrêter au
//     premier trou (case vide, ou association `resolving` / `downloading` /
//     `unavailable` / `tooShort`) ;
//  4. ce segment EST le montage exporté. S'il existe plusieurs segments,
//     c'est le PREMIER qui compte — comportement prévisible, dont la
//     mini-timeline montre les bornes.
//
//  **Ce qui NE change PAS** :
//  - aucune case n'est jamais DÉPLACÉE : les cases gardent leurs temps
//    musicaux ABSOLUS (§9, §53 ; principe « les clips ultérieurs ne sont
//    jamais déplacés » §51) ;
//  - aucun écran noir n'est ajouté (§51) ;
//  - si aucune case n'est prête, l'export reste IMPOSSIBLE (bouton
//    désactivé) — `ReadySegment.isEmpty`.
//
//  **Conséquence temporelle — le point critique.** Le montage ne commence
//  plus forcément à l'instant 0 de la musique. Pour un segment
//  [première, dernière] :
//
//      musicStart = première.start          (instant ABSOLU dans le morceau)
//      musicEnd   = dernière.end
//      durée      = musicEnd - musicStart
//
//  Dans la composition (§48, §54) :
//  - la MUSIQUE insérée est la PORTION `[musicStart, musicEnd]` du fichier
//    ORIGINAL, placée à l'instant 0 de la composition ;
//  - la VIDÉO de la case `i` est placée à `(slot.start - musicStart)`, pour
//    une durée `(slot.end - slot.start)` — c'est
//    `ReadySegment.compositionStart(of:)`.
//
//  Tout reste en TICKS entiers (§9) : aucune conversion en secondes, aucun
//  arrondi cumulatif. Un segment commençant à `musicStart` produit donc
//  exactement le même son et les mêmes frontières que la portion
//  correspondante du morceau — seule l'ORIGINE de la timeline exportée a
//  changé.
//
//  `contiguousReadyPrefix` est SUPPRIMÉ : il n'existe plus de notion de
//  préfixe dans le domaine.
//

import Foundation

// MARK: - Portées de prévisualisation (spec §47, verbatim)

enum PreviewScope: Sendable {
    case slot(UUID)
    /// Aperçu principal (§47.2). Le nom du cas est CONSERVÉ pour ne pas casser
    /// l'API §7 et ses appelants, mais il désigne désormais le SEGMENT continu
    /// de cases prêtes (voir l'en-tête de ce fichier), plus le préfixe §51.
    case contiguousPrefix
    case complete
}

// MARK: - Portée d'export

// Non defini par la specification — definition minimale V1.
enum ExportScope: Sendable {
    /// Segment continu de cases prêtes (voir l'en-tête). Nom conservé pour la
    /// stabilité de l'API.
    case contiguousPrefix
    case complete
}

// MARK: - Résultat d'export

// Non defini par la specification — definition minimale V1.
struct ExportResult: Codable, Sendable {
    let outputURL: URL
    /// Durée du fichier produit = `musicEnd - musicStart` du segment exporté
    /// (et NON la fin absolue de la dernière case : le montage ne commence
    /// plus forcément à l'instant 0 de la musique).
    let duration: MediaTime
    let slotCount: Int
}

// MARK: - Snapshots (support)

// Non defini par la specification — definition minimale V1.
struct ClipAssignmentSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let assetLocalIdentifier: String
    let status: ClipAssignmentStatus
}

// Non defini par la specification — definition minimale V1.
struct ProjectSlot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let index: Int
    let start: MediaTime
    let end: MediaTime
    let assignment: ClipAssignmentSnapshot?
}

extension ProjectSlot {
    /// Durée calculée `end - start` — jamais persistée (spec §9, §13.2).
    var duration: MediaTime { end - start }
}

// Non defini par la specification — definition minimale V1.
struct ProjectSnapshot: Codable, Sendable {
    let projectID: UUID
    let slots: [ProjectSlot]
    let geometry: ProjectGeometry?

    /// Segment continu de cases prêtes, prêt à prévisualiser/exporter
    /// (changement produit — voir l'en-tête de ce fichier).
    var contiguousReadySegment: ReadySegment {
        MontageMusical.contiguousReadySegment(slots: slots)
    }
}

// MARK: - Segment exportable (changement produit — remplace le préfixe §51)

/// Suite CONTIGUË de cases prêtes, où qu'elle commence dans le morceau.
///
/// Les cases conservent leurs temps musicaux ABSOLUS (§9, §53) : `slots` n'est
/// jamais recompacté, jamais décalé. Le décalage n'existe qu'au moment de
/// construire la composition, et il est calculé par `compositionStart(of:)` —
/// jamais réécrit dans les cases.
///
/// Un segment VIDE (`isEmpty`) signifie « aucune case prête » : l'export et
/// l'aperçu principal sont alors impossibles (bouton désactivé).
struct ReadySegment: Sendable, Equatable {

    /// Cases prêtes contiguës, dans l'ordre d'index CROISSANT (vide si aucune
    /// case n'est prête).
    let slots: [ProjectSlot]

    /// Segment vide : aucune case prête (export/aperçu principal désactivés).
    static let empty = ReadySegment(slots: [])

    init(slots: [ProjectSlot]) {
        self.slots = slots
    }

    /// Aucune case prête → rien à prévisualiser ni à exporter.
    var isEmpty: Bool { slots.isEmpty }

    /// Nombre de plans du montage exporté (§56 : « 12 plans • 18,43 s »).
    var slotCount: Int { slots.count }

    /// Instant ABSOLU, dans le morceau, où commence le montage exporté.
    ///
    /// C'est la portion de musique à insérer à l'instant 0 de la composition
    /// — plus forcément le début du morceau.
    var musicStart: MediaTime { slots.first?.start ?? .zero }

    /// Instant ABSOLU, dans le morceau, où s'arrête le montage exporté.
    var musicEnd: MediaTime { slots.last?.end ?? .zero }

    /// Durée du montage exporté : `musicEnd - musicStart`, en ticks exacts
    /// (§9). Zéro pour un segment vide.
    var duration: MediaTime { musicEnd - musicStart }

    /// Index de la PREMIÈRE case du segment — pour l'affichage
    /// « Plans 28 à 50 ». `nil` si le segment est vide.
    var startIndex: Int? { slots.first?.index }

    /// Index de la DERNIÈRE case du segment. `nil` si le segment est vide.
    var endIndex: Int? { slots.last?.index }

    /// Instant de composition d'une case du segment : `slot.start - musicStart`.
    ///
    /// **C'est LE calcul du changement produit**, isolé ici pour être testable
    /// sans AVFoundation : la case garde son temps musical absolu, seule la
    /// timeline exportée est ramenée à zéro. La première case du segment tombe
    /// donc exactement à `.zero`, et l'écart entre deux cases reste
    /// rigoureusement celui de la musique (§53 : la musique est l'horloge
    /// maîtresse).
    ///
    /// Arithmétique en ticks entiers (§9) : aucun arrondi, aucune dérive, quel
    /// que soit le rang de la case dans le morceau.
    func compositionStart(of slot: ProjectSlot) -> MediaTime {
        slot.start - musicStart
    }
}

/// Segment continu de cases prêtes — voir l'en-tête de ce fichier (changement
/// produit qui remplace l'algorithme §51 `contiguousReadyPrefix`).
///
/// Règles :
/// - tri par index, puis recherche de la PREMIÈRE case `ready` ;
/// - avancée tant que les cases suivantes sont `ready` ;
/// - arrêt au premier trou : case vide, ou association `resolving` /
///   `downloading` / `unavailable` / `tooShort` ;
/// - plusieurs segments possibles → le PREMIER gagne (comportement
///   prévisible) ;
/// - segment vide → export et aperçu principal désactivés ;
/// - aucun écran noir n'est ajouté, aucune case n'est déplacée : les temps
///   restent ABSOLUS.
func contiguousReadySegment(slots: [ProjectSlot]) -> ReadySegment {
    var result: [ProjectSlot] = []
    for slot in slots.sorted(by: { $0.index < $1.index }) {
        if slot.assignment?.status == .ready {
            result.append(slot)
        } else if !result.isEmpty {
            // Premier trou APRÈS le début du segment : on s'arrête là. Les
            // cases prêtes situées au-delà forment d'autres segments, qui ne
            // sont PAS exportés (et ne sont jamais avancées pour combler le
            // trou).
            break
        }
        // Trou AVANT tout début de segment : simplement ignoré — c'est ce qui
        // distingue le segment du préfixe §51.
    }
    return ReadySegment(slots: result)
}
