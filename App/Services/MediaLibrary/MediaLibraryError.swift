//
//  MediaLibraryError.swift
//  MontageMusical
//
//  Erreurs de la photothèque — spec §64 (« Photothèque ») :
//  chaque cas correspond à un cas limite listé par la spécification, avec
//  un message français clair expliquant quoi faire (pattern
//  `AudioImportError`, §62).
//

import Foundation

/// Erreurs de l'accès photothèque et de la résolution d'assets (spec §64).
///
/// Les cas de refus (`accessDenied`, `noVideoTrack`, `assetTooShort`) ne
/// remplissent JAMAIS une case ; les cas récupérables (`icloudUnavailable`)
/// permettent un réessai explicite.
enum MediaLibraryError: Error, Equatable, LocalizedError {

    /// Accès Photos refusé ou restreint (§40/§64 : « accès refusé : écran
    /// explicatif + Réglages » — ne jamais bloquer l'application entière).
    case accessDenied

    /// L'album demandé n'existe plus (supprimé ou hors de la sélection
    /// limitée). Non defini par la specification — definition minimale V1.
    case albumNotFound

    /// Asset introuvable (§64 : « asset supprimé : case `unavailable` »).
    case assetNotFound

    /// §43/§64 : « asset annoncé compatible mais trop court après
    /// résolution : refuser l'association ». Le filtre initial
    /// (`PHAsset.duration`, métadonnée arrondie) annonçait compatible mais
    /// la durée réelle de l'`AVAsset` résolu est insuffisante.
    case assetTooShort(requiredTicks: Int64, observedTicks: Int64)

    /// §64 : « piste vidéo absente : refuser ».
    case noVideoTrack

    /// §64 : « iCloud hors réseau : permettre réessai » — le téléchargement
    /// à la demande (§44) a échoué ou le réseau était interdit.
    case icloudUnavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "L'accès à la photothèque est refusé. "
                + "Ouvrez Réglages pour autoriser la lecture de vos vidéos : "
                + "l'application en a besoin uniquement pour sélectionner vos rushs."
        case .albumNotFound:
            return "Cet album n'est plus disponible. "
                + "Il a peut-être été supprimé ou n'est plus autorisé. "
                + "Choisissez un autre album."
        case .assetNotFound:
            return "Cette vidéo n'est plus disponible dans votre photothèque. "
                + "Elle a peut-être été supprimée. Choisissez une autre vidéo."
        case .assetTooShort(let requiredTicks, let observedTicks):
            let required = MediaTime(ticks: requiredTicks).seconds
            let observed = MediaTime(ticks: observedTicks).seconds
            return String(
                format: "Cette vidéo est trop courte pour la case : "
                    + "%.2f s disponibles pour %.2f s requises. "
                    + "La case n'a pas été remplie — choisissez une vidéo plus longue.",
                observed, required
            )
        case .noVideoTrack:
            return "Ce média ne contient aucune piste vidéo lisible et ne peut "
                + "pas être utilisé dans le montage. Choisissez une vidéo."
        case .icloudUnavailable:
            return "Cette vidéo est dans iCloud et n'a pas pu être téléchargée. "
                + "Vérifiez votre connexion réseau puis réessayez."
        }
    }
}
