import AppKit
import Foundation

/// Installs the native bridge automatically and keeps the extension itself
/// inside Workspace++. Chrome still owns the one-time extension consent UI.
struct ChromeExtensionBridge: Sendable {
    static let extensionID = "ofkngiajlpfhidkljfeccohbcokcfgoh"
    static let hostName = "com.saint.workspaceplusplus.chrome"

    enum BridgeError: LocalizedError {
        case resourcesMissing
        case installationFailed(String)
        case noSnapshot

        var errorDescription: String? {
            switch self {
            case .resourcesMissing:
                return "The bundled Chrome companion files are missing."
            case .installationFailed(let message): return message
            case .noSnapshot:
                return "The Chrome companion has not sent a browser snapshot yet."
            }
        }
    }

    private var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Workspace++", isDirectory: true)
    }

    private var bridgeDirectory: URL {
        supportDirectory.appendingPathComponent("ChromeBridge", isDirectory: true)
    }

    var latestSnapshotURL: URL { bridgeDirectory.appendingPathComponent("latest.json") }

    var isReceivingSnapshots: Bool {
        guard let values = try? latestSnapshotURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return false }
        return date.timeIntervalSinceNow > -180
    }

    /// Copies the extension to a stable user-owned path and registers the
    /// app-bundled native executable. The copied extension is used only for
    /// development; public builds point the same button at the Web Store ID.
    func installBundledComponents() throws -> URL {
        guard let extensionResource = Bundle.main.url(
            forResource: "ChromeExtension",
            withExtension: nil
        ) else { throw BridgeError.resourcesMissing }
        let hostExecutable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/WorkspacePlusChromeHost")
        guard FileManager.default.isExecutableFile(atPath: hostExecutable.path) else {
            throw BridgeError.resourcesMissing
        }

        let fileManager = FileManager.default
        let installedExtension = supportDirectory
            .appendingPathComponent("ChromeExtension", isDirectory: true)
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            guard let bundledManifest = try? Data(
                contentsOf: extensionResource.appendingPathComponent("manifest.json")
            ) else { throw BridgeError.resourcesMissing }
            let installedManifest = try? Data(
                contentsOf: installedExtension.appendingPathComponent("manifest.json")
            )
            if bundledManifest != installedManifest {
                if fileManager.fileExists(atPath: installedExtension.path) {
                    try fileManager.removeItem(at: installedExtension)
                }
                try fileManager.copyItem(at: extensionResource, to: installedExtension)
            }
            try fileManager.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)

            let manifestDirectory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Google/Chrome/NativeMessagingHosts",
                    isDirectory: true
                )
            try fileManager.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "name": Self.hostName,
                "description": "Workspace++ Chrome session bridge",
                "path": hostExecutable.path,
                "type": "stdio",
                "allowed_origins": ["chrome-extension://\(Self.extensionID)/"],
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(
                to: manifestDirectory.appendingPathComponent("\(Self.hostName).json"),
                options: .atomic
            )
            return installedExtension
        } catch {
            throw BridgeError.installationFailed(error.localizedDescription)
        }
    }

    func openChromeExtensionSetup() throws {
        let installedExtension = try installBundledComponents()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installedExtension.path, forType: .string)
        guard let url = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open(url)
    }

    func capturedWindows() throws -> [CapturedChromeWindow] {
        guard let data = try? Data(contentsOf: latestSnapshotURL) else {
            throw BridgeError.noSnapshot
        }
        struct Snapshot: Decodable { let windows: [CapturedChromeWindow] }
        return try JSONDecoder().decode(Snapshot.self, from: data).windows
    }

    func requestRestore(windows: [WorkspaceCapturedWindow]) throws {
        try FileManager.default.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
        let command: [String: Any] = [
            "type": "restore",
            "requestId": UUID().uuidString,
            "windows": try windows.map { window -> [String: Any] in
                let data = try JSONEncoder.cloud.encode(window)
                return try JSONSerialization.jsonObject(with: data) as! [String: Any]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        try data.write(to: bridgeDirectory.appendingPathComponent("command.json"), options: .atomic)
    }
}
