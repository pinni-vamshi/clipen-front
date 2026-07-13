import Foundation
import IOKit

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
