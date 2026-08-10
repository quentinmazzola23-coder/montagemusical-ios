//
//  ProjectExporting.swift
//  MontageMusical
//
//  Protocole d'export — spécification §7 (verbatim).
//

import Foundation

protocol ProjectExporting {
    func export(
        project: ProjectSnapshot,
        scope: ExportScope,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult
}
