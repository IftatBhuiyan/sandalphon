#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: renders every settings page offscreen to PNG files, without starting the key tap.
///
///   swift build && .build/debug/Sandalphon --snapshot-settings DIR [--untrusted]
enum SettingsSnapshot {
    static func run(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--snapshot-settings"), i + 1 < arguments.count else { return }
        let dir = URL(fileURLWithPath: arguments[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let icon = NSImage(contentsOfFile: "Resources/Sandalphon.icns") { NSApp.applicationIconImage = icon }
        let state = AppState(preview: true)
        state.trusted = !arguments.contains("--untrusted")
        state.engineReady = state.trusted
        state.systemAutocorrectOff = state.trusted
        state.launchAtLogin = state.trusted
        state.learnedWords = 1284
        let height = arguments.firstIndex(of: "--height").map { CGFloat(Double(arguments[$0 + 1]) ?? 560) } ?? 560
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for pane in Pane.allCases {
                state.pane = pane
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.title = "Sandalphon"
                window.contentViewController = NSHostingController(rootView: MainView(state: state).environment(\.controlActiveState, .key))
                window.setContentSize(NSSize(width: 760, height: height))
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                window.orderFrontRegardless()
                for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                let view = window.contentView!.superview!
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("\(pane.rawValue)-\(name).png"))
                window.orderOut(nil)
            }
        }
        exit(0)
    }
}
#endif
