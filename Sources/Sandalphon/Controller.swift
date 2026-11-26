import AppKit
import Carbon.HIToolbox
import TypeEngine

/// User-facing switches, shared between the menu (main thread) and the key thread.
/// When the suggestion bar is allowed to appear.
enum SuggestMode: Int {
    case never = 0, onDemand = 1, whileTyping = 2
}

struct Settings {
    var enabled = true
    var autocorrect = true
    /// Quiet by default: nothing appears unless the user asks with the shortcut.
    var mode = SuggestMode.onDemand
    var predictions = true
    var tabAccepts = true
    var capitalizeSentences = true
    var capitalizeNames = true
    var grammar = true
    var doubleSpacePeriod = true
    var retro = true
    var excluded: Set<String> = Settings.defaultExcluded

    /// Terminals, code editors and password managers: prose correction does more harm than good there.
    static let defaultExcluded: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "dev.warp.Warp-Stable", "com.apple.dt.Xcode", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "com.panic.Nova",
        "com.1password.1password", "com.apple.keychainaccess", "com.apple.Spotlight",
    ]

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excluded.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }
}

/// Owns the keyboard event tap and everything that reacts to a keystroke.
///
/// Threading: the tap, the `TypingSession` and the engine all live on one dedicated high-priority thread.
/// A key is handled with in-memory work only and released immediately; suggestions are computed after the
/// key has been passed on, Accessibility is queried on a separate queue, and the panel is drawn on main.
final class Controller {
    private static let marker: Int64 = 0x53414E44 // tags events we post ourselves

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var session: TypingSession?
    private var settings = Settings()
    private var appExcluded = false
    private var handsOff = false          // secure or search field
    private var singleLine = false
    /// We started typing without knowing what is in the field; keep trying to find out between keys.
    private var blind = false
    private var generation: UInt64 = 0
    private var lastKey = Date.distantPast
    /// The user pressed the shortcut: show suggestions until this word is finished.
    private var requested = false
    /// Alternatives for a selected word; picking one types over the selection.
    private var selectionItems: [Suggestion]?
    private let source = CGEventSource(stateID: .combinedSessionState)

    private let reader = FocusReader()
    private let translator = KeyTranslator()
    private let axQueue = DispatchQueue(label: "sandalphon.ax", qos: .userInitiated)
    private let panel: SuggestionPanel
    private let panelLock = NSLock()
    private var panelShown = false
    private var userModelURL: URL?

    init(panel: SuggestionPanel) {
        self.panel = panel
        panel.onPick = { [weak self] i in self?.onKeyThread { self?.accept(i, viaClick: true) } }
    }

    // MARK: - Lifecycle (main thread)

