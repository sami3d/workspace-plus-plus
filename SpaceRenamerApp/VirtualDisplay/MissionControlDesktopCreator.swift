import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum MissionControlDesktopCreationError: LocalizedError {
    case accessibilityDenied
    case eventSourceUnavailable
    case missionControlUnavailable
    case dockUnavailable
    case addDesktopButtonNotFound
    case ambiguousAddDesktopButtons(Int)
    case pressFailed(AXError)

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Workspace++ needs Accessibility permission to operate Mission Control."
        case .eventSourceUnavailable:
            return "Workspace++ could not create a Mission Control keyboard event."
        case .missionControlUnavailable:
            return "Workspace++ could not launch the macOS Mission Control app."
        case .dockUnavailable:
            return "The macOS Dock process is unavailable."
        case .addDesktopButtonNotFound:
            return "Mission Control did not expose an Add Desktop button on the temporary display."
        case let .ambiguousAddDesktopButtons(count):
            return "Workspace++ found " + String(count)
                + " possible Add Desktop buttons and refused to guess."
        case let .pressFailed(error):
            return "macOS rejected the Add Desktop button action (AX error "
                + String(error.rawValue) + ")."
        }
    }
}

@MainActor
final class MissionControlDesktopCreator {
    private struct Candidate {
        let element: AXUIElement
        let center: CGPoint
    }

    func createDesktop(on displayBounds: CGRect) async throws {
        guard AXIsProcessTrusted() else {
            throw MissionControlDesktopCreationError.accessibilityDenied
        }
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else {
            throw MissionControlDesktopCreationError.dockUnavailable
        }

        let missionControlURL = URL(
            fileURLWithPath: "/System/Applications/Mission Control.app"
        )
        guard FileManager.default.fileExists(atPath: missionControlURL.path) else {
            throw MissionControlDesktopCreationError.missionControlUnavailable
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: missionControlURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } catch {
            throw MissionControlDesktopCreationError.missionControlUnavailable
        }
        do {
            let button = try await waitForAddDesktopButton(
                dockPID: dock.processIdentifier,
                displayBounds: displayBounds
            )
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            guard result == .success else {
                throw MissionControlDesktopCreationError.pressFailed(result)
            }
            try await Task.sleep(for: .milliseconds(900))
            try postKey(53) // Escape Mission Control.
        } catch {
            try? postKey(53)
            throw error
        }
    }

    private func waitForAddDesktopButton(
        dockPID: pid_t,
        displayBounds: CGRect
    ) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(6)
        var lastDiagnostic = "<unreported>"
        repeat {
            let root = AXUIElementCreateApplication(dockPID)
            let candidates = collectCandidates(from: root)
            let diagnostic = candidates.map {
                String(format: "(%.0f,%.0f)", $0.center.x, $0.center.y)
            }.joined(separator: ", ")
            if diagnostic != lastDiagnostic {
                NSLog(
                    "Workspace++ Mission Control diagnostic: target=%@ Add Desktop centers=[%@]",
                    NSStringFromRect(displayBounds),
                    diagnostic
                )
                lastDiagnostic = diagnostic
            }
            let onTargetDisplay = candidates.filter {
                displayBounds.insetBy(dx: -2, dy: -2).contains($0.center)
            }

            if onTargetDisplay.count == 1 {
                return onTargetDisplay[0].element
            }
            if onTargetDisplay.count > 1 {
                throw MissionControlDesktopCreationError
                    .ambiguousAddDesktopButtons(onTargetDisplay.count)
            }
            // On macOS 26 the Dock sometimes reports the sole Add Desktop
            // button in coordinates local to its Spaces Bar, not in global
            // display coordinates. In that case, accept it only while the
            // independently queried pointer is inside the temporary display.
            if candidates.count == 1,
               let pointer = CGEvent(source: nil)?.location,
               displayBounds.contains(pointer) {
                return candidates[0].element
            }
            try await Task.sleep(for: .milliseconds(120))
        } while Date() < deadline

        throw MissionControlDesktopCreationError.addDesktopButtonNotFound
    }

    private func collectCandidates(from root: AXUIElement) -> [Candidate] {
        var result: [Candidate] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0

        while cursor < queue.count {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard depth <= 14 else { continue }

            let role = stringAttribute(kAXRoleAttribute, of: element)?.lowercased() ?? ""
            let description = [
                stringAttribute(kAXDescriptionAttribute, of: element),
                stringAttribute(kAXIdentifierAttribute, of: element),
                stringAttribute(kAXTitleAttribute, of: element),
                stringAttribute(kAXHelpAttribute, of: element),
            ]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()

            if role == (kAXButtonRole as String).lowercased(),
               description.contains("add desktop"),
               let center = center(of: element) {
                result.append(Candidate(
                    element: element,
                    center: center
                ))
            }

            queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
        }
        return result
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &raw
        ) == .success else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &raw
        ) == .success else { return nil }
        return raw as? String
    }

    private func center(of element: AXUIElement) -> CGPoint? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &rawPosition
        ) == .success,
        AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &rawSize
        ) == .success,
        let rawPosition,
        let rawSize,
        CFGetTypeID(rawPosition) == AXValueGetTypeID(),
        CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }

        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private func postKey(_ keyCode: CGKeyCode) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: false
              ) else {
            throw MissionControlDesktopCreationError.eventSourceUnavailable
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
