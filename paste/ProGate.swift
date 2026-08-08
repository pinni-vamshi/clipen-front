import AppKit
import Combine
import FirebaseAnalytics
import Foundation
import SwiftUI

final class ProGate: ObservableObject {
    static let shared = ProGate()

    @Published private(set) var isUnlocked: Bool = true

    @Published private(set) var trialRemaining: Int = 0

    @Published private(set) var paywallApplies: Bool = false

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

    func evaluate() {
        let applies = UserDefaults.standard.bool(forKey: Key.paywallApplies)
        let used = TrackingService.shared.totalPastes
        let remaining = max(0, trialTotal - used)

        let paid = UserDefaults.standard.bool(forKey: Self.forceProKey)
            || UserDefaults.standard.bool(forKey: Key.serverIsPro)

        let unlocked = paid || !applies || remaining > 0

        if applies, !paid, trialRemaining > 0, remaining == 0 {
            AuthManager.shared.registerActionUsage(actionID: "action.trial_exhausted")
        }
        if paywallApplies != applies { paywallApplies = applies }
        if trialRemaining != remaining { trialRemaining = remaining }
        if isUnlocked != unlocked { isUnlocked = unlocked }
        if isPro != paid { isPro = paid }
    }

    private struct Entitlement: Decodable {
        let success: Bool
        let paywall: Bool
        let pro: Bool
        let trial_total: Int
    }

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

            if result.pro {
                Analytics.logEvent("pro_unlocked", parameters: nil)
            } else if result.paywall {
                Analytics.logEvent("paywall_gated", parameters: nil)
            }

            Analytics.setUserProperty(result.pro ? "pro" : "free", forName: "plan")

            DispatchQueue.main.async { [weak self] in
                self?.evaluate()
            }
        }.resume()
    }
}

struct SubscribeGateView: View {
    @ObservedObject private var pro = ProGate.shared

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
