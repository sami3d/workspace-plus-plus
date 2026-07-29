import AppKit
import QuartzCore

/// Borderless, click-through, transparent `NSWindow` that displays one Space's
/// custom name as a huge bold banner. One instance per Space, anchored to its
/// target Space via `SpaceWindowAnchoring`. See *Design Revision 2026-06-04*.
///
/// Visibility logic, when the window's Space *is* the active Space (the user
/// is on it):
///   - On switch-in or Mission Control close: banner becomes visible, then
///     fades out after `fadeAfterSeconds` so it doesn't permanently obscure
///     the desktop.
///   - On Mission Control open (detected as window occlusion): banner is
///     re-shown so the thumbnail render picks it up.
///
/// When the window's Space is *not* the active Space, the banner stays at
/// alpha 1: the user can't see it (they're on a different Space), but Mission
/// Control's thumbnail of that Space renders it normally.
@MainActor
final class SpaceLabelWindow: NSWindow {
    let spaceId: String
    private let tintView = NSView()
    private let label = NSTextField(labelWithString: "")
    private static let labelFontSize: CGFloat = 128
    private static let bandOuterInset: CGFloat = 64
    private static let bandTextInset: CGFloat = 64
    private static let bandVerticalInset: CGFloat = 48
    private let backgroundOpacity: CGFloat
    private let showsAppWindows: Bool
    private let targetScreenFrame: NSRect
    private var isActiveSpace = false
    private var fadeWorkItem: DispatchWorkItem?
    private static let fadeAfterSeconds: TimeInterval = 0.1
    private static let fadeDuration: TimeInterval = 0.4

