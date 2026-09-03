import Foundation

/// Lets a Settings toggle be flipped from the PostHog dashboard instead of
/// waiting for the user to click it, or for a new app release. PostHog has
/// no push channel — the app has to ask — so this fetches the current
/// Feature Flag state and applies it locally, the same way a user's own
/// click would: through the real `@Published` property, so it persists to
/// UserDefaults and updates the Settings UI exactly like a manual toggle.
///
/// Deliberately opt-in per toggle, not a blanket override: `MAPPING` below
/// is the only place a setting becomes remotely controllable, and a flag
/// that was never created in the PostHog dashboard for that key simply
/// never appears in the response — that toggle is untouched, still
/// entirely the user's own choice. Only add a setting here when it's
/// genuinely meant to be an admin-side kill switch or rollout control, not
/// as a way to quietly override a preference the user set for themselves.
enum PostHogRemoteConfig {
    // Shared with PostHogTracking.swift's event capture — same PostHog
    // project, one place to rotate either value.
    private static let apiKey = PostHogTracking.apiKey
    private static let host = PostHogTracking.host

    /// PostHog flag key -> the Settings toggle it controls. The flag key is
    /// what you create under Feature Flags in the PostHog dashboard; its
    /// boolean value (for "all users" or whatever rollout you set) becomes
    /// this property's new value the next time the app fetches flags.
    @MainActor
    private static let mapping: [(flagKey: String, keyPath: ReferenceWritableKeyPath<ClipboardManager, Bool>)] = [
        ("remote_ai_structuring_enabled", \.aiStructuringEnabled),
        ("remote_screenshot_capture_enabled", \.screenshotCaptureEnabled),
        ("remote_auto_tips_enabled", \.autoTipsEnabled),
        ("remote_interaction_sounds_enabled", \.interactionSoundsEnabled),
        ("remote_popup_hints_enabled", \.showPopupInteractionHints),
        ("remote_auto_dismiss_enabled", \.autoDismissEnabled),
        ("remote_reference_app_affinity_enabled", \.referenceAppAffinityEnabled),
        ("remote_uncaptured_fallback_enabled", \.uncapturedFallbackEnabled),
        ("remote_capture_rich_text_enabled", \.captureRichText),
        ("remote_capture_files_enabled", \.captureFiles),
        ("remote_fetch_url_titles_enabled", \.fetchURLTitles),
        ("remote_show_color_swatches_enabled", \.showColorSwatches),
        ("remote_unlimited_ring_size_enabled", \.unlimitedRingSize),
        ("remote_paste_plain_text_by_default", \.pastePlainTextByDefault),
        ("remote_advance_after_mark", \.advanceAfterMark),
        ("remote_open_on_second_tap", \.openOnSecondTap),
        ("remote_remember_last_selection", \.rememberLastSelection),
        ("remote_reverse_cycle_uses_b", \.reverseCycleUsesB),
    ]

    /// Every previously-applied override, so a flag change is detectable
    /// (only log/act on an actual change) and so a flag REMOVED from
    /// PostHog could, in principle, be told apart from one never fetched.
    /// Persisted because the alternative — re-deriving "did this come from
    /// a remote push or the user's own click" — isn't otherwise knowable
    /// once the value has been written into the same `@Published` property
    /// either way.
    private static let appliedDefaultsKey = "PostHogRemoteConfig.lastAppliedFlags"

    /// Fetches current flag state and applies any that are mapped above.
    /// Fire-and-forget, same posture as event capture: a network failure
    /// here must never block launch or crash anything — the app just keeps
    /// running on whatever values were already in UserDefaults, identical
    /// to how it behaves with no network at all.
    ///
    /// This is only ever called on launch and once every 6 hours
    /// (pasteApp.swift), so a single dropped request used to leave a
    /// remote-controlled toggle — a kill switch or rollout gate, per the
    /// mapping's own doc comment — stale for the entire 6-hour gap, not just
    /// a brief blip. One retry after a short delay closes that window
    /// without turning this into an open-ended retry loop.
    static func refreshAndApply(retryOnFailure: Bool = true) {
        guard let url = URL(string: "\(host)/decide/?v=3") else { return }
        let body: [String: Any] = [
            "api_key": apiKey,
            "distinct_id": DeviceIdentity.installKey,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let flags = root["featureFlags"] as? [String: Any]
            else {
                if retryOnFailure {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        refreshAndApply(retryOnFailure: false)
                    }
                }
                return
            }
            DispatchQueue.main.async {
                apply(flags: flags)
            }
        }.resume()
    }

    @MainActor
    private static func apply(flags: [String: Any]) {
        let manager = ClipboardManager.shared
        var lastApplied = UserDefaults.standard.dictionary(forKey: appliedDefaultsKey) as? [String: Bool] ?? [:]
        var changed = false

        for (flagKey, keyPath) in mapping {
            // PostHog returns `false` for a flag that resolves to "off" for
            // this user, but OMITS the key entirely for a flag that was
            // never created, or was deleted, in the dashboard — that
            // omission is exactly what keeps an un-configured toggle as the
            // user's own setting instead of silently becoming `false`.
            guard let value = flags[flagKey] as? Bool else { continue }
            guard lastApplied[flagKey] != value else { continue }

            manager[keyPath: keyPath] = value
            lastApplied[flagKey] = value
            changed = true
            DebugLog.write("PostHogRemoteConfig: applied \(flagKey) = \(value)")
        }

        guard changed else { return }
        UserDefaults.standard.set(lastApplied, forKey: appliedDefaultsKey)
    }
}
