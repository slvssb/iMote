import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

enum HostDisplayPreferences {
    static let virtualDisplayWhenHeadlessKey = "imote.host.virtualDisplayWhenHeadless"
    static let selectedDisplayIDKey = "imote.host.selectedDisplayID"
    static let selectedVendorKey = "imote.host.selectedDisplayVendor"
    static let selectedModelKey = "imote.host.selectedDisplayModel"
    static let selectedSerialKey = "imote.host.selectedDisplaySerial"

    static var virtualDisplayWhenHeadless: Bool {
        if UserDefaults.standard.object(forKey: virtualDisplayWhenHeadlessKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: virtualDisplayWhenHeadlessKey)
    }

    static var selectedDisplayID: CGDirectDisplayID {
        storedUInt32(selectedDisplayIDKey)
    }

    static var selectedIdentity: DisplayHardwareIdentity? {
        let identity = DisplayHardwareIdentity(
            vendor: storedUInt32(selectedVendorKey),
            model: storedUInt32(selectedModelKey),
            serial: storedUInt32(selectedSerialKey)
        )
        return identity.isSpecific ? identity : nil
    }

    private static func storedUInt32(_ key: String) -> UInt32 {
        let value = UserDefaults.standard.integer(forKey: key)
        guard value > 0, value <= Int(UInt32.max) else { return 0 }
        return UInt32(value)
    }

    static func save(virtualDisplayWhenHeadless enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: virtualDisplayWhenHeadlessKey)
    }

    static func saveSelection(displayID: CGDirectDisplayID, identity: DisplayHardwareIdentity?) {
        UserDefaults.standard.set(Int(displayID), forKey: selectedDisplayIDKey)
        UserDefaults.standard.set(Int(identity?.vendor ?? 0), forKey: selectedVendorKey)
        UserDefaults.standard.set(Int(identity?.model ?? 0), forKey: selectedModelKey)
        UserDefaults.standard.set(Int(identity?.serial ?? 0), forKey: selectedSerialKey)
    }
}

struct HostDisplayRecord: Sendable {
    var info: HostDisplayInfo
    var identity: DisplayHardwareIdentity
    var cgBounds: CGRect
}

enum HostDisplayDirectory {
    @MainActor
    static func localizedNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber else {
                continue
            }
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty == false {
                names[number.uint32Value] = name
            }
        }
        return names
    }

    static func onlineRecords(
        virtualDisplayID: CGDirectDisplayID?,
        names: [CGDirectDisplayID: String],
        capturedID: CGDirectDisplayID?
    ) -> [HostDisplayRecord] {
        let ids = onlineDisplayIDs()
        return ids.map { id in
            let virtual = VirtualDisplayManager.isOurVirtualDisplay(id, knownID: virtualDisplayID)
            let kind: HostDisplayKind
            if virtual {
                kind = .virtual
            } else if CGDisplayIsBuiltin(id) != 0 {
                kind = .builtin
            } else {
                kind = .physical
            }

            let rawName = names[id] ?? ""
            let name: String
            if virtual {
                name = "Virtual display"
            } else if rawName.isEmpty == false {
                name = rawName
            } else if kind == .builtin {
                name = "Built-in display"
            } else {
                name = "Display"
            }

            let bounds = CGDisplayBounds(id)
            let info = HostDisplayInfo(
                id: id,
                name: name,
                width: Int(CGDisplayPixelsWide(id)),
                height: Int(CGDisplayPixelsHigh(id)),
                kind: kind,
                isAsleep: CGDisplayIsAsleep(id) != 0,
                isCaptured: capturedID == id
            )
            let identity = DisplayHardwareIdentity(
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id)
            )
            return HostDisplayRecord(info: info, identity: identity, cgBounds: bounds)
        }
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

enum VirtualDisplaySyncResult: Equatable {
    case created(CGDirectDisplayID)
    case creationFailed
    case tornDown
    case unchanged
}

/// Creates one private `CGVirtualDisplay` when macOS has no physical display online.
///
/// This is private CoreGraphics SPI. It is the right tool for an app you install yourself:
/// ScreenCaptureKit cannot invent a framebuffer, and there is no public API that creates a
/// display. App Store review can reject the class name even when it is looked up at runtime.
/// If creation fails on a future macOS, an HDMI dummy plug is the hardware fallback.
final class VirtualDisplayManager {
    static let vendorID: UInt32 = 0x1ED5
    static let productID: UInt32 = 0x0001
    static let serialNumber: UInt32 = 0x0001

