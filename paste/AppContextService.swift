import AppKit
import ApplicationServices

enum AppContextService {
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.pushplaylabs.sidekick",
    ]

    static func currentContext(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return runAppleScript("""
                tell application "Safari"
                    if (count of windows) = 0 then return ""
                    return URL of current tab of front window
                end tell
                """)

        case let id where chromiumBundleIDs.contains(id):
            guard let appName = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundleID })?.localizedName
            else { return nil }
            return runAppleScript("""
                tell application "\(appName)"
                    if (count of windows) = 0 then return ""
                    return URL of active tab of front window
                end tell
                """)

        case "com.apple.finder":
            return runAppleScript("""
                tell application "Finder"
                    if (count of Finder windows) = 0 then return ""
                    return (POSIX path of (target of front window as alias))
                end tell
                """)

        default:
            return accessibilityWindowTitle(forBundleID: bundleID)
        }
    }

    private static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorDict: NSDictionary?
        let result = script.executeAndReturnError(&errorDict)
        if let errorDict {
            NSLog("[Clipen] AppContextService AppleScript failed: %@", errorDict)
        }
        guard errorDict == nil, let value = result.stringValue, !value.isEmpty else { return nil }
        return value
    }

    static func allTabTexts(for bundleID: String) -> [String] {
        switch bundleID {
        case "com.apple.Safari":
            guard let raw = runAppleScript("""
                tell application "Safari"
                    set out to {}
                    repeat with w in windows
                        repeat with t in tabs of w
                            set end of out to ((name of t) & " || " & (URL of t))
                        end repeat
                    end repeat
                    return out
                """) else { return [] }
            return splitList(raw)

        case let id where chromiumBundleIDs.contains(id):
            guard let appName = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundleID })?.localizedName
            else { return [] }
            guard let raw = runAppleScript("""
                tell application "\(appName)"
                    set out to {}
                    repeat with w in windows
                        repeat with t in tabs of w
                            set end of out to ((title of t) & " || " & (URL of t))
                        end repeat
                    end repeat
                    return out
                """) else { return [] }
            return splitList(raw)

        case "com.apple.finder":
            guard let raw = runAppleScript("""
                tell application "Finder"
                    set out to {}
                    repeat with w in Finder windows
                        set end of out to (name of w)
                    end repeat
                    return out
                """) else { return [] }
            return splitList(raw)

        default:
            return accessibilityWindowTitle(forBundleID: bundleID).map { [$0] } ?? []
        }
    }

    private static func splitList(_ raw: String) -> [String] {
        raw.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    private static func accessibilityWindowTitle(forBundleID bundleID: String) -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
              let focusedWindowRef, CFGetTypeID(focusedWindowRef) == AXUIElementGetTypeID()
        else { return nil }
        let window = focusedWindowRef as! AXUIElement

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty
        else { return nil }
        return title
    }
}
