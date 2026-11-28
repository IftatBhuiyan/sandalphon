import Foundation
import TypeEngine

// Offline quality check for the engine: false positives on real words, recall on typos, and speed.
// Usage: sandalphon-eval [dataDir] [--type "some text"]

let args = CommandLine.arguments
let dataDir = URL(fileURLWithPath: args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "Data")
let start = Date()
let engine = try Engine(dataDirectory: dataDir)
print(String(format: "loaded %d words in %.0f ms", engine.lexicon.count, Date().timeIntervalSince(start) * 1000))

if let i = args.firstIndex(of: "--explain"), i + 1 < args.count {
    engine.explain(args[i + 1], context: Array(args.dropFirst(i + 2))).forEach { print($0) }
    exit(0)
}
if let i = args.firstIndex(of: "--unknown"), i + 1 < args.count {
    // Valid words the dictionary does not know (names, rare words, jargon): how many get "corrected"?
    let words = ((try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        .filter { !engine.isKnown($0.lowercased()) && $0.count >= 3 }
    var changed: [String] = []
    for w in words {
        // Mid-sentence, as typed: names keep their capital, the rest are lowercase.
        if let fix = engine.autocorrection(for: w, context: ["ask"]) { changed.append("\(w)->\(fix)") }
    }
    print("\(words.count) valid words not in the dictionary: \(changed.count) changed (\(String(format: "%.1f", 100 * Double(changed.count) / Double(max(words.count, 1))))%)")
    if args.contains("--verbose") { print("  ", changed.prefix(60).joined(separator: ", ")) }
    exit(0)
}
if let i = args.firstIndex(of: "--testset"), i + 1 < args.count {
    // Lines of "right: wrong1 wrong2 ...": isolated human misspellings, no context.
    let text = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
    var n = 0, fixed = 0, wrong = 0, left = 0, top3 = 0, known = 0
    var wrongs: [String] = [], lefts: [String] = []
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: ":")
        guard parts.count == 2 else { continue }
        let right = parts[0].trimmingCharacters(in: .whitespaces)
        for w in parts[1].split(separator: " ").map(String.init) where w != right {
            n += 1
            if engine.isKnown(w.lowercased()) { known += 1 }
            let got = engine.autocorrection(for: w, context: [])
            let options = engine.analyze(typed: w, context: [], eager: true).suggestions.map { $0.text.lowercased() }
            if got?.lowercased() == right.lowercased() || options.contains(right.lowercased()) { top3 += 1 }
            if let got {
                if got.lowercased() == right.lowercased() { fixed += 1 } else { wrong += 1; if wrongs.count < 30 { wrongs.append("\(w)->\(got) (\(right))") } }
            } else { left += 1; if lefts.count < 40 { lefts.append("\(w) (\(right)) [\(options.joined(separator: "|"))]") } }
        }
    }
    func pc(_ a: Int) -> String { String(format: "%.1f%%", 100 * Double(a) / Double(max(n, 1))) }
    print("\(n) misspellings: fixed automatically \(pc(fixed)), changed to the wrong word \(pc(wrong)), left alone \(pc(left)); right answer offered \(pc(top3)); \(pc(known)) are themselves real words")
    if args.contains("--verbose") {
        print("  wrong:", wrongs.joined(separator: ", "))
        print("  left:", lefts.joined(separator: ", "))
    }
    exit(0)
}
if let i = args.firstIndex(of: "--reconsider"), i + 5 < args.count {
    // --reconsider typed left2 left1 right1 right2
    print(engine.reconsider(typed: args[i + 1], current: args[i + 1], left: [args[i + 2], args[i + 3]], right: [args[i + 4], args[i + 5]]) ?? "(keep)")
    exit(0)
}
if let i = args.firstIndex(of: "--retro"), i + 1 < args.count {
    // Held-out sentences: how often is a correct word changed, and how often is a planted slip repaired?
    let text = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
    var checked = 0, changedGood = 0, planted = 0, repaired = 0, misrepaired = 0
    var bad: [String] = [], good: [String] = [], missed: [String] = []
    let swaps: [String: String] = ["from": "form", "their": "there", "then": "than", "than": "then", "your": "you",
                                   "were": "where", "with": "wit", "the": "teh", "what": "waht", "going": "gong",
                                   "think": "thing", "know": "now", "want": "wnat", "have": "hvae", "that": "taht",
                                   "this": "thsi", "good": "god", "just": "jsut", "about": "abut", "here": "her",
                                   "they": "the", "time": "tim", "like": "lik", "right": "rihgt", "really": "relly"]
    for line in text.split(separator: "\n").prefix(40000) {
        let words = line.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init)
        guard words.count >= 4, words.allSatisfy({ engine.lexicon.contains($0) }) else { continue }
        for k in 0..<(words.count - 1) {
            let left = Array((["<s>"] + words[..<k]).suffix(2)), right = Array(words[(k + 1)...].prefix(2))
            checked += 1
            if let alt = engine.reconsider(typed: words[k], current: words[k], left: left, right: right) {
                changedGood += 1
                if bad.count < 40 { bad.append("\(left.joined(separator: " ")) [\(words[k])->\(alt)] \(right.joined(separator: " "))") }
            }
            if let slip = swaps[words[k]] {
                planted += 1
                // What the forward pass would have left in the text for this slip.
                let forward = engine.autocorrection(for: slip, context: left) ?? slip
                if forward.lowercased() == words[k] { repaired += 1; continue }
                let alt = engine.reconsider(typed: slip, current: forward, left: left, right: right)
                if alt?.lowercased() == words[k] { repaired += 1; if good.count < 12 { good.append("\(slip)->\(alt!)") } }
                else if let alt { misrepaired += 1; if missed.count < 15 { missed.append("\(slip)->\(alt) (\(words[k]))") } }
            }
        }
    }
    print("correct words re-examined: \(checked), wrongly changed: \(changedGood) (\(String(format: "%.3f", 100 * Double(changedGood) / Double(max(checked, 1))))%)")
    print("  ", bad.joined(separator: " | "))
    print("planted slips: \(planted), ended up right: \(repaired) (\(100 * repaired / max(planted, 1))%), changed to something else: \(misrepaired)")
    print("  ", good.joined(separator: ", "), "||", missed.joined(separator: ", "))
    exit(0)
}
if let i = args.firstIndex(of: "--confusables"), i + 1 < args.count {
    // Held-out sentences: for each word in a confusable set, is a correct use ever changed, and when another
    // member of its set is planted in its place, is it put right?
    let text = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
    let sets = [["their", "there", "they're"], ["your", "you're"], ["its", "it's"], ["then", "than"], ["loose", "lose"],
                ["to", "too"], ["affect", "effect"], ["who's", "whose"], ["were", "where", "we're"]]
    var setOf: [String: Int] = [:]
    for (n, set) in sets.enumerated() { for w in set { setOf[w] = n } }
    var uses = [Int](repeating: 0, count: sets.count), changed = uses, planted = uses, fixed = uses, wrong = uses
    var examples: [String] = []
    var checked = 0
    for line in text.split(separator: "\n").prefix(Int(ProcessInfo.processInfo.environment["CONF_LINES"] ?? "") ?? 200000) {
        let words = line.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init)
        guard words.count >= 4, words.allSatisfy({ engine.lexicon.contains($0) }) else { continue }
        for k in 0..<(words.count - 1) {
            guard let n = setOf[words[k]] else { continue }
            checked += 1
            let left = Array((["<s>"] + words[..<k]).suffix(2)), right = Array(words[(k + 1)...].prefix(2))
            uses[n] += 1
            if let alt = engine.reconsider(typed: words[k], current: words[k], left: left, right: right) {
                changed[n] += 1
                if examples.count < 40 { examples.append("\(left.joined(separator: " ")) [\(words[k])->\(alt)] \(right.joined(separator: " "))") }
            }
            for other in sets[n] where other != words[k] {
                planted[n] += 1
                let alt = engine.reconsider(typed: other, current: other, left: left, right: right)?.lowercased()
                if alt == words[k] { fixed[n] += 1 } else if alt != nil { wrong[n] += 1 }
            }
        }
    }
    func pct(_ a: Int, _ b: Int) -> String { String(format: "%.2f%%", 100 * Double(a) / Double(max(b, 1))) }
    print("set                       correct uses  changed          planted  fixed            wrong")
    for (n, set) in sets.enumerated() {
        print(set.joined(separator: "/").padding(toLength: 26, withPad: " ", startingAt: 0)
              + String(uses[n]).padding(toLength: 14, withPad: " ", startingAt: 0)
              + "\(changed[n]) (\(pct(changed[n], uses[n])))".padding(toLength: 17, withPad: " ", startingAt: 0)
              + String(planted[n]).padding(toLength: 9, withPad: " ", startingAt: 0)
              + "\(fixed[n]) (\(pct(fixed[n], planted[n])))".padding(toLength: 17, withPad: " ", startingAt: 0)
              + "\(wrong[n])")
    }
    let tu = uses.reduce(0, +), tc = changed.reduce(0, +), tp = planted.reduce(0, +), tf = fixed.reduce(0, +)
    print("total: \(tu) correct uses, \(tc) changed (\(pct(tc, tu))); \(tp) planted, \(tf) fixed (\(pct(tf, tp))), \(wrong.reduce(0, +)) wrong")
    if args.contains("--verbose") { print("  ", examples.joined(separator: " | ")) }
    exit(0)
}
if let i = args.firstIndex(of: "--context"), i + 1 < args.count {
    // Real misspellings inside real sentences (Holbrook corpus format: <ERR targ=right> wrong </ERR>).
    // Each line is typed through a fresh session; every word is then compared with what the writer meant.
    let raw = (try? String(contentsOfFile: args[i + 1], encoding: .isoLatin1)) ?? ""
    let verbose = args.contains("--verbose")
    var nonword = (n: 0, fixed: 0, wrong: 0), realword = (n: 0, fixed: 0, wrong: 0)
    var good = 0, goodChanged = 0, lines = 0, skipped = 0, confusableReal = 0
    var wrongs: [String] = [], lefts: [String] = [], harms: [String] = []
    func bare(_ s: String) -> String { s.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "'"))) }
    for line in raw.split(separator: "\n") {
        var typed: [String] = [], meant: [String?] = []   // meant nil = not scored
        var rest = Substring(line)
        var ok = true
        while !rest.isEmpty {
            if let open = rest.range(of: "<ERR targ=") {
                for w in rest[..<open.lowerBound].split(separator: " ") { typed.append(String(w)); meant.append(String(w)) }
                guard let gt = rest[open.upperBound...].firstIndex(of: ">"), let close = rest.range(of: "</ERR>") else { ok = false; break }
                let target = rest[open.upperBound..<gt].trimmingCharacters(in: .whitespaces)
                let wrong = rest[rest.index(after: gt)..<close.lowerBound].split(separator: " ").map(String.init)
                if wrong.count == 1 && !target.contains(" ") { typed.append(wrong[0]); meant.append("\u{1}" + target) }
                else { for w in wrong { typed.append(w); meant.append(nil) } }
                rest = rest[close.upperBound...]
            } else {
                for w in rest.split(separator: " ") { typed.append(String(w)); meant.append(String(w)) }
                rest = ""
            }
        }
        guard ok, typed.count >= 3, typed.contains(where: { $0.contains(where: \.isLetter) }) else { continue }
        // Punctuation is its own token in the corpus; attach it to the word before, as a person would type it.
        var words: [String] = [], targets: [String?] = []
        for (w, m) in zip(typed, meant) {
            if !w.contains(where: { $0.isLetter || $0.isNumber }), !words.isEmpty { words[words.count - 1] += w }
            else { words.append(w); targets.append(m) }
        }
        let session = TypingSession(engine: engine)
        session.learningEnabled = false
        // A look-back fix is applied just before the next key; the last words of a line have none, so the
        // line ends with an extra space, as if the writer had carried on.
        let out = session.simulate(typing: words.joined(separator: " ") + "  ").split(separator: " ").map(String.init)
        lines += 1
        guard out.count == words.count else { skipped += 1; continue }
        for k in 0..<words.count {
            guard let m = targets[k] else { continue }
            let got = bare(out[k]), was = bare(words[k])
            if m.hasPrefix("\u{1}") {
                let want = bare(String(m.dropFirst()))
                guard want != was, !want.isEmpty else { continue }
                let isReal = engine.lexicon.contains(was)
                if isReal { realword.n += 1 } else { nonword.n += 1 }
                if isReal, engine.isConfusable(was), engine.isConfusable(want) { confusableReal += 1 }
                if got == want { if isReal { realword.fixed += 1 } else { nonword.fixed += 1 } }
                else if got != was {
                    if isReal { realword.wrong += 1 } else { nonword.wrong += 1 }
                    if wrongs.count < 60 { wrongs.append("\(was)->\(got) (\(want))") }
                } else if !isReal, lefts.count < 80 { lefts.append("\(was) (\(want))") }
            } else {
                good += 1
                if got != was { goodChanged += 1; if harms.count < 90 { harms.append("\(k > 0 ? words[k - 1] : "^") [\(was)->\(got)] \(k + 1 < words.count ? words[k + 1] : "$")") } }
            }
        }
    }
    func pct(_ a: Int, _ b: Int) -> String { String(format: "%.1f%%", 100 * Double(a) / Double(max(b, 1))) }
    print("sentences: \(lines) (\(skipped) skipped: word count changed)")
    print("misspellings that are not words: \(nonword.n)  fixed \(pct(nonword.fixed, nonword.n))  wrong \(pct(nonword.wrong, nonword.n))  left \(pct(nonword.n - nonword.fixed - nonword.wrong, nonword.n))")
    print("wrong words that are real words:  \(realword.n)  fixed \(pct(realword.fixed, realword.n))  wrong \(pct(realword.wrong, realword.n))")
    print("  of which both words are in a confusable set: \(confusableReal)")
    print("correct words: \(good)  changed \(goodChanged) (\(pct(goodChanged, good)))")
    if verbose {
        print("  wrong:", wrongs.joined(separator: ", "))
        print("  left:", lefts.joined(separator: ", "))
        print("  harmed:", harms.joined(separator: ", "))
    }
    exit(0)
}
if let i = args.firstIndex(of: "--type"), i + 1 < args.count {
    let session = TypingSession(engine: engine)
    print(session.simulate(typing: args[i + 1]))
    print("suggestions:", session.suggestions.map { $0.text })
    exit(0)
}