    private let lock = NSLock()
    private var display: AnyObject?
    private(set) var virtualDisplayID: CGDirectDisplayID?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return display != nil
    }

    /// A sleeping physical display is still online. Leave it in place and wake it.
    /// A virtual display is only created once the physical display has actually left
    /// the online list, which is what macOS does when an HDMI hot-plug detect drops.
    func syncWithPhysicalDisplays(enabled: Bool) -> VirtualDisplaySyncResult {
        lock.lock()
        defer { lock.unlock() }

        if virtualDisplayObjectIsStale() {
            releaseVirtualDisplayLocked()
        }

        if enabled == false {
            guard display != nil else { return .unchanged }
            releaseVirtualDisplayLocked()
            return .tornDown
        }

        if hasOnlinePhysicalDisplayLocked() {
            guard display != nil else { return .unchanged }
            releaseVirtualDisplayLocked()
            return .tornDown
        }

        guard display == nil else { return .unchanged }
        guard createVirtualDisplayLocked(width: 2560, height: 1600, refreshRate: 60) else {
            return .creationFailed
        }
        return .created(virtualDisplayID ?? 0)
    }

    func tearDown() {
        lock.lock()
        defer { lock.unlock() }
        releaseVirtualDisplayLocked()
    }

    func physicalOnlineCount() -> Int {
        lock.lock()
        let knownID = virtualDisplayID
        lock.unlock()
        return HostDisplayDirectory.onlineDisplayIDs().filter { id in
            Self.isOurVirtualDisplay(id, knownID: knownID) == false
        }.count
    }

    static func isOurVirtualDisplay(_ id: CGDirectDisplayID, knownID: CGDirectDisplayID?) -> Bool {
        if let knownID, knownID != 0, id == knownID {
            return true
        }
        return CGDisplayVendorNumber(id) == vendorID
            && CGDisplayModelNumber(id) == productID
            && CGDisplaySerialNumber(id) == serialNumber
    }

    // MARK: - Private

    private func virtualDisplayObjectIsStale() -> Bool {
        guard display != nil else { return false }
        if let virtualDisplayID, virtualDisplayID != 0, CGDisplayIsOnline(virtualDisplayID) != 0 {
            return false
        }
        if let found = matchingVirtualDisplayID() {
            virtualDisplayID = found
            return false
        }
        return true
    }

    private func hasOnlinePhysicalDisplayLocked() -> Bool {
        HostDisplayDirectory.onlineDisplayIDs().contains { id in
            Self.isOurVirtualDisplay(id, knownID: virtualDisplayID) == false
        }
    }

    private func matchingVirtualDisplayID() -> CGDirectDisplayID? {
        HostDisplayDirectory.onlineDisplayIDs().first { id in
            CGDisplayVendorNumber(id) == Self.vendorID
                && CGDisplayModelNumber(id) == Self.productID
                && CGDisplaySerialNumber(id) == Self.serialNumber
        }
    }

    private func releaseVirtualDisplayLocked() {
        guard let obj = display as? NSObject else {
            display = nil
            virtualDisplayID = nil
            return
        }
        Unmanaged<NSObject>.passUnretained(obj).release()
        display = nil
        virtualDisplayID = nil
    }

    @discardableResult
    private func createVirtualDisplayLocked(width: Int, height: Int, refreshRate: Double) -> Bool {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type else {
            return false
        }

        let descriptor = descriptorClass.init()
        guard assign(descriptor, key: "vendorID", value: NSNumber(value: Self.vendorID)),
              assign(descriptor, key: "productID", value: NSNumber(value: Self.productID)),
              assign(descriptor, key: "serialNum", value: NSNumber(value: Self.serialNumber)),
              assign(descriptor, key: "name", value: "iMote Virtual Display"),
              assign(descriptor, key: "maxPixelsWide", value: NSNumber(value: width)),
              assign(descriptor, key: "maxPixelsHigh", value: NSNumber(value: height)) else {
            return false
        }

        let ppi: Double = 144
        let physicalSize = CGSize(
            width: 25.4 * Double(width) / ppi,
            height: 25.4 * Double(height) / ppi
        )
        _ = assign(descriptor, key: "sizeInMillimeters", value: NSValue(size: physicalSize))
        _ = assign(descriptor, key: "redPrimary", value: NSValue(point: NSPoint(x: 0.6797, y: 0.3203)))
        _ = assign(descriptor, key: "greenPrimary", value: NSValue(point: NSPoint(x: 0.2559, y: 0.6983)))
        _ = assign(descriptor, key: "bluePrimary", value: NSValue(point: NSPoint(x: 0.1494, y: 0.0557)))
        _ = assign(descriptor, key: "whitePoint", value: NSValue(point: NSPoint(x: 0.3125, y: 0.3291)))
        _ = assign(descriptor, key: "queue", value: DispatchQueue(label: "com.imote.virtual-display"))

        let allocSelector = NSSelectorFromString("alloc")
        guard let allocated = (displayClass as AnyObject)
            .perform(allocSelector)?
            .takeUnretainedValue() as? NSObject,
              let displayObj = allocated
            .perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor)?
            .takeUnretainedValue() as? NSObject else {
            return false
        }

        let settings = settingsClass.init()
        guard assign(settings, key: "hiDPI", value: NSNumber(value: 0)) else {
            return false
        }

        guard let modeAllocated = (modeClass as AnyObject)
            .perform(allocSelector)?
            .takeUnretainedValue() as? NSObject else {
            return false
        }

        typealias ModeInitFunc = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?
        let modeSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let modeInit = unsafeBitCast(modeAllocated.method(for: modeSelector), to: ModeInitFunc.self)
        guard let mode = modeInit(modeAllocated, modeSelector, UInt32(width), UInt32(height), refreshRate) as? NSObject else {
            return false
        }

        guard assign(settings, key: "modes", value: [mode]) else {
            return false
        }

        typealias ApplyFunc = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let applySelector = NSSelectorFromString("applySettings:")
        guard displayObj.responds(to: applySelector) else { return false }
        let apply = unsafeBitCast(displayObj.method(for: applySelector), to: ApplyFunc.self)
        guard apply(displayObj, applySelector, settings) else { return false }

        _ = Unmanaged.passRetained(displayObj)
        display = displayObj
        virtualDisplayID = readDisplayID(from: displayObj) ?? waitForPublishedVirtualDisplayID()
        return true
    }

    private func readDisplayID(from displayObj: NSObject) -> CGDirectDisplayID? {
        if let number = displayObj.value(forKey: "displayID") as? NSNumber, number.uint32Value != 0 {
            return number.uint32Value
        }
        return nil
    }

    private func waitForPublishedVirtualDisplayID() -> CGDirectDisplayID? {
        for _ in 0..<20 {
            if let found = matchingVirtualDisplayID() {
                return found
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return matchingVirtualDisplayID()
    }

    @discardableResult
    private func assign(_ object: NSObject, key: String, value: Any) -> Bool {
        let setterName = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        let setter = NSSelectorFromString(setterName)
        guard object.responds(to: setter) else { return false }
        object.setValue(value, forKey: key)
        return true
    }
}

/// Holds the display and the system awake only while a paired iPhone is connected.
final class RemoteSessionPowerAssertion {
    private let lock = NSLock()
    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0

    /// Sleep can invalidate an assertion without telling us. Drop the IDs so the next
    /// activate call creates fresh ones.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        releaseAssertion(&displayAssertion)
        releaseAssertion(&systemAssertion)
    }

    func setRemoteSessionActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if active {
            if displayAssertion == 0 {
                displayAssertion = createAssertion(
                    kIOPMAssertionTypeNoDisplaySleep as CFString,
                    name: "iMote is showing this Mac on a connected iPhone"
                )
            }
            if systemAssertion == 0 {
                systemAssertion = createAssertion(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    name: "iMote is controlling this Mac from a connected iPhone"
                )
            }
        } else {
            releaseAssertion(&displayAssertion)
            releaseAssertion(&systemAssertion)
        }
    }

    func wakeDisplaysNow() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            "iMote remote session" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
    }

    private func createAssertion(_ type: CFString, name: String) -> IOPMAssertionID {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &assertionID
        )
        return result == kIOReturnSuccess ? assertionID : 0
    }

    private func releaseAssertion(_ assertionID: inout IOPMAssertionID) {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}
