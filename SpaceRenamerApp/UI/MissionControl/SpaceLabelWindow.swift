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
    private let label = NSTextField(labelWithString: "")
    private let labelFontSize: CGFloat = 92
    private let horizontalTextInset: CGFloat = 40
    private var isActiveSpace = false
    private var fadeWorkItem: DispatchWorkItem?
    private static let fadeAfterSeconds: TimeInterval = 0.1
    private static let fadeDuration: TimeInterval = 0.4

    init(spaceId: String, name: String, screen: NSScreen) {
        self.spaceId = spaceId
        let screenFrame = screen.frame
        // Keep the banner fully inside compact displays and scaled-display
        // modes. The previous fixed 800×500 window could extend beyond a
        // narrow screen even before text layout was considered.
        let bannerSize = NSSize(
            width: max(1, min(800, floor(screenFrame.width * 0.82))),
            height: max(1, min(560, floor(screenFrame.height * 0.72)))
        )
        let origin = NSPoint(x: screenFrame.midX - bannerSize.width / 2,
                             y: screenFrame.midY - bannerSize.height / 2)

        super.init(contentRect: NSRect(origin: origin, size: bannerSize),
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

        // Dark translucent glass with the label centered. Forces `darkAqua` so
        // the banner shape stays consistent regardless of the user's appearance.
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: bannerSize))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 36
        effect.layer?.masksToBounds = true

        label.font = NSFont.systemFont(ofSize: labelFontSize, weight: .bold)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.preferredMaxLayoutWidth = max(
            1,
            bannerSize.width - horizontalTextInset * 2
        )
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.stringValue = name
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            label.leadingAnchor.constraint(
                equalTo: effect.leadingAnchor,
                constant: horizontalTextInset
            ),
            label.trailingAnchor.constraint(
                equalTo: effect.trailingAnchor,
                constant: -horizontalTextInset
            ),
            label.topAnchor.constraint(
                greaterThanOrEqualTo: effect.topAnchor,
                constant: 24
            ),
            label.bottomAnchor.constraint(
                lessThanOrEqualTo: effect.bottomAnchor,
                constant: -24
            ),
        ])

        self.contentView = effect
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
}
