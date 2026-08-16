//
//  AssemblyView.swift
//  MontageMusical
//
//  Écran de la timeline d'assemblage — Jalon 7, spec §35 (zone haute,
//  carrousel trois cases, mini-timeline), §36 (dock contextuel « Case
//  vide » / « Case remplie » ; « + Vidéo »/« Remplacer » présentent la
//  photothèque Jalon 8 §40–§46 en sheet, `onSlotChanged` recentre le
//  carrousel §46), §51 (Export désactivé si le montage exportable est vide),
//  §59 (debounce très court UNIQUEMENT pour la navigation), §60 (case
//  active restaurée à la réouverture), §65 (« Changer de rythme » →
//  duplication si verrouillé).
//
//  ÉCART PRODUIT — EXPORT CONCATÉNÉ DES ZONES REMPLIES (13 août 2026,
//  demande utilisateur POSTÉRIEURE à la spécification ; détail dans
//  IMPLEMENTATION_STATUS.md).
//  §51/§66 limitaient l'export au PRÉFIXE (cases prêtes depuis la case 0,
//  arrêt au premier trou ; première case vide → export impossible). L'export
//  CONCATÈNE désormais TOUTES les zones remplies : « n'exporte que les
//  parties avec de la vidéo ». Une ZONE (un « run ») est une suite maximale
//  de cases prêtes contiguës ; les cases vides ou non prêtes sont PUREMENT
//  SUPPRIMÉES du montage — vidéo ET musique.
//  Exemple : plans 28 à 35 prêts, 36 à 39 vides, 40 à 50 prêts → 8 + 11 = 19
//  plans mis bout à bout, durée = somme des durées de ces 19 cases.
//  (Numérotation AFFICHÉE, 1-based, §35.1 — soit les index 27…34 et 39…49 ;
//  convention unique en tête d'ExportModels.swift.)
//  Conséquences pour CET écran :
//  - « Export » et « Prévisualiser le montage » sont actifs dès qu'AU MOINS
//    UNE case est prête (`AssemblyViewLogic.isExportEnabled`), plus seulement
//    quand la PREMIÈRE case est prête ;
//  - la mini-timeline §35.3 marque TOUTES les zones exportées (un crochet par
//    zone), pas une seule : l'utilisateur voit d'un coup d'œil les morceaux
//    qui partiront et les trous qui seront supprimés ;
//  - aucune case prête n'est JAMAIS omise, aucun écran noir n'est ajouté, et
//    à l'intérieur d'une zone les cases restent jointives avec leur musique
//    d'origine. La musique SAUTE aux jonctions entre zones : conséquence
//    assumée de la demande, annoncée par le résumé §56.
//  Reste vrai de §51 : export impossible si le résultat est vide (aucune case
//  prête → bouton désactivé, raison annoncée §66).
//
//  CORRECTIFS (relecture adversariale du 13 août 2026) :
//  - UN SEUL COMPTE DE PLANS. Le nombre de plans exportés était affiché depuis
//    deux dérivations — le compte du domaine d'un côté, la somme des LARGEURS
//    des intervalles d'index de l'autre (titre d'aperçu, valeur VoiceOver de
//    la mini-timeline). Les deux ne coïncident que si les index d'une zone
//    sont strictement contigus. `AssemblyViewLogic.exportedSlotCount(items:)`
//    est désormais l'unique compte, passé aux libellés — écran ET VoiceOver ;
//  - UN SEUL DÉCOUPAGE EN ZONES (relecture du 13 août 2026, second passage).
//    `exportedZonePositions(items:)` ne fermait une zone que sur un changement
//    d'ÉTAT, alors que le domaine (`readyTimeline(slots:)`) ferme aussi un run
//    sur toute DISCONTINUITÉ — index sauté ou trou temporel. L'écran pouvait
//    donc dessiner un crochet là où l'export produit deux zones concaténées
//    (donc une coupe musicale de plus). Les deux fonctions appliquent
//    désormais les mêmes trois règles de fermeture ;
//  - §64 : LE GESTE PROPOSÉ DÉPEND DE LA CAUSE. Le hint du bouton « Export »
//    désactivé disait toujours « Remplissez au moins une case », y compris
//    quand toutes les cases étaient REMPLIES mais non prêtes (téléchargement
//    iCloud §44, asset indisponible §64, rush trop court §43) — il faut alors
//    attendre ou remplacer, pas remplir. `nothingReadyCause(items:)` traduit
//    les états en constats, la table des messages restant unique
//    (`ExportSummaryLogic.NothingReadyCause`).
//
//  Jalon 9 : §47.1 (aperçu LOCAL — toucher sur la zone haute quand la case
//  active est prête), §47.2 (aperçu PRINCIPAL des zones exportées — son
//  emplacement a changé au Jalon 10, voir ci-dessous), §48 (invalidation du cache de preview
//  dès qu'une association change), §35.3 (courbe musicale simplifiée passée à
//  la mini-timeline — écart Jalon 7 résorbé), §49 (rattrapage du verrou de
//  géométrie si aucune géométrie n'a été posée alors qu'une case est prête).
//
//  Jalon 10 : §36 la zone DROITE du dock retrouve « Export » — l'écran
//  d'export existe désormais (`ExportSummaryView`, §56) — et l'aperçu
//  principal §47.2 prend un bouton dédié en zone basse (voir la DÉCISION
//  ci-dessous), §51 (Export actif seulement si le montage exportable est non
//  vide — les ZONES remplies depuis l'écart produit ci-dessus), §66 (aucune
//  case prête → export désactivé, raison annoncée).
//
//  Règle du pouce §30 / §89 : toutes les actions ESSENTIELLES vivent dans la
//  moitié basse ou sur le contenu lui-même — navigation entre cases
//  (carrousel + mini-timeline), ajout/remplacement de vidéo et EXPORT
//  (dock §36), APERÇU PRINCIPAL §47.2 (bouton pleine largeur sous le
//  carrousel), APERÇU LOCAL §47.1 (toucher sur la zone haute). Seul
//  « Changer de rythme » (§65), action rare et non essentielle au parcours
//  minimal §88, vit dans le menu ellipsis en haut à droite (écart §30
//  assumé — la règle vise les contrôles obligatoires).
//
//  DÉCISION Jalon 10 — placement de « Prévisualiser le montage » (§88.11,
//  §88.12, §89, §36) :
//  Le parcours minimal exige DEUX actions distinctes en fin de chaîne —
//  « prévisualiser le préfixe rempli » (§88.11) et « exporter le préfixe sans
//  finir le projet » (§88.12), lus depuis l'écart produit comme « les ZONES
//  remplies » — alors que le dock §36 n'admet que TROIS
//  zones, déjà occupées par `Projets`, `+ Vidéo`/`Remplacer` et `Export`.
//  Au Jalon 9, la zone droite portait provisoirement « Prévisualiser » faute
//  d'écran d'export ; ce n'est plus tenable maintenant que l'export existe.
//  Solutions écartées :
//  - aperçu en zone CENTRE : cette zone porte « Remplacer » (§36), action de
//    remplissage utilisée à chaque case — la déplacer casserait le tableau ;
//  - aperçu dans le seul menu ellipsis : §89 interdit qu'une action
//    essentielle vive exclusivement en haut ;
//  - quatrième zone dans le dock : §36 plafonne à trois zones importantes.
//  Retenu : un bouton DISCRET pleine largeur « Prévisualiser le montage »
//  placé SOUS le carrousel, juste au-dessus de la mini-timeline — donc en
//  zone basse (§30), cible ≥ 44 pt (§39), affiché UNIQUEMENT quand au moins
//  une case est prête (§51 + écart produit) : il n'occupe aucune place
//  tant qu'il n'y a rien à lire, et il ne fait pas partie du dock (les trois
//  zones §36 restent intactes). L'entrée « Prévisualiser » du menu ellipsis est
//  RETIRÉE : elle serait désormais un doublon d'un bouton toujours visible
//  quand il est utile, et un menu du haut n'est pas le bon endroit pour une
//  action du parcours minimal (§89).
//
//  Matériaux translucides sobres §37 (aucun verre permanent sur l'aperçu),
//  aucune animation DÉCORATIVE §38 (les deux animations exigées par §38 sont
//  décrites ci-dessous), accessibilité §39 complète.
//
//  Jalon 12 (§39/§87) — DYNAMIC TYPE : la hauteur du carrousel et celle de
//  la mini-timeline étaient des constantes (132 et 44). Aux tailles
//  d'accessibilité AX1–AX5, les cartes débordaient donc du carrousel et leur
//  contenu était tronqué. Les deux hauteurs passent par `@ScaledMetric`, la
//  première sur la MÊME base que `SlotCardView` (source unique
//  `SlotCardView.baseMinHeight`) : carte et carrousel grandissent ensemble.
//  La largeur des cartes reste proportionnelle au conteneur (§35.2 :
//  « largeur tactile stable »), donc indépendante de la taille de texte.
//
//  Jalon 12 (§39/§87) — DÉBORDEMENT AUX TAILLES D'ACCESSIBILITÉ : une fois
//  les hauteurs mises à l'échelle, le `VStack` figé de `assemblyContent` ne
//  tenait plus à l'écran (à AX5, le seul carrousel dépasse 400 pt). La zone
//  haute et le carrousel sont donc devenus DÉFILABLES, le bouton d'aperçu
//  §47.2, la mini-timeline §35.3 et le dock §36 restant ANCRÉS en bas
//  (§30) — voir la documentation de `assemblyContent`.
//
//  Jalon 12 (§38) — LES DEUX ANIMATIONS EXIGÉES : §38 demande QUATRE retours
//  et non deux — haptique d'association réussie, haptique d'erreur sur asset
//  invalide, « glissement vers la prochaine case » et « morphing doux case
//  vide → miniature ». Les deux haptiques existaient déjà (photothèque
//  §46) ; les deux ANIMATIONS ont été ajoutées au Jalon 12 :
//  - GLISSEMENT : tout recentrage PROGRAMMÉ du carrousel (tap sur une
//    voisine §35.2, tap/glissé sur la mini-timeline §35.3, avancement
//    automatique §46 via `onSlotChanged`) passe par
//    `withAnimation(slideAnimation)` dans `select(_:in:)`. Le scroll à la
//    MAIN reste natif : il ne traverse jamais ce chemin. La restauration
//    §60 à l'ouverture n'est pas animée non plus (placement initial) ;
//  - MORPHING : porté par `SlotCardView` (fondu court sur le changement
//    d'état de la carte et sur l'arrivée de la miniature réelle).
//  Ce sont les SEULES animations du projet : aucun fondu, ressort ou
//  translation décoratifs ailleurs (§38 « aucune animation décorative
//  longue »).
//
//  Jalon 12 (§38/§87) — RÉDUIRE LES ANIMATIONS : les deux animations
//  ci-dessus sont NEUTRALISÉES quand le réglage système est actif —
//  `slideAnimation` vaut `nil` (et `withAnimation(nil)` n'anime rien), la
//  carte fait de même de son côté. Toutes deux lisent
//  `\.accessibilityReduceMotion`, exactement comme
//  `reduceMotionSafe()` (App/Core/DesignSystem/ReduceMotion.swift), qui
//  reste posé sur le contenu de l'écran pour neutraliser en plus toute
//  animation implicite héritée d'un contexte parent (chargement →
//  assemblage).
//