// 1. Real words must be left alone.
var changed: [String] = []
for w in engine.lexicon.words.prefix(40_000) {
    if let fix = engine.autocorrection(for: w, context: []), fix.lowercased() != w { changed.append("\(w)->\(fix)") }
}
print("real words changed: \(changed.count) of 40000  \(changed.prefix(30))")

// 2. Synthetic slips on common words.
struct RNG: RandomNumberGenerator {
    var state: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0) }
func neighbour(_ c: Character, _ rng: inout RNG) -> Character {
    for row in rows {
        if let i = row.firstIndex(of: c) {
            let options = [i - 1, i + 1].filter { $0 >= 0 && $0 < row.count }
            return row[options.randomElement(using: &rng)!]
        }
    }
    return c
}
func slip(_ w: String, _ rng: inout RNG) -> String {
    var c = Array(w)
    let i = Int.random(in: 1..<c.count, using: &rng)
    switch Int.random(in: 0..<5, using: &rng) {
    case 0: c[i] = neighbour(c[i], &rng)
    case 1: if i + 1 < c.count { c.swapAt(i, i + 1) } else { c.swapAt(i - 1, i) }
    case 2: c.remove(at: i)
    case 3: c.insert(c[i], at: i)
    default: c.insert(neighbour(c[i], &rng), at: i)
    }
    return String(c)
}
var rng = RNG()
var right = 0, wrong = 0, untouched = 0, inTop3 = 0, total = 0
var wrongSamples: [String] = [], missSamples: [String] = []
let common = engine.lexicon.words.prefix(6000).filter { $0.count >= 4 && !$0.contains("'") }
var elapsed = 0.0
for w in common {
    let typo = slip(w, &rng)
    if typo == w || engine.isKnown(typo) { continue }
    total += 1
    let t0 = Date()
    let fix = engine.autocorrection(for: typo, context: [])
    let sugg = engine.suggestions(typed: typo, context: [])
    elapsed += Date().timeIntervalSince(t0)
    if sugg.contains(where: { $0.text.lowercased() == w }) { inTop3 += 1 }
    if let fix {
        if fix.lowercased() == w { right += 1 } else { wrong += 1; if wrongSamples.count < 25 { wrongSamples.append("\(typo)->\(fix) (\(w))") } }
    } else {
        untouched += 1
        if missSamples.count < 25 { missSamples.append("\(typo) (\(w))") }
    }
}
func pct(_ a: Int, _ b: Int) -> String { String(format: "%.1f%%", 100 * Double(a) / Double(max(b, 1))) }
print("synthetic slips: \(total)  fixed \(pct(right, total))  wrong \(pct(wrong, total))  left \(pct(untouched, total))  in top 3 \(pct(inTop3, total))")
print(String(format: "  %.2f ms per word (autocorrect + suggestions)", elapsed / Double(total) * 1000))
print("  wrong:", wrongSamples.joined(separator: ", "))
print("  left:", missSamples.joined(separator: ", "))

