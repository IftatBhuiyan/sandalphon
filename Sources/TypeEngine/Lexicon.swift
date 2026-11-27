import Foundation

/// Letters are stored as codes 0...25 (a-z) and 26 (apostrophe).
let apostropheCode: UInt8 = 26
let alphabetSize = 27

/// Lowercases, folds curly apostrophes, and returns nil if the word has anything but a-z and '.
func encode(_ s: String) -> [UInt8]? {
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count)
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 97...122: out.append(UInt8(scalar.value - 97))
        case 65...90: out.append(UInt8(scalar.value - 65))
        case 39, 0x2019, 0x2018: out.append(apostropheCode)
        default: return nil
        }
    }
    return out
}

func decode(_ b: [UInt8]) -> String {
    String(decoding: b.map { $0 == apostropheCode ? UInt8(39) : $0 + 97 }, as: UTF8.self)
}

/// Normalises a typed word for lookup: lowercase with straight apostrophes.
public func normalize(_ s: String) -> String {
    s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
}

/// Static language data: vocabulary with frequencies, a trie for fuzzy and prefix search, and bigram counts.
public final class Lexicon {
    public private(set) var words: [String] = []
    var bytes: [[UInt8]] = []
    var counts: [Double] = []
    var logP: [Float] = []
    var prob: [Float] = []
    var index: [String: Int32] = [:]
    var display: [Int32: String] = [:]
    /// Words that are safe to capitalise automatically when typed in lowercase (names, places, brands).
    var autoCap: Set<Int32> = []

    // Trie in first-child / next-sibling form. Node 0 is the root.
    var tChar: [UInt8] = [0]
    var tFirst: [Int32] = [-1]
    var tNext: [Int32] = [-1]
    var tWord: [Int32] = [-1]
    var tMax: [Float] = [-.infinity]

    var bigram: [UInt64: Float] = [:]
    var bigramSum: [Int32: Float] = [:]
    var followers: [Int32: [(word: Int32, count: Float)]] = [:]

    /// Pseudo-word standing for the start of a sentence. Only ever used as context.
    public static let startToken = "<s>"
    var start: Int32 = -1
    // Conversational model: counts per lexicon index (plus `start`), bigrams and trigrams.
    var convUni: [Float] = []
    var conv2: [UInt64: Float] = [:]
    var conv3: [UInt64: Float] = [:]
    // Followers, most frequent first, as ranges into flat arrays.
    var f2Word: [Int32] = [], f2Count: [Float] = []
    var f2Range: [Int32: Range<Int>] = [:]
    var f3Word: [Int32] = [], f3Count: [Float] = []
    var f3Range: [UInt64: Range<Int>] = [:]

    static let shortNames: Set<String> = Set("john paul adam alex andy anne sean kate lisa rome ohio iowa utah iraq iran cuba peru greg phil neil juan doug joel sara joan karl hugh luis owen leon ivan nina noah evan erik kurt hugo jose gary dave matt".split(separator: " ").map(String.init))
    static let notNames: Set<String> = Set("rugby capitol midwest gothic italic cannabis cactus ninja fedora odyssey trojan yankee advent titan burgundy limerick fauna amigo diaspora epiphany acacia nemesis armageddon pharaoh saviour messiah braille paisley galleria chihuahua labrador sequoia spartan bohemian marian santa taylor moore casey hunter jones angus".split(separator: " ").map(String.init))

    public var count: Int { words.count }

    public init(dataDirectory: URL) throws {
        var table: [String: Double] = [:]
        var order: [String] = []

        let uni = try String(contentsOf: dataDirectory.appendingPathComponent("unigrams.txt"), encoding: .utf8)
        for line in uni.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let c = Double(parts[1]) else { continue }
            let w = String(parts[0]).replacingOccurrences(of: "\u{FEFF}", with: "")
            guard encode(w) != nil else { continue }
            if w.count == 1 && w != "a" && w != "i" { continue }
            if w.contains("'") { continue } // contractions come from extra.txt with real counts
            if table[w] == nil { order.append(w) }
            table[w] = c
        }

