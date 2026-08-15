import Foundation

struct CapturedChromeWindow: Codable, Sendable {
    struct Bounds: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Tab: Codable, Sendable {
        let id: String
        let title: String
        let url: String
    }

    let id: String
    let title: String
    let bounds: Bounds
    let mode: String
    let activeTabIndex: Int
    let tabs: [Tab]
}

/// Chrome's supported scripting dictionary exposes every ordinary window and
/// every tab, including stable ordering and the active tab. A future Chrome
/// companion extension can conform to this same output model to add pinned
/// and tab-group metadata without changing the cloud snapshot format.
struct ChromeSessionAdapter: Sendable {
    enum CaptureError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            }
        }
    }

    func capture() async throws -> [CapturedChromeWindow] {
        try await Task.detached(priority: .utility) {
            let script = #"""
            const chrome = Application("Google Chrome");
            const result = chrome.windows().map((window) => ({
              id: String(window.id()),
              title: String(window.title()),
              bounds: window.bounds(),
              mode: String(window.mode()),
              activeTabIndex: Number(window.activeTabIndex()),
              tabs: window.tabs().map((tab) => ({
                id: String(tab.id()),
                title: String(tab.title()),
                url: String(tab.url())
              }))
            }));
            JSON.stringify(result);
            """#
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
            } catch {
                throw CaptureError.unavailable(error.localizedDescription)
            }
            // Drain stdout before waiting. A real workspace can contain
            // hundreds of tabs and exceed a Pipe's kernel buffer; waiting for
            // process exit first would deadlock while osascript waits for us
            // to consume its JSON.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "Chrome did not allow tab capture."
                throw CaptureError.unavailable(message)
            }
            do {
                return try JSONDecoder().decode([CapturedChromeWindow].self, from: data)
            } catch {
                throw CaptureError.unavailable("Chrome returned an unreadable tab list.")
            }
        }.value
    }

    func restore(windows: [WorkspaceCapturedWindow]) async throws {
        guard !windows.isEmpty else { return }
        let script = windows.map { window -> String in
            let tabs = window.tabs.sorted { $0.index < $1.index }
            let firstURL = tabs.first?.url ?? "chrome://newtab/"
            let extraTabs = tabs.dropFirst().map {
                "make new tab at end of tabs of targetWindow with properties {URL:\"\(appleScriptEscaped($0.url))\"}"
            }.joined(separator: "\n")
            let activeIndex = max(1, (tabs.firstIndex(where: \.isActive) ?? 0) + 1)
            let bounds = window.bounds
            return """
            make new window
            set targetWindow to front window
            set bounds of targetWindow to {\(Int(bounds.x)), \(Int(bounds.y)), \(Int(bounds.x + bounds.width)), \(Int(bounds.y + bounds.height))}
            set URL of active tab of targetWindow to "\(appleScriptEscaped(firstURL))"
            \(extraTabs)
            set active tab index of targetWindow to \(activeIndex)
            """
        }.joined(separator: "\n")
        try await runAppleScript("""
        tell application "Google Chrome"
            activate
            \(script)
        end tell
        """)
    }

    private func runAppleScript(_ source: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardError = errors
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw CaptureError.unavailable(error.localizedDescription)
            }
            guard process.terminationStatus == 0 else {
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                throw CaptureError.unavailable(
                    String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "Chrome could not restore the saved windows."
                )
            }
        }.value
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
