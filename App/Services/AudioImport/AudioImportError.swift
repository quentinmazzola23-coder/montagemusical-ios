//
//  AudioImportError.swift
//  MontageMusical
//
//  Erreurs d'import audio — spec §62 (« Import audio ») :
//  chaque cas correspond à un cas limite listé par la spécification, avec
//  un message français clair expliquant quoi faire.
//

import Foundation

/// Erreurs de l'import audio (spec §62).
///
/// Formats initiaux acceptés après validation réelle par AVFoundation :
/// M4A/AAC, MP3, WAV et AIFF. L'extension seule ne suffit jamais ; une piste
/// audio décodable doit exister.
enum AudioImportError: Error, Equatable, LocalizedError {

    /// Extension/UTI hors M4A/AAC, MP3, WAV, AIFF (§62 : « type non
    /// supporté : expliquer »). La valeur associée est l'extension refusée.
    case unsupportedType(String)

    /// Fichier vide ou corrompu (§62 : « ne pas lancer l'analyse »).
    case emptyOrCorruptFile

    /// Aucune piste audio décodable — l'extension seule ne suffit pas (§62).
    case noDecodableAudioTrack

    /// Fichier protégé par DRM (§62 : « expliquer qu'un fichier audio local
    /// non protégé est nécessaire »).
    case protectedContent

    /// Copie interrompue (§62 : « nettoyer le fichier partiel »).
    case copyInterrupted

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let fileExtension):
            let displayed = fileExtension.isEmpty ? "sans extension" : "« .\(fileExtension) »"
            return "Le format \(displayed) n'est pas pris en charge. "
                + "Choisissez un fichier audio M4A/AAC, MP3, WAV ou AIFF."
        case .emptyOrCorruptFile:
            return "Ce fichier audio est vide ou endommagé, l'analyse n'a pas été lancée. "
                + "Choisissez un autre fichier audio."
        case .noDecodableAudioTrack:
            return "Aucune piste audio lisible n'a été trouvée dans ce fichier. "
                + "L'extension ne suffit pas : choisissez un vrai fichier audio "
                + "M4A/AAC, MP3, WAV ou AIFF."
        case .protectedContent:
            return "Ce fichier est protégé (DRM) et ne peut pas être utilisé. "
                + "Choisissez un fichier audio local non protégé, par exemple "
                + "un enregistrement personnel ou un achat sans DRM."
        case .copyInterrupted:
            return "La copie du fichier audio a été interrompue et le fichier "
                + "partiel a été supprimé. Réessayez l'import."
        }
    }
}
