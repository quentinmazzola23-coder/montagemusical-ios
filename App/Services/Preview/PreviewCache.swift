//
//  PreviewCache.swift
//  MontageMusical
//
//  Cache des compositions de prévisualisation — spec §48 : « mettre en cache
//  la composition tant que les associations ne changent pas », et §69 :
//  « Invalider uniquement la couche nécessaire ».
//
//  Non defini par la specification — definition minimale V1.
//

import AVFoundation
import Foundation

// MARK: - Clé de cache (§48, §69)

/// Clé d'une prévisualisation en cache.
///
/// Les trois composantes couvrent EXACTEMENT les causes d'invalidation
/// listées par la spec §48 :
/// - `projectID` : le cache d'un projet ne peut jamais servir à un autre ;
/// - `scopeKey` : une case (`slot:<uuid>`), l'aperçu principal (`prefix`) ou
///   le montage complet (`complete`) sont des compositions différentes (§47) ;
/// - `assignmentsFingerprint` : empreinte des cases, de leurs associations
///   et de la géométrie — elle change dès qu'« une association change », que
///   « la géométrie change lors du premier rush », qu'« un asset devient
///   indisponible » ou que « le rythme change avant verrouillage » (§48).
///
/// Une composition n'est donc JAMAIS réutilisée après une modification du
/// montage : la clé ne correspond simplement plus.
///
/// **Changement produit (timeline concaténée) : la clé reste INCHANGÉE, et
/// c'est VÉRIFIÉ.** L'aperçu principal porte désormais sur la TIMELINE
/// concaténée de toutes les zones remplies. Cette timeline est une FONCTION
/// PURE de `readyTimeline(slots:)`, dont les seules entrées sont l'index, les
/// frontières `start`/`end` et le STATUT d'association de chaque case — les
/// trois familles de données déjà sérialisées par `fingerprint`, case par
/// case et dans l'ordre.
///
/// Il en découle que deux timelines DIFFÉRENTES ne peuvent pas partager une
/// empreinte : tout ce qui change une timeline (une case devenue prête ou non
/// prête, donc un run qui apparaît, disparaît, se scinde ou fusionne ; une
/// frontière déplacée, donc une durée de run et toutes les positions qui
/// suivent ; une case ajoutée ou retirée) change au moins un octet de la
/// description sérialisée. La réciproque n'est pas vraie — deux empreintes
/// différentes peuvent décrire la même timeline (changement d'`assignment.id`
/// à rush identique) — et c'est le bon sens de l'inégalité : le cache peut
/// manquer, il ne peut jamais resservir une composition périmée.
///
/// Ajouter la timeline à la clé n'apporterait donc rien et introduirait une
/// seconde source de vérité. Le test
/// `PreviewCacheKeyTests.testFingerprintDistinguishesTwoDifferentTimelines`
/// verrouille cette propriété sur le cas le plus subtil : deux montages dont
/// le DÉCOUPAGE EN RUNS diffère.
struct PreviewCacheKey: Hashable, Sendable {
    let projectID: UUID
    /// `"slot:<uuid>"` | `"prefix"` (aperçu principal = timeline concaténée) |
    /// `"complete"`. La VALEUR `"prefix"` est conservée telle quelle : c'est
    /// un identifiant opaque de portée, jamais affiché, et le renommer
    /// n'aurait aucun effet observable.
    let scopeKey: String
    /// §48 : invalidation dès qu'une association (ou la géométrie) change.
    let assignmentsFingerprint: String
}

extension PreviewCacheKey {

    /// Clé complète pour une portée d'un instantané de projet — à utiliser
    /// systématiquement plutôt que de composer les champs à la main.
    init(scope: PreviewScope, snapshot: ProjectSnapshot) {
        self.init(
            projectID: snapshot.projectID,
            scopeKey: Self.scopeKey(for: scope),
            assignmentsFingerprint: Self.fingerprint(for: snapshot)
        )
    }

    /// Identité textuelle d'une portée (§47).
    static func scopeKey(for scope: PreviewScope) -> String {
        switch scope {
        case .slot(let slotID): "slot:\(slotID.uuidString)"
        case .contiguousPrefix: "prefix"
        case .complete: "complete"
        }
    }