        var displayByWord: [String: String] = [:]
        var autoCapWords = Set<String>()
        if let dis = try? String(contentsOf: dataDirectory.appendingPathComponent("display.txt"), encoding: .utf8) {
            for (n, line) in dis.split(separator: "\n").enumerated() {
                let parts = line.split(separator: " ")
                guard parts.count == 2 else { continue }
                let w = String(parts[0])
                displayByWord[w] = String(parts[1])
                // Only the well-known ones, and nothing that doubles as an ordinary word.
                if n < 1500, (w.count >= 5 || Lexicon.shortNames.contains(w)), !Lexicon.notNames.contains(w) {
                    autoCapWords.insert(w)
                }
            }
        }
        for name in ["wordlist.txt", "extra.txt", "modern.txt"] {  // later files win
            guard let extra = try? String(contentsOf: dataDirectory.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in extra.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: " ")
                guard parts.count >= 2, encode(String(parts[0])) != nil else { continue }
                let w = String(parts[0])
                if let c = Double(parts[1]) {
                    if table[w] == nil { order.append(w) }
                    table[w] = max(table[w] ?? 0, c)
                    if parts.count >= 3 { displayByWord[w] = String(parts[2]); autoCapWords.insert(w) }
                } else {
                    displayByWord[w] = String(parts[1]) // "word Display" with no count
                    autoCapWords.insert(w)
                }
            }
        }

        var convIDs: [String] = []
        var convCount: [String: Double] = [:]
        var convTotal = 0.0
        if let text = try? String(contentsOf: dataDirectory.appendingPathComponent("conv_vocab.txt"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let c = Double(parts[1]) else { continue }
                convIDs.append(String(parts[0]))
                convCount[String(parts[0])] = c
                if parts[0] != "<s>" && table[String(parts[0])] != nil { convTotal += c }
            }
        }
        let total = table.values.reduce(0, +)
        words.reserveCapacity(order.count)
        for w in order {
            let c = table[w]!
            let i = Int32(words.count)
            words.append(w)
            bytes.append(encode(w)!)
            counts.append(c)
            // Half web text, half conversation, so everyday words are not drowned out by web vocabulary.
            let p = convTotal > 0 ? 0.5 * c / total + 0.5 * (convCount[w] ?? 0) / convTotal : c / total
            prob.append(Float(p))
            logP.append(Float(log(p)))
            index[w] = i
            if let d = displayByWord[w] {
                display[i] = d
                if autoCapWords.contains(w), d != w { autoCap.insert(i) }
            }
        }
        for i in 0..<words.count { insert(Int32(i)) }

        let bi = try String(contentsOf: dataDirectory.appendingPathComponent("bigrams.txt"), encoding: .utf8)
        var lists: [Int32: [(word: Int32, count: Float)]] = [:]
        for line in bi.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let c = Float(parts[2]),
                  let a = index[String(parts[0]).replacingOccurrences(of: "\u{FEFF}", with: "")],
                  let b = index[String(parts[1])] else { continue }
            bigram[Lexicon.key(a, b)] = c
            bigramSum[a, default: 0] += c
            lists[a, default: []].append((b, c))
        }
        for (k, v) in lists { followers[k] = v.sorted { $0.count > $1.count } }

        start = Int32(words.count)
        convUni = [Float](repeating: 0, count: words.count + 1)
        guard !convIDs.isEmpty else { return }
        var map = [Int32](repeating: -1, count: convIDs.count)
        for (id, w) in convIDs.enumerated() {
            let i = id == 0 ? start : (index[w] ?? -1)
            map[id] = i
            if i >= 0 { convUni[Int(i)] = Float(convCount[w] ?? 0) }
        }
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("conv2.bin"), options: .mappedIfSafe) {
            let n = data.count / 12
            conv2.reserveCapacity(n)
            f2Word.reserveCapacity(n); f2Count.reserveCapacity(n)
            data.withUnsafeBytes { raw in
                var current: Int32 = -2, from = 0
                for r in 0..<n {
                    let a = map[Int(raw.loadUnaligned(fromByteOffset: r * 12, as: UInt32.self))]
                    let b = map[Int(raw.loadUnaligned(fromByteOffset: r * 12 + 4, as: UInt32.self))]
                    let c = Float(raw.loadUnaligned(fromByteOffset: r * 12 + 8, as: UInt32.self))
                    guard a >= 0, b >= 0, b != start else { continue }
                    if a != current {
                        if current >= 0 { f2Range[current] = from..<f2Word.count }
                        current = a; from = f2Word.count
                    }
                    conv2[Lexicon.key(a, b)] = c
                    f2Word.append(b); f2Count.append(c)
                }
                if current >= 0 { f2Range[current] = from..<f2Word.count }
            }
        }
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("conv3.bin"), options: .mappedIfSafe) {
            let n = data.count / 16
            conv3.reserveCapacity(n)
            f3Word.reserveCapacity(n); f3Count.reserveCapacity(n)
            data.withUnsafeBytes { raw in
                var current: UInt64 = .max, from = 0
                for r in 0..<n {
                    let a = map[Int(raw.loadUnaligned(fromByteOffset: r * 16, as: UInt32.self))]
                    let b = map[Int(raw.loadUnaligned(fromByteOffset: r * 16 + 4, as: UInt32.self))]
                    let c = map[Int(raw.loadUnaligned(fromByteOffset: r * 16 + 8, as: UInt32.self))]
                    let k = Float(raw.loadUnaligned(fromByteOffset: r * 16 + 12, as: UInt32.self))
                    guard a >= 0, b >= 0, c >= 0, c != start else { continue }
                    let ab = Lexicon.key(a, b)
                    if ab != current {
                        if current != .max { f3Range[current] = from..<f3Word.count }
                        current = ab; from = f3Word.count
                    }
                    conv3[Lexicon.key3(a, b, c)] = k
                    f3Word.append(c); f3Count.append(k)
                }
                if current != .max { f3Range[current] = from..<f3Word.count }
            }
        }
    }

    @inline(__always) static func key3(_ a: Int32, _ b: Int32, _ c: Int32) -> UInt64 {
        (UInt64(UInt32(bitPattern: a)) << 34) | (UInt64(UInt32(bitPattern: b)) << 17) | UInt64(UInt32(bitPattern: c))
    }

    /// Index usable as context: a lexicon word or the sentence-start token.
    @inline(__always) func contextIndex(_ w: String) -> Int32? {
        w == Lexicon.startToken ? start : index[w]
    }

    @inline(__always) static func key(_ a: Int32, _ b: Int32) -> UInt64 {
        (UInt64(UInt32(bitPattern: a)) << 32) | UInt64(UInt32(bitPattern: b))
    }

    private func insert(_ wordIndex: Int32) {
        var node: Int32 = 0
        let lp = logP[Int(wordIndex)]
        if lp > tMax[0] { tMax[0] = lp }
        for c in bytes[Int(wordIndex)] {
            var child = tFirst[Int(node)]
            while child >= 0 && tChar[Int(child)] != c { child = tNext[Int(child)] }
            if child < 0 {
                child = Int32(tChar.count)
                tChar.append(c)
                tFirst.append(-1)
                tNext.append(tFirst[Int(node)])
                tWord.append(-1)
                tMax.append(-.infinity)
                tFirst[Int(node)] = child
            }
            if lp > tMax[Int(child)] { tMax[Int(child)] = lp }
            node = child
        }
        tWord[Int(node)] = wordIndex
    }

    /// Trie node for an exact prefix, or nil.
    func node(forPrefix prefix: [UInt8]) -> Int32? {
        var node: Int32 = 0
        for c in prefix {
            var child = tFirst[Int(node)]
            while child >= 0 && tChar[Int(child)] != c { child = tNext[Int(child)] }
            if child < 0 { return nil }
            node = child
        }
        return node
    }

    /// The `k` most frequent words in the subtree under `node`.
    func topWords(under node: Int32, k: Int) -> [Int32] {
        var best: [(Int32, Float)] = []
        var threshold = -Float.infinity
        func visit(_ n: Int32) {
            if best.count >= k && tMax[Int(n)] <= threshold { return }
            let w = tWord[Int(n)]
            if w >= 0 {
                let lp = logP[Int(w)]
                if best.count < k || lp > threshold {
                    best.append((w, lp))
                    best.sort { $0.1 > $1.1 }
                    if best.count > k { best.removeLast() }
                    if best.count == k { threshold = best[k - 1].1 }
                }
            }
            var child = tFirst[Int(n)]
            while child >= 0 {
                visit(child)
                child = tNext[Int(child)]
            }
        }
        visit(node)
        return best.map { $0.0 }
    }

    public func contains(_ lower: String) -> Bool { index[lower] != nil }

    /// How a lexicon word should be written when nothing about the typed case says otherwise.
    func displayForm(_ i: Int32) -> String { display[i] ?? words[Int(i)] }
}
