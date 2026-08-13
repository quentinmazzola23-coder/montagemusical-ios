//
//  ExportModels.swift
//  MontageMusical
//
//  Portées de prévisualisation (spec §47, verbatim), portée d'export,
//  snapshots de projet et TIMELINE EXPORTABLE.
//
//  ═══════════════════════════════════════════════════════════════════════
//  CHANGEMENT PRODUIT — la TIMELINE CONCATÉNÉE remplace le SEGMENT unique
//  (qui remplaçait lui-même le PRÉFIXE §51)
//  ═══════════════════════════════════════════════════════════════════════
//
//  **Ce qui change et pourquoi.** §51 (« Préfixe exportable ») faisait partir
//  l'export de la case 0 et s'arrêtait au premier trou. Un premier écart
//  produit l'avait remplacé par le PREMIER segment continu de cases prêtes,
//  où qu'il commence. L'utilisateur demande maintenant, explicitement et
//  POSTÉRIEUREMENT à cette spécification : « n'exporte que les parties avec de
//  la vidéo ». Autrement dit l'export CONCATÈNE **toutes** les zones remplies,
//  et les cases vides (ou non prêtes) sont PUREMENT SUPPRIMÉES du montage —
//  vidéo ET musique.
//
//      Exemple de l'utilisateur : cases 28…35 prêtes, 36…39 vides,
//      40…50 prêtes → montage = 8 plans + 11 plans = 19 plans mis bout à
//      bout, d'une durée égale à la somme des durées de ces 19 cases. La
//      portion de musique des cases 36…39 n'existe PAS dans le fichier
//      exporté.
//
//  ─────────────────────────────────────────────────────────────────────
//  MODÈLE TEMPOREL (le point critique)
//  ─────────────────────────────────────────────────────────────────────
//
//  - un **RUN** (`ReadyRun`) est une suite MAXIMALE de cases prêtes contiguës
//    (28…35 est un run, 40…50 en est un autre) ;
//  - les runs sont CONCATÉNÉS dans l'ordre des index ;
//  - **position de composition du run `r`** = somme des durées de TOUTES les
//    cases prêtes des runs précédents
//    (`ReadyTimeline.compositionStart(ofRun:)`) ;
//  - à l'intérieur d'un run, les cases restent JOINTIVES et gardent leurs
//    écarts d'origine : aucune case n'est déplacée par rapport à ses voisines
//    du même run ;
//  - **MUSIQUE** : pour chaque run, la portion `[run.musicStart, run.musicEnd]`
//    du fichier audio ORIGINAL est insérée à la position de composition du
//    run. La musique est donc CONTINUE à l'intérieur d'un run et **SAUTE à
//    chaque jonction entre runs** — conséquence ASSUMÉE et DOCUMENTÉE de la
//    demande : supprimer les cases vides du montage, c'est supprimer le
//    passage musical qu'elles couvraient ;
//  - **VIDÉO** : la case `i` est placée à
//    `(position du run) + (slot.start - run.musicStart)`
//    (`ReadyTimeline.compositionStart(of:)`) ;
//  - **durée totale du montage** = somme des durées de toutes les cases
//    prêtes (§28.1 : les cases d'un run pavent la musique sans trou, donc
//    `run.duration == musicEnd - musicStart == somme des durées de ses
//    cases`).
//
//  ─────────────────────────────────────────────────────────────────────
//  CE QUI NE CHANGE PAS
//  ─────────────────────────────────────────────────────────────────────
//
//  - une case prête n'est **JAMAIS omise** : toutes les zones remplies sont
//    exportées, plus seulement la première ;
//  - **aucun écran noir** n'est ajouté (§51) : un trou n'est pas comblé, il
//    est SUPPRIMÉ ;
//  - les cases gardent leurs temps musicaux ABSOLUS (§9, §53) : `slots` n'est
//    jamais recompacté ni réécrit. La concaténation n'existe qu'au moment de
//    construire la composition, calculée par `compositionStart(of:)` ;
//  - tout reste en **TICKS entiers** (§9) : aucune conversion en secondes,
//    aucun arrondi cumulatif, quel que soit le nombre de runs ;
//  - si aucune case n'est prête, l'export reste IMPOSSIBLE (bouton désactivé)
//    — `ReadyTimeline.isEmpty`.
//
//  `contiguousReadyPrefix` (§51) et `ReadySegment` / `contiguousReadySegment`
//  (premier écart produit) sont SUPPRIMÉS : il n'existe plus ni préfixe ni
//  segment unique dans le domaine, seulement la TIMELINE des runs.
//

