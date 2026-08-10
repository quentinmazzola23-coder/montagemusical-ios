//
//  PreviewBuilding.swift
//  MontageMusical
//
//  Protocole de prévisualisation — spécification §7 (verbatim).
//  AVFoundation est utilisé uniquement à la frontière (`AVPlayerItem`),
//  conformément à la spec §9 (conversion vers CMTime seulement aux
//  frontières AVFoundation).
//

import Foundation

#if canImport(AVFoundation)
import AVFoundation

protocol PreviewBuilding {
    func makePreview(for project: ProjectSnapshot, scope: PreviewScope) async throws -> AVPlayerItem
}
#endif
