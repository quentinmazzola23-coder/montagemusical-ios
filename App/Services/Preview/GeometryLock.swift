//
//  GeometryLock.swift
//  MontageMusical
//
//  Verrouillage de la géométrie du projet (§14, §49) et crop-to-fill centré
//  (§50). Type PUR : aucune dépendance AVFoundation, aucune E/S — il ne
//  reçoit que des valeurs déjà lues (`naturalSize`, `preferredTransform`),
//  ce qui le rend testable sans photothèque ni asset réel.
//
//  Non defini par la specification — definition minimale V1.
//

import CoreGraphics
import Foundation

/// Calculs de géométrie du projet (spec §49, §50).
///
/// Trois responsabilités, dans l'ordre du montage :
/// 1. `geometry(...)` — §49 : le PREMIER rush prêt fixe le rapport et
///    l'orientation du projet ; la valeur produite est ensuite persistée
///    par `ProjectStore.lockGeometry` et **ne change plus jamais** (§14,
///    §49 étape 5, §65) ;
/// 2. `renderSize(...)` — dimensions de rendu respectant ce rapport ;
/// 3. `cropToFillTransform(...)` — §50 : placement d'un rush de rapport
///    différent dans ce rendu, sans bande noire.
enum GeometryLock {

    // MARK: - §49 Géométrie verrouillée par le premier rush

    /// Géométrie du projet déduite du premier rush prêt (spec §49) :
    ///
    /// 1. lire `naturalSize` et `preferredTransform` (fait par l'appelant) ;
    /// 2. calculer les dimensions **orientées** ;
    /// 3. simplifier le rapport (PGCD) pour la métadonnée d'affichage ;
    /// 4. enregistrer la géométrie (`ProjectStore.lockGeometry`) ;
    /// 5. ne plus jamais la modifier automatiquement.
    ///
    /// « Le premier rush peut être vertical, horizontal, carré ou autre. Ne
    /// pas limiter à 9:16/16:9 » (§49) : aucun rapport n'est privilégié, le
    /// PGCD est appliqué tel quel (3840×2160 → 16:9, 1440×1080 → 4:3,
    /// 1080×1080 → 1:1).
    ///
    /// - Parameters:
    ///   - naturalWidth: largeur BRUTE de la piste vidéo (non orientée).
    ///   - naturalHeight: hauteur BRUTE de la piste vidéo (non orientée).
    ///   - preferredTransform: transformation d'orientation de la piste.
    ///   - assetIdentifier: identifiant local du rush qui verrouille (§14
    ///     `lockedByAssetIdentifier`).
    static func geometry(
        naturalWidth: Int,
        naturalHeight: Int,
        preferredTransform: CGAffineTransform,
        assetIdentifier: String
    ) -> ProjectGeometry {
        let oriented = orientedSize(
            naturalSize: CGSize(width: naturalWidth, height: naturalHeight),
            preferredTransform: preferredTransform
        )
        // Arrondi au pixel : une rotation exprimée en radians produit des
        // dimensions à 1e-13 près (1080,0000000000001) — la métadonnée de
        // rapport doit rester entière et stable.
        let width = Int(oriented.width.rounded())
        let height = Int(oriented.height.rounded())

        // GARDE-FOU documenté : dimension nulle ou négative (piste corrompue,
        // transformation dégénérée). Aucun rapport « 0:x » n'est affichable et
        // aucune division par zéro n'est permise → repli 1:1 carré, verrouillé
        // par le même asset. Cas jamais attendu en production : la résolution
        // §43/§64 refuse déjà un asset sans piste vidéo lisible.
        guard width > 0, height > 0 else {
            return ProjectGeometry(
                aspectWidth: 1,
                aspectHeight: 1,
                orientation: .square,
                lockedByAssetIdentifier: assetIdentifier
            )
        }

        let divisor = greatestCommonDivisor(width, height)
        let orientation: ProjectOrientation
        if height > width {
            orientation = .portrait
        } else if width > height {
            orientation = .landscape
        } else {
            orientation = .square
        }

        return ProjectGeometry(
            aspectWidth: width / divisor,
            aspectHeight: height / divisor,
            orientation: orientation,
            lockedByAssetIdentifier: assetIdentifier
        )
    }

    // MARK: - §50 Crop-to-fill centré

    /// Transformation COMPLÈTE à poser sur la `layerInstruction` d'un rush
    /// pour remplir le rendu sans bande noire (spec §50 : « V1 : crop-to-fill
    /// centré », §54 étape 7 : « appliquer orientation, scale et
    /// translation »).
    ///
    /// **L'ORDRE COMPTE** — les trois étapes sont appliquées dans cet ordre
    /// exact (composition de gauche à droite : `a.concatenating(b)` applique
    /// `a` PUIS `b`) :
    ///
    /// 1. **orientation** — `preferredTransform` d'abord, sinon un rush
    ///    filmé en portrait serait mis à l'échelle avec ses dimensions
    ///    capteur (paysage) et le cadrage serait faux. Une rotation ou un
    ///    miroir déplace le rectangle hors de l'origine (une rotation de 90°
    ///    envoie le rush en x négatif) : il est ramené sur (0,0) AVANT toute
    ///    mise à l'échelle ;
    /// 2. **échelle** — `scale = max(renderW / srcW, renderH / srcH)` (§50).
    ///    C'est bien `max` (crop-to-fill : le rush déborde et on rogne) et
    ///    non `min` (fit : bandes noires interdites) ;
    /// 3. **centrage** — le débordement est réparti à parts égales des deux
    ///    côtés, « puis centrer après application de `preferredTransform` »
    ///    (§50).
    ///
    /// - Parameters:
    ///   - naturalSize: taille BRUTE (non orientée) de la piste source.
    ///   - preferredTransform: transformation d'orientation de la piste.
    ///   - renderSize: taille de rendu de la composition (`renderSize(...)`).
    /// - Returns: la transformation complète, à poser telle quelle via
    ///   `AVMutableVideoCompositionLayerInstruction.setTransform(_:at:)`.
    static func cropToFillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        // 1. ORIENTATION (puis recentrage sur l'origine).
        let sourceRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
        let oriented = preferredTransform.concatenating(
            CGAffineTransform(translationX: -sourceRect.origin.x, y: -sourceRect.origin.y)
        )

