import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { state.pane }, set: { state.pane = $0 ?? .overview })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch state.pane {
                case .overview: OverviewPane(state: state)
                case .typing: TypingPane(state: state)
                case .apps: AppsPane(state: state)
                case .privacy: PrivacyPane(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 500)
    }
}

// MARK: - Overview

private struct OverviewPane: View {
    @ObservedObject var state: AppState
    @State private var sample = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sandalphon").font(.title2.weight(.semibold))
                        HStack(spacing: 6) {
                            Circle().fill(state.isActive ? Color.green : (state.trusted ? Color.orange : Color.red))
                                .frame(width: 8, height: 8)
                            Text(state.statusText).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { state.settings.enabled }, set: { v in state.update { $0.enabled = v } }))
                        .toggleStyle(.switch).labelsHidden().disabled(!state.trusted)
                }
                .padding(.vertical, 4)
            }

            Section("Setup") {
                StepRow(done: state.trusted, title: "Allow Accessibility access",
                        detail: state.trusted
                            ? "Sandalphon can see what you type and fix it in place."
                            : "macOS needs your permission before any app can read and correct typing. Open the list and switch Sandalphon on. If it is not listed, drag the icon below into the list.") {
                    if !state.trusted {
                        Button("Open Accessibility Settings") { state.requestAccessibility() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if !state.trusted {
                    HStack(spacing: 12) {
                        DraggableApp()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Drag this into the Accessibility list").font(.callout)
                            HStack {
                                Button("Show in Finder") { state.revealInFinder() }
                                Button("Restart Sandalphon") { state.relaunch() }
                                    .help("Use this if you switched it on and the status above has not changed.")
                            }
                            .controlSize(.small)
                        }
                    }
                }
                StepRow(done: state.systemAutocorrectOff, title: "Turn off the built-in macOS autocorrect",
                        detail: "Otherwise both will try to correct the same word. Apps pick this up the next time they open. Switching it back restores the macOS defaults.") {
                    Toggle("", isOn: Binding(get: { state.systemAutocorrectOff }, set: { state.setSystemAutocorrectOff($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                StepRow(done: state.launchAtLogin, title: "Open at login",
                        detail: "Start Sandalphon automatically so it is always there.") {
                    Toggle("", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            if state.updater != nil {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(get: { state.automaticUpdates },
                                                                            set: { state.setAutomaticUpdates($0) }))
                    HStack {
                        Text(state.versionText).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { state.checkForUpdates() }
                    }
                }
            }

            Section("Try it") {
                TextEditor(text: $sample)
                    .font(.system(size: 14))
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if sample.isEmpty {
                            Text("Type here, mistakes included: teh quick brown fox, i dont knwo…")
                                .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                Text("Corrections happen quietly when you press space; Backspace right after undoes one. Press ⌥ Esc to see suggestions for the word you are on, then Tab to take the first.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct StepRow<Trailing: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 2)
    }
}

/// The app's own icon, draggable as a file so it can be dropped into the System Settings list.
private struct DraggableApp: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().frame(width: 48, height: 48)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
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
            Section {
                Toggle(isOn: binding(\.autocorrect)) {
                    Text("Autocorrect")
                    Text("Fixes a misspelled word when you press space or punctuation, only when it is confident. Backspace right after puts your word back and it is never changed again.")
                }
                Toggle(isOn: binding(\.retro)) {
                    Text("Go back and fix earlier words")
                    Text("As you keep typing, the words that follow can show an earlier one was wrong (“got it form the store”). Sandalphon then steps back, fixes it and returns, without interrupting you.")
                }
                .disabled(!state.settings.autocorrect)
            }
            Section("Capitals, punctuation and grammar") {
                Toggle(isOn: binding(\.capitalizeSentences)) {
                    Text("Capitalise sentences")
                    Text("The first word after a full stop, question mark or exclamation mark, and at the start of a message.")
                }
                Toggle(isOn: binding(\.capitalizeNames)) {
                    Text("Capitalise names and places")
                    Text("london → London, friday → Friday, iphone → iPhone.")
                }
                Toggle(isOn: binding(\.grammar)) {
                    Text("Fix common grammar slips")
                    Text("could of → could have, your welcome → you're welcome, a apple → an apple, repeated words, and a space before a comma.")
                }
                Toggle(isOn: binding(\.doubleSpacePeriod)) {
                    Text("Double space adds a full stop")
                }
            }
            .disabled(!state.settings.autocorrect)
            Section {
                Picker("Show suggestions", selection: Binding(get: { state.settings.mode },
                                                              set: { v in state.update { $0.mode = v } })) {
                    Text("Never").tag(SuggestMode.never)
                    Text("Only when I press ⌥ Esc").tag(SuggestMode.onDemand)
                    Text("While I type").tag(SuggestMode.whileTyping)
                }
                if state.settings.mode == .whileTyping {
                    Toggle(isOn: binding(\.predictions)) {
                        Text("Next-word predictions")
                        Text("After a space, offers the words most likely to come next.")
                    }
                }
            } footer: {
                Text("By default nothing appears while you type. Press ⌥ Esc for completions and corrections of the word at the caret, or select a word first to see alternatives for it. To fix a whole selection, right-click it and choose Services › Fix Typos with Sandalphon.")
            }
            Section("Keys") {
                Toggle(isOn: binding(\.tabAccepts)) {
                    Text("Tab accepts the highlighted suggestion")
                    Text("In single-line fields Tab always moves to the next field instead.")
                }
                LabeledContent("Show suggestions", value: "⌥ Esc")
                LabeledContent("Pick a specific suggestion", value: "⌃1  ⌃2  ⌃3")
                LabeledContent("Hide suggestions", value: "Esc")
                LabeledContent("Undo a correction", value: "Backspace")
            }
            Section {
                Button("Open macOS Keyboard Settings…") { NSWorkspace.shared.open(AppState.keyboardURL) }
            } footer: {
                Text("Capitalising sentences and smart quotes are still handled by macOS under Text Input.")
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
        let icon: NSImage?
    }

    private var entries: [Entry] {
        state.settings.excluded.map { id in
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return Entry(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                             icon: NSWorkspace.shared.icon(forFile: url.path))
            }
            return Entry(id: id, name: id, icon: nil)
        }
        .filter { $0.icon != nil }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                ForEach(entries) { entry in
                    HStack {
                        if let icon = entry.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                        Text(entry.name)
                        Spacer()
                        Button("Remove") { state.toggleExcluded(entry.id) }.controlSize(.small)
                    }
                }
                Button("Add App…", action: add)
            } header: {
                Text("Sandalphon stays off in")
            } footer: {
                Text("Terminals, code editors and password managers are off by default, where correcting prose would get in the way. Password fields and search fields are always left alone. You can also switch the current app off from the menu bar icon.")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.application]
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.allowsMultipleSelection = true
        guard open.runModal() == .OK else { return }
        for url in open.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !state.settings.excluded.contains(id) {
                state.toggleExcluded(id)
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @ObservedObject var state: AppState
    @State private var confirming = false

    var body: some View {
        Form {
            Section("What Sandalphon does with your typing") {
                Label("Everything happens on this Mac. Nothing you type is ever sent anywhere. The only thing Sandalphon uses the network for is checking GitHub for a newer version, which you can switch off on the Overview page.", systemImage: "lock")
                Label("It never sees password fields: macOS blocks them for every app.", systemImage: "key")
                Label("It remembers words and short phrases you use often, so suggestions fit how you write. It does not keep what you wrote.", systemImage: "brain")
            }
            Section("Learned from you") {
                LabeledContent("Words learned", value: "\(state.learnedWords)")
                HStack {
                    Button("Show File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([state.userModelURL])
                    }
                    Button("Forget Everything…", role: .destructive) { confirming = true }
                }
            }
            Section("Permissions") {
                LabeledContent("Accessibility", value: state.trusted ? "Allowed" : "Not allowed")
                Button("Open Accessibility Settings…") { NSWorkspace.shared.open(AppState.accessibilityURL) }
                Button("Open Login Items Settings…") { NSWorkspace.shared.open(AppState.loginItemsURL) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget everything Sandalphon has learned from your typing?", isPresented: $confirming) {
            Button("Forget Everything", role: .destructive) { state.forgetLearned() }
        } message: {
            Text("Learned words, phrases and the corrections you undid will be erased. This cannot be undone.")
        }
    }
}
