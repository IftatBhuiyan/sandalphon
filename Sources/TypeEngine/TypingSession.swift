import Foundation

/// A change to make in the focused text field, expressed relative to the caret.
public struct Edit: Equatable {
    /// Characters to delete before the caret.
    public let deleteCount: Int
    /// Text to type afterwards.
    public let insert: String
    /// Whether the key that triggered this edit should still be delivered after it.
    public let repostKey: Bool

    public init(deleteCount: Int, insert: String, repostKey: Bool) {
        self.deleteCount = deleteCount
        self.insert = insert
        self.repostKey = repostKey
    }
}

/// Follows what is being typed, one key at a time, and decides when to correct or suggest.
/// It only models the text immediately before the caret; anything that moves the caret must call `reset()`.
public final class TypingSession {
    public let engine: Engine

    public private(set) var word = ""
    public private(set) var context: [String] = []
    public private(set) var suggestions: [Suggestion] = []
    /// True when we no longer know what is before the caret and should re-read it before the next key.
    public private(set) var needsSeed = true

    public var autocorrectEnabled = true
    public var suggestionsEnabled = true
    public var predictionsEnabled = true
    /// Show every reasonable option rather than only the confident ones (the user asked to see them).
    public var eager = false { didSet { if eager != oldValue { stale = true } } }
    /// Capitalise the first word of a sentence.
    public var capitalizeSentences = true
    /// Whether the very first word in a field counts as a sentence start (not in single-line fields).
    public var capitalizeFieldStart = true
    /// Fix two-word slips ("could of", "a apple", "the the") and stray spaces before commas.
    public var grammarEnabled = true
    public var doubleSpacePeriod = true
    /// Set when a second space has just been typed after this word: the caller may turn it into ". "
    /// once it has confirmed the field really ends with the word and two spaces.
    public private(set) var doubleSpaceCandidate: String?
    /// When false, nothing typed is added to the user's learned words.
    public var learningEnabled = true

    /// The current token contains something that is not prose (digits, @, /, a dot inside it...). Hands off.
    private var dirty = false
    private var afterSpace = false
    /// The previous word exactly as it stands in the text, while only spaces separate it from the caret.
    private var prevRaw: String?
    private var spaceRun = 0
    private var atFieldStart = false
    private var lastWasPeriod = false
    private var suppressed = false
    private var autoSpacePending = false
    private var pendingFix: String?
    private var analysed = false
    private var stale = false
    /// When true, suggestions are only computed by `updateSuggestions()`, keeping key handling instant.
    public var lazySuggestions = false
    private var lastCorrection: (original: String, replacement: String, delimiter: String)?

    // Recent corrections, newest last, kept in memory only and never more than `historyLimit`.
    public struct Correction: Identifiable, Equatable {
        public let id: Int
        /// What stood there before the correction, and what it became.
        public let original: String
        public let replacement: String
        /// What was typed, for "don't correct this again".
        let typed: String
        /// Where the replacement starts in the current run, or nil once the caret has moved and it can no
        /// longer be found safely.
        var start: Int?
        /// Whether it can still be found where it stands (see also `canRevertInPlace`).
        public var inPlace: Bool { start != nil }
        /// The same entry, marked as no longer changeable in place.
        public func detached() -> Correction {
            var c = self
            c.start = nil
            return c
        }
    }
    public private(set) var history: [Correction] = []
    /// Bumped whenever `history` changes, so a host can tell cheaply when to refresh a copy.
    public private(set) var historyVersion = 0
    public static let historyLimit = 10
    /// How far back from the caret a correction can still be changed in place. Everything from the word to the
    /// caret is checked against the field first, and Accessibility only reports about 160 characters.
    public static let revertReach = 150
    private var nextCorrectionID = 1

    // Second thoughts: everything typed since the caret last moved, exactly as it stands in the field, and
    // where each finished word sits in it, so an earlier word can be revised once later words are known.
    private struct Span {
        var start: Int
        var text: String
        let typed: String
        let left: [String]
        var looks = 0
    }
    private var doc = ""
    private var spans: [Span] = []
    private var wordStart: Int?
    private var retroDue = false
    private var retroPending: (index: Int, text: String)?
    private var retroConfirmed = false
    /// Go back and fix an earlier word when what was typed after it shows it was wrong.
    public var retroEnabled = true