        let orientedWidth = abs(sourceRect.width)
        let orientedHeight = abs(sourceRect.height)
        // Garde-fou : rien à mettre à l'échelle ni à centrer (dimensions
        // dégénérées) — l'orientation seule est retournée, jamais un NaN.
        guard orientedWidth > 0, orientedHeight > 0,
              renderSize.width > 0, renderSize.height > 0 else {
            return oriented
        }

        // 2. ÉCHELLE — crop-to-fill : `max` (§50).
        let scale = max(
            renderSize.width / orientedWidth,
            renderSize.height / orientedHeight
        )
        let scaled = oriented.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        // 3. CENTRAGE — moitié du débordement de chaque côté.
        let translationX = (renderSize.width - orientedWidth * scale) / 2
        let translationY = (renderSize.height - orientedHeight * scale) / 2
        return scaled.concatenating(
            CGAffineTransform(translationX: translationX, y: translationY)
        )
    }

    // MARK: - Dimensions de rendu

    /// Taille de rendu de la composition : **rapport de la géométrie
    /// verrouillée** (§52.1 : « Toujours celle du projet, définie par le
    /// premier rush ») dimensionné sur le clip maître.
    ///
    /// Le rapport est INSCRIT dans les dimensions du maître (jamais
    /// d'agrandissement au-delà de sa résolution réelle : §52.2 « Ne pas
    /// inventer du 4K60 à partir d'un clip 4K30 et d'un autre 1080p60 ») :
    /// la dimension contraignante prend la valeur du maître, l'autre est
    /// déduite du rapport verrouillé. Un maître de rapport différent (§50)
    /// est donc rendu dans la géométrie du projet, sans déformation.
    ///
    /// Les deux dimensions sont **PAIRES** : les encodeurs vidéo H.264/HEVC
    /// en 4:2:0 exigent des dimensions paires (§55). L'arrondi au multiple
    /// de 2 le plus proche introduit au plus un demi-pixel d'écart de
    /// rapport — écart assumé et documenté, invisible à l'image.
    ///
    /// Jalon 9 : l'appelant passe les dimensions ORIENTÉES du premier rush
    /// de la portée. Le **profil maître complet** (§52.2 : classement
    /// lexicographique pixels / cadence / HDR, §52.3 cadences, §52.4
    /// colorimétrie) arrive au **Jalon 10** — seules les dimensions sont
    /// utilisées ici.
    ///
    /// - Parameters:
    ///   - geometry: géométrie verrouillée du projet (§14).
    ///   - masterWidth: largeur ORIENTÉE du clip maître.
    ///   - masterHeight: hauteur ORIENTÉE du clip maître.
    static func renderSize(
        for geometry: ProjectGeometry,
        masterWidth: Int,
        masterHeight: Int
    ) -> CGSize {
        // Garde-fous : aucune dimension ni aucun terme de rapport nul
        // (division par zéro impossible).
        let aspectWidth = Double(max(geometry.aspectWidth, 1))
        let aspectHeight = Double(max(geometry.aspectHeight, 1))
        let sourceWidth = Double(max(masterWidth, 1))
        let sourceHeight = Double(max(masterHeight, 1))

        let width: Double
        let height: Double
        if sourceWidth * aspectHeight >= sourceHeight * aspectWidth {
            // Maître plus large (ou égal) que le rapport cible → la HAUTEUR
            // contraint : on garde toute la hauteur du maître.
            height = sourceHeight
            width = sourceHeight * aspectWidth / aspectHeight
        } else {
            // Maître plus étroit → la LARGEUR contraint.
            width = sourceWidth
            height = sourceWidth * aspectHeight / aspectWidth
        }

        return CGSize(width: evenDimension(width), height: evenDimension(height))
    }

    // MARK: - Helpers (support interne, partagé avec le constructeur de preview)

    /// Dimensions ORIENTÉES d'une piste : rectangle source après application
    /// de `preferredTransform`, valeurs absolues (§49 étape 2).
    ///
    /// `CGRect.applying(_:)` retourne le rectangle ENGLOBANT — c'est
    /// exactement la définition voulue pour une rotation de 90° (1920×1080
    /// → 1080×1920) comme pour un miroir (dimensions inchangées).
    static func orientedSize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Arrondi au multiple de 2 le plus proche, minimum 2 (§55 : dimensions
    /// paires obligatoires à l'encodage).
    private static func evenDimension(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 2 }
        return max(2, (value / 2).rounded() * 2)
    }

    /// PGCD d'Euclide — simplification du rapport d'affichage (§49 étape 3).
    /// Retourne au minimum 1 : jamais de division par zéro.
    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var a = abs(a)
        var b = abs(b)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }
}
