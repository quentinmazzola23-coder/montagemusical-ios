//
//  ProjectModels.swift
//  MontageMusical
//
//  Modèles de projet — spécification §10 et §10.1 (verbatim).
//  Domaine indépendant de SwiftUI (spec §6).
//

import Foundation
import SwiftData

// MARK: - Statut de projet (spec §10, verbatim)

enum ProjectStatus: String, Codable {
    case draft
    case importingAudio
    case analyzing
    case awaitingPaceSelection
    case assembling
    case partiallyPreviewable
    case complete
    case exporting
    case failed
}

// MARK: - Projet persisté (spec §10, verbatim)

/// Enregistrement SwiftData d'un projet.
///
/// Le titre affiché vaut `customTitle ?? automaticTitle` (spec §10).
///
/// Format du titre automatique (spec §10) :
/// ```text
/// Projet du 10 août 2026 • 11:24
/// ```
@Model
final class ProjectRecord {
    var id: UUID
    var automaticTitle: String
    var customTitle: String?
    var createdAt: Date
    var updatedAt: Date
    var statusRaw: String
    var selectedPaceRaw: String?
    var activeSlotIndex: Int
    var audioRelativePath: String?
    var analysisRelativePath: String?
    var geometryData: Data?
    var lastAlbumIdentifier: String?
    var analysisVersion: Int
    var scoreVersion: Int

    init(
        id: UUID,
        automaticTitle: String,
        customTitle: String?,
        createdAt: Date,
        updatedAt: Date,
        statusRaw: String,
        selectedPaceRaw: String?,
        activeSlotIndex: Int,
        audioRelativePath: String?,
        analysisRelativePath: String?,
        geometryData: Data?,
        lastAlbumIdentifier: String?,
        analysisVersion: Int,
        scoreVersion: Int
    ) {
        self.id = id
        self.automaticTitle = automaticTitle
        self.customTitle = customTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.statusRaw = statusRaw
        self.selectedPaceRaw = selectedPaceRaw
        self.activeSlotIndex = activeSlotIndex
        self.audioRelativePath = audioRelativePath
        self.analysisRelativePath = analysisRelativePath
        self.geometryData = geometryData
        self.lastAlbumIdentifier = lastAlbumIdentifier
        self.analysisVersion = analysisVersion
        self.scoreVersion = scoreVersion
    }
}

// MARK: - Case persistée (spec §10.1, verbatim)

/// Enregistrement SwiftData d'une case de montage.
///
/// Contraintes de base de données (spec §10.1) :
/// - unicité logique de `(projectID, scoreModeRaw, index)` — exprimée par
///   `#Unique` ci-dessous ET validée par `ProjectStore.insertSlots` (erreurs
///   typées récupérables) ;
/// - index strictement croissant — validé par `ProjectStore.insertSlots` ;
/// - `endTicks > startTicks` — validé par `ProjectStore.insertSlots` ;
/// - une association maximum par case ;
/// - suppression en cascade des cases et associations lors de la suppression
///   définitive d'un projet — cascade manuelle dans `ProjectStore.delete` ;
/// - aucun changement des temps après verrouillage du rythme, sauf migration
///   explicite ou duplication.
@Model
final class ProjectSlotRecord {
    #Unique<ProjectSlotRecord>([\.projectID, \.scoreModeRaw, \.index])

    var id: UUID
    var projectID: UUID
    var scoreModeRaw: String
    var index: Int
    var startTicks: Int64
    var endTicks: Int64
    var entryAnchorID: UUID
    var exitAnchorID: UUID
    var gestureID: UUID?
    var assignmentID: UUID?

    /// Durée calculée `end - start` — jamais stockée (spec §9 : les durées
    /// d'une case sont calculées par `end - start`).
    var durationTicks: Int64 { endTicks - startTicks }

    init(
        id: UUID,
        projectID: UUID,
        scoreModeRaw: String,
        index: Int,
        startTicks: Int64,
        endTicks: Int64,
        entryAnchorID: UUID,
        exitAnchorID: UUID,
        gestureID: UUID?,
        assignmentID: UUID?
    ) {
        self.id = id
        self.projectID = projectID
        self.scoreModeRaw = scoreModeRaw
        self.index = index
        self.startTicks = startTicks
        self.endTicks = endTicks
        self.entryAnchorID = entryAnchorID
        self.exitAnchorID = exitAnchorID
        self.gestureID = gestureID
        self.assignmentID = assignmentID
    }
}
