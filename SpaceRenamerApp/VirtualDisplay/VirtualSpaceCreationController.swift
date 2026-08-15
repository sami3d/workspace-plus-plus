import AppKit
import CoreGraphics
import SpaceRenamerCore

enum VirtualSpaceCreationError: LocalizedError {
    case virtualDisplayDidNotAppear
    case temporarySpaceDidNotAppear
    case addDesktopWasNotObserved
    case virtualDisplayDidNotDisconnect
    case noSurvivingSpace

    var errorDescription: String? {
        switch self {
        case .virtualDisplayDidNotAppear:
            return "The temporary display did not appear in the macOS Space topology."
        case .temporarySpaceDidNotAppear:
            return "macOS did not assign an initial Space to the temporary display."
        case .addDesktopWasNotObserved:
            return "Workspace++ clicked Add Desktop, but macOS did not report a new Space."
        case .virtualDisplayDidNotDisconnect:
            return "The temporary display did not disconnect in time."
        case .noSurvivingSpace:
            return "The temporary display disconnected, but no new Space survived on a physical display."
        }
    }
}

@MainActor
final class VirtualSpaceCreationController {
    private let monitor: SpaceMonitor
    private let missionControl = MissionControlDesktopCreator()
    private let originalSpaceSwitcher: SpaceSwitching
    private let onDisplayTopologyRestored: () -> Void
    private var isCreating = false

    init(
        monitor: SpaceMonitor,
        originalSpaceSwitcher: SpaceSwitching = RelativeArrowSpaceSwitcher(),
        onDisplayTopologyRestored: @escaping () -> Void = {}
    ) {
        self.monitor = monitor
        self.originalSpaceSwitcher = originalSpaceSwitcher
        self.onDisplayTopologyRestored = onDisplayTopologyRestored
    }