    /// Creates the event tap. Returns false if macOS has not granted Accessibility yet.
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let controller = Unmanaged<Controller>.fromOpaque(refcon!).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            let src = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "sandalphon.keys"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        ready.wait()
        return true
    }

    func install(engine: Engine, userModelURL: URL) {
        onKeyThread {
            let s = TypingSession(engine: engine)
            s.lazySuggestions = true
            self.session = s
            self.userModelURL = userModelURL
            self.applySettings()
        }
    }

    func update(settings: Settings) {
        onKeyThread {
            self.settings = settings
            self.applySettings()
            self.caretMoved()
        }
    }

    func frontmostChanged(bundleID: String?, pid: pid_t) {
        axQueue.async { self.reader.prepare(pid: pid) }
        onKeyThread {
            self.appExcluded = self.settings.isExcluded(bundleID)
            self.caretMoved()
        }
    }

    /// A click somewhere: the caret may be anywhere now.
    func mouseDown() {
        onKeyThread { self.caretMoved() }
    }

    /// Writes what has been learned, but only while the keyboard is idle so a save never delays a key.
    func saveIfIdle(force: Bool = false) {
        onKeyThread {
            guard let url = self.userModelURL, let s = self.session else { return }
            if force || Date().timeIntervalSince(self.lastKey) > 4 { s.engine.user.save(to: url) }
        }
    }

    /// Number of distinct words learned so far, delivered on the main thread.
    func learnedCount(_ completion: @escaping (Int) -> Void) {
        guard runLoop != nil else { return completion(0) }
        onKeyThread {
            let n = self.session?.engine.user.words.count ?? 0
            DispatchQueue.main.async { completion(n) }
        }
    }

    func forgetLearned() {
        onKeyThread {
            guard let url = self.userModelURL, let s = self.session else { return }
            s.engine.user.clear()
            s.engine.user.save(to: url)
            self.caretMoved()
        }
    }

    private func onKeyThread(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - Key thread

    private func applySettings() {
        session?.autocorrectEnabled = settings.autocorrect
        session?.suggestionsEnabled = settings.mode != .never
        session?.predictionsEnabled = settings.predictions
        session?.capitalizeSentences = settings.capitalizeSentences
        session?.grammarEnabled = settings.grammar
        session?.doubleSpacePeriod = settings.doubleSpacePeriod
        session?.retroEnabled = settings.retro
        session?.engine.capitalizeNames = settings.capitalizeNames
    }

    private var active: Bool { settings.enabled && !appExcluded && session != nil }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != Controller.marker,
              active, let session else { return pass }
        generation &+= 1
        lastKey = Date()
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Option-Escape, the classic macOS "complete this word" key, asks for suggestions.
        if code == kVK_Escape, flags.contains(.maskAlternate), !flags.contains(.maskCommand), settings.mode != .never {
            summon()
            return nil
        }
        if selectionItems != nil {
            let picking = code == kVK_Tab || code == kVK_Escape || code == kVK_Return ||
                (flags.contains(.maskControl) && [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3].contains(code))
            if !picking { endSelectionMode() }
        }

        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            if flags.contains(.maskControl), !flags.contains(.maskCommand), isPanelShown,
               let i = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3].firstIndex(of: code), i < currentItems.count {
                accept(i, viaClick: false)
                return nil
            }
            caretMoved()
            return pass
        }

        switch code {
        case kVK_Tab:
            if settings.tabAccepts, !singleLine || requested, isPanelShown, !flags.contains(.maskShift) {
                session.updateSuggestions()
                if !currentItems.isEmpty {
                    accept(0, viaClick: false)
                    return nil
                }
            }
            caretMoved()
            return pass
        case kVK_Escape:
            if isPanelShown {
                if selectionItems != nil { endSelectionMode() } else { session.dismiss() }
                requested = false
                session.eager = false
                publish()
                return nil
            }
            return pass
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
             kVK_ForwardDelete:
            caretMoved()
            return pass
        case kVK_Delete:
            if flags.contains(.maskAlternate) {
                caretMoved()
                return pass
            }
            if let edit = session.backspace() {
                inject(edit, then: nil)
                afterKey()
                return nil
            }
            if session.needsSeed { caretMoved() } else { afterKey() }
            return pass
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if selectionItems != nil, isPanelShown {
                accept(0, viaClick: false)
                return nil
            }
            let edit = handsOff ? nil : session.delimiter("\n")
            hidePanel()
            requestSeed()
            if let edit {
                inject(edit, then: event)
                return nil
            }
            return pass
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return pass } // dead key: the real character comes with the next press
        var string = String(utf16CodeUnits: chars, count: length)
        // If the event's text is just what the bare key produces, work out what the key plus its modifiers
        // really types. Text that has nothing to do with the key code was put there on purpose (dictation,
        // text expanders) and is taken as is.
        if let typed = translator.string(keyCode: code, flags: flags),
           string == typed || string == translator.string(keyCode: code, flags: []) {
            string = typed
        }
        guard string.count == 1, let ch = string.first, let scalar = ch.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value) else {
            return pass
        }
        if handsOff { return pass }
        // We never wait for another app here. If the field has not been read yet, stay out of the way
        // until the next space, from which point everything before the caret is known from the keys alone.
        if session.needsSeed {
            session.seed(textBeforeCaret: nil)
            blind = true
        }
        if blind { requestSeed(after: 0.03) }

        // A revision to an earlier word that has been checked against the field goes in now, ahead of this
        // key, so it can never interleave with what is being typed.
        var held = false
        if let fix = session.takeRetro() {
            inject(fix)
            held = true
        }
        if session.kind(of: ch) == .delimiter {
            requested = false
            session.eager = false
            let edit = session.delimiter(ch)
            if session.doubleSpaceCandidate != nil { checkDoubleSpace() }
            afterKey()
            if let edit {
                inject(edit, then: event)
                return nil
            }
        } else {
            session.character(ch)
            afterKey()
        }
        if held {
            // This key has to arrive after the revision, so send it down the same path.
            inject(Edit(deleteCount: 0, insert: "", repostKey: true), then: event)
            return nil
        }
        return pass
    }

    private var currentItems: [Suggestion] { selectionItems ?? session?.suggestions ?? [] }

    private func accept(_ index: Int, viaClick: Bool) {
        guard let session else { return }
        generation &+= 1
        if let items = selectionItems {
            guard items.indices.contains(index) else { return }
            // Typing over a selection replaces it.
            inject(Edit(deleteCount: 0, insert: items[index].text, repostKey: false), then: nil)
            endSelectionMode()
            caretMoved()
            return
        }
        guard let edit = session.accept(index) else { return }
        requested = false
        session.eager = false
        inject(edit, then: nil)
        afterKey()
    }

    private func endSelectionMode() {
        selectionItems = nil
        requested = false
        hidePanel()
    }

    /// Shows suggestions because the user asked: alternatives for a selected word, otherwise options for
    /// the word at the caret.
    private func summon() {
        generation &+= 1
        let gen = generation
        axQueue.async {
            let info = self.reader.read()
            self.onKeyThread {
                guard gen == self.generation, let session = self.session else { return }
                self.noteField(info)
                if self.handsOff { return }
                let anchor = self.anchor(for: info)
                var items: [Suggestion] = []
                if let selected = info?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
                    if selected.count <= 24, selected.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) {
                        items = session.engine.alternatives(for: selected, context: [])
                            .map { Suggestion(text: $0, isAutocorrect: false) }
                    }
                    self.selectionItems = items.isEmpty ? nil : items
                } else {
                    if session.needsSeed, info?.selectionLength == 0 { session.seed(textBeforeCaret: info?.textBefore) }
                    session.eager = true
                    session.updateSuggestions()
                    items = session.suggestions
                }
                self.requested = !items.isEmpty
                let tabHint = self.settings.tabAccepts
                self.setShown(!items.isEmpty)
                DispatchQueue.main.async {
                    if items.isEmpty {
                        self.panel.flash("No suggestions", anchor: anchor)
                    } else {
                        self.panel.hide()
                        self.panel.show(items, tabHint: tabHint, anchor: anchor)
                        self.setShown(self.panel.isVisible)
                    }
                }
            }
        }
    }

    private func anchor(for info: FocusInfo?) -> CGRect? {
        // Without a caret position, sit just above the field rather than over the text in it.
        info?.caret ?? info?.frame.map { CGRect(x: $0.minX, y: $0.maxY + 34, width: 1, height: 1) }
    }

    /// Steps back to an earlier word, replaces it, and returns to where the caret was.
    private func inject(_ fix: TypingSession.RetroFix) {
        func tap(_ key: Int, times: Int) {
            for _ in 0..<times {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
                    e?.flags = []
                    e?.setIntegerValueField(.eventSourceUserData, value: Controller.marker)
                    e?.post(tap: .cgSessionEventTap)
                }
            }
        }
        tap(kVK_LeftArrow, times: fix.back)
        inject(Edit(deleteCount: fix.deleteCount, insert: fix.insert, repostKey: false), then: nil)
        tap(kVK_RightArrow, times: fix.back)
    }

    /// Replaces text before the caret by posting synthetic keys, then optionally re-sends the triggering key.
    private func inject(_ edit: Edit, then original: CGEvent?) {
        func post(_ e: CGEvent?) {
            guard let e else { return }
            e.setIntegerValueField(.eventSourceUserData, value: Controller.marker)
            e.post(tap: .cgSessionEventTap)
        }
        for _ in 0..<edit.deleteCount {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: down)
                e?.flags = []
                post(e)
            }
        }
        var units = Array(edit.insert.utf16)
        while !units.isEmpty {
            let chunk = Array(units.prefix(20))
            units.removeFirst(chunk.count)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(e)
            }
        }
        if edit.repostKey, let original { post(original.copy()) }
    }

    /// Two spaces after a word become ". ", but only once the field is confirmed to end that way (macOS
    /// does the same thing itself in some apps, and then there is nothing left for us to do).
    private func checkDoubleSpace() {
        let gen = generation
        axQueue.asyncAfter(deadline: .now() + 0.03) {
            guard gen == self.generation else { return }
            let info = self.reader.read()
            self.onKeyThread {
                // Browsers store runs of spaces as non-breaking spaces.
                guard gen == self.generation, let session = self.session, let word = session.doubleSpaceCandidate,
                      info?.selectionLength == 0,
                      let text = info?.textBefore?.replacingOccurrences(of: "\u{00A0}", with: " "),
                      text.hasSuffix(word + "  ") else { return }
                self.generation &+= 1
                self.inject(Edit(deleteCount: 2, insert: ". ", repostKey: false), then: nil)
                session.appliedDoubleSpacePeriod()
            }
        }
    }

    /// The caret may have moved: drop what we know and look at the field again shortly.
    private func caretMoved() {
        generation &+= 1
        requested = false
        selectionItems = nil
        blind = false
        session?.eager = false
        session?.reset()
        hidePanel()
        requestSeed()
    }

    /// Reads the text before the caret in the background. Applied only if no key arrived in the meantime.
    private func requestSeed(after delay: TimeInterval = 0.06) {
        guard active else { return }
        let gen = generation
        axQueue.asyncAfter(deadline: .now() + delay) {
            let info = self.reader.read()
            self.onKeyThread {
                guard gen == self.generation, let session = self.session else { return }
                self.noteField(info)
                if self.handsOff { return }
                let usable = info?.selectionLength == 0 ? info?.textBefore : nil
                if usable == nil && self.blind { return } // still nothing to go on; keep the hands-off state
                session.seed(textBeforeCaret: usable)
                self.blind = usable == nil
                if usable != nil { session.updateSuggestions() }
            }
        }
    }

    private func noteField(_ info: FocusInfo?) {
        handsOff = info.map { $0.isSecure || $0.isSearch } ?? false
        singleLine = info?.isSingleLine ?? false
        session?.capitalizeFieldStart = !singleLine
    }

    /// Runs once the key has been released to the app: compute suggestions, then locate the caret and
    /// check that the field really contains what we think was typed.
    private func afterKey() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            guard let session else { return }
            session.updateSuggestions()
            publish()
            verify(generation: generation, attempt: 0)
        }
    }

    private func verify(generation gen: UInt64, attempt: Int) {
        axQueue.asyncAfter(deadline: .now() + (attempt == 0 ? 0.012 : 0.045)) {
            guard gen == self.generation else { return }
            let info = self.reader.read()
            self.onKeyThread {
                guard gen == self.generation, let session = self.session else { return }
                self.noteField(info)
                if self.handsOff {
                    session.seed(textBeforeCaret: nil)
                    self.hidePanel()
                    return
                }
                if let text = info?.textBefore {
                    let seen = text.replacingOccurrences(of: "\u{2019}", with: "'")
                    let expected = session.word.replacingOccurrences(of: "\u{2019}", with: "'")
                    if info?.selectionLength != 0 || !seen.hasSuffix(expected) {
                        if attempt == 0 {
                            self.verify(generation: gen, attempt: 1) // the app may just be slow to draw the key
                        } else {
                            Debug.log("mismatch: hands off (selection=\(info?.selectionLength ?? -1))")
                            session.seed(textBeforeCaret: nil)        // not what we expected: hands off
                            self.hidePanel()
                        }
                        return
                    }
                }
                // A revision of an earlier word is only allowed once the field is known to end with exactly
                // what we believe was typed.
                if let tail = session.pendingRetroTail {
                    let seen = info?.textBefore?.replacingOccurrences(of: "\u{2019}", with: "'")
                        .replacingOccurrences(of: "\u{00A0}", with: " ")
                    session.confirmRetro(matches: seen?.hasSuffix(tail.replacingOccurrences(of: "\u{2019}", with: "'")) ?? false)
                }
                let anchor = self.anchor(for: info)
                Debug.log("verify role=\(info?.role ?? "-") caret=\(info?.caret.map { "\($0)" } ?? "nil") frame=\(info?.frame.map { "\($0)" } ?? "nil") text=\(info?.textBefore != nil) items=\(session.suggestions.count)")
                if let anchor, !session.suggestions.isEmpty, self.wantsBar {
                    DispatchQueue.main.async { self.panel.move(to: anchor); self.setShown(self.panel.isVisible) }
                }
            }
        }
    }

    // MARK: - Panel

    private var isPanelShown: Bool {
        panelLock.lock(); defer { panelLock.unlock() }
        return panelShown
    }

    private func setShown(_ shown: Bool) {
        panelLock.lock(); panelShown = shown; panelLock.unlock()
    }

    /// The bar only appears while typing if the user chose that; otherwise only after the shortcut.
    private var wantsBar: Bool { settings.mode == .whileTyping || (settings.mode == .onDemand && requested) }

    private func publish() {
        if selectionItems != nil { return }
        let items = wantsBar ? (session?.suggestions ?? []) : []
        let tabHint = settings.tabAccepts && (!singleLine || requested)
        if items.isEmpty { setShown(false) }
        DispatchQueue.main.async {
            self.panel.show(items, tabHint: tabHint, anchor: nil)
            self.setShown(self.panel.isVisible)
        }
    }

    /// Corrects every typo in a piece of text (the right-click service). Blocks the caller briefly.
    func fixTypos(in text: String) -> String {
        guard let runLoop else { return text }
        var result = text
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            if let engine = self.session?.engine {
                let scratch = TypingSession(engine: engine)
                scratch.learningEnabled = false
                scratch.suggestionsEnabled = false
                let fixed = scratch.simulate(typing: text + " ")
                result = String(fixed.dropLast())
            }
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        _ = done.wait(timeout: .now() + 2)
        return result
    }

    private func hidePanel() {
        setShown(false)
        DispatchQueue.main.async { self.panel.hide() }
    }
}

/// Optional diagnostics (`defaults write app.sandalphon.Sandalphon debugLog -bool true`).
/// Records geometry and state only, never the text being typed.
enum Debug {
    static let enabled = UserDefaults.standard.bool(forKey: "debugLog")
    private static let url = FileManager.default.temporaryDirectory.appendingPathComponent("sandalphon-debug.log")
    private static let queue = DispatchQueue(label: "sandalphon.debug")

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = message() + "\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
