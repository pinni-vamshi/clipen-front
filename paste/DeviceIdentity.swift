import Foundation
import IOKit

enum DeviceIdentity {
    // The hardware UUID can't change while the process is running, and this is
    // read on nearly every network/analytics call — compute it once instead of
    // round-tripping through IOKit every time.
    static let installKey: String = {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return "unknown" }
        defer { IOObjectRelease(platformExpert) }
        guard let value = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0) else {
            return "unknown"
        }
        return (value.takeRetainedValue() as? String) ?? "unknown"
    }()

    static var isDeveloperDevice: Bool {
        installKey == "7D6AAA64-A175-5865-939D-B9B519B5B399"
    }

    /// The live site. Kept in one place because the onboarding shipped a
    /// hand-typed "https://clipen.app" for users to copy — a domain that
    /// resolves to nothing at all, so the tutorial was teaching people to
    /// copy a dead link.
    static let websiteURLString = "https://clipen.lovable.app"

    static var pricingURL: URL {
        var comps = URLComponents(string: "\(websiteURLString)/pricing.html")!
        comps.queryItems = [URLQueryItem(name: "hardware_uuid", value: installKey)]
        return comps.url!
    }
}