import Foundation

// MARK: - Portées de prévisualisation (spec §47, verbatim)

enum PreviewScope: Sendable {
    case slot(UUID)
    /// Aperçu principal (§47.2). Le nom du cas est CONSERVÉ pour ne pas casser
    /// l'API §7 et ses appelants, mais il désigne désormais la TIMELINE
    /// concaténée de toutes les zones remplies (voir l'en-tête de ce fichier),
    /// plus le préfixe §51 ni le segment unique.
    case contiguousPrefix
    case complete
}

// MARK: - Portée d'export

// Non defini par la specification — definition minimale V1.
enum ExportScope: Sendable {
    /// Timeline concaténée des cases prêtes (voir l'en-tête). Nom conservé
    /// pour la stabilité de l'API.
    case contiguousPrefix
    case complete
}

// MARK: - Résultat d'export

// Non defini par la specification — definition minimale V1.
struct ExportResult: Codable, Sendable {
    let outputURL: URL
    /// Durée du fichier produit = SOMME des durées de toutes les cases
    /// exportées (et NON `dernière.end - première.start` : les zones vides
    /// n'existent pas dans le fichier).
    let duration: MediaTime
    /// Nombre TOTAL de plans exportés, tous runs confondus.
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

    /// Timeline exportable : toutes les zones remplies, concaténées
    /// (changement produit — voir l'en-tête de ce fichier).
    var readyTimeline: ReadyTimeline {
        MontageMusical.readyTimeline(slots: slots)
    }
}

// MARK: - Run : une zone remplie (changement produit)

/// Suite MAXIMALE de cases prêtes CONTIGUËS, où qu'elle commence dans le
/// morceau. C'est l'unité de concaténation : le montage exporté est la suite
/// des runs mis bout à bout.
///
/// Les cases conservent leurs temps musicaux ABSOLUS (§9, §53) : `slots` n'est
/// jamais recompacté, jamais décalé. Le décalage n'existe qu'au moment de
/// construire la composition, et il est calculé par
/// `ReadyTimeline.compositionStart(of:)` — jamais réécrit dans les cases.
///
/// Un run est **toujours NON VIDE** : c'est ce qu'impose `init?(slots:)`, et
/// c'est ce qui rend `musicStart`, `musicEnd`, `startIndex` et `endIndex`
/// non optionnels. Un montage sans aucune case prête n'a pas de run — il a une
/// `ReadyTimeline` vide.
struct ReadyRun: Sendable, Equatable {

    /// Cases prêtes contiguës, dans l'ordre d'index CROISSANT. Jamais vide.
    let slots: [ProjectSlot]

    /// Construit un run. Rend `nil` pour une liste VIDE : un run vide n'a pas
    /// de sens (ni bornes musicales, ni index), et l'interdire ici dispense
    /// tout le reste du domaine de le tester.
    init?(slots: [ProjectSlot]) {
        guard !slots.isEmpty else { return nil }
        self.slots = slots
    }

    /// Nombre de plans de ce run.
    var slotCount: Int { slots.count }

    /// Instant ABSOLU, dans le morceau, où commence ce run.
    ///
    /// C'est le début de la PORTION de musique à insérer à la position de
    /// composition du run — plus forcément le début du morceau.
    var musicStart: MediaTime { slots[0].start }

    /// Instant ABSOLU, dans le morceau, où s'arrête ce run.
    var musicEnd: MediaTime { slots[slots.count - 1].end }

    /// Durée du run, en ticks exacts (§9) : `musicEnd - musicStart`.
    ///
    /// Les cases d'un run étant jointives par construction (§28.1 : la
    /// partition pave la musique sans trou), cette durée vaut exactement la
    /// SOMME des durées de ses cases.
    var duration: MediaTime { musicEnd - musicStart }

    /// Index de la PREMIÈRE case du run — pour l'affichage « Plans 28 à 35 ».
    var startIndex: Int { slots[0].index }

    /// Index de la DERNIÈRE case du run.
    var endIndex: Int { slots[slots.count - 1].index }

