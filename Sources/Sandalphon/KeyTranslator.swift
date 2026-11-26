import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Turns a key code plus modifier flags into the character the current keyboard layout produces.
///
/// The string carried by a key event is not reliable for this: for some events it reflects the keyboard's
/// physical modifier state rather than the event's own flags, so Shift-1 can read as "1" instead of "!".
final class KeyTranslator {
    private var layout: Data?
    private let lock = NSLock()

    init() {
        reload()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    /// Reads the active layout. Text Input Sources must be used from the main thread.
    private func reload() {
        let work = {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            self.lock.lock(); self.layout = data; self.lock.unlock()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func string(keyCode: Int, flags: CGEventFlags) -> String? {
        lock.lock(); let data = layout; lock.unlock()
        guard let data else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock) }
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), (modifiers >> 8) & 0xFF,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys,
                                  chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
