import Foundation

public struct Suggestion: Equatable {
    /// Text to put in place of the word being typed (or to insert, for a next-word prediction).
    public let text: String
    /// True when this is what pressing space would change the typed word into.
    public let isAutocorrect: Bool

    public init(text: String, isAutocorrect: Bool) {
        self.text = text
        self.isAutocorrect = isAutocorrect
    }
}

struct Candidate {
    let key: String      // lowercase; may contain a space for split corrections
    let display: String  // default written form
    var score: Float     // log probability minus error cost
    var cost: Float
    var p: Float = 0     // probability in context, for completions
}

enum CasePattern {
    case lower, capitalized, upper, mixed

    init(_ s: String) {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        if upper == 0 { self = .lower }
        else if upper == letters.count { self = letters.count == 1 ? .capitalized : .upper }
        else if upper == 1, let f = s.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) { self = .capitalized }
        else { self = .mixed }
    }

    func apply(to display: String) -> String {
        switch self {
        case .lower, .mixed: return display
        case .capitalized: return display.prefix(1).uppercased() + display.dropFirst()
        case .upper: return display.uppercased()
        }
    }
}

private func env(_ name: String) -> Float? { ProcessInfo.processInfo.environment[name].flatMap(Float.init) }

/// Spelling correction, word completion and next-word prediction.
/// Not thread-safe: call from one queue.
public final class Engine {
    public let lexicon: Lexicon
    public let user: UserModel
    private let keyboard = KeyboardModel()

    /// Write names, places and brands with their capitals ("london" -> "London").
    public var capitalizeNames = true
    private var phrases: [String: String] = [:]

    /// How strongly an edit counts against a candidate, in nats per unit of edit cost.
    var alpha: Float = 6.0
    /// Exponent on word probability: below 1 keeps very common words from swallowing everything nearby.
    var gamma: Float = 0.7
    /// How far ahead of the runner-up a correction must be before it is applied without asking.
    var margin: Float = 1.4
    /// Words of four letters or fewer need this much more margin: short typos are the ambiguous ones.
    var shortFactor: Float = 2.0
    /// Three letters or fewer are as likely an acronym as a typo: only swaps and doubled letters are fixed.
    var autoCostTiny: Float = env("SANDALPHON_AUTOCOST_TINY") ?? 0.5
    /// Up to seven letters: one slip of the kind fingers actually make. A substitution between keys that are
    /// nowhere near each other does not qualify, which is what protects "uber" from becoming "user".
    var autoCostShort: Float = env("SANDALPHON_AUTOCOST") ?? 0.96
    var swapFactor: Float = ProcessInfo.processInfo.environment["SANDALPHON_SWAP"].flatMap(Float.init) ?? 0.6
    var autoCostLong: Float = env("SANDALPHON_AUTOCOST_LONG") ?? 1.5
    var rareLimit: Float = -13.5
    /// Pseudo-count that keeps rarely seen previous words from producing overconfident bigram estimates.
    private let bigramPrior: Float = 5e7
    private let probFloor: Float = 1e-12

    /// Well-known misspellings that are fixed outright (Data/misspellings.txt).
    private var overrides: [String: String] = ["ill": "I'll"]
    /// "ill" is left alone after these words ("feel ill").
    private let illContexts: Set<String> = [
        "feel", "feeling", "feels", "felt", "was", "is", "am", "are", "were", "be", "been", "being", "very",
        "really", "so", "got", "get", "getting", "fell", "fall", "seriously", "critically", "mentally",
        "terminally", "too", "quite", "looks", "look", "looked", "become", "became", "taken", "of", "the", "no",
    ]
    /// Lexicon words that are always written with a capital.
    private let alwaysCapitalized: Set<String> = [
        "i", "i'm", "i've", "i'll", "i'd", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "january", "february", "april", "june", "july", "september", "october", "november", "december",
    ]

    public convenience init(dataDirectory: URL, user: UserModel = UserModel()) throws {
        try self.init(lexicon: Lexicon(dataDirectory: dataDirectory), dataDirectory: dataDirectory, user: user)
    }

