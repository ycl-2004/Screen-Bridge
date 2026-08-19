import Foundation
import CoreGraphics
import VirtualDisplayLib

/// Swift wrapper for the Objective-C VirtualDisplay functionality
/// Uses private CoreGraphics APIs to create virtual displays
final class VirtualDisplayManager: @unchecked Sendable {
    enum DisplayPlacement: String, CaseIterable, Identifiable {
        case right
        case left
        case above
        case below

        var id: String { rawValue }

        var title: String {
            switch self {
            case .right: return "Right"
            case .left: return "Left"
            case .above: return "Above"
            case .below: return "Below"
            }
        }
    }

    
    struct Resolution: Hashable {
        let width: Int
        let height: Int
        let ppi: Int
        let hiDPI: Bool
        let name: String
    }
    
    static let receiverBestFitResolution = Resolution(width: 2688, height: 1868, ppi: 220, hiDPI: true, name: "1344 x 934 HiDPI (Best Fit)")

    static let defaultResolutions: [Resolution] = [
        receiverBestFitResolution,
        Resolution(width: 1024, height: 768, ppi: 220, hiDPI: true, name: "1024 x 768 HiDPI (Larger Text)"),
        Resolution(width: 1280, height: 720, ppi: 92, hiDPI: false, name: "1280 x 720 (HD)"),
        Resolution(width: 1920, height: 1080, ppi: 102, hiDPI: false, name: "1920 x 1080 (FHD)"),
        Resolution(width: 1920, height: 1200, ppi: 113, hiDPI: false, name: "1920 x 1200 (16:10)"),
        Resolution(width: 2560, height: 1440, ppi: 109, hiDPI: false, name: "2560 x 1440 (2K)"),
        Resolution(width: 2560, height: 1600, ppi: 227, hiDPI: true, name: "2560 x 1600 (16:10)"),
        Resolution(width: 3840, height: 2160, ppi: 163, hiDPI: false, name: "3840 x 2160 (4K)"),
        Resolution(width: 1440, height: 900, ppi: 127, hiDPI: false, name: "1440 x 900 (16:10)"),
    ]
    
    /// Identity of the virtual display presented to WindowServer.
    ///
    /// This used to be a process-local counter starting at 1, so every launch
    /// reused serial 1, 2, 3… Those identities accumulate state in the system's
    /// display configuration, and once WindowServer decides one of them stays
    /// offline it never publishes it again: `CGDisplayBounds` still answers, but
    /// the display is absent from `CGGetOnlineDisplayList` and invisible to
    /// ScreenCaptureKit. The result is a virtual display that can never become a
    /// real extended desktop — a permanently black receiver.
    ///
    /// The serial is therefore persisted (so macOS remembers the arrangement
    /// across launches) and rotated automatically whenever an identity turns out
    /// to be unusable.
    private static let serialDefaultsKey = "virtualDisplaySerialNumber"

    /// Identities below this are avoided entirely: they are the low counter
    /// values earlier builds burned through, and are the ones most likely to
    /// already be poisoned on a machine that ran those builds.
    private static let minimumUsableSerial: UInt32 = 1000

    private static func loadOrCreateSerial() -> UInt32 {
        let stored = UInt32(UserDefaults.standard.integer(forKey: serialDefaultsKey))
        if stored >= minimumUsableSerial { return stored }
        return rotateSerial()
    }

    @discardableResult
    private static func rotateSerial() -> UInt32 {
        let fresh = UInt32.random(in: minimumUsableSerial...UInt32(Int32.max))
        UserDefaults.standard.set(Int(fresh), forKey: serialDefaultsKey)
        return fresh
    }

    /// How long WindowServer is given to publish a newly created display.
    private static let onlineTimeout: TimeInterval = 2.0
    /// Withdrawal is best-effort: WindowServer often keeps a retired display
    /// listed for a while, and `createDisplay` already recovers by moving to a
    /// fresh identity. Waiting longer here would only slow every reconnect down.
    private static let offlineTimeout: TimeInterval = 0.8
    private static let onlinePollInterval: TimeInterval = 0.1
    /// Number of distinct identities tried before giving up.
    private static let maximumIdentityAttempts = 3

    /// `activeDisplay`/`displayID` are read from the main thread's deferred
    /// callbacks while `destroyDisplay()` may run elsewhere, so access goes
    /// through this lock instead of relying on the previous unsynchronized
    /// stored properties.
    private let stateLock = NSLock()
    private var activeDisplayStorage: Any?
    private var displayIDStorage: CGDirectDisplayID?
    private var isCreatingDisplay = false

