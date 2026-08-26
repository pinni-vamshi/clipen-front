import AppKit
import Combine
import FirebaseAnalytics
import Foundation
import SwiftUI

/// One message the user sent via the in-app feedback box, as the server
/// sees it — identified by (date, index), matching clipen_backend's
/// `feedback_by_date` shape rather than a synthetic id, since messages
/// don't have their own id server-side. `/clipen/entitlement` now returns
/// every message for this device, not just ones with a reply attached (see
/// the endpoint's comment in main.py for why), so reply_text/reply_sent_at
/// are nil for a message that hasn't been answered yet — decoding this as
/// non-optional would fail the WHOLE response the first time any unreplied
/// entry came back, which given the change above is now the common case,
/// not an edge case.
struct FeedbackReply: Codable, Identifiable, Equatable {
    let date: String
    let index: Int
    /// HH:MM:SS on the sender's own local clock at the moment they hit
    /// Send (see AuthManager.timeKey / client_time) — nil only for entries
    /// sent before the server started recording this.
    let time: String?
    let message: String
    let reply_text: String?
    let reply_sent_at: String?

    var id: String { "\(date)|\(index)" }
}

/// One message the user sent via the in-app feedback box, recorded locally
/// the moment it's successfully POSTed. Needed because /clipen/entitlement
/// only ever returns entries that already have a developer reply attached
/// (see FeedbackReply above and clipen_backend's admin_feedback_reply) — a
/// message that hasn't been answered yet, or a second message sent the same
/// day, never comes back from the server at all. Without this, the feedback
/// panel could only ever show messages the developer had already answered,
/// which is backwards from how a real chat works: your own message should
/// appear the instant you send it, not only once someone replies.
struct SentFeedback: Codable, Identifiable, Equatable {
    let date: String
    let message: String
    let sentAt: Date

    var id: String { "\(date)|\(sentAt.timeIntervalSince1970)|\(message)" }
}

final class ProGate: ObservableObject {
    static let shared = ProGate()

    @Published private(set) var isUnlocked: Bool = true

    /// Days left in the free trial — server-computed (see clipen_backend's
    /// `_trial_days_remaining`), cached here, never re-derived locally.
    /// Counts down once `paywallApplies` is true; the gate (`isUnlocked`)
    /// only closes once this hits 0, not the instant the paywall is
    /// switched on.
    @Published private(set) var trialDaysRemaining: Int = 0

    @Published private(set) var paywallApplies: Bool = false

    @Published private(set) var isPro: Bool = false

    /// Developer replies to feedback the user sent via the in-app feedback
    /// box — server-computed (see clipen_backend's `/clipen/entitlement`),
    /// cached here so they survive relaunch even before the next refresh.
    @Published private(set) var feedbackReplies: [FeedbackReply] = []

    /// Every feedback message this device has sent, oldest first — see
    /// SentFeedback's doc comment for why this can't just come from the
    /// server. Recorded by recordSentFeedback(_:date:) at the moment a send
    /// succeeds; never trimmed, since feedback volume per device is tiny.
    @Published private(set) var sentFeedback: [SentFeedback] = []

    private static let forceProKey = "clipen.pro.forcePro"

    private enum Key {
        static let paywallApplies     = "clipen.pro.paywallApplies"
        static let serverIsPro        = "clipen.pro.serverIsPro"
        static let trialDaysRemaining = "clipen.pro.trialDaysRemaining"
        static let lastCheckedAt      = "clipen.pro.lastCheckedAt"
        static let everChecked        = "clipen.pro.everChecked"
        static let feedbackReplies    = "clipen.pro.feedbackReplies"
        static let sentFeedback       = "clipen.pro.sentFeedback"
    }

    private static let defaultTrialDays = 7
    private static let baseURL = URL(string: "https://clipen-backend.onrender.com")!

