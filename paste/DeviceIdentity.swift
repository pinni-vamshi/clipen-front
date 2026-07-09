import Foundation
import IOKit

/// A persistent-per-machine identifier for anonymous usage pings. Deliberately
/// NOT a random UUID stashed in UserDefaults — those get wiped and
/// regenerated on every reinstall (deleting the app removes its preferences
/// plist). IOPlatformUUID is tied to the Mac's logic board, so the same
/// machine reports as the same install across reinstalls and OS updates.
enum DeviceIdentity {
    static var installKey: String {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return "unknown" }
        defer { IOObjectRelease(platformExpert) }
        guard let value = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0) else {
            return "unknown"
        }
        return (value.takeRetainedValue() as? String) ?? "unknown"
    }
}