import SwiftData
import SwiftUI
import UIKit

// MARK: - Logique pure testable (Jalon 7)

// Non defini par la specification — definitions minimales V1.
/// Logique d'écran extraite en fonctions PURES, testables sans UI
/// (`Tests/Unit/AssemblyViewLogicTests.swift`).
enum AssemblyViewLogic {

    /// Clampe l'index de case active aux bornes `0...(slotCount - 1)`
    /// (§60 : la valeur restaurée peut être hors bornes si les cases ont
    /// changé — jamais de crash d'indexation).
    static func clampedActiveIndex(_ index: Int, slotCount: Int) -> Int {
        guard slotCount > 0 else { return 0 }
        return min(max(index, 0), slotCount - 1)
    }

    /// Fenêtre du carrousel §35.3 : la case active et ses voisines
    /// immédiates (`activeIndex - 1 ... activeIndex + 1`), clampée aux
    /// bornes `0` et `slotCount - 1`.
    static func windowRange(activeIndex: Int, slotCount: Int) -> ClosedRange<Int> {
        guard slotCount > 0 else { return 0...0 }
        let active = clampedActiveIndex(activeIndex, slotCount: slotCount)
        return max(0, active - 1)...min(slotCount - 1, active + 1)
    }

    /// Libellés des trois zones du dock contextuel (§36).
    struct DockLabels: Equatable {
        let left: String
        let center: String
        let right: String
    }

    /// Dérivation §36 : case vide → `[Projets] [+ Vidéo • durée] [Export]` ;
    /// case remplie (tout état d'association, même non prêt) →
    /// `[Projets] [Remplacer] [Export]`.
    ///
    /// ZONE DROITE — Jalon 10 : « Export » dans TOUS les cas, exactement
    /// comme le tableau §36. Son libellé ne bouge plus (l'écran d'export
    /// existe désormais) ; seul son ÉTAT varie — actif dès qu'AU MOINS UNE
    /// case est prête (`isExportEnabled`, écart produit), désactivé
    /// sinon avec un hint qui dit pourquoi (§66, lu comme « aucune case
    /// prête : export désactivé »).
    /// L'aperçu principal §47.2 ne passe plus par cette zone : il a son
    /// propre bouton pleine largeur sous le carrousel (décision documentée en
    /// tête de fichier) — le dock reste donc à TROIS zones (§36).
    static func dockLabels(
        activeState: AssemblySlotState,
        requiredDuration: MediaTime
    ) -> DockLabels {
        switch activeState {
        case .empty:
            return DockLabels(
                left: "Projets",
                center: "+ Vidéo • \(requiredDuration.shortDurationString)",
                right: "Export"
            )
        case .resolving, .downloading, .ready, .unavailable, .tooShort:
            return DockLabels(left: "Projets", center: "Remplacer", right: "Export")
        }
    }

    /// §51 : « export désactivé si le résultat est vide » — Export actif dès
    /// qu'AU MOINS UNE case est prête (`readyTimeline`, le MÊME algorithme
    /// que la preview et l'export).
    ///
    /// ÉCART PRODUIT (13 août 2026) : l'export concatène TOUTES les zones
    /// remplies — une première case vide ne désactive plus l'export, et une
    /// zone isolée au milieu du projet suffit.
    static func isExportEnabled(slots: [ProjectSlot]) -> Bool {
        !readyTimeline(slots: slots).isEmpty
    }

    /// Variante sur les items déjà matérialisés (triés par index) : la
    /// timeline exportable est non vide SI ET SEULEMENT SI au moins une case
    /// est prête — strictement équivalent à `readyTimeline(slots:).isEmpty`
    /// (référence unique, testée via la variante snapshots ci-dessus).
    ///
    /// O(N) en comparaisons d'énumération, sans allocation (aucune zone n'est
    /// construite ici) : évaluable à chaque passe de `body` (§82), au même
    /// titre que `assemblyChangeToken`.
    static func isExportEnabled(items: [AssemblySlotItem]) -> Bool {
        items.contains { $0.state == .ready }
    }

    /// Positions (dans le tableau `items`, ordonné par index croissant) de
    /// TOUTES les zones exportées — écart produit du 13 août 2026 :
    /// 1. une ZONE est une suite MAXIMALE de cases `ready` contiguës ;
    /// 2. chaque case non prête (vide, ou association
    ///    `resolving`/`downloading`/`unavailable`/`tooShort`) ferme la zone en
    ///    cours et sera PUREMENT SUPPRIMÉE du montage — vidéo et musique ;
    /// 3. une case prête qui ne PROLONGE pas exactement la zone en cours ferme
    ///    elle aussi la zone : index non consécutif, ou début différent de la
    ///    fin de la case précédente ;
    /// 4. toutes les zones partent à l'export, dans l'ordre des index.
    ///
    /// Tableau VIDE si aucune case n'est prête (export et aperçu principal
    /// indisponibles, §51).
    ///
    /// **MÊMES règles que `readyTimeline(slots:)` du domaine** (ExportModels),
    /// appliquées à la projection d'affichage : une zone se ferme sur un état
    /// non prêt (règle 2) ET sur toute discontinuité (règle 3), exactement
    /// comme un run là-bas.
    ///
    /// CORRECTIF (relecture du 13 août 2026) : la règle 3 manquait. La
    /// justification donnée ici (« `AssemblySlotState.ready` est la dérivation
    /// unique de `ClipAssignmentStatus.ready` ») ne couvrait que l'ÉTAT ; le
    /// domaine, lui, ferme aussi un run sur toute DISCONTINUITÉ (index sauté,
    /// trou temporel — voir « Pourquoi la jointivité est vérifiée et pas
    /// supposée » dans ExportModels.swift). Sur des cases d'index 28, 29, 31,
    /// l'écran annonçait une zone `28…31` là où l'export en produit deux
    /// (`28…29` puis `31…31`, avec une coupe musicale de plus) : deux
    /// découpages, deux vérités. Il n'y en a plus qu'une.
    ///
    /// La comparaison n'a de sens que sur un tableau trié par index croissant
    /// (ordre produit par le store, §10.1) — le domaine, lui, trie lui-même.
    static func exportedZonePositions(items: [AssemblySlotItem]) -> [ClosedRange<Int>] {
        var zones: [ClosedRange<Int>] = []
        var start: Int?
        for (position, item) in items.enumerated() {
            guard item.state == .ready else {
                // Case non prête : elle ferme la zone en cours et disparaît du
                // montage (règle 2).
                if let first = start {
                    zones.append(first...(position - 1))
                    start = nil
                }
                continue
            }
            guard let first = start else {
                start = position // ouverture d'une zone
                continue
            }
            // `start != nil` implique que la case précédente est prête : la
            // seule question restante est de savoir si celle-ci PROLONGE la
            // zone (règle 3, identique à `readyTimeline`).
            let previous = items[position - 1]
            if previous.index + 1 != item.index || previous.end != item.start {
                zones.append(first...(position - 1))
                start = position
            }
        }
        if let first = start {
            zones.append(first...(items.count - 1))
        }
        return zones
    }

    /// Plages d'INDEX de case (`AssemblySlotItem.index`, 0-based) des zones
    /// exportées — les positions de tableau ci-dessus traduites en index de
    /// plans. L'affichage les annonce en 1-based (§35.1 « Plan X sur N ») :
    /// une zone d'index `27…49` se lit « Plans 28 à 50 ».
    ///
    /// Pour une partition complète, position == index ; la traduction reste
    /// explicite pour ne rien supposer d'une projection filtrée.
    ///
    /// Depuis la règle 3 d'`exportedZonePositions`, les index d'une zone sont
    /// CONSÉCUTIFS par construction : la largeur d'une plage vaut donc son
    /// nombre de plans. Le compte affiché reste malgré tout
    /// `exportedSlotCount(items:)` — une seule source, voir ci-dessous.
    static func exportedZoneIndexes(items: [AssemblySlotItem]) -> [ClosedRange<Int>] {
        exportedZonePositions(items: items).map { zone in
            items[zone.lowerBound].index...items[zone.upperBound].index
        }
    }

    /// Nombre de cases RÉELLEMENT exportées — compte FAISANT AUTORITÉ de cet
    /// écran, l'exact pendant de `ReadyTimeline.slotCount` côté domaine.
    ///
    /// CORRECTIF (relecture adversariale du 13 août 2026) : les libellés le
    /// recalculaient en additionnant les LARGEURS des intervalles d'index
    /// (`zone.count`). Les deux ne coïncident que si les index d'une zone sont
    /// strictement contigus — ce que la règle 3 d'`exportedZonePositions`
    /// garantit désormais (second passage : un index sauté SCINDE la zone), mais
    /// alors le second calcul n'apporte rien, et il redeviendrait faux le jour
    /// où une plage viendrait d'ailleurs : le même écran annoncerait deux
    /// comptes différents. Une seule source.
    ///
    /// O(N) en comparaisons d'énumération, sans allocation (§82).
    static func exportedSlotCount(items: [AssemblySlotItem]) -> Int {
        items.reduce(0) { $0 + ($1.state == .ready ? 1 : 0) }
    }