    /// `object(forKey:) != nil` (not just `integer(forKey:) > 0`) so that a
    /// genuine, real "0 days left" from the server stays 0 across relaunch —
    /// collapsing it back to the default would silently re-open the gate.
    private var cachedTrialDaysRemaining: Int {
        let d = UserDefaults.standard
        return d.object(forKey: Key.trialDaysRemaining) != nil
            ? d.integer(forKey: Key.trialDaysRemaining)
            : Self.defaultTrialDays
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Key.feedbackReplies),
           let cached = try? JSONDecoder().decode([FeedbackReply].self, from: data) {
            feedbackReplies = cached
        }
        if let data = UserDefaults.standard.data(forKey: Key.sentFeedback),
           let cached = try? JSONDecoder().decode([SentFeedback].self, from: data) {
            sentFeedback = cached
        }
        evaluate()
    }

    /// Call the moment a feedback POST to /clipen/feedback succeeds — `date`
    /// must be the exact same client_today value sent in that request, so
    /// this entry lines up with the (date, index) the server files it under.
    func recordSentFeedback(_ message: String, date: String) {
        let entry = SentFeedback(date: date, message: message, sentAt: Date())
        sentFeedback.append(entry)
        if let data = try? JSONEncoder().encode(sentFeedback) {
            UserDefaults.standard.set(data, forKey: Key.sentFeedback)
        }
    }

    func evaluate() {
        let applies = UserDefaults.standard.bool(forKey: Key.paywallApplies)
        let remaining = max(0, cachedTrialDaysRemaining)

        let paid = UserDefaults.standard.bool(forKey: Self.forceProKey)
            || UserDefaults.standard.bool(forKey: Key.serverIsPro)

        let unlocked = paid || !applies || remaining > 0

        if applies, !paid, trialDaysRemaining > 0, remaining == 0 {
            AuthManager.shared.registerActionUsage(actionID: "action.trial_exhausted")
        }
        if paywallApplies != applies { paywallApplies = applies }
        if trialDaysRemaining != remaining { trialDaysRemaining = remaining }
        if isUnlocked != unlocked { isUnlocked = unlocked }
        if isPro != paid { isPro = paid }
    }

    private struct Entitlement: Decodable {
        let success: Bool
        let paywall: Bool
        let pro: Bool
        let trial_days_remaining: Int?
        let feedback_replies: [FeedbackReply]?
    }

    /// Below this, a second refresh() call is a no-op — protects against
    /// rapidly flipping between Dashboard/Settings (each Settings-tab visit
    /// now triggers one, see MainWindowView's toolbarSwitcher) or opening
    /// several popups in quick succession from hammering the endpoint with
    /// duplicate requests for data that hasn't had time to change anyway.
    private static let minRefreshInterval: TimeInterval = 15
    private var lastRefreshAt: Date?

    func refresh() {
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < Self.minRefreshInterval { return }
        lastRefreshAt = Date()

        var comps = URLComponents(url: Self.baseURL.appendingPathComponent("clipen/entitlement"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "hardware_uuid", value: DeviceIdentity.installKey),
            URLQueryItem(name: "client_today", value: TrackingService.dateKey(Date())),
        ]
        guard let url = comps?.url else { return }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data,
                  let result = try? JSONDecoder().decode(Entitlement.self, from: data),
                  result.success
            else { return }

            let d = UserDefaults.standard
            d.set(result.paywall, forKey: Key.paywallApplies)
            d.set(result.pro, forKey: Key.serverIsPro)
            if let days = result.trial_days_remaining { d.set(days, forKey: Key.trialDaysRemaining) }
            d.set(Date().timeIntervalSince1970, forKey: Key.lastCheckedAt)
            d.set(true, forKey: Key.everChecked)

            let replies = result.feedback_replies ?? []
            if let repliesData = try? JSONEncoder().encode(replies) {
                d.set(repliesData, forKey: Key.feedbackReplies)
            }

            if result.pro {
                Analytics.logEvent("pro_unlocked", parameters: nil)
            } else if result.paywall {
                Analytics.logEvent("paywall_gated", parameters: nil)
            }

            Analytics.setUserProperty(result.pro ? "pro" : "free", forName: "plan")

            DispatchQueue.main.async { [weak self] in
                self?.evaluate()
                if self?.feedbackReplies != replies { self?.feedbackReplies = replies }
            }
        }.resume()
    }
}

struct SubscribeGateView: View {
    @ObservedObject private var pro = ProGate.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentDim)
                        .frame(width: 56, height: 56)
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.accent)
                }

                VStack(spacing: 6) {
                    Text("Your free trial is complete")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.textPri)

                    Text("Subscribe to Pro to keep using Clipen.")
                        .font(.system(size: 12))
                        .foregroundColor(.textSec)
                        .multilineTextAlignment(.center)
                }

                Button {
                    AuthManager.shared.registerActionUsage(actionID: "action.paywall_subscribe_click")
                    NSWorkspace.shared.open(DeviceIdentity.pricingURL)
                } label: {
                    Text("Subscribe to Pro")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Color.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                Text("Your clipboard history is safe and untouched.")
                    .font(.system(size: 10))
                    .foregroundColor(.textDim)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)

            Divider()
            HStack {
                Spacer()
                Text("Esc to close")
                    .font(.system(size: 10))
                    .foregroundColor(.textDim)
                Spacer()
            }
            .frame(height: 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            AuthManager.shared.registerActionUsage(actionID: "action.paywall_shown")
        }
    }
}