    var displayID: CGDirectDisplayID? {
        stateLock.withLock { displayIDStorage }
    }

    var onDisplayBoundsChanged: ((CGRect) -> Void)?

    /// Creates a virtual display with the specified resolution
    /// - Returns: The CGDirectDisplayID of the created virtual display, or nil if creation failed
    /// Outcome of a virtual-display creation attempt. `busy` is not an error:
    /// it means another creation is already running on this manager, which
    /// happens when runloop-serviced UI callbacks re-enter `createDisplay`
    /// mid-flight. Callers should retry shortly instead of failing the
    /// connection.
    enum CreationOutcome {
        case success(CGDirectDisplayID)
        case busy
        case failure
    }

    func createDisplay(resolution: Resolution, placement: DisplayPlacement = .right) -> CreationOutcome {
        return createDisplay(
            width: resolution.width,
            height: resolution.height,
            ppi: resolution.ppi,
            hiDPI: resolution.hiDPI,
            name: resolution.name,
            placement: placement
        )
    }

    /// Creates a virtual display with custom parameters.
    ///
    /// Creation is only half the job: WindowServer can hand back a display
    /// object whose ID answers `CGDisplayBounds` while never publishing it as an
    /// online display. Capture backends cannot see such a display and the user
    /// cannot move windows onto it, so it is treated as a failure and retried
    /// under a fresh identity rather than returned as if it worked.
    func createDisplay(width: Int, height: Int, ppi: Int, hiDPI: Bool, name: String, placement: DisplayPlacement = .right) -> CreationOutcome {
        // `waitOnePollInterval` services the main runloop while waiting for
        // WindowServer, so debounced UI callbacks can re-enter this method in
        // the middle of the (up to ~8s) creation. A nested create would fight
        // the outer one for WindowServer's single virtual-display slot.
        guard stateLock.withLock({ () -> Bool in
            guard !isCreatingDisplay else { return false }
            isCreatingDisplay = true
            return true
        }) else {
            LogManager.shared.log("VirtualDisplayManager: Refusing nested createDisplay while another creation is in flight")
            return .busy
        }
        defer { stateLock.withLock { isCreatingDisplay = false } }

        // WindowServer publishes at most one of these private virtual displays
        // at a time: while an earlier one is still alive, every new display is
        // created successfully but silently never goes online. Reconnecting
        // therefore has to fully retire the previous display first.
        destroyDisplay()

        for attempt in 1...VirtualDisplayManager.maximumIdentityAttempts {
            let serial = VirtualDisplayManager.loadOrCreateSerial()

            // Held in a var so the failed display can be released deterministically
            // before the next attempt creates another one.
            var display: Any? = createVirtualDisplay(
                Int32(width),
                Int32(height),
                Int32(ppi),
                hiDPI,
                name,
                serial
            )

            guard let created = display else {
                LogManager.shared.log("VirtualDisplayManager: Failed to create virtual display (serial \(serial))")
                VirtualDisplayManager.rotateSerial()
                continue
            }

            guard let displayIDValue = (created as AnyObject).value(forKey: "displayID") as? UInt32 else {
                LogManager.shared.log("VirtualDisplayManager: Created display but couldn't get ID (serial \(serial))")
                display = nil
                VirtualDisplayManager.rotateSerial()
                continue
            }

            if waitUntilOnline(displayIDValue) {
                stateLock.withLock {
                    activeDisplayStorage = created
                    displayIDStorage = displayIDValue
                }
                LogManager.shared.log("VirtualDisplayManager: Created virtual display with ID \(displayIDValue) (serial \(serial), attempt \(attempt))")
                schedulePlacement(for: displayIDValue, placement: placement)
                return .success(displayIDValue)
            }

            LogManager.shared.log(
                "VirtualDisplayManager: Display \(displayIDValue) (serial \(serial)) never came online "
                    + "(attempt \(attempt)); releasing it before retrying"
            )
            display = nil
            waitUntilOffline(displayIDValue)
            VirtualDisplayManager.rotateSerial()
        }

        LogManager.shared.log(
            "VirtualDisplayManager: Could not obtain an online virtual display after "
                + "\(VirtualDisplayManager.maximumIdentityAttempts) attempts. "
                + "Another virtual display may still be held by this app."
        )
        return .failure
    }

