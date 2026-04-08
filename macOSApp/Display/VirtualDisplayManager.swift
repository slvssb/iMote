import CoreGraphics
import Foundation

final class VirtualDisplayManager {
    private var display: AnyObject?
    private(set) var virtualDisplayID: CGDirectDisplayID?

    var isActive: Bool { display != nil }

    /// Creates a virtual display if no physical displays exist, or tears one down
    /// when a physical display becomes available. Call on server queue or before
    /// any capture / event-injection work begins.
    func ensureDisplayAvailable() -> VirtualDisplayEvent? {
        let physicals = physicalDisplayCount()
        if physicals == 0 && display == nil {
            let created = createVirtualDisplay(
                width: 2560,
                height: 1600,
                refreshRate: 60
            )
            return created ? .created : .creationFailed
        }
        if physicals > 0 && display != nil {
            tearDown()
            return .tornDown
        }
        return nil
    }

    func tearDown() {
        guard let obj = display as? NSObject else { return }
        Unmanaged<NSObject>.passUnretained(obj).release()
        display = nil
        virtualDisplayID = nil
    }

    func physicalDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return 0 }
        guard count > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return 0 }
        if let vID = virtualDisplayID {
            return ids.filter { $0 != vID }.count
        }
        return Int(count)
    }

    // MARK: - Private

    @discardableResult
    private func createVirtualDisplay(width: Int, height: Int, refreshRate: Double) -> Bool {
        guard let DescriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let DisplayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let ModeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let SettingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type else {
            return false
        }

        let descriptor = DescriptorClass.init()
        descriptor.setValue(UInt32(0x1ED5), forKey: "vendorID")
        descriptor.setValue(UInt32(0x0001), forKey: "productID")
        descriptor.setValue(UInt32(0x0001), forKey: "serialNum")
        descriptor.setValue("iMote Virtual Display", forKey: "name")
        descriptor.setValue(UInt32(width), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(height), forKey: "maxPixelsHigh")

        let ppi: Double = 144
        let physicalSize = CGSize(
            width: 25.4 * Double(width) / ppi,
            height: 25.4 * Double(height) / ppi
        )
        descriptor.setValue(NSValue(size: physicalSize), forKey: "sizeInMillimeters")

        descriptor.setValue(NSValue(point: NSPoint(x: 0.6797, y: 0.3203)), forKey: "redPrimary")
        descriptor.setValue(NSValue(point: NSPoint(x: 0.2559, y: 0.6983)), forKey: "greenPrimary")
        descriptor.setValue(NSValue(point: NSPoint(x: 0.1494, y: 0.0557)), forKey: "bluePrimary")
        descriptor.setValue(NSValue(point: NSPoint(x: 0.3125, y: 0.3291)), forKey: "whitePoint")
        descriptor.setValue(DispatchQueue(label: "com.imote.virtual-display"), forKey: "queue")

        let allocSelector = NSSelectorFromString("alloc")
        guard let allocated = (DisplayClass as AnyObject)
                .perform(allocSelector)?
                .takeUnretainedValue() as? NSObject,
              let displayObj = allocated
                .perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor)?
                .takeUnretainedValue() as? NSObject else {
            return false
        }

        let settings = SettingsClass.init()
        settings.setValue(UInt32(0), forKey: "hiDPI")

        guard let modeAllocated = (ModeClass as AnyObject)
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

        settings.setValue([mode], forKey: "modes")
        _ = displayObj.perform(NSSelectorFromString("applySettings:"), with: settings)

        // Keep the display object alive for the lifetime of the manager.
        // The passRetained balances the takeUnretainedValue above.
        _ = Unmanaged.passRetained(displayObj)
        display = displayObj
        virtualDisplayID = displayObj.value(forKey: "displayID") as? CGDirectDisplayID

        return virtualDisplayID != nil
    }
}

enum VirtualDisplayEvent {
    case created
    case creationFailed
    case tornDown
}
