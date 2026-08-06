import AppKit
import Combine
import Foundation
import SwiftUI

/// Pro entitlement gate.
///
/// Split of responsibilities, deliberately:
///   * The BACKEND owns the *policy* — is the paywall on at all, is this
///     particular machine one of the test subjects, and how many free pastes
///     the trial grants. That lives in env vars server-side so it can change
///     without shipping a client build.
///   * The CLIENT owns the *arithmetic* — comparing its own lifetime paste
///     count against the granted trial. Doing the comparison locally means the
///     gate closes the instant the user crosses the threshold rather than
///     whenever the next poll happens to land, and it keeps working offline.
///
/// Failure behaviour is asymmetric on purpose. Never having reached the server
/// leaves the user unlocked (a network problem must not lock a paying user out
/// of their own clipboard), but a cached *locked* verdict survives going
/// offline (pulling the ethernet cable is not a way to extend the trial).
final class ProGate: ObservableObject {
    static let shared = ProGate()

    /// False only when the paywall applies to this machine AND the free trial
    /// has been used up. Everything reads this one flag.
    @Published private(set) var isUnlocked: Bool = true

    /// Free pastes left; only meaningful while `paywallApplies`.
    @Published private(set) var trialRemaining: Int = 0

    /// Whether this machine is subject to the paywall at all. False for every
    /// user today — the master switch is off and only listed test machines are
    /// gated — so the whole feature is inert until that changes.
    @Published private(set) var paywallApplies: Bool = false

    /// True once the user has actually PAID, per the server's `plan` field —
    /// not inferred from `paywall` being false, because that's also false for
    /// every ordinary user while the paywall is simply switched off. Without
    /// this as a distinct signal, the badge would go blank for a real
    /// subscriber instead of showing PRO, the moment their own paywall check
    /// legitimately clears. No payment processor exists yet, so this is
    /// `false` for everyone except the local override below.
    ///
    /// The local override exists only so the Pro appearance can be reviewed
    /// without a purchase flow:
    ///     defaults write com.clipen.app clipen.pro.forcePro -bool YES
    @Published private(set) var isPro: Bool = false

    private static let forceProKey = "clipen.pro.forcePro"

    private enum Key {
        static let paywallApplies = "clipen.pro.paywallApplies"
        static let serverIsPro    = "clipen.pro.serverIsPro"
        static let trialTotal     = "clipen.pro.trialTotal"
        static let lastCheckedAt  = "clipen.pro.lastCheckedAt"
        static let everChecked    = "clipen.pro.everChecked"
    }

    private static let defaultTrialTotal = 50
    private static let baseURL = URL(string: "https://clipen-backend.onrender.com")!

    private var trialTotal: Int {
        let stored = UserDefaults.standard.integer(forKey: Key.trialTotal)
        return stored > 0 ? stored : Self.defaultTrialTotal
    }

    private init() {
        evaluate()
    }

    // MARK: - Local evaluation

    /// Recompute from the cached policy plus the live paste count. Cheap and
    /// synchronous — safe to call on every popup open.
    func evaluate() {
        let applies = UserDefaults.standard.bool(forKey: Key.paywallApplies)
        let used = TrackingService.shared.totalPastes
        let remaining = max(0, trialTotal - used)

        let paid = UserDefaults.standard.bool(forKey: Self.forceProKey)
            || UserDefaults.standard.bool(forKey: Key.serverIsPro)
        // Paying always beats the gate; the trial only matters for non-payers.
        let unlocked = paid || !applies || remaining > 0
        // Fires once, on the actual 0-crossing — not every re-evaluation
        // while already exhausted (evaluate() runs on every popup open).
        if applies, !paid, trialRemaining > 0, remaining == 0 {
            AuthManager.shared.registerActionUsage(actionID: "action.trial_exhausted")
        }
        if paywallApplies != applies { paywallApplies = applies }
        if trialRemaining != remaining { trialRemaining = remaining }
        if isUnlocked != unlocked { isUnlocked = unlocked }
        if isPro != paid { isPro = paid }
    }

    // MARK: - Policy refresh

    private struct Entitlement: Decodable {
        let success: Bool
        let paywall: Bool
        let pro: Bool
        let trial_total: Int
    }

    /// Pull the current policy — whether this machine is gated at all, whether
    /// this user has an actual paid plan, and how big the trial is. Deliberately
    /// sends no paste count: the unlock decision is made locally in
    /// `evaluate()`, so a server-side verdict would only be thrown away.
    /// Called on launch, every popup open, and the 30-min background timer; a
    /// failure is silently ignored and the cached policy stands.
    func refresh() {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent("clipen/entitlement"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "hardware_uuid", value: DeviceIdentity.installKey),
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
            if result.trial_total > 0 { d.set(result.trial_total, forKey: Key.trialTotal) }
            d.set(Date().timeIntervalSince1970, forKey: Key.lastCheckedAt)
            d.set(true, forKey: Key.everChecked)

            DispatchQueue.main.async { [weak self] in
                self?.evaluate()
            }
        }.resume()
    }
}

// ============================================================================
// The paywall itself. Rendered *inside* the ⌘V popup in place of the clipboard
// ring, so the prompt appears exactly where the user's attention already is.
// ============================================================================

struct SubscribeGateView: View {
    @ObservedObject private var pro = ProGate.shared

    // No payment processor is wired up yet, so the CTA sends people to the web
    // page rather than opening an in-app purchase sheet.
    private static let subscribeURL = URL(string: "https://clipen.app/pro")!

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
                    NSWorkspace.shared.open(Self.subscribeURL)
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