    private static let closers: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "\"", "\u{201D}", "\u{2026}"]
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "\u{201C}", "\u{2018}", "'"]
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "\n", "\r"]
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs", "etc", "eg", "ie", "inc", "ltd",
                                                     "co", "no", "approx", "fig", "prof", "gen", "sgt", "est", "dept", "apt"]

    public init(engine: Engine) {
        self.engine = engine
    }

    // MARK: - Classification

    public enum KeyKind { case word, delimiter, other }

    /// How a typed character should be fed to the session.
    public func kind(of ch: Character) -> KeyKind {
        if ch.isLetter { return .word }
        if ch == "'" || ch == "\u{2019}" { return word.isEmpty ? .other : .word }
        if ch == " " || ch.isNewline || ch == "\t" { return .delimiter }
        if TypingSession.closers.contains(ch) { return word.isEmpty && ch == "\"" ? .other : .delimiter }
        return .other
    }

    // MARK: - Events

    /// Caret moved, focus changed, or a shortcut ran: forget everything.
    public func reset() {
        word = ""
        context = []
        suggestions = []
        dirty = false
        afterSpace = false
        suppressed = false
        autoSpacePending = false
        lastCorrection = nil
        prevRaw = nil
        spaceRun = 0
        atFieldStart = false
        lastWasPeriod = false
        doubleSpaceCandidate = nil
        clearRun()
        needsSeed = true
    }

    /// Re-establishes state from the text before the caret, or (nil) from nothing at all,
    /// in which case the session stays hands-off until the next whitespace.
    public func seed(textBeforeCaret: String?) {
        reset()
        needsSeed = false
        guard let text = textBeforeCaret else {
            dirty = true
            return
        }
        let tail = String(text.suffix(160)).replacingOccurrences(of: "\u{2019}", with: "'")
        var token = Substring(tail)
        var before = Substring("")
        if let i = tail.lastIndex(where: { $0.isWhitespace }) {
            token = tail[tail.index(after: i)...]
            before = tail[..<i]
        }
        while let f = token.first, TypingSession.openers.contains(f) { token = token.dropFirst() }
        if token.isEmpty {
            dirty = false
        } else if token.count < 30 && token.allSatisfy({ $0.isLetter || $0 == "'" }) {
            word = String(token)
        } else {
            dirty = true
        }
        var atStart = tail.count < 160
        atFieldStart = atStart
        if let cut = before.lastIndex(where: { TypingSession.sentenceEnders.contains($0) }) {
            // Only a full stop that closes a real word starts a sentence ("3.5" and "e.g." do not).
            let ender = before[cut]
            let lead = before[..<cut]
            let closesWord = ender != "." || (lead.last?.isLetter == true
                && !TypingSession.abbreviations.contains(normalize(String(lead.split(whereSeparator: { !$0.isLetter }).last ?? ""))))
            before = before[before.index(after: cut)...]
            atStart = closesWord
            atFieldStart = false
        }
        let words = before.split(whereSeparator: { !($0.isLetter || $0 == "'") }).map { normalize(String($0)) }
        context = (atStart ? [Lexicon.startToken] : []) + words
        if context.count > 3 { context.removeFirst(context.count - 3) }
        refresh()
    }

    /// A letter or in-word apostrophe (`.word`), or any other non-delimiter character (`.other`).
    public func character(_ ch: Character) {
        lastCorrection = nil
        autoSpacePending = false
        afterSpace = false
        doubleSpaceCandidate = nil
        lastWasPeriod = false
        if kind(of: ch) == .word {
            if word.isEmpty {
                if spaceRun != 1 { prevRaw = nil }
                spaceRun = 0
                wordStart = dirty ? nil : doc.count
            }
            if !dirty { word.append(ch) } else if context == [Lexicon.startToken] { context = [] }
        } else {
            if context == [Lexicon.startToken], !(word.isEmpty && !dirty && TypingSession.openers.contains(ch)) { context = [] }
            prevRaw = nil
            spaceRun = 0
            if !(word.isEmpty && !dirty && TypingSession.openers.contains(ch)) {
                dirty = true
                word = ""
            }
        }
        doc.append(ch)
        refresh()
    }

    /// Space, newline or closing punctuation. A non-nil result must be applied instead of the key itself.
    public func delimiter(_ ch: Character) -> Edit? {
        var edit: Edit?
        let isSpace = ch == " " || ch == "\t"
        doubleSpaceCandidate = nil

        // "word " + "." after an accepted suggestion becomes "word."; so does a stray space before a comma.
        let afterAccept = autoSpacePending && [".", ",", "!", "?", ";", ":"].contains(ch)
        let strayComma = grammarEnabled && autocorrectEnabled && ch == "," && spaceRun == 1 && prevRaw != nil
        if word.isEmpty && (afterAccept || strayComma) {
            autoSpacePending = false
            lastCorrection = nil
            afterSpace = false
            dirty = true
            prevRaw = nil
            spaceRun = 0
            lastWasPeriod = ch == "."
            if ch == "." || ch == "!" || ch == "?" { context = [Lexicon.startToken] }
            suggestions = []
            docRemove(1)
            doc.append(ch)
            return Edit(deleteCount: 1, insert: "", repostKey: true)
        }
        autoSpacePending = false
        lastCorrection = nil

        var committed: String?
        if !word.isEmpty && !dirty {
            var final = word
            if autocorrectEnabled {
                // Spelling: normally already worked out while the word was being typed.
                if let fix = analysed ? pendingFix : engine.autocorrection(for: word, context: context) { final = fix }
                // Capital at the start of a sentence.
                if capitalizeSentences, context == [Lexicon.startToken], !(atFieldStart && !capitalizeFieldStart),
                   let first = final.first, first.isLowercase, final.dropFirst().allSatisfy({ !$0.isUppercase }) {
                    final = first.uppercased() + final.dropFirst()
                }
            }
            var original = word
            var deleteCount = word.count
            var replacedPrevious = false
            if autocorrectEnabled, grammarEnabled, let prev = prevRaw, let fixed = engine.pairFix(prev: prev, word: final) {
                original = prev + " " + word
                deleteCount = prev.count + 1 + word.count
                final = fixed
                replacedPrevious = true
            }
            if final != word || replacedPrevious {
                edit = Edit(deleteCount: deleteCount, insert: final, repostKey: true)
                if !ch.isNewline { lastCorrection = (original, final, String(ch)) }
            }
            let left = Array(context.suffix(2))
            if edit != nil {
                docRemove(deleteCount)
                // A capital at the start of a sentence is not worth listing among corrections.
                let onlyCapital = !replacedPrevious && final.lowercased() == word.lowercased()
                    && final.dropFirst() == word.dropFirst()
                if !onlyCapital {
                    record(original: original, replacement: final, typed: replacedPrevious ? original : word,
                           start: replacedPrevious || wordStart != nil ? doc.count : nil)
                }
                doc += final
            }
            if !replacedPrevious, let start = wordStart, !final.contains(" "), start + final.count == doc.count {
                spans.append(Span(start: start, text: final, typed: word, left: left))
                retroDue = true
            }
            if replacedPrevious, !context.isEmpty { context.removeLast() }
            commit(final)
            committed = final
            atFieldStart = false
        }

        word = ""
        wordStart = nil
        doc.append(ch)
        if doc.count > 400 { clearRun() }
        suppressed = false
        dirty = !(isSpace || ch.isNewline)
        afterSpace = isSpace
        if isSpace {
            if let committed {
                prevRaw = committed.split(separator: " ").last.map(String.init)
                spaceRun = 1
            } else if spaceRun >= 1 {
                spaceRun += 1
                if spaceRun == 2, doubleSpacePeriod, autocorrectEnabled, let prev = prevRaw { doubleSpaceCandidate = prev }
            } else {
                prevRaw = nil
            }
        } else {
            prevRaw = nil
            spaceRun = 0
        }

        // Where does a new sentence begin? After ! and ?, and after a full stop that closes a real word:
        // not an abbreviation, an initial, a number, a domain or an ellipsis.
        if ch == "!" || ch == "?" || ch.isNewline {
            context = [Lexicon.startToken]
        } else if ch == "." {
            if let w = committed, w.count >= 2, !lastWasPeriod, !TypingSession.abbreviations.contains(normalize(w)) {
                context = [Lexicon.startToken]
            } else {
                context = []
            }
        }
        if !isSpace { lastWasPeriod = ch == "." }

        if ch.isNewline {
            // Return often submits or clears the field; look again before trusting anything.
            suggestions = []
            needsSeed = true
        } else {
            refresh()
        }
        return edit
    }

    /// The caller replaced the two spaces after a word with ". ".
    public func appliedDoubleSpacePeriod() {
        doubleSpaceCandidate = nil
        prevRaw = nil
        spaceRun = 0
        context = [Lexicon.startToken]
        afterSpace = true
        dirty = false
        lastCorrection = nil
        docRemove(2)
        doc += ". "
        refresh()
    }

    /// Backspace. A non-nil result undoes the last autocorrection and must be applied instead of the key.
    public func backspace() -> Edit? {
        autoSpacePending = false
        afterSpace = false
        prevRaw = nil
        spaceRun = 0
        doubleSpaceCandidate = nil
        if let lc = lastCorrection, word.isEmpty {
            lastCorrection = nil
            if learningEnabled { engine.keep(word: lc.original) }
            if let i = history.lastIndex(where: { $0.replacement == lc.replacement && $0.original == lc.original }) {
                history.remove(at: i)
                historyVersion &+= 1
            }
            let parts = lc.replacement.split(separator: " ").count
            context.removeLast(min(parts, context.count))
            commit(lc.original)
            dirty = lc.delimiter != " "
            afterSpace = lc.delimiter == " "
            docRemove(lc.replacement.count + lc.delimiter.count)
            doc += lc.original + lc.delimiter
            refresh()
            return Edit(deleteCount: lc.replacement.count + lc.delimiter.count,
                        insert: lc.original + lc.delimiter, repostKey: false)
        }
        lastCorrection = nil
        if !word.isEmpty {
            word.removeLast()
            docRemove(1)
            refresh()
        } else {
            suggestions = []
            clearRun()
            needsSeed = true
        }
        return nil
    }

    /// Inserts suggestion `index` in place of the current word.
    public func accept(_ index: Int) -> Edit? {
        updateSuggestions()
        guard suggestions.indices.contains(index) else { return nil }
        let text = suggestions[index].text
        let edit = Edit(deleteCount: word.count, insert: text + " ", repostKey: false)
        commit(text)
        docRemove(word.count)
        doc += text + " "
        wordStart = nil
        word = ""
        dirty = false
        suppressed = false
        lastCorrection = nil
        autoSpacePending = true
        afterSpace = true
        prevRaw = text.split(separator: " ").last.map(String.init)
        spaceRun = 1
        atFieldStart = false
        refresh()
        return edit
    }

    /// Hide suggestions until the current word is finished.
    public func dismiss() {
        suppressed = true
        suggestions = []
    }

    // MARK: - Second thoughts

    /// A change to a word further back: move left `back` characters, replace, and come back.
    public struct RetroFix: Equatable {
        public let back: Int
        public let deleteCount: Int
        public let insert: String
    }

    /// Counts only, for diagnostics.
    public var debugState: String { "doc=\(doc.count) spans=\(spans.count) pending=\(retroPending != nil) confirmed=\(retroConfirmed) wordStart=\(wordStart ?? -1)" }

    /// When a revision is waiting, the text the field must end with for it to be safe to apply.
    public var pendingRetroTail: String? {
        retroPending != nil && !retroConfirmed ? String(doc.suffix(100)) : nil
    }

    /// The caller compared `pendingRetroTail` with the real field.
    public func confirmRetro(matches: Bool) {
        if matches {
            retroConfirmed = retroPending != nil
        } else {
            clearRun() // the field is not what we think it is: revise nothing
        }
    }

    /// Hands over a confirmed revision and updates the session as if it had been applied.
    public func takeRetro() -> RetroFix? {
        guard retroConfirmed, let pending = retroPending, spans.indices.contains(pending.index) else { return nil }
        retroPending = nil
        retroConfirmed = false
        let span = spans[pending.index]
        let end = span.start + span.text.count
        let back = doc.count - end
        guard back >= 0, back <= 60 else { return nil }
        let chars = Array(doc)
        doc = String(chars[..<span.start]) + pending.text + String(chars[end...])
        if learningEnabled { engine.relearn(from: span.text, to: pending.text, context: span.left) }
        let delta = pending.text.count - span.text.count
        shiftHistory(after: span.start, by: delta, replacing: span.start)
        // Undoing this puts back what stood before (possibly an earlier fix), so that is what is remembered.
        record(original: span.text, replacement: pending.text, typed: span.text, start: span.start)
        spans[pending.index].text = pending.text
        spans[pending.index].looks = 9
        for i in spans.indices where i > pending.index { spans[i].start += delta }
        if let start = wordStart { wordStart = start + delta }
        // Keep the running context in step if the word is still part of it.
        let after = spans.count - 1 - pending.index
        let slot = context.count - 1 - after
        if after < 2, context.indices.contains(slot), context[slot] == normalize(span.text) {
            context[slot] = normalize(pending.text)
        }
        if after == 0, spaceRun == 1 { prevRaw = pending.text }
        return RetroFix(back: back, deleteCount: span.text.count, insert: pending.text)
    }

    /// Re-examines the last few finished words in the light of what followed them.
    private func planRetro() {
        guard retroEnabled, autocorrectEnabled, retroPending == nil, spans.count >= 2 else { return }
        let chars = Array(doc)
        // Words that directly follow span `i`, separated by single spaces.
        func following(_ i: Int) -> [String] {
            var out: [String] = []
            var k = i
            while out.count < 2, k + 1 < spans.count {
                let end = spans[k].start + spans[k].text.count
                guard spans[k + 1].start == end + 1, end < chars.count, chars[end] == " " else { break }
                out.append(normalize(spans[k + 1].text))
                k += 1
            }
            return out
        }
        for i in stride(from: spans.count - 2, through: max(0, spans.count - 3), by: -1) {
            let span = spans[i]
            let right = following(i)
            guard span.looks < right.count, !right.isEmpty, doc.count - (span.start + span.text.count) <= 60 else { continue }
            spans[i].looks = right.count
            if let better = engine.reconsider(typed: span.typed, current: span.text, left: span.left, right: right),
               better != span.text {
                retroPending = (i, better)
                retroConfirmed = false
                return
            }
        }
    }

    private func record(original: String, replacement: String, typed: String, start: Int?) {
        history.append(Correction(id: nextCorrectionID, original: original, replacement: replacement, typed: typed, start: start))
        nextCorrectionID += 1
        if history.count > TypingSession.historyLimit { history.removeFirst(history.count - TypingSession.historyLimit) }
        historyVersion &+= 1
    }

    /// Text in the run changed at `position` by `delta` characters: move the records after it.
    private func shiftHistory(after position: Int, by delta: Int, replacing changedStart: Int?) {
        guard delta != 0 || changedStart != nil else { return }
        var changed = false
        for i in history.indices {
            guard let start = history[i].start else { continue }
            if start == changedStart { history[i].start = nil; changed = true }
            else if start > position { history[i].start = start + delta; changed = true }
        }
        if changed { historyVersion &+= 1 }
    }

    /// Whether correction `id` can still be changed back where it stands: found, and near enough to the caret.
    public func canRevertInPlace(_ id: Int) -> Bool { revertTail(id) != nil }

    /// What the field must end with for correction `id` to be changed back safely: everything from the start of
    /// the corrected text to the caret. Nil when the correction cannot be changed back in place.
    public func revertTail(_ id: Int) -> String? {
        guard let entry = history.first(where: { $0.id == id }), let start = entry.start else { return nil }
        let chars = Array(doc)
        let end = start + entry.replacement.count
        guard end <= chars.count, String(chars[start..<end]) == entry.replacement,
              chars.count - start <= TypingSession.revertReach else { return nil }
        return String(chars[start...])
    }

    /// The most recent correction that can be changed back in place.
    public var latestRevertible: Int? { history.last { revertTail($0.id) != nil }?.id }

    /// Changes correction `id` (or, for nil, the most recent one that can be) back to what stood there before,
    /// and remembers not to make it again. Returns how to edit the field, or nil if it cannot be done in place,
    /// in which case the word is still remembered.
    public func revert(_ id: Int? = nil) -> RetroFix? {
        let found: Int?
        if let id { found = history.firstIndex { $0.id == id } } else { found = latestRevertible.flatMap { id in history.firstIndex { $0.id == id } } }
        guard let index = found else { return nil }
        let inReach = revertTail(history[index].id) != nil
        let entry = history[index]
        if learningEnabled { engine.keep(word: entry.typed) }
        history.remove(at: index)
        historyVersion &+= 1
        if lastCorrection?.replacement == entry.replacement { lastCorrection = nil }
        guard inReach, let start = entry.start else { return nil }
        let chars = Array(doc)
        let end = start + entry.replacement.count
        doc = String(chars[..<start]) + entry.original + String(chars[end...])
        let delta = entry.original.count - entry.replacement.count
        // Keep the look-back bookkeeping in step: the word there is now the original, as typed.
        if let i = spans.firstIndex(where: { $0.start == start }) {
            let old = spans[i].text
            spans[i].text = entry.original
            spans[i].looks = 9
            let after = spans.count - 1 - i
            let slot = context.count - 1 - after
            if after < 2, !entry.original.contains(" "), context.indices.contains(slot), context[slot] == normalize(old) {
                context[slot] = normalize(entry.original)
            }
            if after == 0, spaceRun == 1 { prevRaw = entry.original }
        }
        for i in spans.indices where spans[i].start > start { spans[i].start += delta }
        if let ws = wordStart, ws > start { wordStart = ws + delta }
        if let pending = retroPending, spans.indices.contains(pending.index), spans[pending.index].start >= start {
            retroPending = nil
            retroConfirmed = false
        }
        shiftHistory(after: start, by: delta, replacing: nil)
        return RetroFix(back: doc.count - (start + entry.original.count), deleteCount: entry.replacement.count,
                        insert: entry.original)
    }

    private func clearRun() {
        if history.contains(where: { $0.inPlace }) {
            for i in history.indices { history[i].start = nil }
            historyVersion &+= 1
        }
        doc = ""
        spans = []
        wordStart = nil
        retroDue = false
        retroPending = nil
        retroConfirmed = false
    }

    /// The last `n` characters were deleted from the field.
    private func docRemove(_ n: Int) {
        guard n > 0 else { return }
        if n > doc.count {
            clearRun() // reached back past where this run began
            return
        }
        doc.removeLast(n)
        while let last = spans.last, last.start + last.text.count > doc.count { spans.removeLast() }
        if let pending = retroPending, pending.index >= spans.count {
            retroPending = nil
            retroConfirmed = false
        }
    }

    // MARK: - Internals

    private func commit(_ text: String) {
        for part in text.split(separator: " ") {
            if learningEnabled { engine.learn(word: String(part), context: context) }
            context.append(normalize(String(part)))
        }
        if context.count > 3 { context.removeFirst(context.count - 3) }
    }

    private func refresh() {
        analysed = false
        pendingFix = nil
        if lazySuggestions {
            stale = true
        } else {
            updateSuggestions()
        }
    }

    /// Computes suggestions for the current state. Returns true if anything was recomputed.
    @discardableResult
    public func updateSuggestions() -> Bool {
        guard stale || !lazySuggestions else { return false }
        stale = false
        if retroDue {
            retroDue = false
            planRetro()
        }
        guard !dirty else {
            suggestions = []
            return true
        }
        if word.isEmpty {
            suggestions = suggestionsEnabled && !suppressed && predictionsEnabled && afterSpace
                ? engine.predictions(context: context).map { Suggestion(text: $0, isAutocorrect: false) }
                : []
        } else {
            let result = engine.analyze(typed: word, context: context, eager: eager)
            pendingFix = result.autocorrection
            analysed = true
            if !suggestionsEnabled || suppressed {
                suggestions = []
            } else {
                suggestions = autocorrectEnabled ? result.suggestions
                    : result.suggestions.map { Suggestion(text: $0.text, isAutocorrect: false) }
            }
        }
        return true
    }

    /// Types `text` through the session against an in-memory buffer and returns the resulting text.
    /// "\u{8}" is backspace and "\t" accepts the first suggestion. Used by tests and the eval tool.
    public func simulate(typing text: String) -> String {
        var buffer = ""
        seed(textBeforeCaret: "")
        func apply(_ e: Edit) {
            buffer.removeLast(min(e.deleteCount, buffer.count))
            buffer += e.insert
        }
        for ch in text {
            if needsSeed { seed(textBeforeCaret: buffer) }
            if let tail = pendingRetroTail { confirmRetro(matches: buffer.hasSuffix(tail)) }
            if let fix = takeRetro() {
                var chars = Array(buffer)
                let end = chars.count - fix.back
                chars.replaceSubrange((end - fix.deleteCount)..<end, with: Array(fix.insert))
                buffer = String(chars)
            }
            if ch == "\u{8}" {
                if let e = backspace() { apply(e) } else if !buffer.isEmpty { buffer.removeLast() }
            } else if ch == "\t" && (updateSuggestions() || true) && !suggestions.isEmpty {
                if let e = accept(0) { apply(e) }
            } else if kind(of: ch) == .delimiter {
                if let e = delimiter(ch) {
                    apply(e)
                    if e.repostKey { buffer.append(ch) }
                } else {
                    buffer.append(ch)
                    if let cand = doubleSpaceCandidate, buffer.hasSuffix(cand + "  ") {
                        buffer.removeLast(2)
                        buffer += ". "
                        appliedDoubleSpacePeriod()
                    }
                }
            } else {
                character(ch)
                buffer.append(ch)
            }
        }
        return buffer
    }
}
