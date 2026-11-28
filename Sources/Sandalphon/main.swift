import AppKit

#if DEBUG
SettingsSnapshot.run(arguments: CommandLine.arguments)
#endif
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
