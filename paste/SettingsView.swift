import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers


struct CollectionsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SettingsRow2HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private enum CollectionAlertKind {
    case new
    case rename(String)
    case delete(String)
}

struct ClipenSettingsView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var auth    = AuthManager.shared
    @ObservedObject private var proGate = ProGate.shared

    @Binding var showResetConfirm: Bool

    @State private var row1Height: CGFloat = 0

    @State private var newCollectionName = ""
    @State private var renameCollectionText = ""
    /// One shared trigger for all three collection alerts. Chaining three
    /// separate `.alert(isPresented:)` modifiers on the same view is the
    /// cause of a real bug: SwiftUI only reliably tracks one alert's
    /// presentation state per view identity, so after a handful of
    /// presentations across the three, EVERY alert on this view — new,
    /// rename, and delete alike — silently stops presenting at all,
    /// with no error and no visible feedback on click. Routing all
    /// three through a single `.alert(_:isPresented:presenting:)` call
    /// keyed on this one enum removes the conflict entirely.
    @State private var collectionAlertKind: CollectionAlertKind? = nil
    @State private var showingCollectionAlert = false
    @State private var scrollViewportWidth: CGFloat = 0
    @State private var showExcludedAppsManager = false
    @State private var row2Height: CGFloat = 0
    @State private var showAutoPreviewPicker = false
    @State private var showRememberTimeoutPicker = false
    @State private var showAutoDismissPicker = false
    @State private var showOpenDelayPicker = false
    @State private var showPinPositionPicker = false

    private enum FeedbackSendState { case idle, sent, failed }
    @State private var feedbackText = ""
    @State private var feedbackSending = false
    @State private var feedbackSendState: FeedbackSendState = .idle
    @State private var pendingLanguage: AppLanguage?
    @State private var showLanguagePicker = false

    /// SwiftUI-owned source of truth for the beta channel, persisted to the
    /// same UserDefaults key `AppDelegate.allowedChannels(for:)` reads. Using
    /// @AppStorage (instead of a computed binding through weak AppDelegate.shared)
    /// makes turning it OFF actually persist and stops it snapping back on.
    @AppStorage("SUBetaUpdatesEnabled") private var betaUpdatesEnabled = false

    private struct Row1HeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsScrollContent
            Divider().background(Color.border)
            footer
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .onAppear { manager.refreshLaunchAtLoginStatus() }
    }

    private var settingsScrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 44) {
                proUpsellBanner
                collectionsSection

                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 34) {
                        ringSizeSection
                        appSettingsSection
                    }
                    .frame(maxWidth: .infinity, minHeight: row1Height, alignment: .topLeading)
                    .measured(Row1HeightKey.self)

                    mainBehaviourSection
                        .frame(maxWidth: .infinity, minHeight: row1Height, alignment: .topLeading)
                        .measured(Row1HeightKey.self)
                }
                .onPreferenceChange(Row1HeightKey.self) { row1Height = $0 }

                interactionsSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .onPreferenceChange(SettingsRow2HeightKey.self) { row2Height = $0 }

                tipsSection

                feedbackSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
    }

    // MARK: - Tips
    //
    // Cards for the app's real, tracked lesson windows — not a second,
    // separately-worded copy of the same gestures. Heading/description come
    // straight from InteractionDemo (the same source the keyboard-demo
    // popup above and the automatic nudges already use), and clicking a
    // card opens that exact lesson window via `presentTipManually`. The
    // first 5 are the ones that can ALSO appear automatically once their
    // usage threshold is crossed; Collections and Search only ever open
    // from here (see NudgeFeature.thresholdMet).

    private static let tipFeatures: [NudgeFeature] =
        [.multiPaste, .groups, .preview, .pinPreview, .transformPanel, .collections, .search]

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("05", "TIPS")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.tipFeatures, id: \.self) { feature in
                        tipCard(feature)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func tipCard(_ feature: NudgeFeature) -> some View {
        let learned = manager.isNudgeLearned(feature)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(LocalizedStringKey(feature.demo.title))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.textPri)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: learned ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(learned ? .green : .textDim.opacity(0.5))
            }
            // No line cap — the caption fills however much of the card it
            // needs and only truncates if it genuinely doesn't fit, instead
            // of always cutting off at a fixed line count regardless of how
            // much room was actually left.
            Text(LocalizedStringKey(feature.demo.caption))
                .font(.system(size: 11))
                .foregroundColor(.textSec)
            HStack(spacing: 3) {
                Text("Practice")
                Image(systemName: "chevron.right")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.accent)
        }
        .frame(width: 180, height: 140, alignment: .topLeading)
        .padding(12)
        .background(Color.surfaceHi.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipped()
        .onTapGesture { manager.presentTipManually(feature) }
        .help(learned ? "Learned — click to see it again" : "Click to see how")
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("06", "FEEDBACK")

            rowCard(border: .allSides) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Send a message straight to the developer — suggest a feature, report a bug, or paste a macOS crash report.")
                        .font(.system(size: 11)).foregroundColor(.textSec)

                    TextEditor(text: $feedbackText)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(height: 80)
                        .padding(6)
                        .background(Color.surfaceHi.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.border, lineWidth: 1))

                    HStack {
                        if feedbackSendState == .failed {
                            Text("Couldn't send — check your connection and try again.")
                                .font(.system(size: 10)).foregroundColor(.red.opacity(0.8))
                        }
                        Spacer()
                        feedbackReplyHint
                        Button {
                            sendFeedback()
                        } label: {
                            Text(feedbackSending ? "Sending…" : "Send")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(feedbackSending
                                  || feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(14)
            }
        }
    }

    private var feedbackReplyHint: some View {
        HStack(spacing: 4) {
            Text("You can see replies on the")
                .font(.system(size: 11)).foregroundColor(.textPri.opacity(0.85))
            Button {
                if let url = URL(string: "https://www.instagram.com/clipen.official") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Clipen Instagram page")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func sendFeedback() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !feedbackSending else { return }
        feedbackSending = true
        feedbackSendState = .idle
        TrackingService.shared.sendFeedback(trimmed) { success in
            feedbackSending = false
            if success {
                feedbackText = ""
                feedbackSendState = .sent
            } else {
                feedbackSendState = .failed
            }
        }
    }

    private func sectionHeader(_ number: String, _ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(3)
            .foregroundColor(.textSec)
    }

    private func rowNumber(_ n: Int) -> some View {
        Text(String(format: "%02d", n))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.textDim)
            .frame(width: 18, alignment: .leading)
    }

    private enum RowCardBorder { case leadingLine, allSides }

    private func rowCard<C: View>(border: RowCardBorder = .leadingLine,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .overlay {
                if case .allSides = border {
                    Rectangle().stroke(Color.border, lineWidth: 1)
                }
            }
            .overlay(alignment: .leading) {
                if case .leadingLine = border {
                    Rectangle().fill(Color.border).frame(width: 2)
                }
            }
    }

    private func rowDivider(leading: CGFloat = 44) -> some View {
        Divider().background(Color.border).padding(.leading, leading)
    }

    private func behaviourRow(_ n: Int, icon: String, _ label: LocalizedStringKey,
                              isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text(label).font(.system(size: 13)).foregroundColor(.textPri)
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).tint(.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private func autoPreviewRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "eye").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Always show preview").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                togglePopover($showAutoPreviewPicker)
            } label: {
                Text("Configure")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Choose which content types auto-show preview")
            .popover(isPresented: $showAutoPreviewPicker, arrowEdge: .bottom) {
                autoPreviewPicker
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private var autoPreviewPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Auto-preview for").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                Spacer()
                Button(manager.autoPreviewTypes.count == AutoPreviewContentType.allCases.count ? "Clear" : "Select All") {
                    if manager.autoPreviewTypes.count == AutoPreviewContentType.allCases.count {
                        manager.autoPreviewTypes = []
                    } else {
                        manager.autoPreviewTypes = Set(AutoPreviewContentType.allCases)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.accent)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ForEach(AutoPreviewContentType.allCases) { type in
                let isOn = manager.autoPreviewTypes.contains(type)
                Button {
                    if isOn { manager.autoPreviewTypes.remove(type) } else { manager.autoPreviewTypes.insert(type) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: type.sfIcon).font(.system(size: 11)).foregroundColor(.textSec).frame(width: 16)
                        Text(type.label).font(.system(size: 12)).foregroundColor(.textPri)
                        Spacer()
                        if isOn {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.accent)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 6)
        }
        .frame(width: 200)
        .padding(.bottom, 4)
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Language").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AppLanguage.supported) { lang in
                        let isOn = lang.code == manager.appLanguageCode
                        Button {
                            showLanguagePicker = false
                            guard !isOn else { return }
                            pendingLanguage = lang
                        } label: {
                            HStack(spacing: 8) {
                                Text(lang.displayName).font(.system(size: 12)).foregroundColor(.textPri)
                                Spacer()
                                if isOn {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.accent)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
            Spacer(minLength: 6)
        }
        .frame(width: 200)
        .padding(.bottom, 4)
    }

    private static let rememberTimeoutPresets = [1, 3, 5, 10, 15, 30, 60]

    private func rememberLastPositionRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Remember last position").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                togglePopover($showRememberTimeoutPicker)
            } label: {
                let minutes = manager.rememberLastPositionTimeoutMinutes
                let label = minutes == 0 ? "∞"
                    : (minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m")
                HStack(spacing: 4) {
                    Image(systemName: minutes == 0 ? "infinity" : "timer").font(.system(size: 9, weight: .semibold))
                    Text(label).font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(manager.rememberLastSelection ? .textPri : .textDim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(manager.rememberLastSelection ? Color.surfaceHi : Color.surfaceHi.opacity(0.4),
                            in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!manager.rememberLastSelection)
            .opacity(manager.rememberLastSelection ? 1 : 0.4)
            .help("How long a remembered position stays valid before reopening starts at the top again")
            .popover(isPresented: $showRememberTimeoutPicker, arrowEdge: .bottom) {
                rememberTimeoutPicker
            }
            Toggle("", isOn: $manager.rememberLastSelection).toggleStyle(.switch).controlSize(.mini).tint(.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private static let openDelayPresets: [(label: LocalizedStringKey, seconds: Double)] =
        [("Fast", 0.10), ("Medium", 0.25), ("Slow", 0.50)]

    private func openDelayRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "hourglass").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Open delay").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                togglePopover($showOpenDelayPicker)
            } label: {
                Text("Configure")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showOpenDelayPicker, arrowEdge: .bottom) {
                openDelayPicker
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private var openDelayPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $manager.openOnSecondTap) {
                Text("Open on second V click").font(.system(size: 12)).foregroundColor(.textPri)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch).controlSize(.mini).tint(.accent)
            .padding(.horizontal, 12).padding(.vertical, 10)

            Divider().padding(.horizontal, 8)

            Text("Delay speed").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            openDelayChoice(label: "Off",
                            isOn: !manager.openOnSecondTap && manager.firstOpenDelay == 0) {
                manager.firstOpenDelay = 0
                manager.openOnSecondTap = false
            }

            ForEach(Self.openDelayPresets, id: \.seconds) { preset in
                openDelayChoice(label: preset.label,
                                isOn: !manager.openOnSecondTap && manager.firstOpenDelay == preset.seconds) {
                    manager.firstOpenDelay = preset.seconds
                    manager.openOnSecondTap = false
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 200)
    }

    private func openDelayChoice(label: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).foregroundColor(.textPri)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pinPositionRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "pin.fill").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Pin to top").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                togglePopover($showPinPositionPicker)
            } label: {
                Text("Configure")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPinPositionPicker, arrowEdge: .bottom) {
                pinPositionPicker
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private var pinPositionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Starting position").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)

            HStack(spacing: 14) {
                pinCounterButton("minus", enabled: manager.pinStartPosition > 1) {
                    manager.pinStartPosition = max(1, manager.pinStartPosition - 1)
                }
                Text("\(manager.pinStartPosition)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.textPri)
                    .frame(minWidth: 28)
                pinCounterButton("plus", enabled: manager.pinStartPosition < ClipboardManager.maxPinnedItems) {
                    manager.pinStartPosition = min(ClipboardManager.maxPinnedItems, manager.pinStartPosition + 1)
                }
            }
            .frame(maxWidth: .infinity)

            Text("At most \(ClipboardManager.maxPinnedItems) items can be pinned at once.")
                .font(.system(size: 10)).foregroundColor(.textSec)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 200)
    }

    private func pinCounterButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .foregroundColor(enabled ? .textPri : .textDim)
                .frame(width: 30, height: 30)
                .background(Color.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private static let autoDismissPresets: [Double] = [10, 30, 60, 180, 300, 600, 1800]

    private func autoDismissRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "timer").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Auto-dismiss popup").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                togglePopover($showAutoDismissPicker)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hourglass.bottomhalf.filled").font(.system(size: 9, weight: .semibold))
                    Text(Self.autoDismissLabel(manager.autoDismissSeconds))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(manager.autoDismissEnabled ? .textPri : .textDim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(manager.autoDismissEnabled ? Color.surfaceHi : Color.surfaceHi.opacity(0.4),
                            in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!manager.autoDismissEnabled)
            .opacity(manager.autoDismissEnabled ? 1 : 0.4)
            .help("How long the popup sits idle before it auto-dismisses")
            .popover(isPresented: $showAutoDismissPicker, arrowEdge: .bottom) {
                autoDismissPicker
            }
            Toggle("", isOn: $manager.autoDismissEnabled).toggleStyle(.switch).controlSize(.mini).tint(.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private static func autoDismissLabel(_ seconds: Double) -> String {
        seconds >= 60 ? "\(Int(seconds / 60))m" : "\(Int(seconds))s"
    }

    private var autoDismissPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Dismiss after").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ForEach(Self.autoDismissPresets, id: \.self) { seconds in
                rememberTimeoutRow(
                    label: seconds >= 60 ? "\(Int(seconds / 60)) min\(seconds == 60 ? "" : "s")" : "\(Int(seconds)) sec",
                    isOn: manager.autoDismissSeconds == seconds
                ) {
                    manager.autoDismissSeconds = seconds
                    showAutoDismissPicker = false
                }
            }
            Spacer(minLength: 6)
        }
        .frame(width: 160)
        .padding(.bottom, 4)
    }

    private var rememberTimeoutPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Reopen within").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            rememberTimeoutRow(label: "Until turned off", isOn: manager.rememberLastPositionTimeoutMinutes == 0) {
                manager.rememberLastPositionTimeoutMinutes = 0
                showRememberTimeoutPicker = false
            }

            Divider().padding(.horizontal, 8).padding(.vertical, 2)

            ForEach(Self.rememberTimeoutPresets, id: \.self) { minutes in
                rememberTimeoutRow(label: minutes >= 60 ? "\(minutes / 60) hour" : "\(minutes) min\(minutes == 1 ? "" : "s")",
                                   isOn: manager.rememberLastPositionTimeoutMinutes == minutes) {
                    manager.rememberLastPositionTimeoutMinutes = minutes
                    showRememberTimeoutPicker = false
                }
            }
            Spacer(minLength: 6)
        }
        .frame(width: 160)
        .padding(.bottom, 4)
    }

    private func rememberTimeoutRow(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(label)).font(.system(size: 12)).foregroundColor(.textPri)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ringStepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .foregroundColor(.textSec)
                .frame(width: 30, height: 30)
                .background(Color.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pro upsell

    /// Sits above Collections. Disappears entirely once the user is Pro — at
    /// that point the toolbar badge alone carries the status, and a permanent
    /// "subscribe" strip in a paid app would just be noise. Gated on
    /// paywallApplies for the same reason as the toolbar badge: the paywall is
    /// inert for real users today, so there is nothing to upsell them on yet.
    @ViewBuilder
    private var proUpsellBanner: some View {
        if proGate.paywallApplies && !proGate.isPro {
            Button {
                NSWorkspace.shared.open(URL(string: "https://clipen.app/pro")!)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accent)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Subscribe to Pro")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.textPri)
                        Text("Unlock everything and support Clipen's development.")
                            .font(.system(size: 10))
                            .foregroundColor(.textSec)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textDim)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accent.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Collections

    /// Opening any of the picker popovers below routes through
    /// NSPopover.show(...) — see WakeGuard for why that's gated. Closing
    /// stays instant; only the "turning on" transition is ever delayed,
    /// and only in the rare post-wake window.
    private func togglePopover(_ flag: Binding<Bool>) {
        if flag.wrappedValue {
            flag.wrappedValue = false
        } else {
            WakeGuard.afterWakeSettle { flag.wrappedValue = true }
        }
    }

    private var collectionAlertTitle: String {
        switch collectionAlertKind {
        case .new:        return String(localized: "New collection")
        case .rename:     return String(localized: "Rename collection")
        case .delete:     return String(localized: "Delete collection?")
        case nil:         return ""
        }
    }

    private var collectionsSection: some View {
        VStack(alignment: .center, spacing: 14) {
            sectionHeader("00", "COLLECTIONS")
                .frame(maxWidth: .infinity, alignment: .center)

            Text("All is your whole clipboard, unfiltered. Create a collection and anything you copy while it's active is filed under it — hold ⌘ and press 1–9 in the popup to switch instantly.")
                .font(.system(size: 11)).foregroundColor(.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Slot 1 is always All; collections take 2 onward.
                    collectionPill(name: nil, slot: 1)

                    ForEach(Array(manager.collections.enumerated()), id: \.element) { index, name in
                        collectionPill(name: name, slot: index + 2)
                    }

                    if manager.collections.count < ClipboardManager.maxCollections {
                        Button {
                            newCollectionName = ""
                            collectionAlertKind = .new
                            showingCollectionAlert = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                Text("New").font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.accent)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.accent.opacity(0.45),
                                              style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                // Centre the pills while they fit, and only start scrolling
                // once they genuinely overflow.
                .frame(minWidth: scrollViewportWidth, alignment: .center)
            }
            .measuredWidth(CollectionsWidthKey.self)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // Same card treatment as the Interaction Preview panel, stretched the
        // full width of the settings column with its own interior padding.
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.surfaceHi.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.border, lineWidth: 1))
        .onPreferenceChange(CollectionsWidthKey.self) { scrollViewportWidth = $0 }
        .alert(collectionAlertTitle, isPresented: $showingCollectionAlert, presenting: collectionAlertKind) { kind in
            switch kind {
            case .new:
                TextField("Name", text: $newCollectionName)
                Button("Cancel", role: .cancel) { }
                Button("Create") { manager.addCollection(named: newCollectionName) }
            case .rename(let old):
                TextField("Name", text: $renameCollectionText)
                Button("Cancel", role: .cancel) { }
                Button("Rename") { manager.renameCollection(old, to: renameCollectionText) }
            case .delete(let name):
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) { manager.deleteCollection(name) }
            }
        } message: { kind in
            switch kind {
            case .new:
                Text("Up to \(ClipboardManager.maxCollections) collections.")
            case .rename:
                Text("Items already in this collection follow the new name.")
            case .delete(let name):
                Text("Items only in “\(name)” are deleted. Items that also live in another collection are kept there.")
            }
        }
    }

    // MARK: - Excluded Apps
    //
    // Deliberately NOT a Collections-style pill row — this lives as a single
    // "Excluded apps / Manage" row inside App Settings instead (in the exact
    // slot the redundant "Check for Updates" row used to occupy, since that
    // duplicated the toolbar's own Check-for-Updates button). The management
    // surface is a compact vertical list in a popover, not a card of its own
    // on the main settings page — a "set once, rarely revisit" feature earns
    // a lower profile than Collections, which people switch between often.

    private var excludedAppsManagerPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Excluded apps").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                Spacer()
                Button {
                    browseForApplicationToExclude()
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundColor(.accent)
                }
                .buttonStyle(.plain)
                .help("Choose any installed app — it doesn't need to be running")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            Text("Copies from these apps are never captured into your history.")
                .font(.system(size: 10)).foregroundColor(.textDim)
                .padding(.horizontal, 12).padding(.bottom, 6)

            if manager.excludedCaptureBundleIDs.isEmpty {
                Text("None yet — tap + to add one.")
                    .font(.system(size: 11)).foregroundColor(.textDim)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(manager.excludedCaptureBundleIDs).sorted(), id: \.self) { bundleID in
                            excludedAppRow(bundleID: bundleID)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            Spacer(minLength: 6)
        }
        .frame(width: 240)
        .padding(.bottom, 4)
    }

    private func excludedAppRow(bundleID: String) -> some View {
        HStack(spacing: 8) {
            if let icon = ClipenIconCache.shared.appIcon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 12)).foregroundColor(.textDim)
            }
            Text(excludedAppDisplayName(for: bundleID))
                .font(.system(size: 12)).foregroundColor(.textPri)
            Spacer()
            Button {
                manager.excludedCaptureBundleIDs.remove(bundleID)
            } label: {
                Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).foregroundColor(.textDim)
            }
            .buttonStyle(.plain)
            .help("Stop excluding this app")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// Native "choose an app" panel, scoped to /Applications — the standard
    /// macOS pattern for this (Automator, "Open With → Other…", login-item
    /// pickers all work this way). Deliberately NOT a list of currently
    /// running processes: the whole point of an exclusion list is apps like
    /// a password manager that you set up once and that may well not be
    /// open at the moment you're configuring this.
    private func browseForApplicationToExclude() {
        let panel = NSOpenPanel()
        // NSOpenPanel.title is a plain String — never goes through SwiftUI's
        // catalog lookup on its own, so this needs the explicit wrap.
        panel.title = String(localized: "Choose an App to Exclude")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        manager.excludedCaptureBundleIDs.insert(bundleID)
    }

    private func excludedAppDisplayName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return running.localizedName ?? bundleID
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    @ViewBuilder
    private func collectionPill(name: String?, slot: Int) -> some View {
        let isActive = manager.activeCollection == name

        HStack(spacing: 8) {
            // Leading shortcut badge — the literal keystroke that selects it.
            Text("⌘\(slot)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isActive ? .white.opacity(0.9) : .textDim)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))

            Text(name ?? String(localized: "All"))
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? .white : .textPri)

            // Trailing delete — only real collections can be removed; All is
            // the unfiltered view, not something that can be deleted.
            if let name {
                Button {
                    collectionAlertKind = .delete(name)
                    showingCollectionAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isActive ? .white.opacity(0.8) : .textDim)
                }
                .buttonStyle(.plain)
                .help("Delete “\(name)”")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isActive ? Color.accent : Color.surfaceHi.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(isActive ? Color.clear : Color.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { manager.activeCollection = name }
        .contextMenu {
            if let name {
                Button("Rename\u{2026}") {
                    renameCollectionText = name
                    collectionAlertKind = .rename(name)
                    showingCollectionAlert = true
                }
                Button("Delete\u{2026}", role: .destructive) {
                    collectionAlertKind = .delete(name)
                    showingCollectionAlert = true
                }
            }
        }
    }

    private var ringSizeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("01", "RING SIZE")

            Text("\(manager.maxItems)")
                .font(.system(size: 64, weight: .black))
                .foregroundColor(.textPri)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Maximum items in ring")
                .font(.system(size: 11)).foregroundColor(.textSec)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 10) {
                ringStepButton("minus") {
                    withAnimation { manager.setRingSize(manager.maxItems - 5) }
                }
                Slider(value: Binding(get: { Double(manager.maxItems) },
                                      set: { manager.setRingSize(Int(($0 / 5).rounded() * 5)) }),
                       in: 10...500)
                    .tint(.accent)
                ringStepButton("plus") {
                    withAnimation { manager.setRingSize(manager.maxItems + 5) }
                }
            }

            HStack {
                Text("10").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
                Spacer()
                Text("500").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
            }
        }
    }

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("02", "APP SETTINGS")

            rowCard(border: .allSides) {
                HStack(spacing: 10) {
                    Image(systemName: "power").font(.system(size: 11)).foregroundColor(.accent).frame(width: 16)
                    Text("Launch at Login").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Toggle("", isOn: Binding(get: { manager.launchAtLogin },
                                            set: { manager.launchAtLogin = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)

                rowDivider(leading: 40)

                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Auto updates").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { AppDelegate.shared?.automaticallyChecksForUpdates ?? true },
                        set: { value in
                            AppDelegate.shared?.automaticallyChecksForUpdates = value
                            if !value { AppDelegate.shared?.automaticallyDownloadsUpdates = false }
                        }))
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)

                rowDivider(leading: 40)

                HStack(spacing: 10) {
                    Image(systemName: "testtube.2").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Beta updates").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Toggle("", isOn: $betaUpdatesEnabled)
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)

                rowDivider(leading: 40)

                HStack(spacing: 10) {
                    Image(systemName: "globe").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Language").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Button {
                        togglePopover($showLanguagePicker)
                    } label: {
                        Text(AppLanguage.current(for: manager.appLanguageCode).displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accent)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showLanguagePicker, arrowEdge: .bottom) {
                        languagePicker
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)

                rowDivider(leading: 40)

                HStack(spacing: 10) {
                    Image(systemName: "eye.slash").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Excluded apps").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Button {
                        togglePopover($showExcludedAppsManager)
                    } label: {
                        Text("Manage")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.accent)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Apps whose copies are never captured into history")
                    .popover(isPresented: $showExcludedAppsManager, arrowEdge: .bottom) {
                        excludedAppsManagerPopover
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)
            }
        }
        .alert("Restart Clipen to switch language?",
               isPresented: Binding(get: { pendingLanguage != nil }, set: { if !$0 { pendingLanguage = nil } })) {
            Button("Restart Now", role: .destructive) {
                if let lang = pendingLanguage {
                    manager.appLanguageCode = lang.code
                    AppLanguage.apply(lang.code)
                }
                pendingLanguage = nil
            }
            Button("Cancel", role: .cancel) { pendingLanguage = nil }
        } message: {
            Text("Clipen needs to restart to switch to \(pendingLanguage?.displayName ?? "").")
        }
    }

    private var mainBehaviourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("03", "MAIN BEHAVIOUR")

            rowCard {
                openDelayRow(1)

                rowDivider()
                autoPreviewRow(2)
                rowDivider()
                pinPositionRow(3)
                rowDivider()
                rememberLastPositionRow(4)
                rowDivider()
                autoDismissRow(5)
                rowDivider()
                behaviourRow(6, icon: "arrow.right.to.line", "Advance after marking",
                             isOn: Binding(get: { manager.advanceAfterMark },
                                           set: { manager.advanceAfterMark = $0 }))
                rowDivider()
                purePasteRow(7)
            }
        }
    }

    private func purePasteRow(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                rowNumber(n)
                Image(systemName: "textformat").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                Text("Pure paste").font(.system(size: 13)).foregroundColor(.textPri)
                Spacer()
                Toggle("", isOn: Binding(get: { manager.pastePlainTextByDefault },
                                          set: { manager.pastePlainTextByDefault = $0 }))
                    .toggleStyle(.switch).controlSize(.mini).tint(.accent)
            }
            Text(manager.pastePlainTextByDefault
                 ? "Paste with formatting is available via Transform (X)"
                 : "Paste without formatting is available via Transform (X)")
                .font(.system(size: 10))
                .foregroundColor(.textDim.opacity(0.6))
                .padding(.leading, 44)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private static let interactionGroups: [[InteractionDemo]] = [
        [.cycle, .pinnedOpen],
        [.reverseCycle, .multiPaste],
        [.spacePreview, .pinPreview],
        [.transform, .search, .nextCategory, .moveToFront, .delete],
        [.cyclePinned, .pinItem, .group, .collections],
    ]

    private var interactionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionHeader("04", "INTERACTIONS")

                Button {
                    manager.showPopupInteractionHints.toggle()
                } label: {
                    Text(manager.showPopupInteractionHints ? "Hints in popup: On" : "Hints in popup: Off")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(manager.showPopupInteractionHints ? .accent : .textDim)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(manager.showPopupInteractionHints ? Color.accentDim : Color.white.opacity(0.06),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .help(manager.showPopupInteractionHints
                      ? "Hide the interaction hint strip at the top of the popup"
                      : "Show the interaction hint strip at the top of the popup")

                Button {
                    manager.interactionSoundsEnabled.toggle()
                } label: {
                    Text(manager.interactionSoundsEnabled ? "Navigation sounds: On" : "Navigation sounds: Off")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(manager.interactionSoundsEnabled ? .accent : .textDim)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(manager.interactionSoundsEnabled ? Color.accentDim : Color.white.opacity(0.06),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .help(manager.interactionSoundsEnabled
                      ? "Turn off sound feedback for popup gestures (V, Space, X, C, S, P, Delete)"
                      : "Play a sound for every popup gesture (V, Space, X, C, S, P, Delete)")
            }

            KeyboardInteractionPanel()
                .padding(.vertical, 14)
                .frame(minHeight: row2Height, alignment: .top)
                .background(Color.surfaceHi.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .measured(SettingsRow2HeightKey.self)
        }
    }

    // MARK: - Keyboard-based interaction picker
    //
    // Replaces the old flat list of demo rows. Renders an actual keyboard;
    // the keys that trigger a real gesture (V, C, X, G, P, F, `, Space,
    // Delete, Shift) get a pulsing blue border, ⌘ is gold. Click a key to
    // toggle a popup beside it (not over it) showing that gesture's demo —
    // and, for gestures with a configurable speed, the Slow/Medium/Fast
    // picker right there in the same popup. Click the same key again to
    // close it.

    struct KBKey: Identifiable, Equatable {
        let id: String
        let label: String
        var width: CGFloat = 1
        var demos: [InteractionDemo] = []
        var isCommand: Bool = false
        /// Consecutive keys sharing the same groupID render as ONE bordered
        /// cluster (e.g. the whole 1–9 row for Collections) instead of each
        /// key getting its own separate blue box — any of them opens the
        /// same demo, since the real gesture is "hold ⌘ and press 1–9",
        /// not tied to any single number.
        var groupID: String? = nil
        static func == (l: KBKey, r: KBKey) -> Bool { l.id == r.id }
    }

    private enum KBLayout {
        // 1 is "All", 2 through maxCollections+1 are your collections — the
        // whole row is one gesture (hold ⌘, press 1–9), so all nine keys
        // share the Collections demo and render as a single grouped cluster.
        private static let collectionNumberKeys: [KBKey] = (1...9).map { n in
            KBKey(id: "\(n)", label: "\(n)", demos: [.collections], groupID: "collections")
        }

        static let rows: [[KBKey]] = [
            [KBKey(id: "GRAVE", label: "`", demos: [.nextCategory])]
            + collectionNumberKeys
            + [KBKey(id: "0", label: "0"),
             KBKey(id: "MINUS", label: "-"), KBKey(id: "EQUAL", label: "="),
             KBKey(id: "DELETE", label: "⌫", width: 1.6, demos: [.delete])],
            [KBKey(id: "TAB", label: "tab", width: 1.4),
             KBKey(id: "Q", label: "Q"), KBKey(id: "W", label: "W"), KBKey(id: "E", label: "E"),
             KBKey(id: "R", label: "R"), KBKey(id: "T", label: "T"), KBKey(id: "Y", label: "Y"),
             KBKey(id: "U", label: "U"), KBKey(id: "I", label: "I"), KBKey(id: "O", label: "O"),
             KBKey(id: "P", label: "P", demos: [.cyclePinned, .pinItem]),
             KBKey(id: "LBRACKET", label: "["), KBKey(id: "RBRACKET", label: "]"),
             KBKey(id: "BACKSLASH", label: "\\", width: 1.2)],
            [KBKey(id: "CAPS", label: "caps", width: 1.6),
             KBKey(id: "A", label: "A"), KBKey(id: "S", label: "S"), KBKey(id: "D", label: "D"),
             KBKey(id: "F", label: "F", demos: [.search]),
             KBKey(id: "G", label: "G", demos: [.group]),
             KBKey(id: "H", label: "H"), KBKey(id: "J", label: "J"), KBKey(id: "K", label: "K"),
             KBKey(id: "L", label: "L"), KBKey(id: "SEMI", label: ";"), KBKey(id: "QUOTE", label: "'"),
             KBKey(id: "RETURN", label: "return", width: 1.8)],
            [KBKey(id: "LSHIFT", label: "shift", width: 2.0),
             KBKey(id: "Z", label: "Z"),
             KBKey(id: "X", label: "X", demos: [.transform]),
             KBKey(id: "C", label: "C", demos: [.moveToFront]),
             // Reverse (previously its own thing on Shift) is now a category
             // of V itself — Shift+V IS a V gesture, not a separate key.
             KBKey(id: "V", label: "V", demos: [.cycle, .multiPaste, .pinnedOpen, .reverseCycle]),
             // B doubles as the alternate reverse-cycle trigger when that
             // setting is toggled on (see the toggle inside the reverse demo).
             KBKey(id: "B", label: "B", demos: [.reverseCycle]),
             KBKey(id: "N", label: "N"), KBKey(id: "M", label: "M"),
             KBKey(id: "COMMA", label: ","), KBKey(id: "PERIOD", label: "."), KBKey(id: "SLASH", label: "/"),
             KBKey(id: "RSHIFT", label: "shift", width: 2.4)],
            [KBKey(id: "FN", label: "fn", width: 1.2),
             KBKey(id: "CTRL", label: "control", width: 1.3),
             KBKey(id: "OPT", label: "option", width: 1.3),
             KBKey(id: "LCMD", label: "⌘", width: 1.3, isCommand: true),
             KBKey(id: "SPACE", label: "", width: 5.6, demos: [.spacePreview, .pinPreview]),
             KBKey(id: "RCMD", label: "⌘", width: 1.3, isCommand: true),
             KBKey(id: "ROPT", label: "option", width: 1.3),
             KBKey(id: "ARROWS", label: "", width: 3.3)],
        ]
        static let all: [KBKey] = rows.flatMap { $0 }
    }

    private struct KeyCapView: View {
        let key: KBKey
        let isActive: Bool
        /// True while the demo currently playing in this key's (or a sibling
        /// key's) popover is "pressing" this real key — drives the actual
        /// keyboard tile to visibly depress in sync with the popup's own
        /// animated keycap, instead of only the popup animating on its own.
        let isPressed: Bool
        /// True while some OTHER demo is playing and this key isn't part of
        /// it. Its blue/gold interactive styling disappears completely (not
        /// just dims) for the duration — only the keys actually involved in
        /// the current gesture stay highlighted, so the keyboard doesn't
        /// look like a dozen things are happening at once.
        let dimmed: Bool
        let unitWidth: CGFloat
        let keyHeight: CGFloat
        @State private var pulse = false
        @State private var hovered = false

        private var hasDemo: Bool { !key.demos.isEmpty }
        private var showBlue: Bool { hasDemo && !dimmed }
        private var showGold: Bool { key.isCommand && !dimmed }
        private static let interactiveColor = Color(hex: "#4F8EF7")
        private static let commandColor = Color(hex: "#D4AF37")

        var body: some View {
            Text(key.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(isPressed ? .white
                                  : (showGold ? Self.commandColor
                                     : (showBlue ? Self.interactiveColor : .textSec)))
                .frame(width: key.width * unitWidth, height: keyHeight)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isPressed ? Color.accent
                          : (isActive ? Color.accentDim
                             : (hovered && showBlue ? Self.interactiveColor.opacity(0.18) : Color.surfaceHi.opacity(0.6)))))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            showGold ? Self.commandColor
                                : (showBlue ? Self.interactiveColor.opacity(isActive || hovered || isPressed ? 1 : (pulse ? 1 : 0.4)) : Color.border),
                            lineWidth: (showGold || showBlue) ? (isActive || isPressed ? 2.5 : 1.6) : 1)
                )
                .offset(y: isPressed ? 2 : 0)
                .animation(.easeOut(duration: 0.15), value: isActive)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .animation(.easeOut(duration: 0.1), value: isPressed)
                .animation(.easeOut(duration: 0.15), value: dimmed)
                .onHover { hovering in
                    guard hasDemo else { return }
                    hovered = hovering
                }
                .onAppear {
                    guard hasDemo else { return }
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
                }
        }
    }

    struct KeyDemoPopup: View {
        let key: KBKey
        // Shared with KeyboardInteractionPanel (not owned here) so the real
        // keyboard tiles can light up in sync with this demo's own animated
        // keycap row instead of only the popup animating.
        @ObservedObject var lab: InteractionLabController

        @State private var selected: InteractionDemo
        // ON (default): the mock panel etc. always play, with the press
        // animation on the popup's OWN small keycap row — self-contained,
        // nothing behind the popup needs to be visible for the demo to make
        // sense. OFF: the same key presses sync onto the REAL keyboard tiles
        // behind this popup instead, and the popup's own row goes quiet.
        // The two never animate at once — this just picks which one shows it.
        @State private var showInnerButtons = true
        @ObservedObject private var manager = ClipboardManager.shared

        init(key: KBKey, lab: InteractionLabController) {
            self.key = key
            self.lab = lab
            _selected = State(initialValue: key.demos.first ?? .cycle)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if key.demos.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(key.demos, id: \.self) { demo in
                            Button {
                                selected = demo
                                lab.select(demo)
                            } label: {
                                Text(LocalizedStringKey(demo.title))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(selected == demo ? .white : .textSec)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(selected == demo ? Color.accent : Color.surfaceHi, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text(LocalizedStringKey(selected.title))
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.textPri)
                }

                // No separate caption Text here — InteractionLabStage already
                // renders the caption itself (lab.currentCaption). The mock
                // panel always plays; only its own keycap row is toggled off
                // when the real keyboard is doing that job instead.
                InteractionLabStage(lab: lab, showKeyRow: showInnerButtons)

                Button {
                    showInnerButtons.toggle()
                    lab.syncRealKeyboard = !showInnerButtons
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showInnerButtons ? "keyboard" : "rectangle.on.rectangle")
                            .font(.system(size: 9, weight: .semibold))
                        Text(showInnerButtons ? "Animate on keyboard instead" : "Animate keys in popup instead")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)

                if let binding = speedBinding(for: selected) {
                    HStack(spacing: 8) {
                        Text(selected == .pinPreview ? "Double-tap speed" : "Hold speed")
                            .font(.system(size: 9)).foregroundColor(.textDim)
                        ForEach(GestureSpeed.allCases) { speed in
                            Button {
                                binding.wrappedValue = speed
                                lab.select(selected)
                            } label: {
                                Text(LocalizedStringKey(speed.label))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(binding.wrappedValue == speed ? .white : .textSec)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(binding.wrappedValue == speed ? Color.accent : Color.surfaceHi,
                                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Reverse-cycle's actual trigger (Shift+V vs B) is a global
                // setting, not a per-key thing — surface the toggle right
                // here since this demo is reachable from both V and B.
                if selected == .reverseCycle {
                    HStack(spacing: 8) {
                        Text("Reverse key").font(.system(size: 9)).foregroundColor(.textDim)
                        reverseKeyChoice(label: "Shift + V", isOn: !manager.reverseCycleUsesB) {
                            manager.reverseCycleUsesB = false
                            lab.select(selected)
                        }
                        reverseKeyChoice(label: "B", isOn: manager.reverseCycleUsesB) {
                            manager.reverseCycleUsesB = true
                            lab.select(selected)
                        }
                    }
                }
            }
            .padding(14)
            // Wide enough for demos that slide the mock popup aside and show
            // a side panel (Transform, Space-preview) — those two panels
            // together span ~320pt once their offsets are accounted for; a
            // narrower popup clipped the side panel's right edge.
            .frame(width: 380)
            .task {
                lab.syncRealKeyboard = !showInnerButtons
                try? await Task.sleep(nanoseconds: 80_000_000)
                lab.select(selected)
            }
            .onDisappear { lab.stop() }
        }

        private func reverseKeyChoice(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(isOn ? .white : .textSec)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(isOn ? Color.accent : Color.surfaceHi,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
        }

        private func speedBinding(for demo: InteractionDemo) -> Binding<GestureSpeed>? {
            let m = ClipboardManager.shared
            switch demo {
            case .multiPaste:  return Binding(get: { m.markHoldSpeed }, set: { m.markHoldSpeed = $0 })
            case .pinItem:     return Binding(get: { m.pinHoldSpeed }, set: { m.pinHoldSpeed = $0 })
            case .pinPreview:  return Binding(get: { m.spaceDoubleTapSpeed }, set: { m.spaceDoubleTapSpeed = $0 })
            case .pinnedOpen:  return Binding(get: { m.pinnedOpenHoldSpeed }, set: { m.pinnedOpenHoldSpeed = $0 })
            default:           return nil
            }
        }
    }

    private struct ArrowKeysCluster: View {
        let totalWidth: CGFloat
        let keyHeight: CGFloat

        var body: some View {
            let gap: CGFloat = 1.5
            let arrowW = (totalWidth - 2 * gap) / 3
            let halfH = (keyHeight - gap) / 2

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Color.clear.frame(width: arrowW, height: halfH)
                    arrowCap("chevron.up", width: arrowW, height: halfH)
                    Color.clear.frame(width: arrowW, height: halfH)
                }
                HStack(spacing: gap) {
                    arrowCap("chevron.left", width: arrowW, height: halfH)
                    arrowCap("chevron.down", width: arrowW, height: halfH)
                    arrowCap("chevron.right", width: arrowW, height: halfH)
                }
            }
            .frame(width: totalWidth, height: keyHeight)
        }

        private func arrowCap(_ icon: String, width: CGFloat, height: CGFloat) -> some View {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.textSec)
                .frame(width: width, height: height)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.surfaceHi.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.border, lineWidth: 1))
        }
    }

    private struct KeyboardInteractionPanel: View {
        @State private var activeKeyID: String? = nil
        // Owned here (not inside KeyDemoPopup) so the real keyboard tiles
        // below can read its pressedKeys and depress in sync with whichever
        // demo is currently playing in the open popover.
        @StateObject private var lab = InteractionLabController()

        private let keySpacing: CGFloat = 7
        private let horizontalPadding: CGFloat = 14
        private let keyHeight: CGFloat = 50

        var body: some View {
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let pressedRealIDs = lab.syncRealKeyboard ? Set(lab.pressedKeys.flatMap { $0.kbKeyIDs }) : []
                // While a demo plays, only the real keys it actually uses
                // (plus the key whose popover is open) stay lit — every
                // other interactive key's blue border disappears entirely
                // for the duration instead of just quieting its pulse.
                let involvedRealIDs: Set<String> = lab.isPlaying
                    ? Set(lab.selectedDemo.heroKeys.flatMap { $0.kbKeyIDs }).union(activeKeyID.map { [$0] } ?? [])
                    : []

                VStack(spacing: keySpacing) {
                    ForEach(Array(KBLayout.rows.enumerated()), id: \.offset) { _, row in
                        let segments = Self.segments(for: row)
                        // Must match what's actually RENDERED (one gap per
                        // segment boundary), not the ungrouped key count —
                        // grouping several keys (e.g. the whole 1–9 row) into
                        // one cluster removes their internal gaps, so
                        // counting 13 gaps for a row that only draws 5 made
                        // every row's units come out too small and rows
                        // stopped lining up with the ones above/below them.
                        let rowUnits = row.reduce(CGFloat(0)) { $0 + $1.width }
                        let rowGaps = CGFloat(segments.count - 1)
                        let rowAvail = totalWidth - horizontalPadding * 2 - rowGaps * keySpacing
                        let unitW = max(16, rowAvail / rowUnits)

                        HStack(spacing: keySpacing) {
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                if segment.count == 1, segment[0].id == "ARROWS" {
                                    ArrowKeysCluster(totalWidth: segment[0].width * unitW, keyHeight: keyHeight)
                                } else if segment.count == 1 {
                                    let key = segment[0]
                                    KeyCapView(key: key, isActive: activeKeyID == key.id,
                                               isPressed: pressedRealIDs.contains(key.id),
                                               dimmed: lab.isPlaying && !involvedRealIDs.contains(key.id),
                                               unitWidth: unitW, keyHeight: keyHeight)
                                        .onTapGesture {
                                            guard !key.demos.isEmpty else { return }
                                            if activeKeyID == key.id {
                                                activeKeyID = nil
                                            } else {
                                                let id = key.id
                                                WakeGuard.afterWakeSettle { activeKeyID = id }
                                            }
                                        }
                                        .popover(isPresented: Binding(
                                            get: { activeKeyID == key.id },
                                            set: { isPresented in if !isPresented { activeKeyID = nil } }
                                        ), arrowEdge: .bottom) {
                                            KeyDemoPopup(key: key, lab: lab)
                                        }
                                } else {
                                    let groupActive = segment.contains { $0.id == activeKeyID }
                                    GroupedKeyCluster(keys: segment,
                                                       isActive: groupActive,
                                                       pressedRealIDs: pressedRealIDs,
                                                       dimmed: lab.isPlaying && !segment.contains(where: { involvedRealIDs.contains($0.id) }),
                                                       unitWidth: unitW, keyHeight: keyHeight,
                                                       onTapKey: { tapped in
                                                           activeKeyID = groupActive ? nil : tapped.id
                                                       })
                                        .popover(isPresented: Binding(
                                            get: { groupActive },
                                            set: { isPresented in if !isPresented { activeKeyID = nil } }
                                        ), arrowEdge: .bottom) {
                                            KeyDemoPopup(key: segment.first(where: { $0.id == activeKeyID }) ?? segment[0], lab: lab)
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 14)
                .frame(width: totalWidth, alignment: .center)
            }
            .frame(minHeight: 320)
        }

        /// Splits a row into render segments: consecutive keys sharing the
        /// same non-nil groupID collapse into one segment (rendered as a
        /// single bordered cluster); everything else stays its own segment.
        private static func segments(for row: [KBKey]) -> [[KBKey]] {
            var result: [[KBKey]] = []
            var current: [KBKey] = []
            for key in row {
                if let last = current.last, let g = last.groupID, g == key.groupID {
                    current.append(key)
                } else {
                    if !current.isEmpty { result.append(current) }
                    current = [key]
                }
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
    }

    /// Renders a run of keys (e.g. the whole 1–9 Collections row) as ONE
    /// bordered box instead of N separate ones — any key in it opens the
    /// same demo, so visually they read as a single unified control rather
    /// than nine individually-interactive buttons.
    private struct GroupedKeyCluster: View {
        let keys: [KBKey]
        let isActive: Bool
        let pressedRealIDs: Set<String>
        let dimmed: Bool
        let unitWidth: CGFloat
        let keyHeight: CGFloat
        let onTapKey: (KBKey) -> Void
        @State private var pulse = false
        @State private var hovered = false

        private static let interactiveColor = Color(hex: "#4F8EF7")
        private var anyPressed: Bool { keys.contains { pressedRealIDs.contains($0.id) } }

        var body: some View {
            HStack(spacing: 0) {
                ForEach(Array(keys.enumerated()), id: \.offset) { idx, key in
                    let keyPressed = pressedRealIDs.contains(key.id)
                    Text(key.label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(keyPressed ? .white : (dimmed ? .textSec : Self.interactiveColor))
                        .frame(width: key.width * unitWidth, height: keyHeight)
                        .background(keyPressed ? Color.accent
                                    : (isActive ? Color.accentDim : Color.surfaceHi.opacity(0.6)))
                        .overlay(alignment: .trailing) {
                            if idx < keys.count - 1 {
                                Rectangle().fill(Color.border.opacity(dimmed ? 1 : 0.6)).frame(width: 1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onTapKey(key) }
                        .animation(.easeOut(duration: 0.1), value: keyPressed)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(dimmed ? Color.border
                            : Self.interactiveColor.opacity(isActive || hovered || anyPressed ? 1 : (pulse ? 1 : 0.4)),
                            lineWidth: dimmed ? 1 : (isActive || anyPressed ? 2.5 : 1.6))
            )
            .onHover { hovering in hovered = hovering }
            .animation(.easeOut(duration: 0.15), value: isActive)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.15), value: dimmed)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }

    private static var appVersionString: String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"]            as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private var footer: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "https://www.instagram.com/clipen.official") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill").font(.system(size: 11)).foregroundColor(.pink)
                        Text("Support Clipen").font(.system(size: 11)).foregroundColor(.textSec)
                    }
                }
                .buttonStyle(.plain)
                .help("Support Clipen")

                Text("· \(Self.appVersionString) · Built by Vamshi Krishna Pinni")
                    .font(.system(size: 11)).foregroundColor(.textDim)
            }
            Spacer()
            footerLink("Website", "https://clipen.lovable.app")
            footerLink("Privacy", "https://clipen.lovable.app/privacy.html")
            footerLink("Support", "https://clipen.lovable.app/support.html")
            Button {
                showResetConfirm = true
            } label: {
                HStack(spacing: 4) {
                    Text("Reset to Defaults")
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#FF5555"))
            }
            .buttonStyle(.plain)
        }
    }

    private func footerLink(_ title: String, _ urlString: String) -> some View {
        Button(LocalizedStringKey(title)) { NSWorkspace.shared.open(URL(string: urlString)!) }
            .buttonStyle(.plain)
            .font(.system(size: 11)).foregroundColor(.textSec)
    }
}
