import AppKit
import ApplicationServices
import ServiceManagement
import Sparkle
import TypeEngine

enum Pane: String, CaseIterable, Identifiable {
    case overview, typing, apps, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .typing: return "Typing"
        case .apps: return "Apps"
        case .privacy: return "Privacy"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "checkmark.seal"
        case .typing: return "keyboard"
        case .apps: return "square.grid.2x2"
        case .privacy: return "hand.raised"
        }
    }
}

/// Everything the windows and the menu show, and the actions behind them. Main thread only.
final class AppState: ObservableObject {
    @Published var settings = Settings()
    @Published var trusted = AXIsProcessTrusted()
    @Published var engineReady = false
    @Published var systemAutocorrectOff = false
    @Published var launchAtLogin = false
    @Published var learnedWords = 0
    @Published var pane: Pane = .overview

    /// Checks GitHub for new releases. Only started in a real app bundle with a feed configured.
    let updater: SPUStandardUpdaterController? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    @Published var automaticUpdates = true
    /// Whether the "star on GitHub" note on the Overview page has been hidden. Kept on this Mac only.
    @Published var starNoteHidden = UserDefaults.standard.bool(forKey: "starNoteHidden")
    static let repositoryURL = URL(string: "https://github.com/IftatBhuiyan/sandalphon")!

    let panel = SuggestionPanel()
    lazy var controller = Controller(panel: panel)
    private var tapRunning = false
    private var engineLoading = false
    private let defaults = UserDefaults.standard

    static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let keyboardURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
    static let loginItemsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    var userModelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sandalphon/user.json")
    }

    /// One line describing what Sandalphon is doing right now.
    var statusText: String {
        if !trusted { return "Needs Accessibility access" }
        if !settings.enabled { return "Paused" }
        if !engineReady { return "Starting…" }
        return "On"
    }

    var isActive: Bool { trusted && settings.enabled && engineReady }

    init() {
        defaults.register(defaults: ["enabled": true, "autocorrect": true, "suggestMode": SuggestMode.onDemand.rawValue, "predictions": true,
                                     "tabAccepts": true, "capitalizeSentences": true, "capitalizeNames": true, "grammar": true,
                                     "doubleSpacePeriod": true, "retro": true])
        settings.enabled = defaults.bool(forKey: "enabled")
        settings.autocorrect = defaults.bool(forKey: "autocorrect")
        settings.mode = SuggestMode(rawValue: defaults.integer(forKey: "suggestMode")) ?? .onDemand
        settings.predictions = defaults.bool(forKey: "predictions")
        settings.tabAccepts = defaults.bool(forKey: "tabAccepts")
        settings.capitalizeSentences = defaults.bool(forKey: "capitalizeSentences")
        settings.capitalizeNames = defaults.bool(forKey: "capitalizeNames")
        settings.grammar = defaults.bool(forKey: "grammar")
        settings.doubleSpacePeriod = defaults.bool(forKey: "doubleSpacePeriod")
        settings.retro = defaults.bool(forKey: "retro")
        if let list = defaults.stringArray(forKey: "excluded") { settings.excluded = Set(list) }
        automaticUpdates = updater?.updater.automaticallyChecksForUpdates ?? false
        refresh()
    }

    // MARK: - Polling

    /// Called every second: picks up permission changes and starts the key tap as soon as it is allowed.
    func refresh() {
        let now = AXIsProcessTrusted()
        if now != trusted { trusted = now }
        if now && !tapRunning { startTap() }
        let off = readSystemAutocorrectOff()
        if off != systemAutocorrectOff { systemAutocorrectOff = off }
        let login = SMAppService.mainApp.status == .enabled
        if login != launchAtLogin { launchAtLogin = login }
        controller.learnedCount { [weak self] n in if self?.learnedWords != n { self?.learnedWords = n } }
        controller.saveIfIdle()
    }

    private func startTap() {
        guard controller.start() else { return }
        tapRunning = true
        pushSettings()
        guard !engineLoading else { return }
        engineLoading = true
        let url = userModelURL
        DispatchQueue.global(qos: .userInitiated).async {
            guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Data"),
                  let engine = try? Engine(dataDirectory: dir, user: UserModel.load(from: url)) else {
                NSLog("Sandalphon: could not load language data")
                return
            }
            NSFullUserName().split(separator: " ").forEach { engine.addName(String($0)) }
            DispatchQueue.main.async {
                self.controller.install(engine: engine, userModelURL: url)
                self.engineReady = true
            }
        }
    }

    // MARK: - Settings

    func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        defaults.set(settings.enabled, forKey: "enabled")
        defaults.set(settings.autocorrect, forKey: "autocorrect")
        defaults.set(settings.mode.rawValue, forKey: "suggestMode")
        defaults.set(settings.predictions, forKey: "predictions")
        defaults.set(settings.tabAccepts, forKey: "tabAccepts")
        defaults.set(settings.capitalizeSentences, forKey: "capitalizeSentences")
        defaults.set(settings.capitalizeNames, forKey: "capitalizeNames")
        defaults.set(settings.grammar, forKey: "grammar")
        defaults.set(settings.doubleSpacePeriod, forKey: "doubleSpacePeriod")
        defaults.set(settings.retro, forKey: "retro")
        defaults.set(Array(settings.excluded), forKey: "excluded")
        pushSettings()
    }

    private func pushSettings() {
        controller.update(settings: settings)
        if let front = NSWorkspace.shared.frontmostApplication {
            controller.frontmostChanged(bundleID: front.bundleIdentifier, pid: front.processIdentifier)
        }
    }

    func toggleExcluded(_ bundleID: String) {
        update { s in
            if s.excluded.contains(bundleID) { s.excluded.remove(bundleID) } else { s.excluded.insert(bundleID) }
        }
    }

    // MARK: - Permissions

    /// Makes macOS add Sandalphon to the Accessibility list (switched off) and opens that list.
    func requestAccessibility() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        NSWorkspace.shared.open(AppState.accessibilityURL)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func relaunch() {
        controller.saveIfIdle(force: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - macOS built-in autocorrect

    private let systemKeys = ["NSAutomaticSpellingCorrectionEnabled", "WebAutomaticSpellingCorrectionEnabled",
                              "NSAutomaticInlinePredictionEnabled"]

    private func readSystemAutocorrectOff() -> Bool {
        systemKeys.allSatisfy {
            (CFPreferencesCopyValue($0 as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                    kCFPreferencesAnyHost) as? Bool) == false
        }
    }

    /// Turns the built-in autocorrect and inline predictions off, or back to their defaults, so the two do
    /// not fight. Apps pick the change up the next time they launch.
    func setSystemAutocorrectOff(_ off: Bool) {
        let value: CFPropertyList? = off ? kCFBooleanFalse : nil
        for key in systemKeys {
            CFPreferencesSetValue(key as CFString, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                  kCFPreferencesAnyHost)
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        systemAutocorrectOff = readSystemAutocorrectOff()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Sandalphon: login item change failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setAutomaticUpdates(_ on: Bool) {
        updater?.updater.automaticallyChecksForUpdates = on
        automaticUpdates = updater?.updater.automaticallyChecksForUpdates ?? false
    }

    /// Opens the project page in the browser. Nothing is sent from the app itself.
    func openRepository() { NSWorkspace.shared.open(AppState.repositoryURL) }

    func hideStarNote() {
        starNoteHidden = true
        defaults.set(true, forKey: "starNoteHidden")
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates(nil)
    }

    var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Version \(v)"
    }

    func forgetLearned() {
        controller.forgetLearned()
        learnedWords = 0
    }
}
