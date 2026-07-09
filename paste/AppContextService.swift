import AppKit
import ApplicationServices

/// Captures a "context" string identifying not just which app is frontmost,
/// but WHICH tab/window/document within it — used to make Smart Reference's
/// auto-surface match a specific browser tab or Finder window, not just
/// "any Safari window." Best-effort, layered for maximum coverage:
///   1. Known scriptable apps (Safari, every Chromium-based browser, Finder)
///      — AppleScript queries the actual active-tab URL or window target,
///      the most precise signal available.
///   2. Everything else — the focused window's title via the Accessibility
///      API, which works for any app that exposes a standard window title
///      (most native Mac apps do). Less precise than a real tab/document
///      identity, but far broader than the scripted list alone.
///   3. Nothing usable (sandboxed app with no title, script denied, etc.)
///      — returns nil, and the caller falls back to the existing app-only
///      (bundle ID) matching, exactly as it worked before this feature.
enum AppContextService {
    /// Every Chromium-based browser shares Chrome's AppleScript dictionary
    /// shape (each just impersonates "Google Chrome" scripting support
    /// under its own app name), so one query below covers all of them.
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
            // Silent before this — a denied/not-yet-granted Automation
            // permission (System Settings > Privacy & Security > Automation
            // > Clipen) looks IDENTICAL to "nothing to capture" from the
            // caller's side (both just return nil), so tab/window tags can
            // silently stop appearing with zero visible cause. Logging the
            // real AppleScript error number (-1743 = not authorized is the
            // one to look for) makes that diagnosable via Console.app
            // instead of looking like a mystery feature regression.
            NSLog("[Clipen] AppContextService AppleScript failed: %@", errorDict)
        }
        guard errorDict == nil, let value = result.stringValue, !value.isEmpty else { return nil }
        return value
    }

    /// Every tab's title + URL across EVERY window of `bundleID` (not just
    /// the frontmost tab) — used by the semantic best-match path in
    /// ClipboardManager.surfaceReferencePanel, which needs to check if ANY
    /// open tab (not only the active one) reads as topically similar to a
    /// pinned reference, e.g. a second tab in a background window. Same
    /// layering as currentContext(for:): detailed for Safari/Chromium/
    /// Finder, single focused-window title for everything else.
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

    /// AppleScript list results come back from `.stringValue` joined with
    /// ", " — split back into individual entries. Good enough here since
    /// none of the fields we build (title/URL pairs, window names) contain
    /// ", " themselves in the overwhelming common case, and a stray misplit
    /// just means one candidate scores slightly oddly, not a crash or a
    /// wrong paste.
    private static func splitList(_ raw: String) -> [String] {
        raw.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    /// Accessibility fallback for any app that isn't one of the scripted
    /// cases above — reads the focused window's title. Requires the same
    /// Accessibility permission Clipen's ⌘V cycling already needs, so this
    /// never prompts for anything new.
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