    /// Empreinte de l'état de montage d'un projet (§48).
    ///
    /// Couvre les cases (identité, ordre, frontières ABSOLUES §9) et leurs
    /// associations (identifiant d'association, rush, statut), plus la
    /// géométrie verrouillée. Deux états de montage différents produisent
    /// donc deux empreintes différentes — et comme la TIMELINE exportable se
    /// déduit entièrement de ces mêmes données (index, frontières, statuts),
    /// deux timelines différentes donnent forcément deux empreintes
    /// différentes.
    ///
    /// Le condensé est un FNV-1a 64 bits : court, stable d'un lancement à
    /// l'autre (contrairement à `Hasher`, dont la graine change à chaque
    /// exécution) et sans dépendance à CryptoKit — aucune propriété
    /// cryptographique n'est requise pour une clé de cache mémoire.
    static func fingerprint(for snapshot: ProjectSnapshot) -> String {
        var description = ""
        if let geometry = snapshot.geometry {
            description += "g:\(geometry.aspectWidth)x\(geometry.aspectHeight)"
                + ":\(geometry.orientation.rawValue):\(geometry.lockedByAssetIdentifier);"
        } else {
            description += "g:none;"
        }
        for slot in snapshot.slots {
            description += "s:\(slot.index):\(slot.id.uuidString)"
                + ":\(slot.start.ticks):\(slot.end.ticks)"
            if let assignment = slot.assignment {
                description += ":a:\(assignment.id.uuidString)"
                    + ":\(assignment.assetLocalIdentifier):\(assignment.status.rawValue)"
            } else {
                description += ":a:none"
            }
            description += ";"
        }
        return Self.fnv1a(description)
    }

    /// FNV-1a 64 bits (déterministe, sans dépendance externe).
    private static func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Composition mise en cache (§48)

/// Couple immuable mis en cache pour une portée de prévisualisation (§48) :
/// la composition assemblée et son plan de rendu géométrique.
///
/// **Pourquoi une composition et NON un `AVPlayerItem`.** Un `AVPlayerItem`
/// ne peut être associé qu'à UN seul `AVPlayer` à la fois : le réutiliser
/// depuis un cache pour l'attacher à un lecteur neuf lève
/// `NSInvalidArgumentException` (« player item cannot be associated with more
/// than one player »). Ce qui coûte cher et mérite le cache (§48), c'est
/// l'ASSEMBLAGE des pistes : résolution PhotoKit, chargement des pistes
/// AVFoundation, insertion des plages, calcul des transformations §50. La
/// fabrication de l'`AVPlayerItem` à partir de ce couple, elle, est
/// instantanée — chaque présentation en fabrique donc un NEUF.
///
/// `asset` est une `AVComposition` IMMUABLE (copie de l'`AVMutableComposition`
/// de travail) : une composition immuable peut alimenter plusieurs
/// `AVPlayerItem` successifs sans risque, contrairement à la version mutable
/// dont la mutation pendant la lecture est un comportement indéfini.
struct CachedComposition {

    // Non defini par la specification — outil de concurrence V1.
    /// Boîte de transfert d'un objet AVFoundation (non-`Sendable`) conservé
    /// dans une structure de cache.
    ///
    /// `AVPlayerItem(asset:)` prend son asset en paramètre **`sending`** : il
    /// exige une valeur d'une région DISJOINTE. Une propriété stockée — même
    /// recopiée par `copy()` — reste rattachée à la région de son conteneur,
    /// d'où le diagnostic « sending value of non-Sendable type ». Traverser
    /// une valeur `Sendable` détache la région.
    ///
    /// Sûreté par CONTRAT D'USAGE : la composition encapsulée est IMMUABLE
    /// (`AVComposition`, jamais la version mutable de travail) et n'est lue
    /// que sur `@MainActor` (cache, constructeur et lecteur y vivent tous,
    /// §8) — aucun partage entre threads n'est possible.
    private struct AssetBox: @unchecked Sendable {
        let asset: AVComposition
        let videoComposition: AVVideoComposition?
    }

    private let box: AssetBox

    /// Pistes assemblées (§48, §54) — immuable.
    var asset: AVComposition { box.asset }

