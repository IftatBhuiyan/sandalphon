#if os(WASI)
import FoundationEssentials // keeps the web build small; nothing here needs more
#else
import Foundation
#endif

/// What Sandalphon has learned from this person's typing. Stored locally as JSON, never sent anywhere.
public final class UserModel: Codable {
    /// Word counts (lowercase).
    public var words: [String: Int] = [:]
    /// previous word -> next word -> count
    public var bigrams: [String: [String: Int]] = [:]
    /// "two previous words" -> next word -> count
    public var trigrams: [String: [String: Int]] = [:]
    /// Words whose autocorrection the user undid: never touch these again.
    public var keep: Set<String> = []
    /// How the user capitalises words the lexicon does not know.
    public var casing: [String: String] = [:]

    public var total: Int = 0
    public private(set) var dirty = false

    enum CodingKeys: String, CodingKey { case words, bigrams, trigrams, keep, casing, total }

    public init() {}

    public static func load(from url: URL) -> UserModel {
        guard let data = try? Data(contentsOf: url),
              let model = try? JSONDecoder().decode(UserModel.self, from: data) else { return UserModel() }
        model.sanitize()
        return model
    }

    /// The largest count kept, so a hand-edited file can never make a later `+= 1` overflow.
    static let countLimit = 1 << 30

    /// Drops impossible counts from a file that may have been edited by hand.
    private func sanitize() {
        func clean(_ table: [String: Int]) -> [String: Int] {
            table.compactMapValues { $0 > 0 ? min($0, Self.countLimit) : nil }
        }
        words = clean(words)
        bigrams = bigrams.compactMapValues { let t = clean($0); return t.isEmpty ? nil : t }
        trigrams = trigrams.compactMapValues { let t = clean($0); return t.isEmpty ? nil : t }
        total = min(max(total, 0), Self.countLimit)
    }

    /// What is written to disk: only words and phrases used more than once. Something typed a single time, such
    /// as a password in a field that shows it or a recovery phrase, stays in memory for this session and is
    /// never saved.
    func persisted() -> UserModel {
        let copy = UserModel()
        copy.words = words.filter { $0.value > 1 }
        func repeated(_ table: [String: [String: Int]]) -> [String: [String: Int]] {
            table.compactMapValues { next in
                let kept = next.filter { $0.value > 1 }
                return kept.isEmpty ? nil : kept
            }
        }
        copy.bigrams = repeated(bigrams)
        copy.trigrams = repeated(trigrams)
        copy.keep = keep
        copy.casing = casing.filter { copy.words[$0.key] != nil }
        copy.total = copy.words.values.reduce(0, +)
        return copy
    }

    public func save(to url: URL) {
        #if os(WASI)
        return // the web demo keeps nothing
        #else
        guard dirty else { return }
        prune()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(persisted()) {
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Kept out of Time Machine, so "Forget Everything" really does forget.
            var file = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
            dirty = false
        }
        #endif
    }

    /// Forgets everything learned.
    public func clear() {
        words = [:]; bigrams = [:]; trigrams = [:]; keep = []; casing = [:]; total = 0
        dirty = true
    }

    func observe(word: String, context: [String]) {
        guard total < Self.countLimit else { return }
        words[word, default: 0] += 1
        total += 1
        if let prev = context.last {
            bigrams[prev, default: [:]][word, default: 0] += 1
            if context.count >= 2 {
                let key = context[context.count - 2] + " " + prev
                trigrams[key, default: [:]][word, default: 0] += 1
            }
        }
        dirty = true
    }

    /// Takes back one observation (the word turned out to be a slip that was corrected).
    func retract(word: String, context: [String]) {
        func lower(_ table: inout [String: [String: Int]], _ key: String) {
            guard let n = table[key]?[word] else { return }
            if n <= 1 { table[key]?[word] = nil } else { table[key]?[word] = n - 1 }
            if table[key]?.isEmpty == true { table[key] = nil }
        }
        guard let n = words[word] else { return }
        if n <= 1 { words[word] = nil } else { words[word] = n - 1 }
        total = max(0, total - 1)
        if let prev = context.last {
            lower(&bigrams, prev)
            if context.count >= 2 { lower(&trigrams, context[context.count - 2] + " " + prev) }
        }
        dirty = true
    }

    func markKept(_ word: String) {
        keep.insert(word)
        dirty = true
    }

    func count(_ word: String) -> Int { words[word] ?? 0 }

    func bigramCount(_ prev: String, _ word: String) -> Int { bigrams[prev]?[word] ?? 0 }

    func bigramTotal(_ prev: String) -> Int { bigrams[prev]?.values.reduce(0, +) ?? 0 }

    private func prune() {
        func trim(_ table: inout [String: [String: Int]], limit: Int) {
            let size = table.values.reduce(0) { $0 + $1.count }
            guard size > limit else { return }
            for key in table.keys {
                table[key] = table[key]!.filter { $0.value > 1 }
                if table[key]!.isEmpty { table[key] = nil }
            }
        }
        trim(&bigrams, limit: 60_000)
        trim(&trigrams, limit: 60_000)
        if words.count > 40_000 { words = words.filter { $0.value > 1 } }
    }
}
