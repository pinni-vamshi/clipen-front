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
    @ObservedObject private var localLLM = LocalLLMManager.shared
    @ObservedObject private var aiStructuring = AIStructuringService.shared

    @Binding var showResetConfirm: Bool

    @State private var row1Height: CGFloat = 0

    @State private var newCollectionName = ""
    @State private var renameCollectionText = ""

    @State private var collectionAlertKind: CollectionAlertKind? = nil
    @State private var showingCollectionAlert = false
    @State private var scrollViewportWidth: CGFloat = 0
    @State private var showExcludedAppsManager = false
    @State private var showPasteBlockedAppsManager = false
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

                aiStructuringSection

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

    private static let tipFeatures: [NudgeFeature] =
        [.multiPaste, .groups, .preview, .pinPreview, .transformPanel, .collections, .search, .similar]

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                sectionHeader("06", "TIPS")

                Button {
                    manager.autoTipsEnabled.toggle()
                } label: {
                    Text(manager.autoTipsEnabled ? "Practice: On" : "Practice: Off")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(manager.autoTipsEnabled ? .accent : .textDim)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(manager.autoTipsEnabled ? Color.accentDim : Color.white.opacity(0.06),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .help(manager.autoTipsEnabled
                      ? "Practice panels can pop up automatically as you use Clipen"
                      : "Practice panels only show when you open one below yourself")
            }

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
            sectionHeader("07", "FEEDBACK")

            feedbackCommunityBanner

            rowCard(border: .allSides) {
                VStack(alignment: .leading, spacing: 0) {

                    Text("Send a message straight to the developer — suggest a feature, report a bug, share how you'd improve your own workflow, or paste a macOS crash report.")
                        .font(.system(size: 11)).foregroundColor(.textSec)
                        .padding(14)

                    rowDivider(leading: 14)

                    if !feedbackThreadRows.isEmpty {
                        feedbackChatHistory
                        rowDivider(leading: 14)
                    }

                    VStack(alignment: .leading, spacing: 10) {
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
                            } else if feedbackSendState == .sent {
                                Text("Sent — expect a reply within a week. Didn't hear back? Send another one.")
                                    .font(.system(size: 10)).foregroundColor(.textDim)
                            }
                            Spacer()
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
    }

    private var feedbackCommunityBanner: some View {
        Button {
            if let url = URL(string: "https://www.instagram.com/clipen.official") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "at.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Say hi on Instagram")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textPri)
                    Text("Join the Clipen community — @clipen.official.")
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

    private struct FeedbackThreadRow: Identifiable {
        let id: String
        let sortKey: Double
        let message: String
        let replyText: String?
    }

    private var feedbackThreadRows: [FeedbackThreadRow] {
        var claimed = Set<String>()
        var rows: [FeedbackThreadRow] = []

        for sent in proGate.sentFeedback {
            let match = proGate.feedbackReplies.first {
                !claimed.contains($0.id) && $0.date == sent.date && $0.message == sent.message
            }
            if let match { claimed.insert(match.id) }
            rows.append(FeedbackThreadRow(
                id: "sent|\(sent.id)",
                sortKey: sent.sentAt.timeIntervalSince1970,
                message: sent.message,
                replyText: match?.reply_text))
        }

        let dayFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }()
        let dayTimeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.timeZone = TimeZone.current
            return f
        }()
        for reply in proGate.feedbackReplies where !claimed.contains(reply.id) {

            let sortKey: Double
            if let time = reply.time,
               let exact = dayTimeFormatter.date(from: "\(reply.date) \(time)")?.timeIntervalSince1970 {
                sortKey = exact
            } else {
                let dayStart = dayFormatter.date(from: reply.date)?.timeIntervalSince1970 ?? 0
                sortKey = dayStart + Double(reply.index)
            }
            rows.append(FeedbackThreadRow(
                id: "reply|\(reply.id)",
                sortKey: sortKey,
                message: reply.message,
                replyText: reply.reply_text))
        }

        return rows.sorted { $0.sortKey < $1.sortKey }
    }

    private var feedbackChatHistory: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(feedbackThreadRows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(row.message)
                            .font(.system(size: 12))
                            .foregroundColor(.textPri)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Spacer(minLength: 40)
                    }
                    if let replyText = row.replyText {
                        HStack {
                            Spacer(minLength: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Clipen team")
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(0.5)
                                    .foregroundColor(.accent.opacity(0.85))
                                Text(replyText)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.textPri)
                            }
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    } else {
                        HStack {
                            Text("Not answered yet")
                                .font(.system(size: 9))
                                .foregroundColor(.textDim)
                            Spacer(minLength: 40)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func sendFeedback() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !feedbackSending else { return }
        feedbackSending = true
        feedbackSendState = .idle

        let dateKey = TrackingService.dateKey(Date())
        TrackingService.shared.sendFeedback(trimmed) { success in
            feedbackSending = false
            if success {
                feedbackText = ""
                feedbackSendState = .sent
                proGate.recordSentFeedback(trimmed, date: dateKey)
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

    @ViewBuilder
    private var proUpsellBanner: some View {
        if proGate.paywallApplies && !proGate.isPro {
            Button {
                NSWorkspace.shared.open(DeviceIdentity.pricingURL)
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
            HStack(spacing: 6) {
                sectionHeader("00", "COLLECTIONS")
                if manager.isRememberForeverFeatureNew {
                    Text("NEW: Remember Forever")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.textSec)
                        .help("Tap the ∞ toggle on a collection below to keep it forever, exempt from the ring limit")
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            if manager.isRememberForeverFeatureNew {
                HStack(spacing: 4) {
                    Text("Tap")
                    RememberForeverToggle(isOn: false) {}
                        .allowsHitTesting(false)
                    Text("on a collection below to keep it forever, exempt from the ring limit.")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.accent, in: Capsule())
            }

            Text("All is your whole clipboard, unfiltered. Create a collection and anything you copy while it's active is filed under it — hold ⌘ and press 1–9 in the popup to switch instantly.")
                .font(.system(size: 11)).foregroundColor(.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {

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

                .frame(minWidth: scrollViewportWidth, alignment: .center)
            }
            .measuredWidth(CollectionsWidthKey.self)
        }
        .frame(maxWidth: .infinity, alignment: .center)

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
        .onChange(of: newCollectionName) { _, new in
            if new.count > ClipboardManager.maxCollectionNameLength {
                newCollectionName = String(new.prefix(ClipboardManager.maxCollectionNameLength))
            }
        }
        .onChange(of: renameCollectionText) { _, new in
            if new.count > ClipboardManager.maxCollectionNameLength {
                renameCollectionText = String(new.prefix(ClipboardManager.maxCollectionNameLength))
            }
        }
    }

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

    private func browseForApplicationToExclude() {
        let panel = NSOpenPanel()

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

    private var pasteBlockedAppsManagerPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Block paste in").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                Spacer()
                Button {
                    browseForApplicationToPasteBlock()
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundColor(.accent)
                }
                .buttonStyle(.plain)
                .help("Choose any installed app — it doesn't need to be running")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            Text("Cmd+V and other Clipen shortcuts pass through untouched while one of these apps is active. Copying still works normally.")
                .font(.system(size: 10)).foregroundColor(.textDim)
                .padding(.horizontal, 12).padding(.bottom, 6)

            if manager.pasteBlockedBundleIDs.isEmpty {
                Text("None yet — tap + to add one.")
                    .font(.system(size: 11)).foregroundColor(.textDim)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(manager.pasteBlockedBundleIDs).sorted(), id: \.self) { bundleID in
                            pasteBlockedAppRow(bundleID: bundleID)
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

    private func pasteBlockedAppRow(bundleID: String) -> some View {
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
                manager.pasteBlockedBundleIDs.remove(bundleID)
            } label: {
                Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).foregroundColor(.textDim)
            }
            .buttonStyle(.plain)
            .help("Stop blocking paste for this app")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func browseForApplicationToPasteBlock() {
        let panel = NSOpenPanel()

        panel.title = String(localized: "Choose an App")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        manager.pasteBlockedBundleIDs.insert(bundleID)
    }

    @ViewBuilder
    private func collectionPill(name: String?, slot: Int) -> some View {
        let isActive = manager.activeCollection == name

        HStack(spacing: 8) {

            Text("⌘\(slot)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isActive ? .white.opacity(0.9) : .textDim)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))

            Text(name ?? String(localized: "All"))
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? .white : .textPri)

            if let name {
                RememberForeverToggle(isOn: manager.rememberForeverCollections.contains(name)) {
                    manager.toggleRememberForever(name)
                }
            }

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
                Button {
                    manager.toggleRememberForever(name)
                } label: {
                    if manager.rememberForeverCollections.contains(name) {
                        Label("Remembered Forever", systemImage: "checkmark")
                    } else {
                        Text("Remember Forever")
                    }
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

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(manager.unlimitedRingSize ? "∞" : "\(manager.maxItems)")
                    .font(.system(size: 64, weight: .black))
                    .foregroundColor(.textPri)
                    .contentTransition(.numericText())
                Text("items")
                    .font(.system(size: 11)).foregroundColor(.textSec)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Button {
                withAnimation { manager.unlimitedRingSize.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "infinity").font(.system(size: 9, weight: .bold))
                    Text(manager.unlimitedRingSize ? "Infinite items: On" : "Infinite items: Off")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(manager.unlimitedRingSize ? .accent : .textDim)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(manager.unlimitedRingSize ? Color.accentDim : Color.white.opacity(0.06),
                            in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .help(manager.unlimitedRingSize
                  ? "Cap the ring at the size set below"
                  : "Keep every item — no limit on how many the ring holds")

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
            .disabled(manager.unlimitedRingSize)
            .opacity(manager.unlimitedRingSize ? 0.35 : 1)

            HStack {
                Text("10").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
                Spacer()
                Text("500").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
            }
            .opacity(manager.unlimitedRingSize ? 0.35 : 1)
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
                            AuthManager.shared.registerActionUsage(actionID: "setting.auto_update_check", value: value)
                        }))
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)

                if DeviceIdentity.isDeveloperDevice {
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
                }

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
                    Text("Stop copying from these apps").font(.system(size: 13)).foregroundColor(.textPri)
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

                rowDivider(leading: 40)

                HStack(spacing: 10) {
                    Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Disable Clipen in these apps").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Button {
                        togglePopover($showPasteBlockedAppsManager)
                    } label: {
                        Text("Manage")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.accent)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("While one of these apps is active, Clipen's Cmd+V and other shortcuts pass straight through untouched — copying still works as normal")
                    .popover(isPresented: $showPasteBlockedAppsManager, arrowEdge: .bottom) {
                        pasteBlockedAppsManagerPopover
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
                rowDivider()
                behaviourRow(8, icon: "camera.viewfinder", "Screenshot to Clipboard",
                             isOn: Binding(get: { manager.screenshotCaptureEnabled },
                                           set: { manager.screenshotCaptureEnabled = $0 }))
                rowDivider()
                systemFallbackRow(9)
            }
        }
    }

    private var aiStructuringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionHeader("04", "APPLE INTELLIGENCE")
                Spacer()
                if let progress = aiStructuring.regenerateAllProgress {
                    HStack(spacing: 6) {
                        Text("\(progress.completed) of \(progress.total)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.textDim)
                        Button {
                            AIStructuringService.shared.cancelRegenerateAll()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                Text("Cancel").font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundColor(.red)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.red.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button {
                        AuthManager.shared.registerActionUsage(actionID: "action.regenerate-all")
                        AIStructuringService.shared.regenerateAll(items: manager.items)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                            Text("Regenerate All").font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundColor(.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentDim, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Delete every stored AI analysis, then rebuild them all from scratch")
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Structure copied text with Apple Intelligence").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Toggle("", isOn: Binding(get: { manager.aiStructuringEnabled },
                                              set: { manager.aiStructuringEnabled = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 16)

                rowDivider(leading: 14)

                HStack(spacing: 10) {
                    Image(systemName: "cpu").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Engine").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    engineControl
                }
                .padding(.horizontal, 14).padding(.vertical, 16)
            }
            .background(Color.surfaceHi.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func byteProgressText(_ tier: LocalModelTier) -> String {
        let done = localLLM.downloadedBytes[tier] ?? 0
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB]
        let pct = Int((localLLM.downloadProgress[tier] ?? 0) * 100)
        return "\(f.string(fromByteCount: done)) / \(f.string(fromByteCount: tier.totalBytes)) · \(pct)%"
    }

    private func speedText(_ tier: LocalModelTier) -> String {
        let bps = localLLM.downloadSpeed[tier] ?? 0
        guard bps > 1024 else { return "connecting\u{2026}" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useKB]
        let remaining = max(0, tier.totalBytes - (localLLM.downloadedBytes[tier] ?? 0))
        let secs = Int(Double(remaining) / bps)
        let eta = secs > 90 ? "\(secs / 60)m left" : "\(secs)s left"
        return "\(f.string(fromByteCount: Int64(bps)))/s · \(eta)"
    }

    @ViewBuilder
    private var engineControl: some View {
        VStack(alignment: .trailing, spacing: 4) {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { localLLM.selectedEngine },
                set: { localLLM.selectEngine($0) }
            )) {
                Text("Apple Intelligence").tag(AIEngineSelection.apple)
                ForEach(LocalModelTier.allCases) { tier in
                    Text(tier.displayName).tag(AIEngineSelection.local(tier))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 210)
            .labelsHidden()

            if case .local(let tier) = localLLM.selectedEngine {
                if localLLM.downloadingTiers.contains(tier) {
                    ProgressView(value: localLLM.downloadProgress[tier] ?? 0)
                        .frame(width: 60)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(byteProgressText(tier))
                            .font(.system(size: 9)).foregroundColor(.textDim)
                        Text(speedText(tier))
                            .font(.system(size: 8)).foregroundColor(.textDim.opacity(0.6))
                    }
                    .frame(width: 110, alignment: .leading)
                    Button("Cancel") { localLLM.cancelDownload(tier) }
                        .font(.system(size: 9)).buttonStyle(.plain).foregroundColor(.red.opacity(0.75))
                } else if localLLM.downloadedTiers.contains(tier) {
                    Button("Delete") { localLLM.delete(tier) }
                        .font(.system(size: 9)).buttonStyle(.plain).foregroundColor(.red.opacity(0.75))
                } else if LocalModelPaths.hasAnyLocalFiles(tier) {

                    Text("partial files").font(.system(size: 9)).foregroundColor(.orange.opacity(0.8))
                    Button("Delete") { localLLM.delete(tier) }
                        .font(.system(size: 9)).buttonStyle(.plain).foregroundColor(.red.opacity(0.75))
                } else {
                    Text(tier.approxSizeText)
                        .font(.system(size: 9)).foregroundColor(.textDim.opacity(0.6))
                }
            }
        }
        .help(localLLM.lastError ?? "Choose which model runs AI structuring. Picking a local model starts its download automatically if it isn't on disk yet.")
        if let err = localLLM.lastError {
            Text(err).font(.system(size: 10)).foregroundColor(.red.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .trailing)
        }
        }
    }

    private func systemFallbackRow(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                Text("Auto fallback to system paste").font(.system(size: 13)).foregroundColor(.textPri)
                Spacer()
                Toggle("", isOn: Binding(get: { manager.uncapturedFallbackEnabled },
                                          set: { manager.uncapturedFallbackEnabled = $0 }))
                    .toggleStyle(.switch).controlSize(.mini).tint(.accent)
            }
            Text("Uses system default paste when the newest item can't be copied. Doesn't apply to older items in history.")
                .font(.system(size: 10))
                .foregroundColor(.textDim.opacity(0.6))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private func purePasteRow(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
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
                .padding(.leading, 26)
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
                sectionHeader("05", "INTERACTIONS")

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
                      ? "Turn off sound feedback for popup gestures (V, Space, X, C, S, P, R, Delete)"
                      : "Play a sound for every popup gesture (V, Space, X, C, S, P, R, Delete)")
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

    struct KBKey: Identifiable, Equatable {
        let id: String
        let label: String
        var width: CGFloat = 1
        var demos: [InteractionDemo] = []
        var isCommand: Bool = false

        var groupID: String? = nil
        static func == (l: KBKey, r: KBKey) -> Bool { l.id == r.id }
    }

    private enum KBLayout {

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
             KBKey(id: "R", label: "R", demos: [.similar]), KBKey(id: "T", label: "T"), KBKey(id: "Y", label: "Y"),
             KBKey(id: "U", label: "U"), KBKey(id: "I", label: "I"), KBKey(id: "O", label: "O"),
             KBKey(id: "P", label: "P", demos: [.cyclePinned, .pinItem]),
             KBKey(id: "LBRACKET", label: "["), KBKey(id: "RBRACKET", label: "]"),
             KBKey(id: "BACKSLASH", label: "\\", width: 1.2)],
            [KBKey(id: "CAPS", label: "caps", width: 1.6),
             KBKey(id: "A", label: "A"), KBKey(id: "S", label: "S"),
             KBKey(id: "D", label: "D", demos: [.details]),
             KBKey(id: "F", label: "F", demos: [.search]),
             KBKey(id: "G", label: "G", demos: [.group]),
             KBKey(id: "H", label: "H"), KBKey(id: "J", label: "J"), KBKey(id: "K", label: "K"),
             KBKey(id: "L", label: "L"), KBKey(id: "SEMI", label: ";"), KBKey(id: "QUOTE", label: "'"),
             KBKey(id: "RETURN", label: "return", width: 1.8)],
            [KBKey(id: "LSHIFT", label: "shift", width: 2.0, demos: [.shiftReverses]),
             KBKey(id: "Z", label: "Z"),
             KBKey(id: "X", label: "X", demos: [.transform]),
             KBKey(id: "C", label: "C", demos: [.moveToFront]),

             KBKey(id: "V", label: "V", demos: [.cycle, .multiPaste, .pinnedOpen, .reverseCycle]),

             KBKey(id: "B", label: "B", demos: [.smartBack]),
             KBKey(id: "N", label: "N"), KBKey(id: "M", label: "M"),
             KBKey(id: "COMMA", label: ","), KBKey(id: "PERIOD", label: "."), KBKey(id: "SLASH", label: "/"),
             KBKey(id: "RSHIFT", label: "shift", width: 2.4, demos: [.shiftReverses])],
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

    private struct KeyCapView: View, Equatable {
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.key == rhs.key && lhs.isActive == rhs.isActive && lhs.isPressed == rhs.isPressed
                && lhs.dimmed == rhs.dimmed && lhs.unitWidth == rhs.unitWidth && lhs.keyHeight == rhs.keyHeight
        }

        let key: KBKey
        let isActive: Bool

        let isPressed: Bool

        let dimmed: Bool
        let unitWidth: CGFloat
        let keyHeight: CGFloat
        @State private var pulse = false
        @State private var hovered = false

        private var hasDemo: Bool { !key.demos.isEmpty }
        private var showBlue: Bool { hasDemo && !dimmed }
        private var showGold: Bool { key.isCommand && !dimmed }
        private var isReverseKey: Bool { key.id == "LSHIFT" || key.id == "RSHIFT" || key.id == "B" }
        private static let interactiveColor = Color(hex: "#4F8EF7")
        private static let commandColor = Color(hex: "#D4AF37")
        private static let reverseColor = Color(red: 0.82, green: 0.29, blue: 0.14)

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
                            isReverseKey && !dimmed ? Self.reverseColor
                                : (showGold ? Self.commandColor
                                    : (showBlue ? Self.interactiveColor.opacity(isActive || hovered || isPressed ? 1 : (pulse ? 1 : 0.4)) : Color.border)),
                            lineWidth: (showGold || showBlue || (isReverseKey && !dimmed)) ? (isActive || isPressed ? 2.5 : 1.6) : 1)
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
        var showRealKeyboardToggle: Bool = true

        @ObservedObject var lab: InteractionLabController

        @State private var selected: InteractionDemo

        @State private var showInnerButtons = true
        @ObservedObject private var manager = ClipboardManager.shared

        init(key: KBKey, lab: InteractionLabController, showRealKeyboardToggle: Bool = true) {
            self.key = key
            self.lab = lab
            self.showRealKeyboardToggle = showRealKeyboardToggle
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

                InteractionLabStage(lab: lab, showKeyRow: showInnerButtons)

                if showRealKeyboardToggle {
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

                        .foregroundColor(showInnerButtons ? .accent : .white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(showInnerButtons ? Color.accentDim : Color.accent,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

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

                if selected == .smartBack {
                    HStack(spacing: 8) {
                        Text("Smart B").font(.system(size: 9)).foregroundColor(.textDim)
                        settingsChoicePill(label: "Off", isOn: !manager.reverseCycleUsesB) {
                            manager.reverseCycleUsesB = false
                            lab.select(selected)
                        }
                        settingsChoicePill(label: "On", isOn: manager.reverseCycleUsesB) {
                            manager.reverseCycleUsesB = true
                            lab.select(selected)
                        }
                    }
                }
            }
            .padding(14)

            .task {
                lab.syncRealKeyboard = !showInnerButtons

                lab.select(selected)
            }

            .onDisappear { lab.stopIfStillPlaying(selected) }
        }

        private func settingsChoicePill(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
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

        @StateObject private var lab = InteractionLabController()

        private let keySpacing: CGFloat = 7
        private let horizontalPadding: CGFloat = 14
        private let keyHeight: CGFloat = 50

        var body: some View {
            GeometryReader { geo in
                let totalWidth = geo.size.width

                let pressedRealIDs: Set<String> = {
                    guard lab.syncRealKeyboard else { return [] }
                    var ids = Set(lab.pressedKeys.flatMap { $0.kbKeyIDs })
                    if lab.specialVPressed { ids.formUnion(LabKey.v.kbKeyIDs) }
                    return ids
                }()

                let involvedRealIDs: Set<String> = lab.isPlaying
                    ? Set(lab.selectedDemo.heroKeys.flatMap { $0.kbKeyIDs }).union(activeKeyID.map { [$0] } ?? [])
                    : []

                VStack(spacing: keySpacing) {
                    ForEach(Array(KBLayout.rows.enumerated()), id: \.offset) { _, row in
                        let segments = Self.segments(for: row)

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

                                        .equatable()
                                        .onTapGesture {
                                            guard !key.demos.isEmpty else { return }
                                            if activeKeyID == key.id {
                                                activeKeyID = nil
                                            } else {
                                                let id = key.id
                                                AuthManager.shared.registerActionUsage(
                                                    actionID: "action.keyboard-demo-\(id.lowercased())")
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
                                                           if !groupActive {
                                                               AuthManager.shared.registerActionUsage(
                                                                   actionID: "action.keyboard-demo-\(tapped.id.lowercased())")
                                                           }
                                                           activeKeyID = groupActive ? nil : tapped.id
                                                       })
                                        .equatable()
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

    private struct GroupedKeyCluster: View, Equatable {
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.keys == rhs.keys && lhs.isActive == rhs.isActive && lhs.pressedRealIDs == rhs.pressedRealIDs
                && lhs.dimmed == rhs.dimmed && lhs.unitWidth == rhs.unitWidth && lhs.keyHeight == rhs.keyHeight
        }

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