    func requestCreation() {
        guard !isCreating else { return }

        let confirmation = NSAlert()
        confirmation.messageText = "Create an experimental Workspace?"
        confirmation.informativeText = "Workspace++ will temporarily attach a private virtual display, briefly open Mission Control, create a desktop there, and disconnect the display. It will verify the resulting Space topology and will not delete anything if macOS produces an unexpected result."
        confirmation.addButton(withTitle: "Create Workspace")
        confirmation.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        isCreating = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isCreating = false
                self.onDisplayTopologyRestored()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    [weak self] in
                    self?.onDisplayTopologyRestored()
                }
            }
            do {
                let result = try await self.createAndMeasure()
                self.showResult(result)
            } catch {
                NSLog("Workspace++ virtual-space proof: failed: %@", error.localizedDescription)
                self.showFailure(error)
            }
        }
    }

    private struct Result {
        let newSpaces: [ParsedSpace]
    }

    private func createAndMeasure() async throws -> Result {
        monitor.reload()
        let originalIDs = Set(monitor.spaces.map(\.storageID))
        let originalDisplayIDs = Set(monitor.displays.map(\.id))
        let originalCGDisplayIDs = activeDisplayIDs()
        let originalActiveSpaceID = monitor.activeID
        NSLog("Workspace++ virtual-space proof: starting with %d Spaces", originalIDs.count)
        let originalPointer = CGEvent(source: nil)?.location ?? .zero
        let session = try VirtualDisplaySession()
        NSLog(
            "Workspace++ virtual-space proof: attached private display object %u",
            session.displayID
        )

        defer {
            session.disconnect()
            CGWarpMouseCursorPosition(originalPointer)
        }

        var temporaryCGDisplayID: CGDirectDisplayID?
        try await waitUntil(
            timeout: 6,
            failure: .virtualDisplayDidNotAppear
        ) {
            let added = self.activeDisplayIDs().subtracting(originalCGDisplayIDs)
            guard added.count == 1, let displayID = added.first,
                  !CGDisplayBounds(displayID).isEmpty else { return false }
            temporaryCGDisplayID = displayID
            return true
        }
        guard let temporaryCGDisplayID else {
            throw VirtualSpaceCreationError.virtualDisplayDidNotAppear
        }

        var temporaryManagedDisplayID: String?
        try await waitUntil(
            timeout: 7,
            failure: .temporarySpaceDidNotAppear
        ) {
            self.monitor.reload()
            let newDisplays = self.monitor.displays.filter {
                !originalDisplayIDs.contains($0.id)
            }
            guard newDisplays.count == 1, let added = newDisplays.first,
                  !added.spaces.isEmpty else { return false }
            temporaryManagedDisplayID = added.id
            return true
        }
        guard let temporaryManagedDisplayID else {
            throw VirtualSpaceCreationError.temporarySpaceDidNotAppear
        }

        let temporaryCountBefore = monitor.spaces.filter {
            $0.displayID == temporaryManagedDisplayID
        }.count
        let preClickIDs = Set(monitor.spaces.map(\.storageID))
        NSLog(
            "Workspace++ virtual-space proof: temporary display began with %d Spaces",
            temporaryCountBefore
        )

        let target = CGDisplayBounds(temporaryCGDisplayID)
        CGWarpMouseCursorPosition(CGPoint(x: target.midX, y: target.midY))
        try await Task.sleep(for: .milliseconds(180))
        try await missionControl.createDesktop(on: target)
        NSLog("Workspace++ virtual-space proof: Add Desktop AX action accepted")

        try await waitUntil(
            timeout: 7,
            failure: .addDesktopWasNotObserved
        ) {
            self.monitor.reload()
            let added = Set(self.monitor.spaces.map(\.storageID))
                .subtracting(preClickIDs)
            return !added.isEmpty
        }

        session.disconnect()
        NSLog("Workspace++ virtual-space proof: disconnected temporary display")

        try await waitUntil(
            timeout: 8,
            failure: .virtualDisplayDidNotDisconnect
        ) {
            !self.activeDisplayIDs().contains(temporaryCGDisplayID)
        }
        try await Task.sleep(for: .milliseconds(900))
        monitor.reload()

        let newSpaces = monitor.spaces.filter { !originalIDs.contains($0.storageID) }
        NSLog(
            "Workspace++ virtual-space proof: finished with %d new surviving Spaces",
            newSpaces.count
        )
        guard !newSpaces.isEmpty else {
            throw VirtualSpaceCreationError.noSurvivingSpace
        }

        if let originalActiveSpaceID,
           monitor.activeID != originalActiveSpaceID {
            if originalSpaceSwitcher.setCurrentSpace(
                managedSpaceID: originalActiveSpaceID
            ) {
                try await Task.sleep(for: .milliseconds(650))
                monitor.reload()
                NSLog("Workspace++ virtual-space proof: restored original Space")
            } else {
                NSLog("Workspace++ virtual-space proof: could not restore original Space")
            }
        }
        return Result(newSpaces: newSpaces)
    }

    private func waitUntil(
        timeout: TimeInterval,
        failure: VirtualSpaceCreationError,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(120))
        } while Date() < deadline
        throw failure
    }

    private func activeDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0 else { return [] }
        var displayIDs = Array(
            repeating: CGDirectDisplayID(),
            count: Int(count)
        )
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return []
        }
        return Set(displayIDs.prefix(Int(count)))
    }

    private func showResult(_ result: Result) {
        let alert = NSAlert()
        if result.newSpaces.count == 1, let space = result.newSpaces.first {
            let display = monitor.displays.first { $0.id == space.displayID }
            let displayName = display.map {
                DisplayResolver.name(for: $0.id, ordinal: $0.ordinal)
            } ?? "a physical display"
            alert.messageText = "Workspace created"
            alert.informativeText = "macOS created exactly one new Space on "
                + displayName + ". Workspace++ detected it as Desktop "
                + String(space.ordinal) + "."
        } else {
            let locations = result.newSpaces.map { space in
                let display = monitor.displays.first { $0.id == space.displayID }
                return display.map {
                    DisplayResolver.name(for: $0.id, ordinal: $0.ordinal)
                } ?? space.displayID
            }
            alert.alertStyle = .warning
            alert.messageText = "macOS created " + String(result.newSpaces.count) + " Spaces"
            alert.informativeText = "The proof expected one. No automatic cleanup was attempted. Destinations: "
                + locations.joined(separator: ", ") + "."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Workspace creation did not complete"
        alert.informativeText += "\n\nWorkspace++ did not delete or modify any existing Space."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
