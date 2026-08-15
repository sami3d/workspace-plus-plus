import AppKit
import CoreGraphics

enum VirtualDisplaySessionError: LocalizedError {
    case apiUnavailable
    case creationFailed
    case settingsRejected

    var errorDescription: String? {
        switch self {
        case .apiUnavailable:
            return "This macOS version does not expose the virtual-display classes Workspace++ needs."
        case .creationFailed:
            return "macOS did not create the temporary virtual display."
        case .settingsRejected:
            return "macOS rejected the temporary virtual display settings."
        }
    }
}

/// Owns one process-local virtual display. Releasing `display` disconnects it;
/// the stable vendor/product/serial tuple lets macOS recognise repeated proof
/// runs as the same temporary monitor instead of accumulating new identities.
@MainActor
final class VirtualDisplaySession {
    private var display: CGVirtualDisplay?

    let displayID: CGDirectDisplayID

    init() throws {
        guard NSClassFromString("CGVirtualDisplay") != nil,
              NSClassFromString("CGVirtualDisplayDescriptor") != nil,
              NSClassFromString("CGVirtualDisplaySettings") != nil,
              NSClassFromString("CGVirtualDisplayMode") != nil else {
            throw VirtualDisplaySessionError.apiUnavailable
        }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = "Workspace++ Temporary Display"
        descriptor.maxPixelsWide = 1_920
        descriptor.maxPixelsHigh = 1_080
        descriptor.sizeInMillimeters = CGSize(width: 344, height: 194)
        descriptor.vendorID = 0x5753       // "WS"
        descriptor.productID = 0x5050      // "PP"
        descriptor.serialNum = 0x0001

        let display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else {
            throw VirtualDisplaySessionError.creationFailed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: 1_280, height: 720, refreshRate: 60),
            CGVirtualDisplayMode(width: 1_920, height: 1_080, refreshRate: 60),
        ]
        guard display.apply(settings) else {
            throw VirtualDisplaySessionError.settingsRejected
        }

        self.display = display
        self.displayID = display.displayID
    }

    func disconnect() {
        display = nil
    }
}
