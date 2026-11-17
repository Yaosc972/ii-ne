import Foundation

public enum LegacyBrandMigration {
    public static let urlScheme = "yaosnap"
    static let defaultsDomain = "com.yaosnap.app"
    static let settingsKey = "Yaosnap.settings.v1"
    static let paletteKey = "Yaosnap.palette.v1"
    static let credentialService = "com.yaosnap.app.translation"
    static let directoryName = "Yaosnap"
    private static let preferencesMarker = "Iine.migration.preferences.v1"

    enum DirectoryError: Error { case sourceIsNotDirectory }

    enum DirectoryResult: Equatable {
        case sourceMissing, copied, destinationExists
    }

    public static func run() -> [String] {
        let defaults = UserDefaults.standard
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let pictures = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Pictures", isDirectory: true)
        var notices = migratePreferences(
            from: defaults.persistentDomain(forName: defaultsDomain) ?? [:],
            to: defaults
        )
        let directories = [
            (name: "截图历史", marker: "Iine.migration.history.v1",
             source: support.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent("history", isDirectory: true),
             destination: support.appendingPathComponent("ii ne/history", isDirectory: true)),
            (name: "默认截图目录", marker: "Iine.migration.pictures.v1",
             source: pictures.appendingPathComponent(directoryName, isDirectory: true),
             destination: pictures.appendingPathComponent("ii ne", isDirectory: true)),
        ]
        for directory in directories where !defaults.bool(forKey: directory.marker) {
            do {
                let result = try copyDirectory(from: directory.source, to: directory.destination, fileManager: fileManager)
                if result == .destinationExists {
                    notices.append("\(directory.name)的新目录已有数据，旧目录已保留，未合并。")
                }
                defaults.set(true, forKey: directory.marker)
            } catch {
                notices.append("\(directory.name)迁移未完成，旧目录已保留，下次启动将重试。")
            }
        }
        return notices
    }

    static func migratePreferences(from legacy: [String: Any], to defaults: UserDefaults) -> [String] {
        guard !defaults.bool(forKey: preferencesMarker) else { return [] }
        var notices: [String] = []
        if defaults.object(forKey: SettingsStore.defaultsKey) == nil, let stored = legacy[settingsKey] {
            if let data = stored as? Data, (try? JSONDecoder().decode(Settings.self, from: data)) != nil {
                defaults.set(data, forKey: SettingsStore.defaultsKey)
            } else {
                notices.append("旧设置无法读取，原始设置已保留。")
            }
        }
        if defaults.object(forKey: PaletteStore.defaultsKey) == nil, let stored = legacy[paletteKey] {
            if let data = stored as? Data, PaletteModel.decode(data) != nil {
                defaults.set(data, forKey: PaletteStore.defaultsKey)
            } else {
                notices.append("旧调色板无法读取，原始调色板已保留。")
            }
        }
        defaults.set(true, forKey: preferencesMarker)
        return notices
    }

    static func copyDirectory(from source: URL, to destination: URL, fileManager: FileManager = .default) throws -> DirectoryResult {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: source.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .sourceMissing
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw DirectoryError.sourceIsNotDirectory
        }
        guard !fileManager.fileExists(atPath: destination.path) else { return .destinationExists }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".iine-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if fileManager.fileExists(atPath: destination.path) { return .destinationExists }
            throw error
        }
        return .copied
    }
}
