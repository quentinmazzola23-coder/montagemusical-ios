//
//  PhotoLibrarySaver.swift
//  MontageMusical
//
//  Enregistrement du montage exporté dans Photos — spec §40 (autorisations :
//  « Ne demander l'accès d'écriture qu'au premier enregistrement dans
//  Photos »), §55 (« enregistrement dans Photos seulement après succès
//  complet »), §58 (« ne créer aucun asset Photos incomplet »), §66
//  (« Photos refusé : conserver temporairement l'export et proposer
//  d'autoriser l'accès ou partager via feuille système »).
//
//  Non defini par la specification — definition minimale V1.
//

import Foundation
import Photos

/// Enregistre un fichier exporté dans la photothèque (§40, §55).
///
/// **Séparé de l'export volontairement.** `ExportActor` ne l'appelle PAS :
/// l'écriture dans Photos est une action utilisateur distincte, déclenchée
/// après l'export réussi (§40 : la demande d'accès en écriture ne doit
/// survenir qu'au PREMIER enregistrement, pas au lancement ni au début d'un
/// export). Un export annulé ou échoué ne peut donc, par construction, créer
/// aucun asset Photos incomplet (§58).
///
/// `Sendable` sans état : `PHPhotoLibrary` est thread-safe et l'objet ne
/// conserve rien entre deux appels.
struct PhotoLibrarySaver: Sendable {

    init() {}

    // MARK: - §40 Autorisation d'écriture

    /// Demande l'accès en AJOUT à la photothèque (`PHAccessLevel.addOnly`).
    ///
    /// §40 : « Ne demander l'accès d'écriture qu'au premier enregistrement
    /// dans Photos » — cette méthode n'est donc appelée qu'au moment où
    /// l'utilisateur demande explicitement l'enregistrement, jamais au
    /// lancement ni pendant l'encodage.
    ///
    /// Le niveau `.addOnly` est distinct du `.readWrite` demandé par
    /// `MediaLibraryActor` pour CHOISIR les rushs (§40 : deux descriptions de
    /// permission distinctes, `NSPhotoLibraryUsageDescription` et
    /// `NSPhotoLibraryAddUsageDescription`).
    func requestAddAccess() async -> MediaLibraryAuthorization {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return Self.mapAuthorization(status)
    }

    /// État d'autorisation d'AJOUT courant, SANS déclencher de demande
    /// système (affichage d'état, §40).
    func currentAddAuthorization() -> MediaLibraryAuthorization {
        Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    /// Mapping §40 : non demandé / accès complet / accès limité / refusé.
    ///
    /// `.restricted` (contrôle parental…) est traité comme refusé : même
    /// conséquence produit (le fichier est conservé, l'utilisateur partage
    /// via la feuille système, §66).
    ///
    /// `.limited` n'existe pas en pratique pour `.addOnly` (la sélection
    /// limitée concerne la lecture) : le cas est mappé tel quel et traité
    /// comme AUTORISÉ à l'écriture — un ajout reste possible.
    private static func mapAuthorization(_ status: PHAuthorizationStatus) -> MediaLibraryAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .full
        case .limited: .limited
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    // MARK: - §55 Enregistrement

    /// Enregistre le fichier exporté dans la photothèque.
    ///
    /// Déroulé :
    /// 1. autorisation d'ajout — DEMANDÉE ici si elle n'a jamais été demandée
    ///    (§40 : au premier enregistrement seulement) ;
    /// 2. refus → `ExportError.photosAccessDenied`. **Le fichier n'est ni
    ///    supprimé ni déplacé** (§66 : « conserver temporairement l'export et
    ///    proposer d'autoriser l'accès ou partager via feuille système ») ;
    /// 3. création de l'asset via `PHAssetCreationRequest.forAsset()` +
    ///    `addResource(with: .video, fileURL:options:)`.
    ///
    /// `shouldMoveFile = false` : Photos COPIE le fichier. L'export reste
    /// disponible dans `exports/` (§11) — c'est lui que §60 restaure comme
    /// « dernier export réussi », et c'est lui que la feuille de partage
    /// utilise si l'utilisateur préfère partager plutôt qu'enregistrer.
    ///
    /// **Conséquence §57 : la copie demande autant d'espace que l'export.**
    /// Cette place est exigée AVANT l'encodage
    /// (`ProjectExporter.photosCopyFactor`), donc l'échec par manque de place
    /// ne peut venir que d'un espace consommé entre-temps ; il est alors
    /// annoncé distinctement (`ExportError.photosStorageFull`) et le fichier
    /// exporté est conservé (§66).
    ///
    /// Cette méthode n'est appelée qu'APRÈS un export complet (§55, §58) :
    /// aucun asset Photos ne peut correspondre à un encodage partiel.
    func save(fileURL: URL) async throws {
        // §40 : la demande n'a lieu qu'ici, et seulement si l'état est
        // « non demandé » — un refus déjà exprimé n'est jamais re-sollicité
        // en boucle (l'interface renvoie vers Réglages, §64).
        var authorization = currentAddAuthorization()
        if authorization == .notDetermined {
            authorization = await requestAddAccess()
        }
        switch authorization {
        case .full, .limited:
            break
        case .denied, .notDetermined:
            // §66 : le fichier est CONSERVÉ ; l'appelant propose d'autoriser
            // l'accès ou de partager.
            throw ExportError.photosAccessDenied
        }

        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            throw ExportError.exportFailed("Le fichier exporté est introuvable.")
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                // Le fichier source reste dans `exports/` (§11, §60).
                options.shouldMoveFile = false
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: fileURL, options: options)
            }
        } catch {
            // Un refus survenu ENTRE la vérification et l'écriture (accès
            // révoqué depuis Réglages) est traité comme un refus, pas comme
            // un échec d'export : le fichier est conservé, le message §66
            // reste le bon.
            if currentAddAuthorization() == .denied {
                throw ExportError.photosAccessDenied
            }
            // §57 : manque d'espace pendant la COPIE — cause DITE, jamais
            // noyée dans un « échec » générique. Le fichier exporté reste
            // dans `exports/` (§66).
            if Self.isOutOfSpace(error) {
                throw ExportError.photosStorageFull
            }
            throw ExportError.exportFailed(error.localizedDescription)
        }
    }

    /// Vrai si l'erreur système signale un disque plein (§57).
    ///
    /// Deux domaines possibles selon la couche qui a échoué : Cocoa
    /// (`NSFileWriteOutOfSpaceError`) quand c'est l'écriture du fichier, POSIX
    /// (`ENOSPC`, 28) quand l'erreur remonte directement du système de
    /// fichiers. Toute autre erreur reste un échec générique — jamais de
    /// diagnostic inventé.
    private static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 28 { // ENOSPC
            return true
        }
        // L'erreur utile peut être encapsulée (PhotoKit enveloppe l'erreur
        // d'écriture sous-jacente).
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpace(underlying)
        }
        return false
    }
}