    /// Instant de composition d'une case DANS ce run : `slot.start - musicStart`.
    ///
    /// Position RELATIVE au début du run ; la position finale dans le montage
    /// ajoute la position du run (`ReadyTimeline.compositionStart(of:)`).
    /// Arithmétique en ticks entiers (§9) : l'écart entre deux cases d'un même
    /// run reste rigoureusement celui de la musique (§53).
    func offset(of slot: ProjectSlot) -> MediaTime {
        slot.start - musicStart
    }
}

// MARK: - Timeline exportable : les runs concaténés (changement produit)

/// Montage réellement exporté : TOUTES les zones remplies, concaténées dans
/// l'ordre des index.
///
/// Modèle temporel complet en tête de ce fichier. En résumé :
/// - `compositionStart(ofRun:)` = somme des durées des runs précédents ;
/// - `compositionStart(of: slot)` = position du run + `slot.start - run.musicStart` ;
/// - `duration` = somme des durées des runs = somme des durées de TOUTES les
///   cases exportées ;
/// - la musique est insérée PAR RUN : continue à l'intérieur d'un run, elle
///   SAUTE à chaque jonction — c'est la conséquence assumée de « n'exporte que
///   les parties avec de la vidéo ».
///
/// Une timeline VIDE (`isEmpty`) signifie « aucune case prête » : l'export et
/// l'aperçu principal sont alors impossibles (bouton désactivé).
struct ReadyTimeline: Sendable, Equatable {

    /// Runs dans l'ordre des index (vide si aucune case n'est prête).
    let runs: [ReadyRun]

    /// Timeline vide : aucune case prête (export/aperçu principal désactivés).
    static let empty = ReadyTimeline(runs: [])

    init(runs: [ReadyRun]) {
        self.runs = runs
    }

    /// Aucune case prête → rien à prévisualiser ni à exporter.
    var isEmpty: Bool { runs.isEmpty }

    /// Nombre TOTAL de plans du montage exporté, tous runs confondus
    /// (§56 : « 19 plans • 9,50 s »).
    var slotCount: Int {
        runs.reduce(0) { $0 + $1.slotCount }
    }

    /// Durée du montage exporté : SOMME des durées des runs, en ticks exacts
    /// (§9). Zéro pour une timeline vide.
    ///
    /// Ce n'est PAS `dernière.end - première.start` : les portions vides sont
    /// supprimées du fichier, musique comprise.
    var duration: MediaTime {
        runs.reduce(MediaTime.zero) { $0 + $1.duration }
    }

    /// Toutes les cases exportées, dans l'ordre du montage (runs concaténés).
    /// Les cases gardent leurs temps musicaux ABSOLUS.
    var allSlots: [ProjectSlot] {
        runs.flatMap(\.slots)
    }

    /// Position de composition de CHAQUE run, dans l'ordre — le même calcul
    /// que `compositionStart(ofRun:)`, mais en UN seul parcours.
    ///
    /// C'est la forme à utiliser pour assembler une composition : elle évite
    /// le parcours quadratique qu'un appel par run produirait, et garantit que
    /// l'aperçu et l'export posent les runs aux MÊMES instants.
    var runStarts: [MediaTime] {
        var starts: [MediaTime] = []
        starts.reserveCapacity(runs.count)
        var cumulated = MediaTime.zero
        for run in runs {
            starts.append(cumulated)
            cumulated = cumulated + run.duration
        }
        return starts
    }

    /// Position du run `index` dans le montage : somme des durées de tous les
    /// runs précédents (donc de toutes leurs cases).
    ///
    /// - `index <= 0` → `.zero` (le premier run ouvre le montage) ;
    /// - `index >= runs.count` → `duration` (fin du montage) : demander la
    ///   position d'un run inexistant rend la fin de la timeline, jamais une
    ///   valeur inventée.
    func compositionStart(ofRun index: Int) -> MediaTime {
        guard index > 0 else { return .zero }
        var cumulated = MediaTime.zero
        for run in runs.prefix(index) {
            cumulated = cumulated + run.duration
        }
        return cumulated
    }

