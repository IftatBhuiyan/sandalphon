import SwiftUI
import UniformTypeIdentifiers

/// The settings window: a sidebar of pages, laid out like System Settings so nothing has to be learned.
struct MainView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { state.pane }, set: { state.pane = $0 ?? .overview })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch state.pane {
                case .overview: GeneralPane(state: state)
                case .typing: TypingPane(state: state)
                case .shortcuts: ShortcutsPane(state: state)
                case .apps: AppsPane(state: state)
                case .privacy: PrivacyPane(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(state.pane.title)
        }
        .frame(minWidth: 720, minHeight: 500)
    }
}

// MARK: - Shared pieces

/// A small grey note under a group, aligned with the rows above it.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
    }
}

/// A switch row with a title and an optional one-line explanation underneath, the System Settings way.
private struct SwitchRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

/// Shown at the top of the other pages until Sandalphon is allowed to see typing, since until then they do nothing.
private struct SetupBanner: View {
    @ObservedObject var state: AppState

    var body: some View {
        if !state.trusted {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sandalphon is not correcting anything yet")
                            .fontWeight(.medium)
                        Text("It needs Accessibility access first. These settings take effect once it has it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("Finish Setup") { state.pane = .overview }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Keys drawn as keycaps, so a shortcut reads as something to press rather than as text.
private struct Keys: View {
    let keys: [String]
    init(_ keys: String...) { self.keys = keys }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var state: AppState
    @State private var sample = ""

    private var statusColor: Color {
        state.isActive ? .green : (state.trusted ? .orange : .red)
    }

    private var statusDetail: String {
        if !state.trusted { return "Needs Accessibility access to work" }
        if !state.settings.enabled { return "Paused: your typing is left alone" }
        if !state.engineReady { return "Starting…" }
        if !state.settings.autocorrect { return "On, but Autocorrect is switched off under Typing" }
        return "On: correcting as you type, in every app"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sandalphon").font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 8, height: 8)
                            Text(statusDetail).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    if state.trusted {
                        Toggle("Correct my typing", isOn: Binding(get: { state.settings.enabled },
                                                                  set: { v in state.update { $0.enabled = v } }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .help(state.settings.enabled ? "Pause Sandalphon" : "Turn Sandalphon back on")
                    }
                }
                .padding(.vertical, 4)
            }

            if !state.trusted {
                AccessibilitySetup(state: state)
            }

            Section {
                TextEditor(text: $sample)
                    .font(.system(size: 14))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .overlay(alignment: .topLeading) {
                        if sample.isEmpty {
                            Text("Type here, mistakes and all: teh quick brown fox, i dont knwo…")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(!state.isActive)
            } header: {
                Text("Try it")
            } footer: {
                Note(!state.isActive ? "This works once Sandalphon is on."
                     : state.settings.autocorrect ? "Words are fixed when you press space. Press Delete straight after to undo one."
                     : "Autocorrect is off, so misspellings are left alone. Switch it on under Typing.")
            }

            Section("When Sandalphon runs") {
                SwitchRow(title: "Open at login",
                          isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                SwitchRow(title: "Turn off the macOS autocorrect",
                          detail: state.systemAutocorrectOff
                              ? "Recommended, so the two don't correct the same word. Open apps pick this up when they next start."
                              : "Recommended: otherwise macOS and Sandalphon may both change the same word. Open apps pick up a change when they next start.",
                          isOn: Binding(get: { state.systemAutocorrectOff }, set: { state.setSystemAutocorrectOff($0) }))
            }

            if state.updater != nil {
                Section("Updates") {
                    SwitchRow(title: "Check for updates automatically",
                              isOn: Binding(get: { state.automaticUpdates }, set: { state.setAutomaticUpdates($0) }))
                    LabeledContent(state.versionText) {
                        Button("Check Now") { state.checkForUpdates() }
                    }
                }
            }

            if !state.starNoteHidden {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "star")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Free and open source, with no tracking. A star on GitHub helps other people find it.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button("Star on GitHub") { state.openRepository() }
                        Button("Hide") { state.hideStarNote() }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The one thing that matters before anything else works: letting Sandalphon see typing.
private struct AccessibilitySetup: View {
    @ObservedObject var state: AppState

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("Allow Sandalphon to see what you type")
                    .font(.headline)
                Text("macOS asks for your permission before any app can read and correct typing. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    Step(number: 1, text: "Open Privacy & Security › Accessibility.")
                    Step(number: 2, text: "Switch Sandalphon on. If it is not in the list, drag the icon below into it.")
                    Step(number: 3, text: "Come back here. This page updates by itself.")
                }
                HStack(spacing: 16) {
                    Button("Open Accessibility Settings") { state.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    DraggableApp()
                    Spacer()
                }
                HStack(spacing: 4) {
                    Text("Switched on and nothing changed?")
                    Button("Restart Sandalphon") { state.relaunch() }.buttonStyle(.link)
                    Text("·")
                    Button("Show in Finder") { state.revealInFinder() }.buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private struct Step: View {
        let number: Int
        let text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The app's own icon, draggable as a file so it can be dropped into the System Settings list.
private struct DraggableApp: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 32, height: 32)
            Text("Drag me").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.tertiary))
        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
        .help("Drag into System Settings › Privacy & Security › Accessibility")
    }
}

// MARK: - Typing

private struct TypingPane: View {
    @ObservedObject var state: AppState

    private func binding(_ key: WritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { state.settings[keyPath: key] }, set: { v in state.update { $0[keyPath: key] = v } })
    }

    var body: some View {
        Form {
            SetupBanner(state: state)

            Section {
                SwitchRow(title: "Autocorrect",
                          detail: "Fixes misspelled words when you press space, only when it is sure.",
                          isOn: binding(\.autocorrect))
                SwitchRow(title: "Go back and fix earlier words",
                          detail: "When the next words show one was wrong: “got it form the shop” → from.",
                          isOn: binding(\.retro))
                    .disabled(!state.settings.autocorrect)
            } header: {
                Text("Corrections")
            }

            Section {
                SwitchRow(title: "Capitalise sentences",
                          detail: "The first word of a message and after . ? !",
                          isOn: binding(\.capitalizeSentences))
                SwitchRow(title: "Capitalise names and places",
                          detail: "london → London, friday → Friday, iphone → iPhone",
                          isOn: binding(\.capitalizeNames))
                SwitchRow(title: "Fix common grammar slips",
                          detail: "could of → could have, a apple → an apple, repeated words",
                          isOn: binding(\.grammar))
                SwitchRow(title: "Double space adds a full stop",
                          isOn: binding(\.doubleSpacePeriod))
            } header: {
                Text("Capitals and grammar")
            } footer: {
                if !state.settings.autocorrect {
                    Note("Turn on Autocorrect to use these.")
                }
            }
            .disabled(!state.settings.autocorrect)

            Section {
                Picker("Show suggestions", selection: Binding(get: { state.settings.mode },
                                                              set: { v in state.update { $0.mode = v } })) {
                    Text("Only when I press ⌥ Esc").tag(SuggestMode.onDemand)
                    Text("While I type").tag(SuggestMode.whileTyping)
                    Text("Never").tag(SuggestMode.never)
                }
                if state.settings.mode == .whileTyping {
                    SwitchRow(title: "Suggest the next word",
                              detail: "After a space, offers the words most likely to come next.",
                              isOn: binding(\.predictions))
                }
                if state.settings.mode != .never {
                    SwitchRow(title: "Tab takes the highlighted suggestion",
                              detail: "In one-line fields Tab moves to the next field, unless you asked for suggestions with ⌥ Esc.",
                              isOn: binding(\.tabAccepts))
                }
            } header: {
                Text("Suggestions")
            } footer: {
                Note("To fix a whole selection at once, right-click it and choose Services › Fix Typos with Sandalphon.")
            }

            Section("Keys") {
                LabeledContent("Undo a correction, straight after it") { Keys("Delete") }
                LabeledContent("Undo the latest correction, from anywhere") { Keys("⌃", "⌥", "Z") }
                if state.settings.mode != .never {
                    LabeledContent("Show suggestions for the word at the caret") { Keys("⌥", "Esc") }
                    LabeledContent("Pick a suggestion") { Keys("⌃1", "⌃2", "⌃3") }
                    LabeledContent("Hide suggestions") { Keys("Esc") }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps

private struct AppsPane: View {
    @ObservedObject var state: AppState

    private struct Entry: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
    }

    /// Excluded apps that are installed on this Mac. Ids of apps that are not installed stay in the list unseen.
    private var entries: [Entry] {
        state.settings.excluded.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return Entry(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                         icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Default exclusions that were removed and whose app is installed, so restoring them would change something.
    private var removedDefaults: [String] {
        Settings.defaultExcluded.filter {
            !state.settings.excluded.contains($0) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    var body: some View {
        Form {
            SetupBanner(state: state)

            Section {
                let list = entries
                if list.isEmpty {
                    Text("No apps in this list.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                } else {
                    ForEach(list) { entry in
                        HStack(spacing: 10) {
                            Image(nsImage: entry.icon).resizable().frame(width: 24, height: 24)
                            Text(entry.name)
                            Spacer()
                            Button {
                                state.toggleExcluded(entry.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .help("Turn Sandalphon back on in \(entry.name)")
                            .accessibilityLabel("Turn Sandalphon back on in \(entry.name)")
                        }
                    }
                }
            } header: {
                Text("Off in these apps")
            } footer: {
                HStack {
                    Button("Add App…", action: add)
                    if !removedDefaults.isEmpty {
                        Button("Restore Defaults") {
                            state.update { s in s.excluded.formUnion(Settings.defaultExcluded) }
                        }
                        .help("Turn Sandalphon off again in the terminals, code editors and password managers it skips by default.")
                    }
                    Spacer()
                }
            }

            Section {
                Label("Terminals, code editors and password managers start in this list, since correcting prose there gets in the way.",
                      systemImage: "info.circle")
                Label("Password fields and search fields are always left alone, in every app.", systemImage: "lock")
                Label("To switch the app you are in on or off quickly, use the menu bar icon.", systemImage: "menubar.arrow.up.rectangle")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func add() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.application]
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.allowsMultipleSelection = true
        open.prompt = "Turn Off in These Apps"
        guard open.runModal() == .OK else { return }
        for url in open.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !state.settings.excluded.contains(id) {
                state.toggleExcluded(id)
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject var state: AppState
    @State private var editing: Shortcut?
    @State private var selection: Shortcut.ID?

    var body: some View {
        Form {
            SetupBanner(state: state)
            Section {
                if state.shortcuts.isEmpty {
                    VStack(spacing: 4) {
                        Text("No shortcuts yet")
                        Text("For example, ;addr for your address or ;sig for your email signature.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                } else {
                    ForEach(state.shortcuts) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(s.key)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 110, alignment: .leading)
                            Text(s.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit") { editing = s }
                                .buttonStyle(.borderless)
                            Button {
                                state.updateShortcuts(state.shortcuts.filter { $0.id != s.id })
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(s.key)")
                            .accessibilityLabel("Remove \(s.key)")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = s }
                    }
                }
            } header: {
                Text("Your shortcuts")
            } footer: {
                HStack {
                    Button("Add Shortcut…") { editing = Shortcut(key: "", text: "") }
                    Button("Show File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ShortcutStore.url])
                    }
                    .disabled(state.shortcuts.isEmpty)
                    Spacer()
                }
            }
            Section {
                Label("Type a shortcut on its own, then a space or punctuation, and it becomes its text.", systemImage: "text.cursor")
                Label("Press Delete straight after to put the shortcut back.", systemImage: "delete.left")
                Label("Kept in one file on this Mac and never sent anywhere.", systemImage: "lock")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { s in
            ShortcutEditor(shortcut: s, takenKeys: state.shortcuts.filter { $0.id != s.id }.map(\.key)) { saved in
                var list = state.shortcuts
                if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                state.updateShortcuts(list)
            }
        }
    }
}

private struct ShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var shortcut: Shortcut
    let takenKeys: [String]
    let save: (Shortcut) -> Void

    private var problem: String? { ShortcutStore.problem(with: shortcut.key, others: takenKeys) }
    private var looksLikeWord: Bool { !shortcut.key.isEmpty && shortcut.key.allSatisfy(\.isLetter) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(takenKeys.count == 0 && shortcut.key.isEmpty ? "New Shortcut" : "Shortcut")
                .font(.headline)
            LabeledContent("Shortcut") {
                TextField("", text: $shortcut.key, prompt: Text(";addr"))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 200)
            }
            if let problem, !shortcut.key.isEmpty {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else if looksLikeWord {
                Text("If you ever type “\(shortcut.key)” as a word, it will be expanded. Starting with a symbol, like ;\(shortcut.key), avoids that.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Text").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $shortcut.text)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(shortcut)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || shortcut.text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @ObservedObject var state: AppState
    @State private var confirming = false
    @State private var confirmingShortcuts = false

    var body: some View {
        Form {
            SetupBanner(state: state)
            Section("Your typing stays on this Mac") {
                Label("Nothing you type is ever sent anywhere. The only network use is checking GitHub for a newer version, which you can switch off under General. There are no analytics, no usage counts and no crash reports.", systemImage: "lock")
                Label("It never sees password fields: macOS blocks them for every app.", systemImage: "key")
                Label("It remembers words and short phrases you use more than once, so suggestions fit how you write. A word or phrase typed only once is not saved, except a word whose correction you undid, so it is left alone next time. The file is kept out of Time Machine.", systemImage: "brain")
                Label("Text shortcuts are kept in their own file, containing only what you entered in Settings › Shortcuts.", systemImage: "text.badge.plus")
            }
            Section("Text shortcuts") {
                LabeledContent("Shortcuts saved") {
                    HStack(spacing: 8) {
                        Text(state.shortcuts.count.formatted()).foregroundStyle(.secondary)
                        Button("Delete All…", role: .destructive) { confirmingShortcuts = true }
                            .disabled(state.shortcuts.isEmpty)
                    }
                }
            }
            Section {
                LabeledContent("Words learned", value: state.learnedWords.formatted())
                HStack {
                    Button("Show File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([state.userModelURL])
                    }
                    Spacer()
                    Button("Forget Everything…", role: .destructive) { confirming = true }
                }
            } header: {
                Text("Learned from you")
            } footer: {
                Note("Includes the spelling and grammar fixes you undid, so they are not made again.")
            }
            Section {
                LabeledContent("Accessibility access") {
                    HStack(spacing: 8) {
                        Text(state.trusted ? "Allowed" : "Not allowed").foregroundStyle(.secondary)
                        Button("Open Settings…") { NSWorkspace.shared.open(AppState.accessibilityURL) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget everything Sandalphon has learned from your typing?", isPresented: $confirming) {
            Button("Forget Everything", role: .destructive) { state.forgetLearned() }
        } message: {
            Text("Learned words, phrases and the corrections you undid will be erased. This cannot be undone.")
        }
        .confirmationDialog("Delete all your text shortcuts?", isPresented: $confirmingShortcuts) {
            Button("Delete All Shortcuts", role: .destructive) { state.updateShortcuts([]) }
        } message: {
            Text("Their file is removed. This cannot be undone.")
        }
    }
}
