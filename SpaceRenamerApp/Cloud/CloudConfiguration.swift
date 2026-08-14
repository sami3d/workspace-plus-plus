import Foundation

struct CloudConfiguration: Sendable {
    let projectURL: URL
    let publishableKey: String

    static func bundled() -> CloudConfiguration? {
        guard
            let rawURL = Bundle.main.object(
                forInfoDictionaryKey: "WorkspaceCloudURL"
            ) as? String,
            let projectURL = URL(string: rawURL),
            let key = Bundle.main.object(
                forInfoDictionaryKey: "WorkspaceCloudPublishableKey"
            ) as? String,
            !key.isEmpty,
            !key.hasPrefix("REPLACE_")
        else { return nil }
        return CloudConfiguration(projectURL: projectURL, publishableKey: key)
    }
}
