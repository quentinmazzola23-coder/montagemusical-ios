//
//  AudioImporterTests.swift
//  MontageMusicalTests
//
//  Import audio (Jalon 3, spec §78) : copie sandbox §11, validation
//  réelle §62, indépendance de l'URL externe §78, rattachement au
//  projet (attachAudio).
//
//  Aucune ressource embarquée : le WAV de test (PCM 16 bits mono
//  44 100 Hz, 1 s de sinusoïde 440 Hz) est généré en pur Swift —
//  en-têtes RIFF/fmt/data écrits à la main.
//

import XCTest
import SwiftData
@testable import MontageMusical

final class AudioImporterTests: XCTestCase {

    private var rootURL: URL!
    private var sourceDirectoryURL: URL!
    private var fileStore: ProjectFileStore!
    private var importer: AudioImporter!
    private var projectID: UUID!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "AudioImporterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        rootURL = base.appending(path: "Projects", directoryHint: .isDirectory)
        sourceDirectoryURL = base.appending(path: "Sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: sourceDirectoryURL, withIntermediateDirectories: true
        )
        fileStore = ProjectFileStore(rootURL: rootURL)
        importer = AudioImporter(fileStore: fileStore)
        projectID = UUID()
    }

    override func tearDownWithError() throws {
        importer = nil
        fileStore = nil
        if let sourceDirectoryURL {
            let base = sourceDirectoryURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: base.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: base)
            }
        }
        rootURL = nil
        sourceDirectoryURL = nil
        projectID = nil
    }

    // MARK: - Import réussi

    func testImportCopiesFileAndReturnsImportedAudio() async throws {
        let sourceURL = try writeSourceFile(named: "Ma musique.wav", data: makeSineWavData())

        let imported = try await importer.importAudio(from: sourceURL, into: projectID)

        XCTAssertEqual(imported.projectID, projectID)
        XCTAssertEqual(imported.relativePath, "audio/original.wav", "Chemin §11")
        XCTAssertEqual(imported.originalFilename, "Ma musique.wav")
        XCTAssertEqual(imported.fileExtension, "wav")
        XCTAssertLessThanOrEqual(
            abs(imported.duration.ticks - 60_000), 60,
            "1 s de WAV → durée proche de 60 000 ticks (tolérance 60)"
        )

        // Fichier copié en audio/original.wav.
        let audioURL = try XCTUnwrap(fileStore.audioFileURL(projectID: projectID))
        XCTAssertEqual(audioURL.lastPathComponent, "original.wav")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: audioURL.path(percentEncoded: false)
        ))

        // Copie atomique : aucun fichier partiel résiduel dans temp/.
        let tempContents = try FileManager.default.contentsOfDirectory(
            at: fileStore.subdirectoryURL(.temp, for: projectID),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(tempContents.isEmpty, "temp/ nettoyé après le move")
    }

    // MARK: - Indépendance de l'URL externe (§78)

    func testProjectNoLongerDependsOnExternalURLAfterImport() async throws {
        let sourceURL = try writeSourceFile(named: "externe.wav", data: makeSineWavData())
        _ = try await importer.importAudio(from: sourceURL, into: projectID)

        // Suppression du fichier source APRÈS import.
        try FileManager.default.removeItem(at: sourceURL)

        // L'audio du projet existe toujours et reste lisible (§78).
        let audioURL = try XCTUnwrap(
            fileStore.audioFileURL(projectID: projectID),
            "L'audio du projet doit survivre à la disparition de la source"
        )
        let copied = try Data(contentsOf: audioURL)
        XCTAssertFalse(copied.isEmpty)
        XCTAssertEqual(copied, makeSineWavData(), "Copie octet à octet de l'original (§16.1)")
    }

    // MARK: - Remplacement (V1 : un seul original)

    func testReimportReplacesPreviousAudioFile() async throws {
        let first = try writeSourceFile(named: "premier.wav", data: makeSineWavData())
        _ = try await importer.importAudio(from: first, into: projectID)
        let second = try writeSourceFile(
            named: "second.wav",
            data: makeSineWavData(durationSeconds: 2.0)
        )
        let imported = try await importer.importAudio(from: second, into: projectID)

        let audioContents = try FileManager.default.contentsOfDirectory(
            at: fileStore.subdirectoryURL(.audio, for: projectID),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(audioContents.count, 1, "Un seul original (§11)")
        XCTAssertLessThanOrEqual(abs(imported.duration.ticks - 120_000), 60)
    }

    // MARK: - Erreurs §62

    // MARK: - Échec du déplacement (§62 : nettoyer le fichier partiel)

    func testFailedMoveCleansPartialFilesAndLeavesAudioUntouched() async throws {
        let sourceURL = try writeSourceFile(named: "musique.wav", data: makeSineWavData())

        // audio/ en lecture seule : la copie vers temp/ réussit, le move
        // vers audio/ échoue → copyInterrupted attendu.
        try fileStore.createDirectories(for: projectID)
        let audioDirectory = fileStore.subdirectoryURL(.audio, for: projectID)
        let audioPath = audioDirectory.path(percentEncoded: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o555))],
            ofItemAtPath: audioPath
        )
        defer {
            // Rendre audio/ inscriptible pour le tearDown.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: audioPath
            )
        }

        await assertImportFails(from: sourceURL) { error in
            XCTAssertEqual(error, .copyInterrupted)
        }

        // §62 : aucun fichier partiel — temp/ vide, audio/ inchangé (vide).
        let tempContents = try FileManager.default.contentsOfDirectory(
            at: fileStore.subdirectoryURL(.temp, for: projectID),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(tempContents.isEmpty, "temp/ nettoyé après l'échec")
        let audioContents = try FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(audioContents.isEmpty, "audio/ non pollué après l'échec")
    }

    func testEmptyFileThrowsEmptyOrCorruptFile() async throws {
        let sourceURL = try writeSourceFile(named: "vide.wav", data: Data())

        await assertImportFails(from: sourceURL) { error in
            XCTAssertEqual(error, .emptyOrCorruptFile, "Fichier vide → pas d'analyse (§62)")
        }
    }

    func testRandomBytesNamedWavThrowsDecodingError() async throws {
        let sourceURL = try writeSourceFile(named: "faux.wav", data: makeDeterministicNoise())

        await assertImportFails(from: sourceURL) { error in
            XCTAssertTrue(
                error == .noDecodableAudioTrack || error == .emptyOrCorruptFile,
                "L'extension seule ne suffit pas (§62) — AVFoundation décide, obtenu \(error)"
            )
        }
    }

    func testForbiddenExtensionThrowsUnsupportedType() async throws {
        let sourceURL = try writeSourceFile(named: "notes.txt", data: Data("pas audio".utf8))

        await assertImportFails(from: sourceURL) { error in
            XCTAssertEqual(error, .unsupportedType("txt"), "Formats §62 : M4A/AAC, MP3, WAV, AIFF")
        }
    }

    // MARK: - attachAudio (ProjectStore)

    func testAttachAudioSetsPathStatusAndTouchesUpdatedAt() async throws {
        // Conteneur en mémoire — même pattern que ProjectStoreTests.
        let container = try ModelContainerFactory.makeInMemory()
        let store = ProjectStore(modelContainer: container, fileStore: fileStore)
        let created = Date(timeIntervalSinceNow: -3_600)
        let draftID = try await store.createDraft(now: created)

        let imported = ImportedAudio(
            projectID: draftID,
            relativePath: "audio/original.wav",
            originalFilename: "Ma musique.wav",
            duration: MediaTime(ticks: 60_000),
            fileExtension: "wav"
        )
        try await store.attachAudio(imported, projectID: draftID)

        let relativePath = try await store.audioRelativePath(projectID: draftID)
        XCTAssertEqual(relativePath, "audio/original.wav", "audioRelativePath posé (§11)")

        // `XCTUnwrap` n'accepte pas d'expression `await` dans son autoclosure.
        let optionalSummary = try await store.summary(id: draftID)
        let summary = try XCTUnwrap(optionalSummary)
        XCTAssertEqual(summary.status, .analyzing, "Statut annexe A après import")
        XCTAssertGreaterThan(summary.updatedAt, created, "updatedAt touché (§59)")
        XCTAssertTrue(summary.hasContent, "Musique présente → confirmation avant suppression (§31)")
    }

    // MARK: - Helpers

    private func assertImportFails(
        from url: URL,
        file: StaticString = #filePath,
        line: UInt = #line,
        check: (AudioImportError) -> Void
    ) async {
        do {
            _ = try await importer.importAudio(from: url, into: projectID)
            XCTFail("Un échec d'import était attendu", file: file, line: line)
        } catch let error as AudioImportError {
            check(error)
        } catch {
            XCTFail("Erreur inattendue : \(error)", file: file, line: line)
        }
    }

    private func writeSourceFile(named name: String, data: Data) throws -> URL {
        let url = sourceDirectoryURL.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// Bruit pseudo-aléatoire déterministe (LCG) : jamais un WAV valide,
    /// reproductible d'une exécution à l'autre.
    private func makeDeterministicNoise(byteCount: Int = 65_536) -> Data {
        var state: UInt64 = 0x4D6F_6E74_6167_6531
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return Data(bytes)
    }

    // MARK: - Génération WAV (pur Swift, sans ressource embarquée)

    /// WAV PCM 16 bits mono : sinusoïde 440 Hz à 90 % de la pleine échelle.
    private func makeSineWavData(
        durationSeconds: Double = 1.0,
        sampleRate: Int = 44_100
    ) -> Data {
        let sampleCount = Int(durationSeconds * Double(sampleRate))
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let phase = 2.0 * Double.pi * 440.0 * Double(index) / Double(sampleRate)
            let value = 0.9 * sin(phase) * 32_767.0
            samples.append(Int16(max(-32_768.0, min(32_767.0, value.rounded()))))
        }
        return makeWavData(samples: samples, sampleRate: sampleRate)
    }

    /// En-têtes RIFF/fmt/data écrits à la main (PCM 16 bits mono, little-endian).
    private func makeWavData(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))                 // taille du bloc fmt
        data.appendLittleEndian(UInt16(1))                  // PCM linéaire
        data.appendLittleEndian(UInt16(1))                  // mono
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))     // débit octets
        data.appendLittleEndian(UInt16(2))                  // alignement de bloc
        data.appendLittleEndian(UInt16(16))                 // bits par échantillon
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataSize)
        for sample in samples {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        return data
    }
}

// Non partagé : extension file-private d'écriture little-endian.
private extension Data {
    // `Swift.` obligatoire : dans une extension de Data, l'appel non
    // qualifié résout vers la méthode d'instance `Data.withUnsafeBytes(_:)`.
    mutating func appendLittleEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