    /// Énoncé VoiceOver des zones exportables (§39) — `nil` quand rien n'est
    /// prêt (il n'y a alors aucun montage à annoncer, §51) :
    /// - UNE zone → « plans 28 à 50 exportables » / « plan 28 exportable » ;
    /// - DEUX zones ou plus → « 19 plans exportables en 2 zones ».
    ///
    /// Les plages reçues sont des index de case (0-based) et sont annoncées
    /// en 1-based, comme partout dans l'interface (« Plan X sur N », §35.1).
    /// Source UNIQUE de cette formulation : la mini-timeline §35.3 l'utilise
    /// pour sa valeur accessible — le crochet dessiné au-dessus de la piste
    /// est invisible pour VoiceOver.
    ///
    /// `slotCount` est le compte faisant autorité (`exportedSlotCount(items:)`)
    /// et n'est PAS redérivé des plages : l'oreille et l'écran comptent la même
    /// chose (voir `exportedSlotCount`).
    static func spokenExportedZones(zones: [ClosedRange<Int>], slotCount: Int) -> String? {
        guard !zones.isEmpty else { return nil }
        if zones.count == 1, let zone = zones.first {
            let first = max(0, zone.lowerBound) + 1
            let last = max(0, zone.upperBound) + 1
            return first == last
                ? "plan \(first) exportable"
                : "plans \(first) à \(last) exportables"
        }
        let safeCount = max(0, slotCount)
        let plans = safeCount <= 1 ? "\(safeCount) plan exportable" : "\(safeCount) plans exportables"
        return "\(plans) en \(zones.count) zones"
    }

    /// §64 — POURQUOI l'export est indisponible, vu depuis la projection
    /// d'affichage. Traduit les états de cases en deux constats
    /// (« quelque chose est en cours », « quelque chose est bloqué ») que
    /// `ExportSummaryLogic.NothingReadyCause` transforme en geste à proposer :
    /// remplir, attendre, ou remplacer.
    ///
    /// La TABLE des messages n'existe qu'une fois (dans `ExportSummaryLogic`) :
    /// l'écran d'assemblage et le résumé §56 ne peuvent pas conseiller deux
    /// gestes différents pour la même situation.
    static func nothingReadyCause(items: [AssemblySlotItem]) -> ExportSummaryLogic.NothingReadyCause {
        var hasPending = false
        var hasBlocked = false
        for item in items {
            switch item.state {
            case .resolving, .downloading: hasPending = true
            case .unavailable, .tooShort: hasBlocked = true
            case .ready, .empty: break
            }
        }
        return .from(hasPending: hasPending, hasBlocked: hasBlocked)
    }
}

// MARK: - Feuilles de l'écran (Jalons 8 et 9)

// Non defini par la specification — definition minimale V1.
/// Paramètres de la feuille photothèque (§40–§46) : la case visée au moment
/// de l'appui. « Remplacer » (§36) rouvre le sélecteur sur la MÊME case —
/// le nouveau choix remplace l'association via `beginAssignment`.
private struct ClipPickerContext: Identifiable {
    /// Identifiant de la case (`ProjectSlotRecord.id`).
    let id: UUID
    let slotIndex: Int
    let requiredDuration: MediaTime
}

// Non defini par la specification — definition minimale V1.
/// Paramètres de la feuille de prévisualisation (§47) : portée + titre
/// affiché au-dessus du dock « Prévisualisation » (§36).
private struct PreviewSheetContext {
    /// Identité STABLE de la feuille (portée) — sert d'`id` à `sheet(item:)`.
    let id: String
    let scope: PreviewScope
    let title: String
}

// Non defini par la specification — definition minimale V1.
/// UNE seule feuille à la fois (photothèque §40–§46, prévisualisation §47 OU
/// export §56) : un `sheet(item:)` unique évite les conflits de présentations
/// concurrentes attachées à la même vue.
private enum AssemblySheet: Identifiable {
    case clipPicker(ClipPickerContext)
    case preview(PreviewSheetContext)
    /// Résumé avant export §56 + progression §58 (Jalon 10).
    case export

    var id: String {
        switch self {
        case .clipPicker(let context): "picker-\(context.id.uuidString)"
        case .preview(let context): "preview-\(context.id)"
        case .export: "export"
        }
    }
}

// MARK: - Déclencheur d'invalidation du cache (§48, §82)

// Non defini par la specification — definition minimale V1.
/// Valeur comparée par le `.onChange` d'invalidation du cache de preview
/// (§48) : nombre d'associations + condensé entier de leur contenu. Deux
/// entiers, aucune allocation — calculable à chaque passe de `body` sans
/// coût (§82 : « projet long navigable sans perte de fluidité »).
private struct AssemblyChangeToken: Equatable {
    let assignmentCount: Int
    let digest: UInt64
}

// MARK: - Écran d'assemblage (§35)

