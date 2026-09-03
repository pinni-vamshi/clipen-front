import Foundation

/// Direct client-side PostHog event capture — replaces the backend's
/// `posthog_forward.py`, which only ever sent events once a day, aggregated
/// per metric, batched from whatever `TrackingService` had queued up for
/// `/clipen/usage`. This fires the same event names/properties immediately,
/// at the moment the action actually happens, timestamped with this
/// machine's own clock — the backend's Firestore usage collection (the
/// once-a-day batch) is untouched and keeps working exactly as before.
///
/// Deliberately does NOT set `$geoip_disable`: the backend had to disable
/// it because it was forwarding from Render's own server IP, not the
/// user's. Sent straight from the user's Mac, PostHog's normal IP-based
/// geoip resolution is correct and should run as usual.
enum PostHogTracking {
    // Internal, not private: PostHogRemoteConfig.swift's /decide/ call uses
    // the same project key and host — previously copy-pasted verbatim into
    // both files, a rotation risk if only one copy ever got updated.
    static let apiKey = "phc_AiTe7F7AzGvjsKgm9753DXjiRuRgkYqHosvRxQqPa9DN"
    static let host = "https://us.i.posthog.com"

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Fire-and-forget — analytics must never block or affect the feature
    /// that triggered it, same posture as the backend's own send_batch.
    static func capture(_ event: String, properties: [String: Any] = [:], at date: Date = Date()) {
        guard let url = URL(string: "\(host)/capture/") else { return }
        let body: [String: Any] = [
            "api_key": apiKey,
            "event": event,
            "distinct_id": DeviceIdentity.installKey,
            "timestamp": iso8601.string(from: date),
            "properties": properties,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Mirrors the backend's person_set_event — `$set` for current-state
    /// properties, `$set_once` for values that should never be overwritten
    /// once recorded (e.g. first_seen).
    static func setPersonProperties(_ set: [String: Any], setOnce: [String: Any] = [:]) {
        var properties: [String: Any] = [:]
        if !set.isEmpty { properties["$set"] = set }
        if !setOnce.isEmpty { properties["$set_once"] = setOnce }
        guard !properties.isEmpty else { return }
        capture("$set", properties: properties)
    }
}
