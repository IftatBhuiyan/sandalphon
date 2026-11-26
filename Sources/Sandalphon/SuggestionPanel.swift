import AppKit
import TypeEngine

/// The small floating bar of suggestions shown next to the caret. Never takes focus.
final class SuggestionPanel {
    private let panel: NSPanel
    private let stack = NSStackView()
    private var pills: [PillView] = []
    private var lastAnchor: CGRect?
    private var lastFlash: Date?
    var onPick: ((Int) -> Void)?
    private(set) var isVisible = false
    var window: NSWindow { panel }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect

        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        for i in 0..<3 {
            let pill = PillView()
            pill.onClick = { [weak self] in self?.onPick?(i) }
            pills.append(pill)
            stack.addArrangedSubview(pill)
        }
    }

    /// Updates the contents right away. `anchor` (the caret) may follow later via `move(to:)`.
    func show(_ items: [Suggestion], tabHint: Bool, anchor: CGRect?, muted: Bool = false) {
        lastFlash = nil
        guard !items.isEmpty else {
            hide()
            return
        }
        for (i, pill) in pills.enumerated() {
            if i < items.count {
                pill.configure(text: items[i].text, primary: i == 0 && !muted, autocorrect: items[i].isAutocorrect,
                               hint: i == 0 && tabHint ? "⇥" : "")
                pill.isHidden = false
            } else {
                pill.isHidden = true
            }
        }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: false)
        if let anchor { place(at: anchor) } else if let lastAnchor { place(at: lastAnchor, force: true) }
        if !isVisible, anchor != nil || lastAnchor != nil {
            panel.orderFrontRegardless()
            isVisible = true
        }
    }

    /// A short note in place of suggestions ("No suggestions"), which goes away by itself.
    func flash(_ message: String, anchor: CGRect?) {
        show([Suggestion(text: message, isAutocorrect: false)], tabHint: false, anchor: anchor, muted: true)
        let shownAt = Date()
        lastFlash = shownAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.lastFlash == shownAt { self?.hide() }
        }
    }

    func move(to anchor: CGRect) {
        place(at: anchor)
        if !isVisible, !pills[0].isHidden {
            panel.orderFrontRegardless()
            isVisible = true
        }
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        isVisible = false
        lastAnchor = nil
    }

    private func place(at anchor: CGRect, force: Bool = false) {
        // Stay put while the caret advances along a line so the bar does not jitter with every letter.
        if !force, let last = lastAnchor, abs(last.minY - anchor.minY) < 2, abs(last.minX - anchor.minX) < 90,
           anchor.minX >= last.minX { return }
        lastAnchor = anchor
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -2, dy: -2).contains(anchor.origin) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        var origin = CGPoint(x: anchor.minX - 8, y: anchor.minY - size.height - 6)
        if origin.y < bounds.minY { origin.y = anchor.maxY + 6 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        panel.setFrameOrigin(origin)
    }
}

private final class PillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 5.5
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        let row = NSStackView(views: [label, hint])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The first suggestion gets a soft tint and stronger text; the rest stay quiet.
    func configure(text: String, primary: Bool, autocorrect: Bool, hint hintText: String) {
        label.stringValue = text
        hint.stringValue = hintText
        hint.isHidden = hintText.isEmpty
        label.font = .systemFont(ofSize: 12.5, weight: primary ? .semibold : .regular)
        label.textColor = primary ? .labelColor : .secondaryLabelColor
        hint.textColor = .tertiaryLabelColor
        layer?.backgroundColor = primary ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        toolTip = autocorrect ? "Space will change the word to this. Backspace right after undoes it." : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
