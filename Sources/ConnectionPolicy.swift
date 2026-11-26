import Foundation

/// ImageCaptureCore may replace its ICCameraDevice instance when the USB driver
/// finishes loading or the phone reconnects. Object identity is not device identity.
struct USBDeviceIdentity {
    let persistentID: String?
    let uuid: String?
    let serial: String?
    let location: Int32

    func matches(_ other: Self) -> Bool {
        func same(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
            return lhs == rhs
        }
        return same(persistentID, other.persistentID) || same(uuid, other.uuid)
            || same(serial, other.serial) || (location != 0 && location == other.location)
    }
}
