import Foundation

private let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Workspace++/ChromeBridge", isDirectory: true)

private func readMessage() -> [String: Any]? {
    let header = FileHandle.standardInput.readData(ofLength: 4)
    guard header.count == 4 else { return nil }
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    guard length > 0, length < 64 * 1024 * 1024 else { return nil }
    let data = FileHandle.standardInput.readData(ofLength: Int(length))
    guard data.count == Int(length) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    var length = UInt32(data.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(data)
}

private func writeJSON(_ object: Any, to name: String) {
    try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    try? data.write(to: supportDirectory.appendingPathComponent(name), options: .atomic)
}

while let message = readMessage() {
    switch message["type"] as? String {
    case "snapshot":
        if let payload = message["payload"] { writeJSON(payload, to: "latest.json") }
        send(["type": "snapshotAccepted"])
    case "restoreResult":
        writeJSON(message, to: "restore-result.json")
        send(["type": "resultAccepted"])
    case "poll":
        let commandURL = supportDirectory.appendingPathComponent("command.json")
        if let data = try? Data(contentsOf: commandURL),
           let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try? FileManager.default.removeItem(at: commandURL)
            send(command)
        } else {
            send(["type": "idle"])
        }
    default:
        send(["type": "error", "message": "Unknown Workspace++ native message"])
    }
}
