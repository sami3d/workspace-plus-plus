import Foundation

/// Watches a tiny local request file written by the Raycast extension.
/// Polling only stats the file until its modification date changes, then
/// decodes one small JSON object. This avoids menu automation, URL-routing
/// races, networking, and additional permissions.
@MainActor
final class RaycastSwitchRequestMonitor: NSObject {
    private struct Request: Decodable {
        let requestID: String
        let storageID: String
    }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Space Renamer", isDirectory: true)
        .appendingPathComponent("raycast-switch-request.json")

    private let onRequest: (String) -> Void
    nonisolated(unsafe) private var timer: Timer?
    private var lastModificationDate: Date?
    private var lastRequestID: String?

    init(onRequest: @escaping (String) -> Void) {
        self.onRequest = onRequest
        super.init()

        // Treat any request left from a previous app run as already consumed.
        if let snapshot = readRequest() {
            lastModificationDate = snapshot.date
            lastRequestID = snapshot.request.requestID
        }

        let timer = Timer(timeInterval: 0.15,
                          target: self,
                          selector: #selector(poll),
                          userInfo: nil,
                          repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    @objc private func poll() {
        guard let snapshot = readRequest(),
              snapshot.date != lastModificationDate else { return }
        lastModificationDate = snapshot.date
        guard snapshot.request.requestID != lastRequestID else { return }
        lastRequestID = snapshot.request.requestID
        onRequest(snapshot.request.storageID)
    }

    private func readRequest() -> (date: Date, request: Request)? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: Self.fileURL.path)
            guard let date = attributes[.modificationDate] as? Date else { return nil }
            let data = try Data(contentsOf: Self.fileURL)
            return (date, try JSONDecoder().decode(Request.self, from: data))
        } catch {
            // Missing or momentarily-partial files are normal: the extension
            // may be writing while this poll fires. The next tick retries.
            return nil
        }
    }
}