    /// True once WindowServer publishes `displayID` as an online display.
    ///
    /// `CGDisplayBounds` is deliberately not used as the signal: it returns a
    /// plausible rect for displays that are known to CoreGraphics but withheld
    /// from the desktop, which is exactly the failure being detected here.
    private func waitUntilOnline(_ displayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(VirtualDisplayManager.onlineTimeout)
        repeat {
            if onlineDisplayIDs().contains(displayID) { return true }
            waitOnePollInterval()
        } while Date() < deadline
        return onlineDisplayIDs().contains(displayID)
    }

    /// Waits for a retired display to disappear from the online list.
    @discardableResult
    private func waitUntilOffline(_ displayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(VirtualDisplayManager.offlineTimeout)
        repeat {
            if !onlineDisplayIDs().contains(displayID) { return true }
            waitOnePollInterval()
        } while Date() < deadline
        return !onlineDisplayIDs().contains(displayID)
    }

    /// Waits one poll interval **without starving the main runloop**.
    ///
    /// The sender is launched by Launch Services, which makes it a full
    /// WindowServer client. A newly created virtual display only transitions to
    /// online once WindowServer's messages are processed on the main thread, so
    /// sleeping the main thread here meant the display never appeared and every
    /// connection failed with "Virtual display unavailable". Sleeping is still
    /// correct off the main thread, where there is no runloop to service.
    private func waitOnePollInterval() {
        let interval = VirtualDisplayManager.onlinePollInterval
        if Thread.isMainThread {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
        } else {
            Thread.sleep(forTimeInterval: interval)
        }
    }
    
    /// Destroys the currently active virtual display.
    ///
    /// Dropping the reference is not enough: WindowServer withdraws the display
    /// asynchronously, and while it lingers no replacement display can go
    /// online. Reconnect immediately follows disconnect, so this waits for the
    /// withdrawal to actually land.
    func destroyDisplay() {
        let retiringID = stateLock.withLock { () -> CGDirectDisplayID? in
            let id = displayIDStorage
            activeDisplayStorage = nil
            displayIDStorage = nil
            return id
        }

        guard let retiringID else { return }
        let wentOffline = waitUntilOffline(retiringID)
        LogManager.shared.log(
            "VirtualDisplayManager: Destroyed virtual display \(retiringID)"
                + (wentOffline ? "" : " (WindowServer still listing it; the next display will use a fresh identity)")
        )
    }
    
    deinit {
        destroyDisplay()
    }

    private func schedulePlacement(for displayID: CGDirectDisplayID, placement: DisplayPlacement, attempt: Int = 1) {
        let delays: [TimeInterval] = [0.25, 0.75, 1.5, 3.0, 5.0]
        guard attempt <= delays.count else { return }

        let delay = delays[attempt - 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.displayID == displayID else { return }

            if self.placeDisplay(displayID, relativeToBuiltIn: placement) {
                LogManager.shared.log("VirtualDisplayManager: Placed display \(displayID) \(placement.rawValue) of the built-in display (attempt \(attempt))")
                // A successful configuration is terminal. Reapplying display
                // configuration after success makes WindowServer repeatedly
                // withdraw and republish the new display while
                // ScreenCaptureKit is trying to discover it.
                return
            } else {
                LogManager.shared.log("VirtualDisplayManager: Placement attempt \(attempt) failed for display \(displayID)")
            }
            self.schedulePlacement(for: displayID, placement: placement, attempt: attempt + 1)
        }
    }

    private func placeDisplay(_ displayID: CGDirectDisplayID, relativeToBuiltIn placement: DisplayPlacement) -> Bool {
        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            return false
        }

        let referenceDisplayID = builtInDisplayID() ?? CGMainDisplayID()
        let referenceBounds = CGDisplayBounds(referenceDisplayID)
        guard referenceBounds.width > 0, referenceBounds.height > 0 else {
            return false
        }

        let occupiedDisplays = onlineDisplayIDs().filter { $0 != displayID }
        var targetOrigin = targetOrigin(
            for: displayBounds.size,
            beside: referenceBounds,
            avoiding: occupiedDisplays.map { CGDisplayBounds($0) },
            placement: placement
        )

        let targetRect = CGRect(origin: targetOrigin, size: displayBounds.size)
        if occupiedDisplays.contains(where: { CGDisplayBounds($0).intersects(targetRect) }) {
            targetOrigin = fallbackOuterOrigin(
                for: displayBounds.size,
                beside: referenceBounds,
                avoiding: occupiedDisplays.map { CGDisplayBounds($0) },
                placement: placement
            )
        }

        guard applyDisplayOrigin(displayID, targetOrigin) else {
            return false
        }

