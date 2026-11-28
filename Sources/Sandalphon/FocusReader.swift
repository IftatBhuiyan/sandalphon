import AppKit
import ApplicationServices

/// What the Accessibility API says about the focused text field.
struct FocusInfo {
    var role: String?
    var subrole: String?
    /// Up to 160 characters before the caret, or nil if the app does not expose its text.
    var textBefore: String?
    var selectionLength = 0
    /// The selected text, when there is a selection.
    var selectedText: String?
    /// Caret rectangle in Cocoa screen coordinates.
    var caret: CGRect?
    /// Frame of the focused element in Cocoa screen coordinates.
    var frame: CGRect?

    var isSecure: Bool { subrole == "AXSecureTextField" || role == "AXSecureTextField" }
    /// Browser address bars and search boxes: queries and URLs, not prose.
    var isAddressBar = false
    var isSearch: Bool { subrole == "AXSearchField" || isAddressBar }
    /// Single-line fields use Tab to move between fields, so Tab must not accept suggestions there.
    var isSingleLine: Bool { role == "AXTextField" || role == "AXComboBox" }
}

/// Reads the focused field through Accessibility. Every call is cross-process and can be slow,
/// so this is only ever used off the keystroke path.
final class FocusReader {
    private let system = AXUIElementCreateSystemWide()
    private var frontPID: pid_t = 0

    init() {
        AXUIElementSetMessagingTimeout(system, 0.2)
    }

    /// Electron apps keep their accessibility tree off until asked.
    func prepare(pid: pid_t) {
        frontPID = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private func parameterized(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &value) == .success ? value : nil
    }

    private func rangeValue(_ location: Int, _ length: Int) -> AXValue? {
        var r = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &r)
    }

    private func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &r) else { return nil }
        return r
    }

    /// Accessibility uses a top-left origin on the primary display; AppKit uses bottom-left.
    private func flipped(_ r: CGRect) -> CGRect {
        // The primary display's height; CoreGraphics, unlike NSScreen, is safe off the main thread.
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    /// Web content (Safari, Chrome, Electron) reports the caret through text markers rather than ranges.
    private func markerCaret(_ el: AXUIElement) -> CGRect? {
        guard let markers = attribute(el, "AXSelectedTextMarkerRange"),
              let b = rect(parameterized(el, "AXBoundsForTextMarkerRange", markers)), b.height > 1 else { return nil }
        return flipped(b.width > 2 ? b : CGRect(x: b.maxX, y: b.minY, width: 1, height: b.height))
    }

    func read() -> FocusInfo? {
        // The system-wide lookup sometimes fails (Chrome, or while a system dialog is up); asking the
        // frontmost app directly still works.
        var found = attribute(system, kAXFocusedUIElementAttribute as String)
        if found == nil, frontPID != 0 {
            found = attribute(AXUIElementCreateApplication(frontPID), kAXFocusedUIElementAttribute as String)
        }
        guard let focused = found, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let el = focused as! AXUIElement
        var info = FocusInfo()
        info.role = attribute(el, kAXRoleAttribute as String) as? String
        info.subrole = attribute(el, kAXSubroleAttribute as String) as? String
        if info.isSecure { return info }
        if info.role == "AXTextField" || info.role == "AXComboBox" {
            let labels = [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute]
                .compactMap { attribute(el, $0 as String) as? String }.joined(separator: " ").lowercased()
            info.isAddressBar = labels.contains("address") || labels.contains("search") || labels.contains("url")
        }

        if let pos = attribute(el, kAXPositionAttribute as String), let size = attribute(el, kAXSizeAttribute as String),
           CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            info.frame = flipped(CGRect(origin: p, size: s))
        }

        guard let sel = attribute(el, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(sel) == AXValueGetTypeID() else {
            info.caret = markerCaret(el)
            return info
        }
        var range = CFRange()
        guard AXValueGetValue(sel as! AXValue, .cfRange, &range), range.location >= 0 else {
            info.caret = markerCaret(el)
            return info
        }
        info.selectionLength = range.length
        if range.length > 0 {
            info.selectedText = attribute(el, kAXSelectedTextAttribute as String) as? String
            if let r = rangeValue(range.location, range.length),
               let b = rect(parameterized(el, kAXBoundsForRangeParameterizedAttribute as String, r)), b.height > 1 {
                info.caret = flipped(b)
            } else {
                info.caret = markerCaret(el)
            }
            return info
        }

        let take = min(range.location, 160)
        if take == 0 {
            info.textBefore = ""
        } else if let r = rangeValue(range.location - take, take),
                  let s = parameterized(el, kAXStringForRangeParameterizedAttribute as String, r) as? String {
            info.textBefore = s
        } else if let count = attribute(el, kAXNumberOfCharactersAttribute as String) as? Int, count < 20_000,
                  let value = attribute(el, kAXValueAttribute as String) as? String {
            let ns = value as NSString
            if range.location <= ns.length {
                info.textBefore = ns.substring(with: NSRange(location: range.location - take, length: take))
            }
        }

        // The character before the caret gives the most reliable line box; a zero-length range is the fallback
        // (and the only option at the start of a line).
        let lineStart = info.textBefore?.last?.isNewline ?? true
        if !lineStart, range.location > 0, let r = rangeValue(range.location - 1, 1),
           let b = rect(parameterized(el, kAXBoundsForRangeParameterizedAttribute as String, r)), b.height > 1 {
            info.caret = flipped(CGRect(x: b.maxX, y: b.minY, width: 1, height: b.height))
        } else if let r = rangeValue(range.location, 0),
                  let b = rect(parameterized(el, kAXBoundsForRangeParameterizedAttribute as String, r)), b.height > 1 {
            info.caret = flipped(b)
        }
        if info.caret == nil { info.caret = markerCaret(el) }
        return info
    }
}