    /// Shares an already loaded lexicon (it is immutable) with a separate user model.
    public init(lexicon: Lexicon, dataDirectory: URL, user: UserModel = UserModel()) throws {
        self.lexicon = lexicon
        self.user = user
        if let text = try? String(contentsOf: dataDirectory.appendingPathComponent("misspellings.txt"), encoding: .utf8) {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2, parts[0] != parts[1] { overrides[String(parts[0])] = String(parts[1]) }
            }
        }
        if let text = try? String(contentsOf: dataDirectory.appendingPathComponent("phrases.txt"), encoding: .utf8) {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: "|")
                if parts.count == 2 { phrases[String(parts[0])] = String(parts[1]) }
            }
        }
        if let v = ProcessInfo.processInfo.environment["SANDALPHON_ALPHA"].flatMap(Float.init) { alpha = v }
        if let v = ProcessInfo.processInfo.environment["SANDALPHON_GAMMA"].flatMap(Float.init) { gamma = v }
        if let v = ProcessInfo.processInfo.environment["SANDALPHON_MARGIN"].flatMap(Float.init) { margin = v }
        if let v = ProcessInfo.processInfo.environment["SANDALPHON_SHORT"].flatMap(Float.init) { shortFactor = v }
        if let v = ProcessInfo.processInfo.environment["SANDALPHON_RARE"].flatMap(Float.init) { rareLimit = v }
    }

    // MARK: - Language model

    /// Context resolved once per query so scoring many candidates stays cheap.
    struct Ctx {
        let words: [String]
        let prev: String?
        let b: Int32?      // index of the previous word
        let a: Int32?      // index of the word before that
        let cb: Float      // conversational count of b
        let webSum: Float  // web bigram mass of b, or -1
        let cab: Float     // conversational count of (a, b), or -1
        let userBigramTotal: Int
        let userTrigrams: [String: Int]?
        let userTrigramTotal: Int
    }

    func makeContext(_ words: [String]) -> Ctx {
        let prev = words.last
        let b = prev.flatMap { lexicon.contextIndex($0) }
        let a = words.count >= 2 ? lexicon.contextIndex(words[words.count - 2]) : nil
        var cab: Float = -1
        if let a, let b, let c = lexicon.conv2[Lexicon.key(a, b)] { cab = c }
        let tri = words.count >= 2 && user.total > 0 ? user.trigrams[words[words.count - 2] + " " + prev!] : nil
        return Ctx(words: words, prev: prev, b: b, a: a,
                   cb: b.map { lexicon.convUni[Int($0)] } ?? 0,
                   webSum: b.flatMap { lexicon.bigramSum[$0] } ?? -1,
                   cab: cab,
                   userBigramTotal: prev.map { user.bigramTotal($0) } ?? 0,
                   userTrigrams: tri, userTrigramTotal: tri?.values.reduce(0, +) ?? 0)
    }

    /// P(word | context): interpolated trigram / bigram / unigram, plus what the user has typed before.
    func probability(_ word: String, _ index: Int32?, _ ctx: Ctx) -> Float {
        var p: Float = 0
        if let i = index {
            let pu = lexicon.prob[Int(i)]
            p = pu
            if let b = ctx.b {
                var p2: Float = -1
                if ctx.cb > 0 { p2 = (lexicon.conv2[Lexicon.key(b, i)] ?? 0) / ctx.cb }
                if ctx.webSum >= 0 {
                    let pw = (lexicon.bigram[Lexicon.key(b, i)] ?? 0) / (ctx.webSum + bigramPrior)
                    p2 = p2 < 0 ? pw : 0.65 * p2 + 0.35 * pw
                }
                if p2 >= 0 {
                    let weight = max(ctx.cb, 200)
                    p = (weight * p2 + 100 * pu) / (weight + 100)
                }
                if ctx.cab > 0, let a = ctx.a {
                    let c3 = lexicon.conv3[Lexicon.key3(a, b, i)] ?? 0
                    p = (c3 + 20 * p) / (ctx.cab + 20)
                }
            }
        }
        if user.total > 0 {
            // What the user has typed before counts, but only once it has been seen more than once: a single
            // occurrence (possibly the very slip being judged) is not evidence of a habit.
            let uc = user.count(word)
            if uc > 1 {
                p += 0.15 * Float(uc - 1) / Float(user.total + 300)
                if let prev = ctx.prev {
                    let bc = user.bigramCount(prev, word)
                    if bc > 1 { p += 0.5 * Float(bc - 1) / Float(ctx.userBigramTotal + 3) }
                    if let tc = ctx.userTrigrams?[word], tc > 1 { p += 0.6 * Float(tc - 1) / Float(ctx.userTrigramTotal + 2) }
                }
            }
        }
        return max(p, probFloor)
    }

    func probability(_ word: String, context: [String]) -> Float {
        probability(word, lexicon.index[word], makeContext(context))
    }

    /// A word we should not try to correct.
    public func isKnown(_ lower: String) -> Bool {
        lexicon.contains(lower) || user.keep.contains(lower) || user.count(lower) >= 3
    }

    private func display(for key: String) -> String {
        if let i = lexicon.index[key] { return lexicon.displayForm(i) }
        return user.casing[key] ?? key
    }

    // MARK: - Fuzzy search

    private struct Match { let node: Int32; let word: Int32; let cost: Float }

    /// Walks the trie computing a weighted Damerau-Levenshtein distance between each vocabulary word
    /// (what was meant) and `t` (what was typed). In prefix mode, matches trie prefixes instead of whole words.
    private func fuzzy(_ t: [UInt8], maxCost: Float, prefixMode: Bool) -> [Match] {
        let n = t.count
        guard n > 0 else { return [] }
        let lex = lexicon
        let width = n + 1
        let maxDepth = n + 3
        var rows = [Float](repeating: 0, count: (maxDepth + 1) * width)
        let extra = keyboard.extraCosts(t)
        for j in 1...n { rows[j] = rows[j - 1] + extra[j - 1] }
        var out: [Match] = []
        let sub = keyboard.sub

        func visit(_ node: Int32, _ d: Int, _ parent: UInt8, _ parentMin: Float) {
            let c = lex.tChar[Int(node)]
            let cur = d * width, prev = (d - 1) * width
            let omit = keyboard.omit(c, parent: parent, pos: d - 1)
            rows[cur] = rows[prev] + omit
            var minV = rows[cur]
            for j in 1...n {
                let tc = t[j - 1]
                var s = sub[Int(c) * alphabetSize + Int(tc)]
                if d == 1 && j == 1 { s *= KeyboardModel.firstLetterMultiplier }
                var v = rows[prev + j - 1] + s
                let del = rows[prev + j] + omit
                if del < v { v = del }
                let ins = rows[cur + j - 1] + extra[j - 1]
                if ins < v { v = ins }
                if d >= 2 && j >= 2 && c == t[j - 2] && parent == tc && c != parent {
                    let tr = rows[(d - 2) * width + j - 2] + KeyboardModel.transposition
                    if tr < v { v = tr }
                }
                rows[cur + j] = v
                if v < minV { minV = v }
            }
            // A transposition can reach back to the row above, so that row must be hopeless too.
            if minV > maxCost && parentMin + KeyboardModel.transposition > maxCost { return }
            let total = rows[cur + n]
            if total <= maxCost {
                if prefixMode {
                    if d >= n - 1 { out.append(Match(node: node, word: -1, cost: total)) }
                } else if lex.tWord[Int(node)] >= 0 {
                    out.append(Match(node: node, word: lex.tWord[Int(node)], cost: total))
                }
            }
            guard d < maxDepth else { return }
            var child = lex.tFirst[Int(node)]
            while child >= 0 {
                visit(child, d + 1, c, minV)
                child = lex.tNext[Int(child)]
            }
        }

        var child = lex.tFirst[0]
        while child >= 0 {
            visit(child, 1, 255, 0)
            child = lex.tNext[Int(child)]
        }
        return out
    }

    // MARK: - Corrections

    /// Ranked corrections for a finished word, best first. Does not include the typed word itself.
    func corrections(lower: String, t: [UInt8], ctx: Ctx) -> [Candidate] {
        let n = t.count
        var out: [Candidate] = []
        for m in fuzzy(t, maxCost: KeyboardModel.maxCost(length: n), prefixMode: false) {
            let w = lexicon.words[Int(m.word)]
            if w == lower { continue }
            let score = gamma * log(probability(w, m.word, ctx)) - alpha * m.cost
            out.append(Candidate(key: w, display: lexicon.displayForm(m.word), score: score, cost: m.cost))
        }
        // A missing space: "thankyou" -> "thank you". Needs both halves to be words that are seen together.
        if n >= 4, !lower.contains("'") {
            let utf8 = Array(lower.utf8)
            for i in 1..<(n - 1) {
                let left = String(decoding: utf8[0..<i], as: UTF8.self)
                let right = String(decoding: utf8[i...], as: UTF8.self)
                // Both halves must be real, substantial words; short fragments ("tom or") are coincidences.
                guard left.count >= 3, right.count >= 3,
                      let li = lexicon.index[left], let ri = lexicon.index[right] else { continue }
                var pair: Float = 0
                if let c = lexicon.conv2[Lexicon.key(li, ri)], lexicon.convUni[Int(li)] > 0 {
                    pair = c / lexicon.convUni[Int(li)]
                }
                if let c = lexicon.bigram[Lexicon.key(li, ri)], let sum = lexicon.bigramSum[li] {
                    pair = max(pair, c / (sum + bigramPrior))
                }
                guard pair > 0.004 else { continue }
                let p = probability(left, li, ctx) * pair
                let cost: Float = 0.8
                out.append(Candidate(key: left + " " + right,
                                     display: lexicon.displayForm(li) + " " + lexicon.displayForm(ri),
                                     score: gamma * log(max(p, probFloor)) - alpha * cost, cost: cost))
            }
        }
        out.sort { $0.score > $1.score }
        return out
    }

    /// Decides whether `typed` should be replaced outright. `cands` receives the ranked corrections if they
    /// were computed along the way, so callers do not search twice.
    private func decide(typed: String, lower: String, t: [UInt8], pattern: CasePattern, ctx: Ctx,
                        cands: inout [Candidate]?) -> String? {
        if pattern == .mixed || pattern == .upper { return nil }
        if user.keep.contains(lower) { return nil }
        if let fixed = overrides[lower] {
            if lower == "ill" {
                guard let prev = ctx.prev, prev != Lexicon.startToken, !illContexts.contains(prev) else { return nil }
            }
            return differing(pattern.apply(to: fixed), from: typed)
        }
        if let i = lexicon.index[lower] {
            if alwaysCapitalized.contains(lower) || (capitalizeNames && pattern == .lower && lexicon.autoCap.contains(i)) {
                return differing(pattern.apply(to: lexicon.displayForm(i)), from: typed)
            }
            return nil
        }
        if user.count(lower) >= 3 { return nil }
        // A capitalised unknown word in the middle of a sentence is almost always a name.
        if pattern == .capitalized, let prev = ctx.prev, prev != Lexicon.startToken { return nil }

        let list = corrections(lower: lower, t: t, ctx: ctx)
        cands = list
        guard let best = list.first, !Engine.neverSubstitute.contains(best.key) else { return nil }
        // Changing a word outright takes more certainty than suggesting: about one real slip for ordinary
        // words, and only a trivial slip if the replacement is itself an uncommon word. This is what keeps
        // names and jargon ("priya") from being turned into the nearest dictionary word ("pray").
        let limit = t.count <= 3 ? autoCostTiny : (t.count <= 7 ? autoCostShort : autoCostLong)
        if best.cost > limit { return nil }
        if !best.key.contains(" "), let bi = lexicon.index[best.key], lexicon.logP[Int(bi)] < rareLimit, best.cost > 0.6 {
            return nil
        }
        // The correction has to be a reasonably common word, and clearly better than the runner-up.
        if !best.key.contains(" "), let bi = lexicon.index[best.key], lexicon.logP[Int(bi)] < -16.5 { return nil }
        var needed = t.count <= 4 ? margin * shortFactor : margin
        // The same letters in a different order is the clearest sign of a slip there is. If only the best
        // candidate is such a swap, it needs less of a lead.
        if list.count > 1, isSwap(best.key, lower), !isSwap(list[1].key, lower) { needed *= swapFactor }
        if list.count > 1, best.score - list[1].score < needed { return nil }
        return differing(pattern.apply(to: best.display), from: typed)
    }

    /// What the typed word should be silently replaced with when the user moves on, or nil to leave it alone.
    public func autocorrection(for typed: String, context: [String]) -> String? {
        guard typed.count >= 1, typed.count <= 24 else { return nil }
        let lower = normalize(typed)
        guard let t = encode(lower) else { return nil }
        var cands: [Candidate]?
        return decide(typed: typed, lower: lower, t: t, pattern: CasePattern(typed), ctx: makeContext(context), cands: &cands)
    }

    /// Words we never turn something into on our own. Typing them directly still works.
    static let neverSubstitute: Set<String> = ["fuck", "fucked", "fucking", "fucker", "shit", "shitty", "bitch", "cunt",
                                               "dick", "cock", "pussy", "slut", "whore", "ass", "asshole", "bastard",
                                               "porn", "sex", "sexy", "rape", "nazi", "piss", "tits", "boob", "boobs",
                                               "slave", "retard", "fag", "nigger", "nigga", "damn", "crap"]

    private func isSwap(_ a: String, _ b: String) -> Bool {
        a.utf8.count == b.utf8.count && a.utf8.sorted() == b.utf8.sorted()
    }

    private func differing(_ s: String, from typed: String) -> String? {
        s == typed.replacingOccurrences(of: "\u{2019}", with: "'") ? nil : s
    }

    // MARK: - Completions

    func completions(lower: String, t: [UInt8], ctx: Ctx) -> [Candidate] {
        var ids = Set<Int32>()
        if let node = lexicon.node(forPrefix: t) {
            for w in lexicon.topWords(under: node, k: 16) { ids.insert(w) }
        }
        // Words that tend to follow the context and start with what has been typed.
        func scan(_ words: ArraySlice<Int32>, take: Int) {
            var found = 0
            for w in words where lexicon.bytes[Int(w)].starts(with: t) {
                ids.insert(w)
                found += 1
                if found >= take { break }
            }
        }
        if let b = ctx.b {
            if let a = ctx.a, let r = lexicon.f3Range[Lexicon.key(a, b)] { scan(lexicon.f3Word[r].prefix(600), take: 8) }
            if let r = lexicon.f2Range[b] { scan(lexicon.f2Word[r].prefix(800), take: 8) }
            if let list = lexicon.followers[b] {
                var found = 0
                for (w, _) in list.prefix(600) where lexicon.bytes[Int(w)].starts(with: t) {
                    ids.insert(w)
                    found += 1
                    if found >= 6 { break }
                }
            }
        }
        var out: [Candidate] = []
        for w in ids {
            let key = lexicon.words[Int(w)]
            if key == lower { continue }
            let p = probability(key, w, ctx)
            out.append(Candidate(key: key, display: lexicon.displayForm(w), score: gamma * log(p) - 0.5, cost: 0, p: p))
        }
        if user.total > 0 {
            for (w, c) in user.words where c >= 3 && w != lower && w.hasPrefix(lower) && lexicon.index[w] == nil {
                let p = probability(w, nil, ctx)
                out.append(Candidate(key: w, display: display(for: w), score: gamma * log(p) - 0.5, cost: 0, p: p))
            }
        }
        out.sort { $0.score > $1.score }
        return out
    }

    /// Completions when the typed prefix itself contains a slip ("recie" -> "receive").
    private func fuzzyCompletions(t: [UInt8], ctx: Ctx) -> [Candidate] {
        let n = t.count
        guard n >= 3 else { return [] }
        let limit: Float = n <= 4 ? 0.6 : 1.0
        var best: [String: Candidate] = [:]
        let matches = fuzzy(t, maxCost: limit, prefixMode: true).sorted { $0.cost < $1.cost }.prefix(8)
        for m in matches {
            for w in lexicon.topWords(under: m.node, k: 3) {
                let key = lexicon.words[Int(w)]
                let score = gamma * log(probability(key, w, ctx)) - alpha * m.cost - 0.5
                if let old = best[key], old.score >= score { continue }
                best[key] = Candidate(key: key, display: lexicon.displayForm(w), score: score, cost: m.cost)
            }
        }
        return best.values.sorted { $0.score > $1.score }
    }

    // MARK: - Public suggestion API

    public struct Analysis {
        /// Suggestions to show; the first is what Tab inserts.
        public let suggestions: [Suggestion]
        /// What the word becomes if the user moves on without choosing.
        public let autocorrection: String?
    }

    /// Everything about the word under the caret in one pass.
    public func analyze(typed: String, context: [String], limit: Int = 3, eager: Bool = false) -> Analysis {
        guard typed.count >= 1, typed.count <= 24 else { return Analysis(suggestions: [], autocorrection: nil) }
        let lower = normalize(typed)
        guard let t = encode(lower) else { return Analysis(suggestions: [], autocorrection: nil) }
        let pattern = CasePattern(typed)
        let ctx = makeContext(context)
        var cands: [Candidate]?
        let auto = decide(typed: typed, lower: lower, t: t, pattern: pattern, ctx: ctx, cands: &cands)
        guard typed.count >= 2, pattern != .mixed else {
            return Analysis(suggestions: auto.map { [Suggestion(text: $0, isAutocorrect: true)] } ?? [], autocorrection: auto)
        }

        var pool: [String: Candidate] = [:]
        func add(_ c: Candidate) {
            if let old = pool[c.key], old.score >= c.score { return }
            pool[c.key] = c
        }
        // Completions are only worth interrupting for when they save real typing and are likely. A word that
        // is already complete is left in peace unless a longer one is clearly what is meant here.
        let known = isKnown(lower)
        let typedP = known ? probability(lower, lexicon.index[lower], ctx) : 0
        var comps = completions(lower: lower, t: t, ctx: ctx)
        // When the likeliest ending is a single letter away ("wan" -> "want"), offering the longer, less
        // likely ones instead would only mislead.
        if let top = comps.first, top.key.count - lower.count < 2,
           let next = comps.first(where: { $0.key.count - lower.count >= 2 }), top.p > next.p * 3 {
            comps = []
        }
        if eager {
            // The user asked to see options: offer everything reasonable, including near-misses of real words.
            comps = completions(lower: lower, t: t, ctx: ctx)
        } else {
            comps = comps.filter { c in
                guard c.key.count - lower.count >= 2 else { return false }
                if known { return c.p > typedP * 4 }
                return t.count >= 3 || c.p >= 0.05
            }
        }
        comps.prefix(6).forEach(add)
        if (!known || eager) && overrides[lower] == nil {
            (cands ?? corrections(lower: lower, t: t, ctx: ctx)).filter { !$0.key.contains(" ") }.prefix(4).forEach(add)
            if comps.isEmpty { fuzzyCompletions(t: t, ctx: ctx).prefix(4).forEach(add) }
        }
        let everything = pool.values.sorted { $0.score > $1.score }
        var ranked = everything
        // Long shots only add clutter next to a good option.
        if let top = ranked.first { ranked = ranked.filter { $0.score >= top.score - 4.5 } }

        var out: [Suggestion] = []
        var seen = Set<String>()
        let typedPlain = typed.replacingOccurrences(of: "\u{2019}", with: "'")
        func push(_ text: String, _ isAuto: Bool) {
            guard out.count < limit, text != typedPlain, seen.insert(text).inserted else { return }
            out.append(Suggestion(text: text, isAutocorrect: isAuto))
        }
        // The pending autocorrection always gets a slot; it leads unless a completion clearly outranks it.
        if let auto {
            let autoScore = everything.first { pattern.apply(to: $0.display) == auto }?.score ?? .infinity
            if let top = ranked.first, top.score > autoScore + 1 { push(pattern.apply(to: top.display), false) }
            push(auto, true)
        }
        for c in ranked { push(pattern.apply(to: c.display), false) }
        return Analysis(suggestions: out, autocorrection: auto)
    }

    /// Ranked corrections with scores, for diagnostics.
    public func explain(_ word: String, context: [String]) -> [String] {
        let lower = normalize(word)
        guard let t = encode(lower) else { return [] }
        return corrections(lower: lower, t: t, ctx: makeContext(context)).prefix(6).map {
            String(format: "%@ score=%.2f cost=%.2f", $0.key, $0.score, $0.cost)
        }
    }

    /// Other words the given (finished) word might have been meant to be, best first.
    public func alternatives(for word: String, context: [String], limit: Int = 3) -> [String] {
        let lower = normalize(word)
        guard word.count >= 1, word.count <= 24, let t = encode(lower) else { return [] }
        let pattern = CasePattern(word)
        var out: [String] = []
        if let fixed = overrides[lower] { out.append(pattern.apply(to: fixed)) }
        for c in corrections(lower: lower, t: t, ctx: makeContext(context)) where out.count < limit {
            let text = pattern.apply(to: c.display)
            if text != word, !out.contains(text) { out.append(text) }
        }
        return out
    }

    public func suggestions(typed: String, context: [String], limit: Int = 3) -> [Suggestion] {
        analyze(typed: typed, context: context, limit: limit).suggestions
    }

    /// Likely next words after `context` (lowercase words, most recent last; "<s>" marks a sentence start).
    public func predictions(context: [String], limit: Int = 3) -> [String] {
        guard let prev = context.last else { return [] }
        let ctx = makeContext(context)
        var scored: [String: Float] = [:]
        func consider(_ w: Int32) {
            let key = lexicon.words[Int(w)]
            if scored[key] == nil { scored[key] = probability(key, w, ctx) }
        }
        if let b = ctx.b {
            if let a = ctx.a, let r = lexicon.f3Range[Lexicon.key(a, b)] { lexicon.f3Word[r].prefix(12).forEach(consider) }
            if let r = lexicon.f2Range[b] { lexicon.f2Word[r].prefix(12).forEach(consider) }
            if let list = lexicon.followers[b] { list.prefix(8).forEach { consider($0.word) } }
        }
        if user.total > 0 {
            var mine: [String] = []
            if let row = user.bigrams[prev] { mine += row.filter { $0.value >= 2 }.keys }
            if let row = ctx.userTrigrams { mine += row.filter { $0.value >= 2 }.keys }
            for w in mine where scored[w] == nil { scored[w] = probability(w, lexicon.index[w], ctx) }
        }
        // Only offer predictions we have real evidence for.
        // Only speak up when one continuation is genuinely likely; otherwise stay quiet.
        var ranked = Array(scored.filter { $0.value > 0.03 }.sorted { $0.value > $1.value }.prefix(limit))
        if (ranked.first?.value ?? 0) < 0.06 { ranked = [] }
        let capitalize = prev == Lexicon.startToken
        return ranked.map { capitalize ? CasePattern.capitalized.apply(to: display(for: $0.key)) : display(for: $0.key) }
    }

    // MARK: - Grammar

    private static let repeatable: Set<String> = ["the", "a", "an", "to", "of", "and", "in", "is", "it", "for", "on",
                                                  "with", "at", "this", "be", "are", "was", "we", "you", "my", "i"]
    /// Words after which a lone "a" is more likely a label or list item than an article ("plan a or b").
    private static let notAfterA: Set<String> = ["or", "and", "is", "in", "on", "at", "of", "if", "it", "as", "an", "are",
                                                 "am", "i", "into", "onto", "its", "it's", "isn't", "also", "even",
                                                 "one", "once", "ones", "either", "each", "all", "only", "about"]

    /// Fixes slips that only show once two words are side by side: "could of", "a apple", "the the".
    /// Returns the text that should replace both words, or nil.
    public func pairFix(prev: String, word: String) -> String? {
        let p = normalize(prev), w = normalize(word)
        guard !p.isEmpty, !w.isEmpty, !user.keep.contains(p + " " + w) else { return nil }
        let capital = prev.first?.isUppercase == true && p != "i"
        func cased(_ s: String) -> String { capital ? s.prefix(1).uppercased() + s.dropFirst() : s }

        if let fixed = phrases[p + " " + w] { return cased(fixed) }
        if p == w, Engine.repeatable.contains(p) { return prev }
        guard let wi = lexicon.index[w], CasePattern(word) == .lower, let first = w.first else { return nil }
        if p == "a", "aeio".contains(first), w.count >= 2, !Engine.notAfterA.contains(w), !w.hasPrefix("eu") {
            return cased("an") + " " + word
        }
        if p == "an", !"aeiouh".contains(first), w.count >= 4, wi < 30_000 {
            return cased("a") + " " + word
        }
        return nil
    }

    // MARK: - Second thoughts

    var retroMarginKnown: Float = ProcessInfo.processInfo.environment["SANDALPHON_RETRO_KNOWN"].flatMap(Float.init) ?? 10.0
    var retroMarginUnknown: Float = ProcessInfo.processInfo.environment["SANDALPHON_RETRO_UNKNOWN"].flatMap(Float.init) ?? 3.0

    /// Looks again at a word now that the words after it are known.
    ///
    /// - Parameters:
    ///   - typed: the keys the user actually pressed for this word.
    ///   - current: what stands in the text now (the same, or an earlier correction).
    ///   - left: up to two words before it; right: one or two words after it.
    /// - Returns: a better word, or nil if what is there should stay.
    public func reconsider(typed: String, current: String, left: [String], right: [String]) -> String? {
        let lowerTyped = normalize(typed), lowerCurrent = normalize(current)
        guard let r1 = right.first, let r1i = lexicon.index[r1], typed.count >= 2, typed.count <= 24,
              let t = encode(lowerTyped), !user.keep.contains(lowerTyped), !user.keep.contains(lowerCurrent),
              CasePattern(typed) != .mixed, CasePattern(typed) != .upper, !lowerCurrent.contains(" ") else { return nil }
        let typedKnown = isKnown(lowerTyped)
        if !lexicon.contains(lowerCurrent) && isKnown(lowerCurrent) { return nil } // the user's own word
        // A well-known misspelling already has its one right answer (thier -> their); context must not move it.
        if lowerCurrent != lowerTyped, overrides[lowerTyped]?.lowercased() == lowerCurrent { return nil }
        let ctx = makeContext(left)
        let r2i = right.count > 1 ? lexicon.index[right[1]] : nil

        /// How well `c` fits between what came before and what came after.
        func fit(_ c: String, _ ci: Int32?) -> Float {
            var s = log(probability(c, ci, ctx))
            let after = makeContext((left.last.map { [$0] } ?? []) + [c])
            s += log(probability(r1, r1i, after))
            if let r2i { s += log(probability(right[1], r2i, makeContext([c, r1]))) }
            return s
        }
        func follows(_ ci: Int32) -> Bool {
            lexicon.conv2[Lexicon.key(ci, r1i)] != nil || lexicon.bigram[Lexicon.key(ci, r1i)] != nil
        }

        var costs: [Int32: Float] = [:]
        for m in fuzzy(t, maxCost: KeyboardModel.maxCost(length: t.count), prefixMode: false) {
            costs[m.word] = min(costs[m.word] ?? .infinity, m.cost)
        }
        let currentIndex = lexicon.index[lowerCurrent]
        let currentCost: Float = lowerCurrent == lowerTyped ? 0 : (currentIndex.flatMap { costs[$0] } ?? 1)
        let currentScore = gamma * fit(lowerCurrent, currentIndex) - alpha * currentCost

        var best: (word: Int32, score: Float)?
        // Once a word has been corrected, a second opinion may only pick a spelling about as close to what was
        // typed as the first one; a better-fitting but more distant word (their -> this) is a different word.
        let costCeiling: Float = lowerCurrent == lowerTyped ? .infinity : currentCost + 0.3
        for (ci, cost) in costs where lexicon.words[Int(ci)] != lowerCurrent && cost <= costCeiling && follows(ci)
            && !Engine.neverSubstitute.contains(lexicon.words[Int(ci)]) {
            // A different word needs evidence from both sides, not just a common neighbour.
            let score = gamma * fit(lexicon.words[Int(ci)], ci) - alpha * cost
            if best == nil || score > best!.score { best = (ci, score) }
        }
        guard let best, lexicon.logP[Int(best.word)] > -16.5 else { return nil }
        let margin = (typedKnown && lowerCurrent == lowerTyped) ? retroMarginKnown : retroMarginUnknown
        guard best.score - currentScore >= margin else { return nil }
        let pattern = CasePattern(current)
        return pattern.apply(to: lexicon.displayForm(best.word))
    }

    // MARK: - Learning

    /// Records a word the user committed (after any correction), so future suggestions adapt.
    public func learn(word: String, context: [String]) {
        let lower = normalize(word)
        guard lower.count >= 1, lower.count <= 24, encode(lower) != nil else { return }
        user.observe(word: lower, context: context)
        if !lexicon.contains(lower), word != lower, CasePattern(word) != .upper || word.count <= 5 {
            user.casing[lower] = word
        }
    }

    /// A word that was learned turned out to be a slip and has been replaced: forget it, learn the fix.
    public func relearn(from old: String, to new: String, context: [String]) {
        user.retract(word: normalize(old), context: context)
        learn(word: new, context: context)
    }

    /// Registers a name (the user's own, for instance) so it is never corrected and completes with its capital.
    public func addName(_ name: String) {
        let lower = normalize(name)
        guard lower.count >= 2, encode(lower) != nil, !lexicon.contains(lower) else { return }
        user.keep.insert(lower)
        user.casing[lower] = name
        if user.count(lower) < 3 { user.words[lower] = 3 }
    }

    /// The user undid an autocorrection of this word: stop correcting it.
    public func keep(word: String) {
        user.markKept(normalize(word))
    }
}