/// Écran affiché par `ProjectView` pour les statuts de MONTAGE (§10) :
/// `assembling` (Jalon 7 — remplace le placeholder du Jalon 6) et, depuis le
/// Jalon 10, `partiallyPreviewable`, `complete` et `exporting`. L'écran reste
/// donc en place PENDANT l'export (§58 : la feuille de progression est
/// présentée par-dessus lui) et APRÈS lui (§88.12 : « exporter le préfixe
/// sans finir le projet » — l'utilisateur revient à son montage, pas à un
/// écran de musique).
///
/// Structure verticale (§35) :
/// 1. **Zone haute §35.1** : aperçu (miniature RÉELLE du rush pour une case
///    prête — placeholder neutre 16:9 sinon), « Plan X sur N », timestamps
///    début → fin, durée requise. Toucher : APERÇU LOCAL §47.1 sur une case
///    prête, sinon lecture du PASSAGE MUSICAL de la case ;
/// 2. **Carrousel §35.2** : trois cases visibles (précédente, active,
///    suivante), cartes à largeur tactile stable, scroll = sélection ;
/// 3. **Aperçu principal §47.2** : bouton discret pleine largeur
///    « Prévisualiser le montage », visible uniquement quand au moins une
///    case est prête (§51 + écart produit) — zone basse §30, hors des
///    trois zones du dock §36 (décision Jalon 10 en tête de fichier) ;
/// 4. **Mini-timeline §35.3** : vue d'ensemble proportionnelle aux durées
///    avec courbe musicale simplifiée en fond, marquage de TOUTES les zones
///    exportées, toucher/glisser = navigation rapide ;
/// 5. **Dock contextuel §36** : `[Projets] [+ Vidéo • durée | Remplacer]
///    [Export]` — « Export » présente le résumé §56 dès qu'au moins une case
///    est prête (§51 + écart produit, §88.12), désactivé sinon.
///
/// Depuis le Jalon 12 (§39/§87), seuls **1 et 2** DÉFILENT verticalement ;
/// **3, 4 et 5** restent ANCRÉS en bas et donc toujours sous le pouce (§30),
/// y compris aux tailles d'accessibilité — voir `assemblyContent`.
///
/// La case active est persistée avec un debounce ~300 ms (§59 : « debounce
/// très court uniquement pour les changements fréquents de navigation,
/// jamais pour une association critique ») et restaurée à la réouverture
/// (§60).
///
/// La vue ne reçoit qu'un `UUID` : les enregistrements SwiftData ne
/// traversent jamais une frontière d'acteur.
struct AssemblyView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    /// §38/§87 « respecter Réduire les animations » — MÊME mécanisme que
    /// `reduceMotionSafe()` (App/Core/DesignSystem/ReduceMotion.swift) :
    /// lecture du réglage système, puis animation `nil` (voir
    /// `slideAnimation`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// §39/§87 : hauteur du carrousel — MÊME base que les cartes
    /// (`SlotCardView.baseMinHeight`), donc même mise à l'échelle Dynamic
    /// Type ; une carte ne peut plus déborder de sa fenêtre.
    @ScaledMetric(relativeTo: .subheadline)
    private var carouselHeight: CGFloat = SlotCardView.baseMinHeight
    /// §39/§87 : hauteur de la mini-timeline §35.3 — mise à l'échelle elle
    /// aussi, sans jamais descendre sous 44 pt (cible tactile §39, voir
    /// `miniTimelineHeight`).
    @ScaledMetric(relativeTo: .footnote)
    private var scaledMiniTimelineHeight: CGFloat = 44

    private let projectID: UUID

    /// Projet (case active persistée §60, rythme choisi).
    @Query private var projects: [ProjectRecord]
    /// Cases du projet, triées par index. Après `selectPace`, seules les
    /// cases du mode choisi existent en base (Jalon 6) — aucun filtre de
    /// mode nécessaire.
    @Query private var slotRecords: [ProjectSlotRecord]
    /// Associations du projet — leur statut §13.3 pilote l'état visuel des
    /// cases (mapping recalculé par SwiftUI à chaque changement, O(N)).
    @Query private var assignmentRecords: [ClipAssignmentRecord]

    // MARK: État de navigation

    /// Index de la case active (position dans le tableau trié — égal à
    /// `ProjectSlotRecord.index`, contigu depuis 0 par construction §10.1).
    @State private var activeIndex = 0
    /// Position du carrousel (liaison `scrollPosition`) — synchronisée
    /// bidirectionnellement avec `activeIndex`.
    @State private var carouselPosition: Int?
    /// Vrai après la restauration §60 de la case active (une seule fois).
    @State private var hasRestoredActiveIndex = false
    /// Tâche de persistance débouncée de la case active (§59) — annulable,
    /// la dernière valeur gagne.
    @State private var persistTask: Task<Void, Never>?

    // MARK: État lecture (§35.1)

    /// Lecture du fichier audio ORIGINAL (§16.1) — passage musical d'une
    /// case NON prête par toucher sur l'aperçu (§35.1). Une case prête ouvre
    /// l'aperçu complet §47.1 (vidéo + musique) dans `PreviewPlayerView` ;
    /// ce lecteur est alors arrêté (jamais deux sons simultanés).
    @State private var playerController = AudioPlayerController()
    /// Vrai si `audio/` ne contient aucun fichier lisible (incohérence
    /// disque/base) — la lecture est désactivée, jamais de crash.
    @State private var isMediaUnavailable = false

    // MARK: État changement de rythme (§65)

    /// Alerte §65 : rythme verrouillé par des associations — proposer la
    /// duplication, jamais de mutation destructive.
    @State private var isPaceLockAlertPresented = false
    /// Alerte d'échec (jamais silencieux). Le message dit CE QUI a échoué et
    /// CE QU'IL FAUT FAIRE (§62/§64) : changement de rythme et duplication
    /// sont deux actions différentes, un message unique en aurait décrit une
    /// pour l'autre.
    @State private var paceChangeErrorMessage: String?
    @State private var isPaceChangeErrorPresented = false

    // MARK: État des feuilles (Jalon 8 photothèque, Jalon 9 preview)

    /// Feuille présentée — `nil` : aucune (§40–§46 / §47).
    @State private var activeSheet: AssemblySheet?

    // MARK: État rattrapage de géométrie (Jalon 9, §49)

    /// Vrai dès qu'un rattrapage du verrou §49 a été TENTÉ sur cet écran —
    /// une seule tentative par ouverture : ni boucle de réessai, ni
    /// aller-retour PhotoKit répété (l'échec reste journalisé, jamais
    /// bloquant).
    @State private var hasAttemptedGeometryLock = false

    // MARK: État courbe musicale (§35.3, écart Jalon 7 résorbé)

    /// Pics normalisés `0...1` du morceau (200 bins, `WaveformExtractor`
    /// §16.2/§68) — fond de la mini-timeline §35.3. Vide tant que
    /// l'extraction n'a pas abouti : la mini-timeline se dessine sans fond.
    @State private var musicCurve: [Float] = []

    // MARK: État miniatures (Jalon 8, §35.1/§35.2)

    /// Cache LOCAL des miniatures réelles des cases remplies, par
    /// identifiant d'asset (§35.2) — chargé FENÊTRÉ autour de la case
    /// active (± 2), jamais tout le projet ; libéré avec l'écran (@State).
    @State private var thumbnailsByAssetID: [String: UIImage] = [:]
    /// §39/§87 : hauteur de carte (arrondie) pour laquelle le cache ci-dessus
    /// a été rempli. La résolution demandée dépend de `carouselHeight`
    /// (`@ScaledMetric`) : dès que la taille de texte change, les images
    /// déjà chargées sont PÉRIMÉES et le cache est vidé (voir
    /// `loadThumbnails(for:)`). `0` : cache encore vide.
    @State private var cachedThumbnailCardHeight = 0

    init(projectID: UUID) {
        self.projectID = projectID
        _projects = Query(filter: #Predicate<ProjectRecord> { record in
            record.id == projectID
        })
        _slotRecords = Query(
            filter: #Predicate<ProjectSlotRecord> { slot in
                slot.projectID == projectID
            },
            sort: [SortDescriptor(\ProjectSlotRecord.index, order: .forward)]
        )
        _assignmentRecords = Query(filter: #Predicate<ClipAssignmentRecord> { assignment in
            assignment.projectID == projectID
        })
    }

    // MARK: - Corps

    var body: some View {
        Group {
            let items = slotItems
            if items.isEmpty {
                // Cases pas encore propagées au contexte principal (les
                // écritures viennent de l'acteur `ProjectStore`) — état
                // transitoire sobre, le dock de sortie reste disponible.
                loadingContent
            } else {
                assemblyContent(items: items)
            }
        }
        // §38/§87 : le passage chargement → assemblage n'est PAS animé, et
        // la garde empêche toute animation implicite héritée d'un contexte
        // parent quand « Réduire les animations » est actif. Les deux SEULES
        // animations du projet (glissement du carrousel §38 ici, morphing des
        // cartes §38 dans `SlotCardView`) se neutralisent d'elles-mêmes par
        // le même réglage — voir `slideAnimation` et l'en-tête de fichier.
        .reduceMotionSafe()
        // Menu ellipsis : « Changer de rythme » UNIQUEMENT (§65, action rare
        // et non essentielle au parcours minimal §88). L'entrée
        // « Prévisualiser » du Jalon 9 en a été RETIRÉE au Jalon 10 : l'aperçu
        // principal §47.2 a désormais son bouton dédié en zone basse (sous le
        // carrousel) — un doublon dans un menu du haut n'apporterait rien et
        // brouillerait la lecture (décision en tête de fichier, §89).
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Changer de rythme") {
                        changePace()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Options du projet")
                .accessibilityHint("Contient l'action Changer de rythme.")
            }
        }
        // §65 : jamais de mutation destructive — proposer la duplication.
        .alert("Rythme verrouillé", isPresented: $isPaceLockAlertPresented) {
            Button("Dupliquer") {
                duplicateForPaceChange()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ce rythme est verrouillé par des vidéos déjà associées. Dupliquez le projet pour changer de rythme.")
        }
        .alert("Action impossible", isPresented: $isPaceChangeErrorPresented) {
            Button("OK", role: .cancel) {
                paceChangeErrorMessage = nil
            }
        } message: {
            Text(paceChangeErrorMessage ?? Self.paceChangeFailureMessage)
        }
        // Photothèque (Jalon 8, §40–§46) : la feuille RESTE ouverte pendant
        // l'enchaînement §46/§83 — `onSlotChanged` recentre le carrousel
        // DERRIÈRE la feuille à chaque avancement automatique. Les états
        // resolving/downloading/ready/unavailable des cartes se mettent à
        // jour automatiquement via les @Query (associations §13.3).
        // La feuille de prévisualisation (§47) partage le MÊME point de
        // présentation : une seule feuille à la fois.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .clipPicker(let context):
                ClipPickerView(
                    projectID: projectID,
                    slotID: context.id,
                    slotIndex: context.slotIndex,
                    requiredDuration: context.requiredDuration,
                    onSlotChanged: { index in
                        select(index, in: slotItems)
                    }
                )
            case .preview(let context):
                PreviewPlayerView(
                    projectID: projectID,
                    scope: context.scope,
                    title: context.title
                )
            case .export:
                // §56 : résumé INFORMATIF puis progression §58 — jamais un
                // écran de réglages (§89).
                ExportSummaryView(projectID: projectID)
            }
        }
        .task(id: projectID) {
            loadAudio()
            await loadMusicCurve()
        }
        // §60 : restauration de la case active dès que les cases sont
        // visibles — une seule fois, valeur CLAMPÉE aux bornes.
        .task(id: slotItems.isEmpty) {
            guard !hasRestoredActiveIndex, !slotItems.isEmpty else { return }
            hasRestoredActiveIndex = true
            let restored = AssemblyViewLogic.clampedActiveIndex(
                projects.first?.activeSlotIndex ?? 0,
                slotCount: slotItems.count
            )
            activeIndex = restored
            carouselPosition = restored
        }
        // Le scroll du carrousel change la sélection (§35.2).
        .onChange(of: carouselPosition) { _, newValue in
            guard let newValue, newValue != activeIndex else { return }
            selectionDidChange(to: newValue)
        }
        // §48 : « invalider le cache si une association change ». L'écran
        // d'assemblage est le SEUL endroit toujours vivant pendant qu'une
        // association bouge (il reste monté derrière la photothèque §83) :
        // il porte donc l'invalidation pour tout le projet. Le verrouillage
        // de géométrie (§48, second cas) invalide de son côté depuis
        // `ClipPickerView` et depuis le rattrapage §49 ci-dessous.
        // Déclencheur BON MARCHÉ (§82) — voir `assemblyChangeToken`.
        .onChange(of: assemblyChangeToken) { _, _ in
            environment.previewCache.invalidateAll(projectID: projectID)
        }
        // §49 (rattrapage) : une case peut être PRÊTE sans que la géométrie
        // ait été posée (échec transitoire de `videoGeometry` au moment de
        // l'association). Sans rattrapage, aucun chemin ne la reposerait et
        // les aperçus retomberaient sur un repli DIFFÉRENT selon la portée,
        // alors que §52.1 impose « toujours celle du projet ». Tenté à
        // l'ouverture de l'écran et dès qu'une première case devient prête.
        .task(id: hasReadyAssignment) {
            await lockGeometryIfMissing()
        }
        // Miniatures réelles (Jalon 8, §35.1/§35.2) : chargées FENÊTRÉES —
        // les cases prêtes autour de la case active (± 2) uniquement, la
        // clé change avec la navigation, les associations ET la taille de
        // texte (§39/§87 : la résolution demandée en dépend, voir
        // `ThumbnailWindowKey`).
        .task(id: thumbnailWindowKey) {
            await loadThumbnails(for: thumbnailWindowKey)
        }
        .onDisappear {
            // Lecture arrêtée et observateurs retirés (§35.1). La tâche de
            // persistance débouncée N'EST PAS annulée : la dernière case
            // active est toujours sauvegardée (§59, §60).
            playerController.invalidate()
        }
    }

    // MARK: - Mapping records → items (contrat Jalon 7)

    /// `[AssemblySlotItem]` dérivés des records — dérivation UNIQUE de
    /// l'état par `AssemblySlotState.from(assignmentStatusRaw:)` via un
    /// dictionnaire `assignmentID → record`. Recalculé par SwiftUI à
    /// chaque changement des deux `@Query`, O(N). L'identifiant d'asset de
    /// l'association alimente les miniatures réelles (§35.1/§35.2).
    private var slotItems: [AssemblySlotItem] {
        let assignmentsByID = Dictionary(
            assignmentRecords.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return slotRecords.map { record in
            // `assignmentID` orphelin (association supprimée) → raw `nil`
            // → `.empty` : la case redevient remplissable.
            let assignment = record.assignmentID.flatMap { assignmentsByID[$0] }
            return AssemblySlotItem(
                id: record.id,
                index: record.index,
                start: MediaTime(ticks: record.startTicks),
                end: MediaTime(ticks: record.endTicks),
                state: AssemblySlotState.from(
                    assignmentStatusRaw: assignment?.statusRaw
                ),
                assetLocalIdentifier: assignment?.assetLocalIdentifier
            )
        }
    }

    // Non defini par la specification — definition minimale V1.
    /// Déclencheur BON MARCHÉ d'invalidation du cache de preview (§48, §82).
    ///
    /// Une propriété calculée alimentant un `.onChange` est évaluée à CHAQUE
    /// passe de `body` : elle doit rester O(N) en opérations ENTIÈRES, sans
    /// allocation. Ce condensé ne construit donc aucune chaîne et ne
    /// matérialise aucun instantané — contrairement à
    /// `PreviewCacheKey.fingerprint`, qui compose ~120 caractères par case
    /// (~35 Ko à 300 cases) et reste réservé à la CLÉ de cache, calculée une
    /// fois par ouverture d'aperçu dans `PreviewPlayerView`.
    ///
    /// Couverture §48 — « invalider si une association change » :
    /// - `count` attrape toute création ou suppression d'association
    ///   (`beginAssignment`, `removeAssignment(IfCurrent)`) ;
    /// - `digest` combine, pour chaque association, son identifiant, sa case
    ///   et son statut : un REMPLACEMENT (§36 — même case, nouvel
    ///   identifiant) et tout changement de statut (`resolving` →
    ///   `downloading` §44 → `ready`, ou → `unavailable` §64 « un asset
    ///   devient indisponible ») changent la valeur.
    ///   La combinaison est un OU-exclusif — donc INDÉPENDANTE de l'ordre de
    ///   la `@Query` (aucun `sort` sur les associations) : seul un vrai
    ///   changement de contenu déclenche, jamais un simple réordonnancement.
    ///
    /// Les deux autres causes §48 sont couvertes AILLEURS, sans coût ici :
    /// la géométrie du premier rush invalide depuis `ClipPickerView` et
    /// depuis le rattrapage §49 de cet écran ; « le rythme change avant
    /// verrouillage » détruit cet écran (retour au choix du rythme §34) ou
    /// crée un autre projet (duplication §65).
    ///
    /// `updatedAt` du projet n'est volontairement PAS utilisé : le store le
    /// touche à CHAQUE mutation (§59), y compris `setActiveSlot` — une simple
    /// navigation dans le carrousel jetterait alors les compositions en
    /// cache, exactement ce que §48 demande de conserver.
    private var assemblyChangeToken: AssemblyChangeToken {
        var digest: UInt64 = 0
        for assignment in assignmentRecords {
            // Mélange par association (entiers uniquement, aucune
            // allocation) ; XOR final = indépendant de l'ordre.
            var mixed = UInt64(bitPattern: Int64(assignment.id.hashValue))
            mixed = mixed &* 0x0000_0100_0000_01B3
            mixed ^= UInt64(bitPattern: Int64(assignment.slotID.hashValue))
            mixed = mixed &* 0x0000_0100_0000_01B3
            mixed ^= UInt64(bitPattern: Int64(assignment.statusRaw.hashValue))
            digest ^= mixed
        }
        return AssemblyChangeToken(assignmentCount: assignmentRecords.count, digest: digest)
    }

    // MARK: - État transitoire sans cases

    private var loadingContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ProgressView()
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chargement des plans")
        .safeAreaInset(edge: .bottom) { projectsOnlyDock }
    }

    private var projectsOnlyDock: some View {
        HStack {
            dockSecondaryButton(
                title: "Projets",
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Écran complet (§35)

    /// §39/§87 — DÉBORDEMENT AUX TAILLES D'ACCESSIBILITÉ (correctif Jalon 12).
    ///
    /// PROBLÈME : la zone haute (aperçu 16:9 + quatre lignes de texte) et le
    /// carrousel suivent tous deux la taille de texte (`@ScaledMetric`). Aux
    /// tailles AX1–AX5 ils ne tiennent plus ensemble à l'écran — à AX5, le
    /// seul carrousel dépasse 400 pt. Empilés dans un `VStack` NON défilable,
    /// ils repoussaient la mini-timeline §35.3 et le dock §36 hors du cadre :
    /// les contrôles OBLIGATOIRES du parcours devenaient inatteignables,
    /// exactement ce qu'interdit la règle du pouce §30.
    ///
    /// SOLUTION RETENUE (la plus simple qui préserve §30) : rendre DÉFILABLE
    /// verticalement la seule partie qui grandit — zone haute §35.1 +
    /// carrousel §35.2 — et laisser ANCRÉS en bas le bouton d'aperçu §47.2,
    /// la mini-timeline §35.3 et le dock §36. Ces trois-là ne défilent
    /// jamais : ils restent sous le pouce à N'IMPORTE QUELLE taille de texte
    /// (§30), et la navigation reste possible même quand la zone haute occupe
    /// tout l'espace visible (la mini-timeline §35.3 permet à elle seule
    /// d'atteindre n'importe quelle case).
    ///
    /// Solution écartée : compacter la zone haute aux tailles
    /// d'accessibilité — §35.1 impose ses quatre informations (aperçu, plan X
    /// sur N, timestamps, durée requise), et cela ne réglerait de toute façon
    /// pas le carrousel, qui dépasse à lui seul la hauteur de l'écran à AX5.
    ///
    /// Le `minHeight` égal à la hauteur du conteneur (`GeometryReader`)
    /// conserve EXACTEMENT la mise en page des tailles standard : le `Spacer`
    /// continue de pousser le carrousel vers le bas, et le défilement
    /// n'apparaît que lorsque le contenu dépasse réellement
    /// (`.scrollBounceBehavior(.basedOnSize)` : aucun rebond sinon, l'écran
    /// reste perçu comme fixe).
    ///
    /// Complément indispensable : l'aperçu 16:9 de la zone haute reçoit un
    /// PLANCHER de hauteur (`Self.minPreviewHeight`, voir `topZone`). Sans
    /// lui, c'est ce cadre — le seul totalement flexible — que la mise en
    /// page écraserait à zéro dès que la place manque, et l'aperçu §35.1
    /// disparaîtrait aux tailles d'accessibilité au lieu de faire défiler.
    ///
    /// Contrôle visuel : preview « Assemblage — accessibilité 3 » en bas de
    /// fichier.
    private func assemblyContent(items: [AssemblySlotItem]) -> some View {
        // Clamp défensif : si le nombre de cases changeait sous la vue
        // (duplication, migration), jamais d'indexation hors bornes.
        let active = AssemblyViewLogic.clampedActiveIndex(activeIndex, slotCount: items.count)
        let activeItem = items[active]
        // Zones exportées (écart produit) : calculées UNE fois par passe, puis
        // partagées par le bouton d'aperçu §47.2 — la mini-timeline les
        // redérive de son côté à la construction (§82 : rien pendant le
        // dessin).
        let exportedZones = AssemblyViewLogic.exportedZoneIndexes(items: items)
        // Compte FAISANT AUTORITÉ des plans exportés — jamais redérivé des
        // plages d'index par les libellés (voir `exportedSlotCount`).
        let exportedSlotCount = AssemblyViewLogic.exportedSlotCount(items: items)
        return VStack(spacing: 14) {
            // Partie DÉFILABLE (§39/§87) : elle occupe toute la place que lui
            // laissent les contrôles ancrés ci-dessous.
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 14) {
                        topZone(item: activeItem, count: items.count)

                        Spacer(minLength: 0)

                        carousel(items: items, activeIndex: active)
                    }
                    // Au moins la hauteur visible : aux tailles standard, le
                    // `Spacer` s'étend comme avant (carrousel en zone basse
                    // §30) ; aux tailles d'accessibilité, le contenu dépasse
                    // et devient défilable au lieu d'être coupé.
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            // APERÇU PRINCIPAL §47.2 — décision Jalon 10 (§88.11/§89,
            // documentée en tête de fichier) : bouton discret pleine largeur,
            // en ZONE BASSE (§30) et hors des trois zones du dock §36,
            // affiché UNIQUEMENT quand au moins une ZONE exportable existe
            // (§51 + écart produit) : sans lui, il n'y aurait rien à lire et
            // la place est rendue au contenu.
            if !exportedZones.isEmpty {
                montagePreviewButton(zones: exportedZones, slotCount: exportedSlotCount)
            }

            // Mini-timeline §35.3 : toucher/glisser déplace la sélection.
            // ANCRÉE hors du défilement (§30/§39/§87) — c'est le moyen de
            // navigation qui reste atteignable d'un pouce quelle que soit la
            // taille de texte, même quand la zone haute remplit l'écran.
            AssemblyMiniTimelineView(
                slots: items,
                activeIndex: active,
                windowRange: AssemblyViewLogic.windowRange(
                    activeIndex: active,
                    slotCount: items.count
                ),
                // §35.3 : courbe musicale simplifiée en fond (écart Jalon 7
                // résorbé) — vide tant que l'extraction n'a pas abouti.
                musicCurve: musicCurve,
                onSelect: { index in
                    select(index, in: items)
                }
            )
            // §39 : suit la taille de texte, jamais sous 44 pt (cible
            // tactile — c'est aussi une zone de tap et de glissé §35.3).
            .frame(height: miniTimelineHeight)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) {
            contextualDock(activeItem: activeItem, items: items)
        }
    }

    // MARK: - Zone haute (§35.1)

    /// Hauteur minimale de l'aperçu 16:9 de la zone haute (§35.1) — voir le
    /// commentaire de `topZone`. Constante d'ÉCRAN, pas de texte : elle ne
    /// suit volontairement pas Dynamic Type (une vidéo ne grossit pas avec la
    /// taille de police), elle garantit seulement que l'aperçu reste VISIBLE
    /// quand la place manque (§39/§87).
    private static let minPreviewHeight: CGFloat = 120

    /// Aperçu + « Plan X sur N » + timestamps début → fin + durée requise.
    ///
    /// L'aperçu affiche la miniature RÉELLE du rush pour une case PRÊTE
    /// (Jalon 8, §35.1 — même image que sa carte du carrousel), un
    /// placeholder neutre 16:9 sinon.
    ///
    /// Toucher (§35.1 « lecture par toucher sur l'aperçu ») :
    /// - case PRÊTE → APERÇU LOCAL §47.1 (vidéo de la case + passage musical
    ///   correspondant, uniquement la plage de la case) en feuille ;
    /// - case non prête (vide, en cours, indisponible) → lecture du PASSAGE
    ///   MUSICAL seul, comme au Jalon 7 (fichier original §16.1, pause
    ///   automatique à la fin de la case) : il n'y a pas encore de vidéo à
    ///   montrer, mais l'utilisateur doit pouvoir entendre ce qu'il remplit.
    private func topZone(item: AssemblySlotItem, count: Int) -> some View {
        VStack(spacing: 8) {
            Button {
                topZoneTapped(item: item, count: count)
            } label: {
                // Case prête : le toucher OUVRE l'aperçu §47.1 — l'icône est
                // donc toujours « lecture », jamais l'état du lecteur audio.
                let opensPreview = item.state == .ready
                let playIconName = (opensPreview || !playerController.isPlaying)
                    ? "play.fill"
                    : "pause.fill"
                ZStack {
                    if let image = thumbnail(for: item) {
                        // Jalon 8 (§35.1) : miniature RÉELLE du rush de la
                        // case active prête — MÊME image que sa carte du
                        // carrousel ; remplace le placeholder neutre 16:9.
                        // Posée en overlay d'un gabarit fixe puis rognée : sa
                        // taille intrinsèque n'influence pas la mise en page.
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.quaternary)
                            .overlay(
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        // Commande de lecture lisible sur la photo : icône
                        // blanche sur pastille sombre (même recette que les
                        // badges de la photothèque §42) — contraste garanti,
                        // l'état est AUSSI porté par `accessibilityValue`
                        // (§39, jamais la seule apparence).
                        Image(systemName: playIconName)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.55), in: Circle())
                    } else {
                        // Fond neutre — pas de verre permanent sur la zone
                        // vidéo (§37 : le contenu reste prioritaire).
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.quaternary)
                        VStack(spacing: 6) {
                            Image(systemName: playIconName)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(opensPreview ? "Aperçu du plan" : "Passage musical")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                // §39/§87 : PLANCHER de visibilité. Un cadre en `aspectRatio`
                // est totalement flexible en hauteur : dans un `VStack`, c'est
                // donc lui que la mise en page écrase en premier quand la
                // place manque — aux tailles d'accessibilité, l'aperçu §35.1
                // disparaissait purement et simplement au profit des lignes de
                // texte et du carrousel. Ce plancher l'en empêche : le 16/9
                // est alors conservé en réduisant la LARGEUR (le cadre reste
                // centré), et c'est le défilement de `assemblyContent` qui
                // absorbe le dépassement. Ne joue jamais aux tailles standard
                // (la hauteur naturelle y vaut ~190 pt sur un grand iPhone).
                .frame(minHeight: Self.minPreviewHeight)
            }
            .buttonStyle(.plain)
            // §64 : seule la lecture du PASSAGE MUSICAL dépend du fichier
            // audio — une case PRÊTE garde son aperçu §47.1 accessible même
            // sans musique lisible (le lecteur expliquera l'échec, §64 :
            // jamais un toucher sans effet).
            .disabled(isMediaUnavailable && item.state != .ready)
            .padding(.horizontal, 24)
            .accessibilityLabel(
                "Plan \(item.index + 1) sur \(count), "
                    + "durée requise \(item.duration.spokenString), "
                    + spokenState(item.state)
            )
            // §39 : l'état de lecture n'a de sens que pour le passage
            // musical — une case prête ouvre un aperçu vidéo (§47.1).
            .accessibilityValue(
                item.state == .ready
                    ? ""
                    : (playerController.isPlaying ? "Lecture en cours" : "En pause")
            )
            .accessibilityHint(
                previewHint(for: item)
            )

            // « Plan X sur N » (§35.1) — index HUMAIN (1-based).
            Text("Plan \(item.index + 1) sur \(count)")
                .font(.headline.monospacedDigit())

            // Timestamps absolus début → fin, centième d'AFFICHAGE (§9).
            Text("\(item.start.displayString) → \(item.end.displayString)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("De \(item.start.displayString) à \(item.end.displayString)")

            // Durée requise (§35.1) — toujours calculée end - start (§9).
            Text("Durée requise : \(item.duration.shortDurationString)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Durée requise : \(item.duration.spokenString)")
        }
        .padding(.top, 8)
    }

    // MARK: - Carrousel (§35.2)

    /// Trois cases visibles : précédente, active, suivante. Cartes à
    /// largeur tactile STABLE (~62 % du conteneur — les voisines dépassent
    /// de chaque côté), case active centrée (`viewAligned` + ancre
    /// centrale). Le scroll change la sélection via `carouselPosition`.
    private func carousel(items: [AssemblySlotItem], activeIndex: Int) -> some View {
        GeometryReader { proxy in
            // Marges latérales = (100 % − 62 %) / 2 : la première et la
            // dernière carte peuvent elles aussi se centrer.
            // Cartes à 55 % : les voisines montrent leur numéro et leur
            // état (identifiables, pas de simples tranches — §35.2).
            let sideMargin = proxy.size.width * 0.225
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    // Identité = POSITION (Int) : c'est elle que
                    // `scrollPosition(id:)` lit/écrit — les cases ne se
                    // réordonnent jamais (§10.1, index gelés).
                    ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                        SlotCardView(
                            item: item,
                            isActive: position == activeIndex,
                            // Miniature réelle (§35.2) — `nil` tant qu'elle
                            // n'est pas chargée (fenêtre active ± 2).
                            thumbnail: thumbnail(for: item)
                        )
                            .containerRelativeFrame(.horizontal) { length, _ in
                                // Largeur tactile stable §35.2.
                                length * 0.55
                            }
                            // §82 « navigation par tap » : toucher une
                            // voisine la sélectionne (le scroll reste).
                            .onTapGesture {
                                select(position, in: items)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, sideMargin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $carouselPosition, anchor: .center)
            .scrollIndicators(.hidden)
        }
        // §39/§87 : même mise à l'échelle Dynamic Type que les cartes
        // (base commune `SlotCardView.baseMinHeight`) — aux tailles
        // d'accessibilité, la fenêtre grandit avec son contenu au lieu de
        // le tronquer.
        .frame(height: carouselHeight)
    }

    /// Hauteur effective de la mini-timeline §35.3 : la valeur mise à
    /// l'échelle, plancher 44 pt (§39 — la zone reste tapable et glissable
    /// même aux tailles de texte les plus PETITES, où `@ScaledMetric`
    /// réduirait la valeur de base).
    private var miniTimelineHeight: CGFloat {
        max(44, scaledMiniTimelineHeight)
    }

    // MARK: - Aperçu principal des zones exportées (§47.2, zone basse §30)

    /// Bouton DISCRET pleine largeur « Prévisualiser le montage » — accès de
    /// référence à l'aperçu principal §47.2 depuis le Jalon 10.
    ///
    /// Sobre (matériau translucide léger §37, pas de couleur d'accent) : il
    /// ne concurrence pas le CTA de remplissage du dock (« + Vidéo » /
    /// « Remplacer »), qui reste l'action dominante tant que le montage se
    /// construit. Cible ≥ 44 pt (§39), libellé complet pour VoiceOver.
    ///
    /// Le LIBELLÉ ne change pas (« Prévisualiser le montage ») ; c'est le
    /// hint VoiceOver qui NOMME ce qui est lu (« Lit le montage : plans 28 à
    /// 50. », « … : 19 plans en 2 zones. ») depuis l'écart produit : le
    /// montage n'est plus une plage unique, et l'utilisateur doit le savoir
    /// avant d'appuyer (§39).
    private func montagePreviewButton(zones: [ClosedRange<Int>], slotCount: Int) -> some View {
        Button {
            requestMontagePreview(zones: zones, slotCount: slotCount)
        } label: {
            Label("Prévisualiser le montage", systemImage: "play.rectangle")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44) // cible ≥ 44 pt (§39)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .accessibilityLabel("Prévisualiser le montage")
        .accessibilityHint(
            "Lit le montage : \(exportedPlansLabel(zones: zones, slotCount: slotCount).lowercased())."
        )
    }

    /// « Plans 28 à 50 » (une zone) / « 19 plans en 2 zones » (plusieurs) —
    /// source UNIQUE `ExportSummaryLogic.exportedPlansLabel`, partagée avec le
    /// résumé §56 : l'aperçu et l'export nomment exactement le même montage.
    /// Repli neutre si les zones sont vides — ce chemin n'est jamais atteint
    /// (le bouton n'existe pas sans zone).
    ///
    /// `slotCount` est le compte faisant autorité de l'écran
    /// (`AssemblyViewLogic.exportedSlotCount`) : le titre de l'aperçu et le
    /// résumé §56 annoncent le même nombre de plans, jamais deux comptes
    /// dérivés séparément.
    private func exportedPlansLabel(zones: [ClosedRange<Int>], slotCount: Int) -> String {
        ExportSummaryLogic.exportedPlansLabel(zones: zones, slotCount: slotCount) ?? "aucun plan"
    }

    // MARK: - Dock contextuel (§36)

    /// `[Projets] [+ Vidéo • durée] [Export]` (case vide) ou
    /// `[Projets] [Remplacer] [Export]` (case remplie) — exactement le
    /// tableau §36. Libellés dérivés par la logique pure
    /// `AssemblyViewLogic.dockLabels` (testée).
    ///
    /// Zone droite (Jalon 10) : « Export » ouvre le résumé §56
    /// (`ExportSummaryView`) dès qu'AU MOINS UNE case est prête ; sinon le
    /// bouton est DÉSACTIVÉ avec un hint qui dit pourquoi (§51 : « export
    /// désactivé si le résultat est vide » ; §66 lu depuis l'écart produit :
    /// aucune case prête → export désactivé) — état RÉEL calculé par la MÊME
    /// règle que l'export (`isExportEnabled`), pas un stub.
    private func contextualDock(activeItem: AssemblySlotItem, items: [AssemblySlotItem]) -> some View {
        // Balayage O(N) sans allocation sur les items déjà matérialisés
        // (§82 : rien de coûteux pendant un glisser sur la mini-timeline) —
        // équivalent strict de `readyTimeline(slots:).isEmpty`.
        let isExportEnabled = AssemblyViewLogic.isExportEnabled(items: items)
        let labels = AssemblyViewLogic.dockLabels(
            activeState: activeItem.state,
            requiredDuration: activeItem.duration
        )
        return HStack(spacing: 8) {
            dockSecondaryButton(
                title: labels.left,
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }

            // Centre : « + Vidéo • durée » / « Remplacer » — ouvre la
            // photothèque (Jalon 8, §40–§46) sur la case active.
            Button {
                requestVideoSelection(for: activeItem)
            } label: {
                Text(labels.center)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                activeItem.state == .empty
                    ? "Ajouter une vidéo, durée requise \(activeItem.duration.spokenString)"
                    : "Remplacer la vidéo"
            )
            .accessibilityHint("Ouvre la photothèque pour choisir une vidéo.")

            // Droite : « Export » (§36) — présente le résumé §56 dès qu'au
            // moins une case est prête (§51 + écart produit), désactivé
            // sinon.
            Button {
                requestExport()
            } label: {
                Text(labels.right)
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!isExportEnabled)
            // État désactivé marqué par l'opacité ET annoncé par VoiceOver
            // (trait « estompé » automatique + hint) — jamais par la seule
            // couleur (§39).
            .opacity(isExportEnabled ? 1 : 0.4)
            .accessibilityLabel(labels.right)
            // §64 : désactivé, le hint nomme le geste qui débloque VRAIMENT
            // l'export. Une case peut être REMPLIE sans être prête
            // (téléchargement iCloud §44, asset indisponible §64, rush trop
            // court §43) : « remplissez une case » serait alors le mauvais
            // conseil — il faut attendre, ou remplacer.
            .accessibilityHint(
                isExportEnabled
                    ? "Affiche le résumé de l'export du montage déjà prêt."
                    : ExportSummaryLogic.nothingReadyShortHint(
                        AssemblyViewLogic.nothingReadyCause(items: items)
                    )
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Navigation entre cases (§35.3, §59)

    /// §38 « GLISSEMENT VERS LA PROCHAINE CASE » + §87 : animation du
    /// recentrage PROGRAMMÉ du carrousel — `nil` dès que « Réduire les
    /// animations » est actif, et `withAnimation(nil)` n'anime rien : le
    /// carrousel se replace alors instantanément, sans glissement.
    ///
    /// Volontairement COURTE (0,25 s) et sans rebond : §38 interdit toute
    /// « animation décorative longue ». Avec le morphing de `SlotCardView`,
    /// c'est la seule animation du projet.
    private var slideAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.25)
    }

    /// Sélection PROGRAMMÉE d'une case : tap sur une carte voisine (§35.2),
    /// tap/glissé sur la mini-timeline (§35.3) et avancement automatique
    /// §46 (`onSlotChanged` depuis la photothèque, la feuille restant
    /// ouverte §83). Met à jour la case active ET recentre le carrousel.
    private func select(_ index: Int, in items: [AssemblySlotItem]) {
        let clamped = AssemblyViewLogic.clampedActiveIndex(index, slotCount: items.count)
        guard clamped != activeIndex else { return }
        // §38 « glissement vers la prochaine case » : le recentrage GLISSE au
        // lieu de sauter. Seul ce chemin est animé — le scroll à la MAIN
        // reste natif (il arrive par `.onChange(of: carouselPosition)`), et
        // la restauration §60 à l'ouverture n'est pas animée non plus
        // (placement initial). Neutralisé sous « Réduire les animations »
        // (§38/§87) : `slideAnimation` vaut alors `nil`.
        withAnimation(slideAnimation) {
            carouselPosition = clamped
        }
        selectionDidChange(to: clamped)
    }

    /// Changement de sélection (scroll du carrousel OU mini-timeline) :
    /// arrêt du passage musical en cours, mise à jour de l'état, puis
    /// persistance DÉBOUNCÉE (§59 : navigation uniquement).
    private func selectionDidChange(to index: Int) {
        playerController.stopSegment()
        activeIndex = index
        schedulePersistActiveIndex(index)
    }

    /// §59 : « debounce très court uniquement pour les changements
    /// fréquents de navigation » — ~300 ms, tâche annulable, la dernière
    /// valeur gagne. Une association (Jalon 8) sera sauvegardée SANS
    /// debounce par `ProjectStore` (§59 : jamais pour une association
    /// critique).
    private func schedulePersistActiveIndex(_ index: Int) {
        persistTask?.cancel()
        let store = environment.projectStore
        let logger = environment.logger
        let id = projectID
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try await store.setActiveSlot(index: index, projectID: id)
            } catch {
                // Échec non bloquant : la navigation reste fluide, la
                // prochaine sauvegarde rattrapera la valeur (§59).
                logger.error("Sauvegarde de la case active impossible : \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lecture du passage musical (§35.1)

    /// Charge le lecteur sur le fichier audio ORIGINAL (§16.1).
    private func loadAudio() {
        guard let url = environment.fileStore.audioFileURL(projectID: projectID) else {
            isMediaUnavailable = true
            environment.logger.error("Aucun fichier dans audio/ alors que le projet est en assemblage.")
            return
        }
        isMediaUnavailable = false
        playerController.load(url: url)
    }

    /// Toucher sur la zone haute (§35.1) — aiguillage Jalon 9 :
    /// - case PRÊTE → APERÇU LOCAL §47.1 (feuille `PreviewPlayerView`,
    ///   portée `.slot`) : « disponible pour toute case remplie, même après
    ///   un trou » ;
    /// - sinon → passage musical seul (comportement Jalon 7).
    private func topZoneTapped(item: AssemblySlotItem, count: Int) {
        guard item.state == .ready else {
            // Seule la LECTURE DU PASSAGE MUSICAL exige le fichier audio :
            // sans lui, le bouton est déjà désactivé pour une case non prête
            // (§39 : état annoncé) — garde de défense en profondeur.
            guard !isMediaUnavailable else { return }
            togglePassagePlayback(item: item)
            return
        }
        // §64 : une case PRÊTE ouvre son aperçu MÊME si la musique du projet
        // est introuvable — jamais d'échec muet. Le constructeur lèvera
        // `missingAudio` et `PreviewPlayerView` affichera le message français
        // prévu, ce qui explique le problème au lieu de ne rien faire.
        // La musique de l'écran s'arrête : le lecteur de l'aperçu prend le
        // relais (jamais deux sons simultanés).
        playerController.stopSegment()
        activeSheet = .preview(PreviewSheetContext(
            id: "slot-\(item.id.uuidString)",
            scope: .slot(item.id),
            title: "Plan \(item.index + 1) sur \(count)"
        ))
    }

    /// Lecture du passage musical de la case (`start → end`, pause
    /// automatique à `end`), ou arrêt s'il est déjà en cours.
    private func togglePassagePlayback(item: AssemblySlotItem) {
        guard !isMediaUnavailable else { return }
        if playerController.isPlaying {
            playerController.stopSegment()
        } else {
            playerController.playSegment(from: item.start, to: item.end)
        }
    }

    /// §47.2 « Aperçu principal » : lit le montage exporté — TOUTES les zones
    /// remplies mises bout à bout (portée `.contiguousPrefix` — nom
    /// d'énumération du domaine, dont la RÈGLE est celle de l'écart produit).
    /// Déclencheur UNIQUE depuis le Jalon 10 — le bouton « Prévisualiser le
    /// montage » sous le carrousel (zone basse §30/§88.11), affiché seulement
    /// quand une zone existe : ce chemin n'est donc atteint qu'avec au moins
    /// une case prête.
    ///
    /// Le TITRE de la feuille nomme ce qui est lu (« Montage — plans 28 à
    /// 50 », « Montage — 19 plans en 2 zones ») : l'aperçu ne couvre pas tout
    /// le projet et l'utilisateur doit savoir quoi, sans avoir à le deviner
    /// (§87).
    private func requestMontagePreview(zones: [ClosedRange<Int>], slotCount: Int) {
        playerController.stopSegment()
        let plans = exportedPlansLabel(zones: zones, slotCount: slotCount)
        activeSheet = .preview(PreviewSheetContext(
            id: "montage",
            scope: .contiguousPrefix,
            title: "Montage — \(plans.lowercased())"
        ))
    }

    // MARK: - Rattrapage du verrou de géométrie (§49, §52.1)

    /// Vrai si au moins une association est PRÊTE — clé du `.task` de
    /// rattrapage. Comparaisons de chaînes courtes sans allocation :
    /// évaluable à chaque passe de `body` (§82).
    private var hasReadyAssignment: Bool {
        assignmentRecords.contains { $0.statusRaw == ClipAssignmentStatus.ready.rawValue }
    }

    /// §49 « Au premier rush prêt … enregistrer la géométrie » — RATTRAPAGE.
    ///
    /// Le chemin nominal verrouille depuis `ClipPickerView` juste après
    /// `completeAssignment`. Si `videoGeometry` y a échoué (asset repassé sur
    /// iCloud, lecture momentanément impossible) et que l'utilisateur ne
    /// refait aucune association, le projet resterait SANS géométrie avec des
    /// cases prêtes : chaque aperçu retomberait alors sur un repli propre à sa
    /// portée, en contradiction avec §52.1 (« la géométrie est TOUJOURS celle
    /// du projet »).
    ///
    /// Même méthode que le picker : `MediaLibraryActor.videoGeometry` puis
    /// `ProjectStore.lockGeometry` — déjà NO-OP si une géométrie existe
    /// (verrou définitif §49/§65), la lecture préalable évite simplement un
    /// aller-retour PhotoKit inutile. Le rush retenu est celui de la
    /// PREMIÈRE case prête (ordre des cases), au plus près de « premier rush »
    /// §49. Erreur → journal seulement, JAMAIS bloquant (aucune alerte : rien
    /// n'est cassé du point de vue de l'utilisateur).
    private func lockGeometryIfMissing() async {
        guard !hasAttemptedGeometryLock else { return }
        guard let firstReady = slotItems.first(where: { $0.state == .ready }),
              let assetID = firstReady.assetLocalIdentifier else {
            return // aucune case prête : rien à verrouiller (§49)
        }
        hasAttemptedGeometryLock = true
        let store = environment.projectStore
        do {
            let existing = try await store.geometry(projectID: projectID)
            guard existing == nil else {
                return // déjà verrouillée : rien à faire (§49)
            }
            let geometry = try await environment.mediaLibrary.videoGeometry(id: assetID)
            try await store.lockGeometry(geometry, projectID: projectID)
            environment.previewCache.invalidateAll(projectID: projectID) // §48
        } catch {
            environment.logger.error(
                "Rattrapage du verrouillage de géométrie impossible : \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Courbe musicale de la mini-timeline (§35.3)

    /// Extrait 200 bins du fichier audio ORIGINAL (§16.1) — même service et
    /// même résolution que la forme d'onde de `ProjectView` (§16.2, lecture
    /// par blocs §68). Échec ou annulation : la courbe reste vide, la
    /// mini-timeline se dessine sans fond (jamais bloquant).
    private func loadMusicCurve() async {
        guard musicCurve.isEmpty,
              let url = environment.fileStore.audioFileURL(projectID: projectID) else { return }
        do {
            musicCurve = try await environment.waveformExtractor.waveform(for: url, binCount: 200)
        } catch is CancellationError {
            return // écran quitté pendant l'extraction : nouvelle tentative au retour
        } catch {
            environment.logger.error("Courbe musicale indisponible : \(error.localizedDescription)")
        }
    }

    // MARK: - Miniatures réelles (Jalon 8, §35.1/§35.2)

    /// Miniature d'une case si elle est PRÊTE et déjà chargée — `nil`
    /// sinon (placeholder). Source unique pour la carte ET la zone haute
    /// (« même image », §35.1).
    private func thumbnail(for item: AssemblySlotItem) -> UIImage? {
        guard item.state == .ready, let assetID = item.assetLocalIdentifier else {
            return nil
        }
        return thumbnailsByAssetID[assetID]
    }

    /// Fenêtre de chargement des miniatures : identifiants d'asset des
    /// cases PRÊTES autour de la case active (± 2 — les trois cartes
    /// visibles du carrousel et leurs voisines immédiates §35.2).
    private var thumbnailWindowAssetIDs: [String] {
        let items = slotItems
        guard !items.isEmpty else { return [] }
        let active = AssemblyViewLogic.clampedActiveIndex(activeIndex, slotCount: items.count)
        let window = max(0, active - 2)...min(items.count - 1, active + 2)
        return window.compactMap { position in
            let item = items[position]
            guard item.state == .ready else { return nil }
            return item.assetLocalIdentifier
        }
    }

    /// Clé du `.task(id:)` des miniatures : la fenêtre ET la hauteur de
    /// carte ARRONDIE (§39/§87).
    ///
    /// La hauteur en fait partie parce que la taille demandée au
    /// `ThumbnailProvider` (`cardThumbnailPixelSize(cardHeight:)`) est celle
    /// de la carte, donc celle de `carouselHeight`, un `@ScaledMetric` :
    /// changer la taille de texte change la RÉSOLUTION demandée. Sans elle,
    /// la clé ne bougerait pas et les cartes garderaient des miniatures
    /// calculées pour l'ancienne taille (floues en grandissant). Arrondie au
    /// point : deux hauteurs identiques ne relancent rien.
    private struct ThumbnailWindowKey: Equatable, Sendable {
        let assetIDs: [String]
        let cardHeight: Int
    }

    private var thumbnailWindowKey: ThumbnailWindowKey {
        ThumbnailWindowKey(
            assetIDs: thumbnailWindowAssetIDs,
            cardHeight: Int(carouselHeight.rounded())
        )
    }

    /// Taille de carte en PIXELS pour les miniatures (§35.2) : largeur de
    /// carte ~55 % d'un grand iPhone (~215 pt) × hauteur de carte (celle du
    /// carrousel, mise à l'échelle Dynamic Type §39), à l'échelle de
    /// l'écran — approximation STABLE documentée (la largeur réelle dépend
    /// du conteneur), jamais de décodage 4K (§42/§67). La zone haute
    /// réutilise la même image (§35.1 « même image »), quitte à l'agrandir
    /// légèrement.
    ///
    /// La hauteur est passée en PARAMÈTRE (et non relue depuis
    /// `carouselHeight`) : c'est la MÊME valeur que celle de la clé du
    /// `.task`, donc la résolution demandée correspond toujours exactement
    /// à la taille pour laquelle le cache est rempli.
    private func cardThumbnailPixelSize(cardHeight: Int) -> CGSize {
        CGSize(width: 215 * displayScale, height: CGFloat(cardHeight) * displayScale)
    }

    /// Charge les miniatures MANQUANTES de la fenêtre (§35.2) via
    /// `ThumbnailProvider` — séquentiel (au plus 5 assets), chaque image
    /// mise en cache local par identifiant d'asset.
    ///
    /// §39/§87 : le cache est indexé par identifiant d'asset SEUL, alors que
    /// la résolution demandée dépend de la taille de texte. Un changement de
    /// taille périme donc TOUTES les images déjà chargées — le cache est vidé
    /// avant rechargement, sinon la boucle sauterait les entrées existantes
    /// et laisserait des miniatures à l'ancienne résolution. Le test est fait
    /// ICI (et non dans un `.onChange`) pour qu'il n'y ait aucun ordre
    /// d'exécution à supposer : le vidage précède toujours le rechargement.
    private func loadThumbnails(for key: ThumbnailWindowKey) async {
        if key.cardHeight != cachedThumbnailCardHeight {
            thumbnailsByAssetID.removeAll()
            cachedThumbnailCardHeight = key.cardHeight
        }
        let targetSize = cardThumbnailPixelSize(cardHeight: key.cardHeight)
        for assetID in key.assetIDs where thumbnailsByAssetID[assetID] == nil {
            guard !Task.isCancelled else { return }
            guard let image = await environment.thumbnailProvider.thumbnail(
                for: assetID,
                targetSize: targetSize
            ) else { continue } // asset disparu (§64) → placeholder
            thumbnailsByAssetID[assetID] = image
        }
    }

    // MARK: - Photothèque (Jalon 8) et export (Jalon 10)

    /// Ouvre la photothèque (Jalon 8, §40–§46) sur la case active. Le dock
    /// « + Vidéo » (case vide) et « Remplacer » (case remplie §36) mènent au
    /// MÊME sélecteur : sur une case remplie, le nouveau choix remplace
    /// l'association existante via `beginAssignment`. Le passage musical en
    /// cours est arrêté (§35.1).
    private func requestVideoSelection(for item: AssemblySlotItem) {
        playerController.stopSegment()
        activeSheet = .clipPicker(ClipPickerContext(
            id: item.id,
            slotIndex: item.index,
            requiredDuration: item.duration
        ))
    }

    /// Export (Jalon 10, §56) : présente le résumé AVANT export en feuille.
    /// Le bouton du dock n'est actif que si au moins une case est prête, ce
    /// chemin n'est donc atteint qu'avec un montage non vide ; le résumé
    /// revérifie de son côté (source unique : `readyTimeline(slots:)` sur
    /// l'instantané persisté).
    ///
    /// Rouvrir cette feuille PENDANT un encodage ne lance jamais un second
    /// export (§58) : `ExportSummaryView` détecte la progression en cours et
    /// en reprend le suivi.
    ///
    /// Le passage musical en cours est arrêté (§35.1) — l'écran d'export ne
    /// produit aucun son, mais laisser la musique tourner sous une feuille
    /// modale serait déroutant.
    private func requestExport() {
        playerController.stopSegment()
        activeSheet = .export
    }

    // MARK: - Changement de rythme (§65 — venant du placeholder Jalon 6)

    /// Changement de rythme AVANT association (§65) :
    /// `revertToPaceSelection` efface les cases et ramène le statut à
    /// `awaitingPaceSelection` — le routage de `ProjectView` affiche alors
    /// `PaceSelectionView`. Si une association existe : alerte §65 avec
    /// « Dupliquer », aucune mutation.
    private func changePace() {
        playerController.stopSegment()
        Task {
            do {
                try await environment.projectStore.revertToPaceSelection(projectID: projectID)
            } catch ProjectStoreError.paceLockedByAssignments {
                isPaceLockAlertPresented = true
            } catch {
                environment.logger.error("Changement de rythme impossible : \(error.localizedDescription)")
                paceChangeErrorMessage = Self.paceChangeFailureMessage
                isPaceChangeErrorPresented = true
            }
        }
    }

    /// §62/§64 : le message dit ce qui a échoué ET quoi faire — le montage
    /// n'a pas bougé, l'action est simplement à refaire.
    private static let paceChangeFailureMessage =
        "Le rythme n'a pas pu être changé. Votre montage est intact : réessayez depuis le menu du projet."

    private static let duplicationFailureMessage =
        "Le projet n'a pas pu être dupliqué. Votre montage est intact : réessayez, "
        + "ou libérez de l'espace sur l'iPhone si le problème persiste."

    /// §65 : duplication POUR CHANGER DE RYTHME — la copie repart SANS
    /// associations, au choix du rythme (`duplicateForPaceChange`), sinon
    /// la copie serait verrouillée comme l'original (impasse). Après
    /// duplication, retour à la liste où la copie apparaît.
    /// Non defini par la specification — definition minimale V1.
    private func duplicateForPaceChange() {
        Task {
            do {
                _ = try await environment.projectStore.duplicateForPaceChange(projectID: projectID)
                dismiss()
            } catch {
                environment.logger.error("Duplication impossible : \(error.localizedDescription)")
                paceChangeErrorMessage = Self.duplicationFailureMessage
                isPaceChangeErrorPresented = true
            }
        }
    }

    // MARK: - Helpers accessibilité (§39)

    /// Indication vocale de la zone haute (§39) — trois cas seulement :
    /// aperçu du plan (case prête §47.1), passage musical (case non prête),
    /// musique introuvable (§64 : la raison est DITE, jamais un bouton muet).
    private func previewHint(for item: AssemblySlotItem) -> String {
        if item.state == .ready {
            return "Touchez pour voir l'aperçu de ce plan."
        }
        if isMediaUnavailable {
            return "La musique du projet est introuvable : lecture impossible."
        }
        return "Touchez pour écouter le passage musical de ce plan."
    }

    /// Forme parlée de l'état d'une case — source UNIQUE partagée avec
    /// `SlotCardView` (§39 : même vocabulaire partout sur l'écran).
    private func spokenState(_ state: AssemblySlotState) -> String {
        state.spokenLabel
    }

    // MARK: - Composants de dock partagés (§37, §39)

    /// Bouton secondaire de dock — même style que `ProjectView` et
    /// `PaceSelectionView` (capsule translucide, cible ≥ 44 pt).
    private func dockSecondaryButton(
        title: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 52) // cible ≥ 44 pt (§39)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }
}

// La forme parlée `MediaTime.spokenString` (§39) est définie UNE seule fois
// dans App/Core/Time/MediaTimeFormatting.swift (extension interne partagée).

// MARK: - Previews (conteneur en mémoire, cases synthétiques)

@MainActor
private func makeAssemblyPreviewContainer(
    durationsTicks: [Int64],
    activeSlotIndex: Int
) -> (container: ModelContainer, projectID: UUID) {
    let container = try! ModelContainerFactory.makeInMemory()
    let projectID = UUID()
    let now = Date.now
    container.mainContext.insert(ProjectRecord(
        id: projectID,
        automaticTitle: automaticProjectTitle(date: now),
        customTitle: nil,
        createdAt: now,
        updatedAt: now,
        statusRaw: ProjectStatus.assembling.rawValue,
        selectedPaceRaw: PaceMode.kick.rawValue,
        activeSlotIndex: activeSlotIndex,
        audioRelativePath: nil,
        analysisRelativePath: nil,
        geometryData: nil,
        lastAlbumIdentifier: nil,
        analysisVersion: 1,
        scoreVersion: 1
    ))
    var start: Int64 = 0
    for (index, duration) in durationsTicks.enumerated() {
        container.mainContext.insert(ProjectSlotRecord(
            id: UUID(),
            projectID: projectID,
            scoreModeRaw: PaceMode.kick.rawValue,
            index: index,
            startTicks: start,
            endTicks: start + duration,
            entryAnchorID: UUID(),
            exitAnchorID: UUID(),
            gestureID: nil,
            assignmentID: nil
        ))
        start += duration
    }
    return (container, projectID)
}

#Preview("Assemblage — cases vides") {
    let (container, projectID) = makeAssemblyPreviewContainer(
        durationsTicks: [72_000, 96_000, 60_000, 120_000, 84_000, 108_000, 66_000, 90_000],
        activeSlotIndex: 2
    )
    let environment = AppEnvironment(modelContainer: container)
    return NavigationStack {
        AssemblyView(projectID: projectID)
            .navigationTitle("Projet du 10 août 2026 • 11:24")
            .toolbarTitleDisplayMode(.inline)
    }
    .environment(environment)
    .modelContainer(container)
}

// §39/§87 : contrôle visuel Dynamic Type de l'écran complet. Le carrousel et
// la mini-timeline suivent la taille de texte (`@ScaledMetric`) ; à cette
// taille, les hauteurs fixes du Jalon 7 tronquaient les cartes.
#Preview("Assemblage — accessibilité 3") {
    let (container, projectID) = makeAssemblyPreviewContainer(
        durationsTicks: [72_000, 96_000, 60_000, 120_000, 84_000, 108_000, 66_000, 90_000],
        activeSlotIndex: 2
    )
    let environment = AppEnvironment(modelContainer: container)
    return NavigationStack {
        AssemblyView(projectID: projectID)
            .navigationTitle("Projet du 10 août 2026 • 11:24")
            .toolbarTitleDisplayMode(.inline)
    }
    .environment(environment)
    .modelContainer(container)
    .environment(\.dynamicTypeSize, .accessibility3)
}
