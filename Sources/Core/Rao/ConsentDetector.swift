import Foundation

/// The user's own saved settings in the watched app, read from its settings file.
struct ConsentSnapshot: Sendable, Equatable, Codable {
    var mode: ConsentMode
    /// Setting label → display value, in the profile's order.
    var settings: [Setting]
    var booleans: [String: Bool]
    var readAt: Date
    var sourcePath: String

    struct Setting: Sendable, Equatable, Codable, Identifiable {
        var key: String
        var label: String
        var value: String
        var id: String { key }
    }

    /// Human-readable differences from an earlier snapshot.
    func changes(since earlier: ConsentSnapshot?) -> [String] {
        guard let earlier else { return [] }
        let before = Dictionary(uniqueKeysWithValues: earlier.settings.map { ($0.key, $0) })
        return settings.compactMap { setting in
            guard let old = before[setting.key], old.value != setting.value else { return nil }
            return "\(setting.label): \(old.value) → \(setting.value)"
        }
    }
}

/// Reads an app's consent mode from its own settings file (read-only). Returns nil when the
/// file or key is missing — the UI then asks the user instead of guessing.
enum ConsentDetector {

    static func read(_ store: ConsentStore) -> ConsentSnapshot? {
        guard let url = newestFile(store) else { return nil }
        return read(url: url, store: store)
    }

    static func newestFile(_ store: ConsentStore) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = store.directory.hasPrefix("~/") ? home + store.directory.dropFirst() : store.directory
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else {
            return nil
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix(store.filePrefix) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    static func read(url: URL, store: ConsentStore) -> ConsentSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return parse(root, store: store, sourcePath: url.path)
    }

    /// Pure: property list → snapshot.
    static func parse(_ root: Any, store: ConsentStore, sourcePath: String, now: Date = Date()) -> ConsentSnapshot? {
        var node: Any = root
        for key in store.statePath {
            guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
            node = next
        }
        guard let state = node as? [String: Any], let onDevice = state[store.onDeviceKey] as? Bool else {
            return nil
        }
        var booleans: [String: Bool] = [:]
        let settings = store.settings.compactMap { setting -> ConsentSnapshot.Setting? in
            guard let value = state[setting.key] else { return nil }
            if let flag = value as? Bool { booleans[setting.key] = flag }
            return .init(key: setting.key, label: setting.label, value: display(value))
        }
        return ConsentSnapshot(mode: onDevice ? .onDevice : .signedIn, settings: settings,
                               booleans: booleans, readAt: now, sourcePath: sourcePath)
    }

    private static func display(_ value: Any) -> String {
        switch value {
        case let flag as Bool: return flag ? "on" : "off"
        case let list as [Any]:
            if list.isEmpty { return "none" }
            let items = list.map { "\($0)" }
            return items.count <= 3 ? items.joined(separator: ", ") : "\(items.count) apps"
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return "\(value)"
        }
    }
}
