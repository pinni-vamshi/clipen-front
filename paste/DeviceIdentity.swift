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

    /// Gates developer-only Settings UI (currently just the Beta updates
    /// toggle) to this one machine. A hardcoded installKey rather than a
    /// server-side flag on purpose — this needs to keep working even if
    /// the backend is unreachable, and it's a UI-visibility gate, not a
    /// security boundary.
    static var isDeveloperDevice: Bool {
        installKey == "7D6AAA64-A175-5865-939D-B9B519B5B399"
    }

    /// clipen.app has no DNS record yet (tracked separately) — points at
    /// the Lovable-hosted domain directly until that's fixed. hardware_uuid
    /// is required: the Paddle checkout forwards it into custom_data, and
    /// the backend webhook refuses to grant Pro to any purchase that
    /// arrives without one (see clipen_backend main.py's /paddle/webhook).
    static var pricingURL: URL {
        var comps = URLComponents(string: "https://clipen.lovable.app/pricing.html")!
        comps.queryItems = [URLQueryItem(name: "hardware_uuid", value: installKey)]
        return comps.url!
    }
}