        let updatedBounds = CGDisplayBounds(displayID)
        if updatedBounds.width > 0, updatedBounds.height > 0 {
            onDisplayBoundsChanged?(updatedBounds)
        } else {
            onDisplayBoundsChanged?(CGRect(origin: targetOrigin, size: displayBounds.size))
        }

        return true
    }

    private func applyDisplayOrigin(_ displayID: CGDirectDisplayID, _ origin: CGPoint) -> Bool {
        let x = Int32(origin.x.rounded())
        let y = Int32(origin.y.rounded())

        // Session-scoped on purpose. This display exists only while a receiver
        // is connected, so writing its arrangement into the machine's permanent
        // display configuration leaves behind state for a display that no longer
        // exists. The placement is reapplied on every connection anyway, so
        // nothing is lost by not persisting it.
        return configureDisplayOrigin(displayID, x: x, y: y, option: .forSession)
    }

    private func configureDisplayOrigin(
        _ displayID: CGDirectDisplayID,
        x: Int32,
        y: Int32,
        option: CGConfigureOption
    ) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            LogManager.shared.log("VirtualDisplayManager: Failed to begin display configuration")
            return false
        }

        let configureError = CGConfigureDisplayOrigin(
            config,
            displayID,
            x,
            y
        )
        guard configureError == .success else {
            CGCancelDisplayConfiguration(config)
            LogManager.shared.log("VirtualDisplayManager: Failed to configure display origin for \(displayID): \(configureError.rawValue)")
            return false
        }

        let completeError = CGCompleteDisplayConfiguration(config, option)
        guard completeError == .success else {
            LogManager.shared.log("VirtualDisplayManager: Failed to complete display configuration for \(displayID): \(completeError.rawValue)")
            return false
        }

        return true
    }

    private func targetOrigin(
        for displaySize: CGSize,
        beside referenceBounds: CGRect,
        avoiding occupiedBounds: [CGRect],
        placement: DisplayPlacement
    ) -> CGPoint {
        let proposed: CGPoint
        switch placement {
        case .right:
            proposed = CGPoint(x: referenceBounds.maxX, y: referenceBounds.minY)
        case .left:
            proposed = CGPoint(x: referenceBounds.minX - displaySize.width, y: referenceBounds.minY)
        case .above:
            proposed = CGPoint(x: referenceBounds.minX, y: referenceBounds.minY - displaySize.height)
        case .below:
            proposed = CGPoint(x: referenceBounds.minX, y: referenceBounds.maxY)
        }

        let proposedRect = CGRect(origin: proposed, size: displaySize)
        if !occupiedBounds.contains(where: { $0.intersects(proposedRect) }) {
            return proposed
        }

        return fallbackOuterOrigin(
            for: displaySize,
            beside: referenceBounds,
            avoiding: occupiedBounds,
            placement: placement
        )
    }

    private func fallbackOuterOrigin(
        for displaySize: CGSize,
        beside referenceBounds: CGRect,
        avoiding occupiedBounds: [CGRect],
        placement: DisplayPlacement
    ) -> CGPoint {
        switch placement {
        case .right:
            let rightMostX = occupiedBounds.map(\.maxX).max() ?? referenceBounds.maxX
            return CGPoint(x: rightMostX, y: referenceBounds.minY)
        case .left:
            let leftMostX = occupiedBounds.map(\.minX).min() ?? referenceBounds.minX
            return CGPoint(x: leftMostX - displaySize.width, y: referenceBounds.minY)
        case .above:
            let topMostY = occupiedBounds.map(\.minY).min() ?? referenceBounds.minY
            return CGPoint(x: referenceBounds.minX, y: topMostY - displaySize.height)
        case .below:
            let bottomMostY = occupiedBounds.map(\.maxY).max() ?? referenceBounds.maxY
            return CGPoint(x: referenceBounds.minX, y: bottomMostY)
        }
    }

    private func builtInDisplayID() -> CGDirectDisplayID? {
        onlineDisplayIDs().first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)

        var status = CGGetOnlineDisplayList(UInt32(displays.count), &displays, &displayCount)
        if status == .success && displayCount > UInt32(displays.count) {
            // More online displays than the fixed buffer could hold. Growing the
            // buffer to the reported count keeps large desktops from being
            // silently truncated (a truncated list made the virtual display look
            // offline and triggered pointless identity rotation).
            displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            status = CGGetOnlineDisplayList(UInt32(displays.count), &displays, &displayCount)
        }
        guard status == .success else {
            return []
        }

        return Array(displays.prefix(Int(displayCount)))
    }
}
