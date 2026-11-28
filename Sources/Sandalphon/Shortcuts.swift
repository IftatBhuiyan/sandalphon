import Foundation

/// One text shortcut: typing `key` on its own, then a space or punctuation, types `text` instead.
struct Shortcut: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String
    var text: String
}

/// The user's shortcuts, kept in one readable file next to the learned words. Main thread only; the key
/// thread gets a plain dictionary copy.
enum ShortcutStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sandalphon/shortcuts.json")
    }

    static func load() -> [Shortcut] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Shortcut].self, from: data)) ?? []
    }

    static func save(_ list: [Shortcut]) {
        let fm = FileManager.default
        if list.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Why `key` cannot be used, or nil if it can. `others` are the keys already taken.
    static func problem(with key: String, others: [String]) -> String? {
        if key.isEmpty { return "Type the shortcut." }
        if key.contains(where: { $0.isWhitespace }) { return "A shortcut cannot contain spaces." }
        if key.count > 32 { return "Keep the shortcut under 32 characters." }
        if others.contains(key) { return "That shortcut is already in use." }
        return nil
    }

    static func dictionary(_ list: [Shortcut]) -> [String: String] {
        var d: [String: String] = [:]
        for s in list where !s.key.isEmpty && !s.text.isEmpty { d[s.key] = s.text }
        return d
    }
}