    /// Instant de composition FINAL d'une case exportée :
    /// `(position de son run) + (slot.start - run.musicStart)`.
    ///
    /// **C'est LE calcul du changement produit**, isolé ici pour être testable
    /// sans AVFoundation : la case garde son temps musical absolu, seule la
    /// timeline exportée est recomposée. La première case du premier run tombe
    /// exactement à `.zero` ; à l'intérieur d'un run l'écart entre deux cases
    /// reste rigoureusement celui de la musique (§53) ; entre deux runs il n'y
    /// a AUCUN trou (le run suivant commence là où le précédent finit).
    ///
    /// Arithmétique en ticks entiers (§9) : aucun arrondi, aucune dérive, quel
    /// que soit le nombre de runs.
    ///
    /// - Returns: `nil` si la case n'appartient à AUCUN run de cette timeline
    ///   (case vide, non prête, ou d'un autre projet) — une case non exportée
    ///   n'a pas d'instant de composition, et l'appelant ne doit pas en
    ///   inventer un.
    func compositionStart(of slot: ProjectSlot) -> MediaTime? {
        var cumulated = MediaTime.zero
        for run in runs {
            if run.slots.contains(where: { $0.id == slot.id }) {
                return cumulated + run.offset(of: slot)
            }
            cumulated = cumulated + run.duration
        }
        return nil
    }

    /// Timeline RÉDUITE aux `count` premières cases exportées (§66 : un rush
    /// devenu indisponible PENDANT l'export).
    ///
    /// La coupe suit l'ordre du montage : les runs entiers situés avant la
    /// case en cause sont conservés, le run qui la contient est raccourci
    /// juste avant elle, et **tous les runs suivants sont abandonnés**. C'est
    /// le comportement le plus simple et le plus prévisible : livrer les runs
    /// d'après produirait un montage DIFFÉRENT de celui annoncé par le résumé
    /// §56 (durée et nombre de plans), pour un gain nul.
    ///
    /// `count <= 0` rend une timeline VIDE ; un `count` supérieur au nombre de
    /// cases rend la timeline inchangée (rien à retirer).
    func truncated(toFirst count: Int) -> ReadyTimeline {
        guard count > 0 else { return .empty }
        guard count < slotCount else { return self }

        var kept: [ReadyRun] = []
        var remaining = count
        for run in runs {
            if remaining <= 0 { break }
            if run.slotCount <= remaining {
                kept.append(run)
                remaining -= run.slotCount
            } else if let partial = ReadyRun(slots: Array(run.slots.prefix(remaining))) {
                kept.append(partial)
                remaining = 0
            }
        }
        return ReadyTimeline(runs: kept)
    }
}

/// Timeline exportable d'un montage — voir l'en-tête de ce fichier (changement
/// produit qui remplace l'algorithme §51 `contiguousReadyPrefix`, puis
/// `contiguousReadySegment`).
///
/// Règles :
/// - tri par index, puis découpage en RUNS : chaque suite maximale de cases
///   `ready` contiguës forme un run ;
/// - une case vide, `resolving`, `downloading`, `unavailable` ou `tooShort`
///   FERME le run en cours et n'est jamais exportée ;
/// - TOUS les runs sont conservés, dans l'ordre : plus aucune zone remplie
///   n'est abandonnée (c'est exactement la demande « n'exporte que les parties
///   avec de la vidéo ») ;
/// - aucune case n'est déplacée : les temps restent ABSOLUS, la concaténation
///   est calculée par `ReadyTimeline.compositionStart(of:)` ;
/// - aucun écran noir n'est ajouté : les zones vides sont SUPPRIMÉES, musique
///   comprise ;
/// - aucun run → timeline vide → export et aperçu principal désactivés.
func readyTimeline(slots: [ProjectSlot]) -> ReadyTimeline {
    var runs: [ReadyRun] = []
    var current: [ProjectSlot] = []

    // Tri par index AVANT toute décision : l'ordre du montage est celui des
    // index, jamais celui de la collection reçue.
    for slot in slots.sorted(by: { $0.index < $1.index }) {
        if slot.assignment?.status == .ready {
            current.append(slot)
        } else if let run = ReadyRun(slots: current) {
            // Fin d'une zone remplie : le run est clos et CONSERVÉ (c'est ce
            // qui distingue la timeline du segment unique, qui s'arrêtait ici).
            runs.append(run)
            current = []
        }
    }
    if let run = ReadyRun(slots: current) {
        runs.append(run) // dernière zone remplie, close par la fin du montage
    }
    return ReadyTimeline(runs: runs)
}
