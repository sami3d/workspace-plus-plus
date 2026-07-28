import Cocoa

// Explicit NIB-less AppKit entry point. `@main` directly on an
// `NSApplicationDelegate` does NOT connect the delegate in a storyboard-less
// app (the app ran a delegate-less NSApplication and did nothing), so we own
// the bootstrap here on the main actor and wire the delegate manually.
@main
enum WorkspacePlusPlusMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar agent (also set via LSUIElement)
        app.run()
    }
}
