import Foundation
import Testing
@testable import IineCore

struct BrandMigrationTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "IineTests.Migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iine-migration-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func oldSettingsAndPaletteBecomeReadableWithoutChangingExplicitSavePath() throws {
        try withDefaults { defaults in
            var settings = Settings.standard
            settings.deepSeekModel = "custom-model"
            settings.quickSaveDirectory = "/tmp/user-selected-captures"
            settings.restoreCapacity = 7
            let settingsData = try JSONEncoder().encode(settings)
            let paletteData = try PaletteModel.standard.jsonData()
            let legacy: [String: Any] = [
                LegacyBrandMigration.settingsKey: settingsData,
                LegacyBrandMigration.paletteKey: paletteData,
                "unrelated.preference": "must not copy",
            ]
            #expect(LegacyBrandMigration.migratePreferences(from: legacy, to: defaults).isEmpty)
            #expect(SettingsStore(defaults: defaults).load() == settings)
            #expect(defaults.data(forKey: PaletteStore.defaultsKey) == paletteData)
            #expect(defaults.object(forKey: "unrelated.preference") == nil)
            #expect(legacy[LegacyBrandMigration.settingsKey] as? Data == settingsData)
        }
    }

    @Test func newSettingsAndPaletteWinOverOlderValues() throws {
        try withDefaults { defaults in
            var current = Settings.standard
            current.deepSeekModel = "new-model"
            SettingsStore(defaults: defaults).save(current)
            let currentPalette = try PaletteModel.standard.jsonData()
            defaults.set(currentPalette, forKey: PaletteStore.defaultsKey)
            let legacy: [String: Any] = [
                LegacyBrandMigration.settingsKey: try JSONEncoder().encode(Settings.standard),
                LegacyBrandMigration.paletteKey: Data("invalid old palette".utf8),
            ]
            #expect(LegacyBrandMigration.migratePreferences(from: legacy, to: defaults).isEmpty)
            #expect(SettingsStore(defaults: defaults).load() == current)
            #expect(defaults.data(forKey: PaletteStore.defaultsKey) == currentPalette)
        }
    }

    @Test func completedPreferenceMigrationDoesNotRestoreClearedValues() throws {
        try withDefaults { defaults in
            let legacy = [LegacyBrandMigration.settingsKey: try JSONEncoder().encode(Settings.standard)]
            _ = LegacyBrandMigration.migratePreferences(from: legacy, to: defaults)
            defaults.removeObject(forKey: SettingsStore.defaultsKey)
            #expect(LegacyBrandMigration.migratePreferences(from: legacy, to: defaults).isEmpty)
            #expect(defaults.object(forKey: SettingsStore.defaultsKey) == nil)
        }
    }

    @Test func malformedLegacyPreferencesStayOutsideNewStores() {
        withDefaults { defaults in
            let notices = LegacyBrandMigration.migratePreferences(from: [
                LegacyBrandMigration.settingsKey: Data("invalid settings".utf8),
                LegacyBrandMigration.paletteKey: "invalid palette",
            ], to: defaults)
            #expect(notices.count == 2)
            #expect(defaults.object(forKey: SettingsStore.defaultsKey) == nil)
            #expect(defaults.object(forKey: PaletteStore.defaultsKey) == nil)
        }
    }

    @Test func directoryCopyPublishesAllHistoryFilesAndPreservesSourceOnRetry() throws {
        try withDirectory { root in
            let source = root.appendingPathComponent("old/history", isDirectory: true)
            let destination = root.appendingPathComponent("ii ne/history", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let files = ["index.json": "index", "shot.png": "image", "full-shot.png": "full frame", "edit-shot.png": "editable frame"]
            for (name, contents) in files {
                try Data(contents.utf8).write(to: source.appendingPathComponent(name))
            }
            #expect(try LegacyBrandMigration.copyDirectory(from: source, to: destination) == .copied)
            #expect(try LegacyBrandMigration.copyDirectory(from: source, to: destination) == .destinationExists)
            for (name, contents) in files {
                #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == Data(contents.utf8))
                #expect(try Data(contentsOf: source.appendingPathComponent(name)) == Data(contents.utf8))
            }
            let siblings = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            #expect(siblings == ["history"])
        }
    }

    @Test func existingDestinationKeepsItsOwnFiles() throws {
        try withDirectory { root in
            let source = root.appendingPathComponent("old", isDirectory: true)
            let destination = root.appendingPathComponent("new", isDirectory: true)
            for directory in [source, destination] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data("old".utf8).write(to: source.appendingPathComponent("index.json"))
            try Data("new".utf8).write(to: destination.appendingPathComponent("index.json"))
            #expect(try LegacyBrandMigration.copyDirectory(from: source, to: destination) == .destinationExists)
            #expect(try Data(contentsOf: destination.appendingPathComponent("index.json")) == Data("new".utf8))
            #expect(try Data(contentsOf: source.appendingPathComponent("index.json")) == Data("old".utf8))
        }
    }

    @Test func missingSourceDoesNotCreateDestination() throws {
        try withDirectory { root in
            let destination = root.appendingPathComponent("new", isDirectory: true)
            let result = try LegacyBrandMigration.copyDirectory(from: root.appendingPathComponent("missing"), to: destination)
            #expect(result == .sourceMissing)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func failedCopyCleansStagingAndCanRetry() throws {
        try withDirectory { root in
            let source = root.appendingPathComponent("old", isDirectory: true)
            let destination = root.appendingPathComponent("new", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("capture.png"))
            #expect(throws: CocoaError.self) {
                try LegacyBrandMigration.copyDirectory(from: source, to: destination, fileManager: FailingCopyFileManager())
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["old"])
            #expect(try LegacyBrandMigration.copyDirectory(from: source, to: destination) == .copied)
            #expect(try Data(contentsOf: destination.appendingPathComponent("capture.png")) == Data("original".utf8))
        }
    }
}

private final class FailingCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: destination.appendingPathComponent("partial"))
        throw CocoaError(.fileWriteOutOfSpace)
    }
}