// 3. Common real-world misspellings.
let pairs: [(String, String)] = [
    ("teh", "the"), ("adn", "and"), ("taht", "that"), ("thier", "their"), ("recieve", "receive"),
    ("definately", "definitely"), ("seperate", "separate"), ("occured", "occurred"), ("untill", "until"),
    ("wierd", "weird"), ("becuase", "because"), ("beleive", "believe"), ("freind", "friend"),
    ("tommorow", "tomorrow"), ("accomodate", "accommodate"), ("goverment", "government"),
    ("neccessary", "necessary"), ("wich", "which"), ("alot", "a lot"), ("dont", "don't"), ("im", "I'm"),
    ("ive", "I've"), ("youre", "you're"), ("doesnt", "doesn't"), ("didnt", "didn't"), ("cant", "can't"),
    ("wouldnt", "wouldn't"), ("thankyou", "thank you"), ("hte", "the"), ("waht", "what"), ("jsut", "just"),
    ("knwo", "know"), ("abotu", "about"), ("woudl", "would"), ("peopel", "people"), ("realy", "really"),
    ("probaly", "probably"), ("diffrent", "different"), ("intresting", "interesting"), ("tomorow", "tomorrow"),
    ("calender", "calendar"), ("experiance", "experience"), ("happend", "happened"), ("basicly", "basically"),
    ("begining", "beginning"), ("buisness", "business"), ("enviroment", "environment"), ("existance", "existence"),
    ("foward", "forward"), ("grammer", "grammar"), ("immediatly", "immediately"), ("independant", "independent"),
    ("knowlege", "knowledge"), ("occassion", "occasion"), ("posession", "possession"), ("recomend", "recommend"),
    ("refered", "referred"), ("succesful", "successful"), ("suprise", "surprise"), ("truely", "truly"),
    ("writting", "writing"), ("i", "I"), ("somthing", "something"), ("togehter", "together"), ("litle", "little"),
]
var ok = 0
var failed: [String] = []
for (typo, want) in pairs {
    let got = engine.autocorrection(for: typo, context: [])
    if got == want { ok += 1 } else {
        failed.append("\(typo)->\(got ?? "-") [\(engine.suggestions(typed: typo, context: []).map { $0.text }.joined(separator: "|"))]")
    }
}
print("misspellings fixed: \(ok)/\(pairs.count)")
print("  not fixed:", failed.joined(separator: ", "))

// 4. Suggestions and predictions.
for (ctx, typed) in [(["thank"], ""), (["<s>", "i"], ""), (["how", "are"], ""), (["looking", "forward"], ""), (["<s>"], ""), (["i", "don't"], ""), (["see", "you"], ""), (["let", "me"], ""), (["<s>", "i"], "wan"), (["going", "to"], "b"), ([], "tomor"), (["i"], "wou"), ([], "recie"), (["the"], "wor"), ([], "helo"), ([], "lond")] {
    let list = typed.isEmpty ? engine.predictions(context: ctx) : engine.suggestions(typed: typed, context: ctx).map { $0.text + ($0.isAutocorrect ? "*" : "") }
    print("  \(ctx.joined(separator: " ")) | \(typed) -> \(list)")
}