    /// Plan de rendu §49/§50 (taille de rendu + instructions par case), ou
    /// `nil` si la portée ne contient aucun segment vidéo.
    var videoComposition: AVVideoComposition? { box.videoComposition }

    init(asset: AVComposition, videoComposition: AVVideoComposition?) {
        self.box = AssetBox(asset: asset, videoComposition: videoComposition)
    }

    /// Fabrique un `AVPlayerItem` NEUF pour une présentation (§48).
    ///
    /// À appeler à CHAQUE ouverture du lecteur : l'item est jetable, la
    /// composition ne l'est pas. Un `AVPlayerItem` ne pouvant être rattaché
    /// qu'à un seul `AVPlayer`, il n'est JAMAIS mis en cache.
    func makePlayerItem() -> AVPlayerItem {
        let box = self.box
        let item = AVPlayerItem(asset: box.asset)
        item.videoComposition = box.videoComposition
        return item
    }
}

// MARK: - Cache (§48, §69)

/// Cache mémoire des compositions de prévisualisation (§48 : « mettre en
/// cache la composition tant que les associations ne changent pas »).
///
/// `@MainActor` : une `AVComposition` n'est pas `Sendable` et est consommée
/// par la vue de lecture (§8 : « Les vues et view models restent sur
/// `@MainActor` »). Le cache vit donc dans le même domaine d'isolation que
/// `PreviewBuilder` et que le lecteur — aucun objet AVFoundation ne traverse
/// de frontière.
///
/// Capacité bornée (§67/§68 : la mémoire est une ressource limitée sur
/// iPhone) : au-delà de `capacity`, l'entrée la plus anciennement UTILISÉE
/// est évincée. Une éviction n'est jamais une perte de données — la
/// composition est reconstruite à la demande.
@MainActor
final class PreviewCache {

    /// Nombre maximal de compositions conservées.
    /// Non defini par la specification — valeur minimale V1 : un aperçu
    /// principal + quelques aperçus locaux récents (§47).
    /// Visibilité interne (et non privée) pour que les tests d'éviction
    /// décrivent la borne réelle plutôt qu'une constante dupliquée.
    static let capacity = 6

    private var compositions: [PreviewCacheKey: CachedComposition] = [:]
    /// Ordre d'utilisation, du plus ancien au plus récent (éviction LRU).
    private var usageOrder: [PreviewCacheKey] = []

    init() {}

    /// Composition en cache pour cette clé, ou `nil`.
    ///
    /// Un accès rafraîchit la position LRU : l'aperçu qu'on relit ne se fait
    /// pas évincer par un aperçu local ponctuel.
    func composition(for key: PreviewCacheKey) -> CachedComposition? {
        guard let composition = compositions[key] else { return nil }
        touch(key)
        return composition
    }

    /// Met une composition en cache (§48 : « tant que les associations ne
    /// changent pas » — c'est la clé qui porte cette garantie).
    func store(_ composition: CachedComposition, for key: PreviewCacheKey) {
        compositions[key] = composition
        touch(key)
        while usageOrder.count > Self.capacity {
            let evicted = usageOrder.removeFirst()
            compositions[evicted] = nil
        }
    }

    /// Invalide TOUTES les compositions d'un projet (§48).
    ///
    /// Filet de sécurité explicite lorsqu'un changement ne se voit pas dans
    /// l'empreinte : musique remplacée, projet dupliqué, retour depuis les
    /// Réglages après un changement d'autorisation photothèque (§40, §65).
    /// Les autres projets ne sont pas touchés.
    func invalidateAll(projectID: UUID) {
        // Clés collectées AVANT la mutation : jamais d'itération sur la vue
        // `keys` d'un dictionnaire en cours de modification.
        let obsoleteKeys = compositions.keys.filter { $0.projectID == projectID }
        for key in obsoleteKeys {
            compositions[key] = nil
        }
        usageOrder.removeAll { $0.projectID == projectID }
    }

    /// Replace la clé en fin de liste d'utilisation (position « la plus
    /// récente »).
    private func touch(_ key: PreviewCacheKey) {
        usageOrder.removeAll { $0 == key }
        usageOrder.append(key)
    }
}
