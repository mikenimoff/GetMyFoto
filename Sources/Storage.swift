import Foundation
import CryptoKit

enum ImportStorage {
    static func safeName(_ name: String) -> String {
        let result = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .components(separatedBy: .controlCharacters).joined()
        return result.isEmpty || result == "." || result == ".." ? "Untitled" : result
    }

    static func key(device: String, path: String, size: Int64, date: Date?) -> String {
        let parts = [device, path, String(size), date.map { String($0.timeIntervalSince1970) } ?? "unknown"]
        let data = try! JSONEncoder().encode(parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func month(_ date: Date?) -> String {
        guard let date else { return "Без даты" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    static func uniqueURL(folder: URL, name: String) -> URL {
        let clean = safeName(name)
        var url = folder.appendingPathComponent(clean)
        let ext = (clean as NSString).pathExtension
        let stem = (clean as NSString).deletingPathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)"))
            index += 1
        }
        return url
    }

    static func containedURL(root: URL, relative: String) -> URL? {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    static func stagedFile(root: URL, returnedName: String) -> URL? {
        let candidate = returnedName.hasPrefix("/") ? URL(fileURLWithPath: returnedName) : root.appendingPathComponent(returnedName)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.path.hasPrefix(base + "/") ? resolved : nil
    }
}

struct ImportRecord: Codable {
    let relativePath: String
    let bytes: Int64
    let importedAt: Date
}

struct ImportHistory: Codable {
    var version = 1
    var files: [String: ImportRecord] = [:]

    static func url(in root: URL) -> URL {
        root.appendingPathComponent(".getmyfoto-history.json")
    }

    static func load(from root: URL) throws -> ImportHistory {
        let url = url(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return ImportHistory() }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1 else {
            throw NSError(domain: "GetMyFoto", code: 1, userInfo: [NSLocalizedDescriptionKey: "Неизвестная версия истории импорта."])
        }
        return value
    }

    func save(to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: root), options: .atomic)
    }

    func alreadyImported(_ key: String, root: URL) -> Bool {
        guard let record = files[key],
              let url = ImportStorage.containedURL(root: root, relative: record.relativePath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber else { return false }
        return size.int64Value == record.bytes && record.bytes > 0
    }
}
