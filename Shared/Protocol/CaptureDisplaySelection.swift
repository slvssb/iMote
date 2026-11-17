import Foundation

public struct DisplayHardwareIdentity: Codable, Equatable, Sendable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32

    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }

    /// Vendor, model, and serial are all zero for some virtual or not-yet-published displays.
    /// Those values must not be used to recognize a display after its ID changes.
    public var isSpecific: Bool {
        vendor != 0 || model != 0 || serial != 0
    }
}

public struct CaptureDisplayCandidate: Equatable, Sendable {
    public var id: UInt32
    public var pixelCount: Int
    public var isAsleep: Bool
    public var isVirtual: Bool
    public var isMain: Bool

    public init(id: UInt32, pixelCount: Int, isAsleep: Bool, isVirtual: Bool, isMain: Bool) {
        self.id = id
        self.pixelCount = pixelCount
        self.isAsleep = isAsleep
        self.isVirtual = isVirtual
        self.isMain = isMain
    }
}

public enum CaptureDisplaySelection {
    /// `preferredID` of 0 leaves the choice automatic.
    /// A pinned display is kept even when it is asleep, so an explicit choice is not replaced.
    public static func choose(
        from displays: [CaptureDisplayCandidate],
        preferredID: UInt32
    ) -> CaptureDisplayCandidate? {
        guard displays.isEmpty == false else { return nil }

        if preferredID != 0, let pinned = displays.first(where: { $0.id == preferredID }) {
            return pinned
        }

        let awakePhysical = displays.filter { $0.isAsleep == false && $0.isVirtual == false }
        if let main = awakePhysical.first(where: { $0.isMain }) {
            return main
        }
        if let largestAwake = awakePhysical.max(by: { $0.pixelCount < $1.pixelCount }) {
            return largestAwake
        }

        if let awakeVirtual = displays.first(where: { $0.isVirtual && $0.isAsleep == false }) {
            return awakeVirtual
        }
        if let virtual = displays.first(where: { $0.isVirtual }) {
            return virtual
        }

        if let main = displays.first(where: { $0.isMain }) {
            return main
        }
        return displays.max(by: { $0.pixelCount < $1.pixelCount })
    }
}