    init(spaceId: String, name: String, color: NSColor,
         backgroundOpacity: CGFloat, showsAppWindows: Bool, screen: NSScreen) {
        self.spaceId = spaceId
        self.backgroundOpacity = backgroundOpacity
        self.showsAppWindows = showsAppWindows
        let screenFrame = screen.frame
        self.targetScreenFrame = screenFrame
        // Mission Control uses the window's real bounds, not the visible
        // pixels inside a transparent full-screen window. Use a genuinely
        // band-sized window when app windows should remain visible.
        let windowFrame = Self.windowFrame(
            for: name,
            screenFrame: screenFrame,
            showsAppWindows: showsAppWindows
        )
        let bannerSize = windowFrame.size

        super.init(contentRect: windowFrame,
                   styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)

        self.isReleasedWhenClosed = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .floating
        // Pinned to a single Space; visible over fullscreen apps so it appears
        // in the Mission Control thumbnail for fullscreen Spaces too. Excludes
        // `.canJoinAllSpaces` (would defeat the per-Space anchoring) and
        // `.transient` (would suppress in Mission Control's snapshot).
        self.collectionBehavior = [.managed, .participatesInCycle,
                                   .fullScreenAuxiliary, .ignoresCycle]
        self.ignoresMouseEvents = true

        let container = NSView(frame: NSRect(origin: .zero, size: bannerSize))
        container.wantsLayer = true

        tintView.wantsLayer = true
        tintView.translatesAutoresizingMaskIntoConstraints = false

        label.font = NSFont.systemFont(ofSize: Self.labelFontSize, weight: .bold)
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.preferredMaxLayoutWidth = max(
            1,
            bannerSize.width - (
                showsAppWindows
                    ? Self.bandTextInset * 2
                    : Self.bandOuterInset * 2
            )
        )
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.stringValue = name
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(tintView)
        NSLayoutConstraint.activate([
            tintView.topAnchor.constraint(equalTo: container.topAnchor),
            tintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        tintView.addSubview(label)
        if showsAppWindows {
            tintView.layer?.cornerRadius = 36
            tintView.layer?.masksToBounds = true
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(
                    equalTo: tintView.topAnchor,
                    constant: Self.bandVerticalInset
                ),
                label.bottomAnchor.constraint(
                    equalTo: tintView.bottomAnchor,
                    constant: -Self.bandVerticalInset
                ),
                label.leadingAnchor.constraint(
                    equalTo: tintView.leadingAnchor,
                    constant: Self.bandTextInset
                ),
                label.trailingAnchor.constraint(
                    equalTo: tintView.trailingAnchor,
                    constant: -Self.bandTextInset
                ),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                label.leadingAnchor.constraint(
                    equalTo: container.leadingAnchor,
                    constant: Self.bandOuterInset
                ),
                label.trailingAnchor.constraint(
                    equalTo: container.trailingAnchor,
                    constant: -Self.bandOuterInset
                ),
                label.topAnchor.constraint(
                    greaterThanOrEqualTo: container.topAnchor,
                    constant: 40
                ),
                label.bottomAnchor.constraint(
                    lessThanOrEqualTo: container.bottomAnchor,
                    constant: -40
                ),
            ])
        }
        setColor(color)

        self.contentView = container
        self.alphaValue = 0   // manager will set the right state right after init

        // Drive active-Space visibility from occlusion: Mission Control covers
        // the on-screen window when it opens (occlusion → re-show banner; close
        // → fade again). NSWindow exposes this only via notification.
        // (NSObject's runtime auto-unregisters at deallocation, so no manual
        // removeObserver — avoids the Swift 6 nonisolated-deinit diagnostic.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionStateChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Primary signal from the manager: `true` = this Space is the current
    /// Space (transient banner with fade); `false` = it's one of the other
    /// Spaces (always-visible banner for the Mission Control thumbnail).
    func setIsActiveSpace(_ active: Bool) {
        let changed = (active != isActiveSpace)
        isActiveSpace = active
        if active {
            // Show briefly on switch-in, then fade.
            if changed { showThenFade() }
        } else {
            // Non-active Space — always visible (user can't see it because
            // they're elsewhere; Mission Control thumbnail uses it).
            cancelFade()
            self.alphaValue = 1
        }
    }

    func setName(_ name: String) {
        label.stringValue = name
        guard showsAppWindows else { return }
        let newFrame = Self.windowFrame(
            for: name,
            screenFrame: targetScreenFrame,
            showsAppWindows: true
        )
        label.preferredMaxLayoutWidth = max(
            1,
            newFrame.width - Self.bandTextInset * 2
        )
        setFrame(newFrame, display: true)
    }

    func setColor(_ color: NSColor) {
        tintView.layer?.backgroundColor = color
            .withAlphaComponent(backgroundOpacity)
            .cgColor
        label.textColor = WorkspaceColor.readableTextColor(on: color)
    }

    /// Mission Control covers the on-screen window when it opens, which the
    /// system reports as occlusion on this window. On the active Space's
    /// window: occluded → re-show (so the thumbnail render picks it up);
    /// un-occluded → fade out again. Non-active windows are unaffected (they
    /// stay at alpha 1 for the always-on Mission Control thumbnail).
    @objc private func occlusionStateChanged(_ note: Notification) {
        guard isActiveSpace else { return }
        let visibleOnScreen = self.occlusionState.contains(.visible)
        if visibleOnScreen {
            // Mission Control just closed — fade banner out again.
            showThenFade()
        } else {
            // Mission Control just opened — snap to alpha 1 *instantly* so
            // the thumbnail snapshot captures a fully-rendered banner. An
            // animated 0→1 fade-in here could be partially captured (the
            // most likely cause of "banner missing from active thumbnail"
            // reports).
            cancelFade()
            self.alphaValue = 1
        }
    }

    private func showThenFade() {
        cancelFade()
        self.alphaValue = 1
        let work = DispatchWorkItem { [weak self] in
            self?.animateAlpha(to: 0)
        }
        fadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeAfterSeconds, execute: work)
    }

    private func cancelFade() {
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
    }

    private func animateAlpha(to value: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeDuration
            self.animator().alphaValue = value
        }
    }

    /// Continuous low-amplitude opacity animation. Forces WindowServer to keep
    /// re-rendering the window so Mission Control's snapshot of this Space
    /// stays current. Without this, the thumbnail commonly shows a stale frame
    /// or no banner (well-known workaround; see *Design Revision 2026-06-04*).
    func startRenderingLoop() {
        guard let layer = self.contentView?.layer else { return }
        let key = "spaceLabelRedrawLoop"
        if layer.animation(forKey: key) != nil { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.999
        anim.duration = 1.0
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: key)
    }

    private static func windowFrame(
        for name: String,
        screenFrame: NSRect,
        showsAppWindows: Bool
    ) -> NSRect {
        guard showsAppWindows else { return screenFrame }

        let width = max(1, screenFrame.width - bandOuterInset * 2)
        let textWidth = max(1, width - bandTextInset * 2)
        let font = NSFont.systemFont(ofSize: labelFontSize, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        let measured = (name as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
            ]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textHeight = min(ceil(measured.height), lineHeight * 4)
        let desiredHeight = max(
            lineHeight + bandVerticalInset * 2,
            textHeight + bandVerticalInset * 2
        )
        let height = max(1, min(screenFrame.height - 80, desiredHeight))
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}
