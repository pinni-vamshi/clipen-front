import SwiftUI
import AppKit

struct OnboardingView: View {
    @State private var step      = 0
    @State private var fade      = true
    @State private var bounce    = false
    @State private var cycleTimer: Timer? = nil

    private let steps: [(icon: String, key: String, title: String, sub: String)] = [
        ("doc.on.clipboard.fill", "⌘C",        "Copy anything",        "Copy text, images, files or URLs anywhere on your Mac"),
        ("arrow.clockwise",       "Hold ⌘ · V", "Cycle your ring",      "Tap V for the next item · ⌘⌥V jumps 5 forward while ⌘ is held"),
        ("arrow.down.doc.fill",   "Release ⌘",  "Paste your pick",      "Let go of ⌘ to paste whichever item is highlighted"),
        ("wand.and.stars",        "V → X",      "Pick, then transform", "Hold ⌘, tap V to land on an item, then tap X — tap X again to cycle transforms"),
        ("trash",                 "V → ⌫",      "Pick, then delete",    "Hold ⌘, tap V to highlight what to remove, then tap ⌫ to drop it from the ring"),
        ("pin.fill",              "Hold P",     "Pin your favourites",  "Hold ⌘, tap V to land on an item, then hold P to pin it so it never falls off the ring"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle().fill(Color.accentDim).frame(width: 84, height: 84)
                Image(systemName: steps[step].icon).font(.system(size: 34, weight: .thin))
                    .foregroundColor(.accent)
                    .scaleEffect(bounce ? 1.12 : 1.0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.55), value: bounce)
            }
            .opacity(fade ? 1 : 0).animation(.easeInOut(duration: 0.25), value: fade)
            .padding(.bottom, 24)

            Text(steps[step].key).font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.accent).padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accent.opacity(0.3), lineWidth: 1))
                .opacity(fade ? 1 : 0).animation(.easeInOut(duration: 0.25), value: fade)
                .padding(.bottom, 14)

            VStack(spacing: 6) {
                Text(steps[step].title).font(.system(size: 17, weight: .semibold)).foregroundColor(.textPri)
                Text(steps[step].sub).font(.system(size: 12)).foregroundColor(.textSec)
                    .multilineTextAlignment(.center).frame(maxWidth: 280)
            }
            .opacity(fade ? 1 : 0).animation(.easeInOut(duration: 0.25), value: fade)

            Spacer()

            HStack(spacing: 7) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule().fill(i == step ? Color.accent : Color.textDim.opacity(0.4))
                        .frame(width: i == step ? 18 : 6, height: 6)
                        .animation(.spring(response: 0.3), value: step)
                }
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startCycle() }
        .onDisappear {
            cycleTimer?.invalidate()
            cycleTimer = nil
        }
    }

    private func startCycle() {
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 2.8, repeats: true) { _ in
            withAnimation { fade = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                step = (step + 1) % steps.count
                withAnimation { fade = true }
                bounce = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { bounce = false }
                }
            }
            if let t = cycleTimer { RunLoop.main.add(t, forMode: .common) }
        }
    }

/// A physical keycap, ported from the marketing site's `.hka` component so the
/// two surfaces read as one product: a 180° #242424→#1A1A1A face, a dark border
/// with a lit top edge, and layered inset shadows. Pressing fills it blue and
/// pushes it down rather than pulsing a stroke, which is what the site does and
/// what a real key does.
struct ClipenKeyCap: View {
    let label: String
    var width: CGFloat = 54
    var height: CGFloat = 50
    var fontSize: CGFloat = 19
    var pressed: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundColor(pressed ? .white : .textSec)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, height: height)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(pressed
                          ? AnyShapeStyle(Color.accent)
                          : AnyShapeStyle(LinearGradient(colors: [.surfaceHi, .surface],
                                                         startPoint: .top, endPoint: .bottom)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(pressed ? Color.accent : Color.black.opacity(0.5), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // The lit top edge — what sells it as a moulded key rather
                // than a rectangle.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .trim(from: 0.62, to: 0.88)
                    .stroke(Color.white.opacity(pressed ? 0.22 : 0.16), lineWidth: 1)
                    .frame(width: width, height: height)
            }
            .shadow(color: .black.opacity(pressed ? 0.35 : 0.55),
                    radius: pressed ? 2 : 4, y: pressed ? 2 : 5)
            .offset(y: pressed ? 4 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
    }
}

/// The site's micro-label: 9pt monospace, heavily tracked, uppercase, dim.
/// Used everywhere the site uses `.htw-cap` / `.fc-n` / `.col-lbl`.
struct MicroLabel: View {
    let text: LocalizedStringKey
    var color: Color = .textDim

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.8)
            .textCase(.uppercase)
            .foregroundColor(color)
    }
}

struct TutorialSheet: View {
    @Binding var isPresented: Bool
    var onSeeMore: () -> Void = {}
    @ObservedObject private var manager = ClipboardManager.shared
    @State private var page: Int = 0
    /// When the sheet opened. Used instead of a snapshot of item IDs: the
    /// history loads asynchronously, so a snapshot taken in onAppear could be
    /// empty, and every item that loaded afterwards then counted as "just
    /// copied" — which is why the first line showed as already done the
    /// moment the tutorial opened. A timestamp cannot race the loader.
    @State private var openedAt = Date()

    /// The app's own demo engine. It already has .pasteOne/.pasteTwo/
    /// .pasteThree — "tap V once/twice/three times, release" — and
    /// InteractionLabStage renders the real thing: the ⌘/V keycaps, a mock of
    /// the Clipen popup with the selection moving through it, the tap-count
    /// dots and the captions. Page 2 used this before; replacing it with a
    /// pair of hand-animated keycaps threw away the one part that actually
    /// shows the user what the popup looks like.
    @StateObject private var lab = InteractionLabController()
    @State private var showAutoTipsAlert = false

    @State private var introRevealed = false
    @State private var revealedRows = 0
    @State private var promptPulse = false
    @State private var wordsShown = 0

    private static let philosophyLineKeys = ["A unique interaction", "behind every paste."]
    private var philosophyWords: [[String]] {
        Self.philosophyLineKeys.map { key in
            String(localized: String.LocalizationValue(key))
                .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        }
    }
    private var philosophyWordCount: Int { philosophyWords.reduce(0) { $0 + $1.count } }
    private func globalWordIndex(line: Int, word: Int) -> Int {
        var idx = word
        for l in 0..<line { idx += philosophyWords[l].count }
        return idx
    }

    private static let totalPages = 3

    /// The three lines the copy gate asks for. The prose is localized; the
    /// URL deliberately is NOT — it used to be mapped through
    /// `String(localized:)` along with the other two, which would have let a
    /// translator "translate" a web address. It was also pointing at
    /// clipen.app, a domain that resolves to nothing.
    private var copyTargets: [String] {
        [
            String(localized: "Hello from Clipen"),
            DeviceIdentity.websiteURLString,
            String(localized: "Made with care on macOS"),
        ]
    }

    private var newCopiedTexts: Set<String> {
        let newItems = manager.items.filter { $0.timestamp > openedAt }
        return Set(newItems.compactMap { item in
            item.content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    private func isCopied(_ t: String) -> Bool {
        newCopiedTexts.contains(t.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Counted in order and stopping at the first gap, so the lines have to
    /// be copied one after another — which is also the order the ring will
    /// hand them back on the next page.
    private var copiedCount: Int {
        var n = 0
        for t in copyTargets {
            guard isCopied(t) else { break }
            n += 1
        }
        return n
    }
    /// The line the user should be copying right now; everything after it is
    /// still locked.
    private var currentCopyTarget: Int { copiedCount }
    private var canAdvance: Bool { copiedCount == copyTargets.count }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0:  copyGatePage
                case 1:  pastePracticePage
                default: spacePreviewFinalPage
                }
            }
            .frame(minHeight: 420)
            .overlay(alignment: .topTrailing) { closeButton }
            Divider().background(Color.border)
            tutorialFooter
        }
        .frame(width: 760).background(Color.surface)
        .onAppear {
            openedAt = Date()
            manager.onboardingCoreLoopOnly = true
            AuthManager.shared.registerActionUsage(actionID: "action.onboarding-started")
        }
        .onDisappear {
            lab.stop()
            manager.onboardingCoreLoopOnly = false
        }
        .onChange(of: page) { _, now in
            // The demo only runs on page 2, and it plays whichever of
            // pasteOne/Two/Three matches the item the user is on.
            if now == 1 {
                lab.select(pasteDemoForTarget)
                focusedPasteBox = currentPasteTarget
            } else {
                lab.stop()
            }
        }
        .onChange(of: currentPasteTarget) { _, next in
            guard page == 1 else { return }
            if next < pasteTargets.count {
                lab.select(pasteDemoForTarget)
                focusedPasteBox = next
            } else {
                lab.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    guard page == 1, allPasted else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { page = 2 }
                }
            }
        }
    }

    private var closeButton: some View {
        Button {
            AuthManager.shared.registerActionUsage(actionID: "action.onboarding-abandoned-page-\(page)")
            isPresented = false
        } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundColor(.textSec)
        }
        .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
        .padding(.top, 22).padding(.trailing, 22)
    }

    private var tutorialFooter: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<Self.totalPages, id: \.self) { i in
                    Circle().fill(i == page ? Color.accent : Color.textDim.opacity(0.4))
                        .frame(width: i == page ? 8 : 6, height: i == page ? 8 : 6)
                        .animation(.spring(response: 0.3), value: page)
                }
            }
            Spacer()
            if page > 0 {
                Button { withAnimation { page -= 1 } } label: {
                    Text("Back").font(.system(size: 12, weight: .medium)).foregroundColor(.textSec)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }

            switch page {
            case 0:
                Text("Copy all three to continue")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.textDim)
                    .padding(.vertical, 9)
            case 1:
                Text("Paste all three to continue")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.textDim)
                    .padding(.vertical, 9)
            default:

                Button {
                    showAutoTipsAlert = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                        Text("Personalise & see more interactions").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Color.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Open Settings to explore every interaction")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)

        .alert("Learn these interactions as you use the app?",
               isPresented: $showAutoTipsAlert) {
            Button("Yes, show me tips") {
                manager.autoTipsEnabled = true
                AuthManager.shared.registerActionUsage(actionID: "action.onboarding-completed-tips-on")
                isPresented = false
                onSeeMore()
            }
            Button("No thanks", role: .cancel) {
                AuthManager.shared.registerActionUsage(actionID: "action.onboarding-completed-tips-off")
                isPresented = false
                onSeeMore()
            }
        } message: {
            Text("Small practice panels can pop up automatically while you use Clipen, to teach you the most useful moves. You can turn this on or off anytime next to Tips in Settings.")
        }
    }

    private var copyGatePage: some View {
        VStack(alignment: .leading, spacing: introRevealed ? 18 : 12) {

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(philosophyWords.enumerated()), id: \.offset) { lineIdx, line in
                    HStack(spacing: 11) {
                        ForEach(Array(line.enumerated()), id: \.offset) { wordIdx, word in
                            let g = globalWordIndex(line: lineIdx, word: wordIdx)
                            // Mask-slide, matching the site's hero reveal
                            // (.w{overflow:hidden} + translateY(110%→0)).
                            // `.offset` is a render transform, so the layout
                            // frame stays put and `.clipped()` masks to it —
                            // the word rises out of a fixed slot instead of
                            // fading in from a blur.
                            Text(word)
                                .font(.system(size: 42, weight: .heavy))
                                .foregroundColor(.textPri)
                                .offset(y: g < wordsShown ? 0 : 52)
                                .clipped()
                        }
                    }
                }
            }

            .scaleEffect(introRevealed ? 0.66 : 1.0, anchor: .topLeading)
            .padding(.bottom, introRevealed ? -34 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)

            if introRevealed {
                copyColumn
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { startIntroChoreography() }
        .onChange(of: canAdvance) { _, done in

            guard done, page == 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard page == 0 else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { page = 1 }
            }
        }
    }

    private func startIntroChoreography() {
        guard wordsShown == 0, !introRevealed else { return }
        if !promptPulse {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                promptPulse = true
            }
        }

        let wordGap = 0.32
        for i in 1...philosophyWordCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + wordGap * Double(i)) {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.65)) { wordsShown = i }
            }
        }

        let afterWords = wordGap * Double(philosophyWordCount) + 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + afterWords) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.76)) { introRevealed = true }
            for i in 1...3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 * Double(i)) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { revealedRows = i }
                }
            }
        }
    }

    private var copyColumn: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("Clipen isn't a list you scroll — it's a keyboard-first ring. Hold ⌘, tap V to cycle, release to paste. Let's feel it in three quick steps.")
                .font(.system(size: 12)).foregroundColor(.textSec)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().background(Color.border)

            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Copy these 3 lines")
                        .font(.system(size: 19, weight: .medium)).tracking(-0.3)
                        .foregroundColor(.textPri)
                        .scaleEffect(promptPulse ? 1.035 : 1.0, anchor: .leading)
                    Text("Click into each box and press ⌘C. Clipen catches every copy automatically.")
                        .font(.system(size: 11)).foregroundColor(.textSec)
                        .fixedSize(horizontal: false, vertical: true)

                    MicroLabel(text: "↓ copy each of these", color: .accent)
                        .offset(x: promptPulse ? 3 : -1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    ForEach(Array(copyTargets.enumerated()), id: \.offset) { idx, text in
                        copyTargetCard(index: idx, text: text, copied: isCopied(text))
                            .opacity(idx < revealedRows ? 1 : 0)
                            .offset(y: idx < revealedRows ? 0 : 14)
                    }

                    Text(canAdvance
                         ? "Nice! Taking you to pasting them back…"
                         : "Copied \(copiedCount) of \(copyTargets.count).")
                        .font(.system(size: 11))
                        .foregroundColor(canAdvance ? .okGreen : .textDim)
                        .frame(minHeight: 16).animation(.easeInOut(duration: 0.2), value: canAdvance)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyTargetCard(index: Int, text: String, copied: Bool) -> some View {
        // Three states, never more than one of them live: done, the line
        // you're on, and still locked. Later lines stay dimmed and offer no
        // Copy button, so the three get copied in order — which is the order
        // the ring hands them back on the next page.
        let isCurrent = index == currentCopyTarget
        let isLocked  = index > currentCopyTarget
        return HStack(spacing: 13) {
            // Square numeral chip, not a rounded pill — the site numbers
            // things with flat mono squares (.mpx-badge).
            Text("\(index + 1)").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(copied || isCurrent ? .white : .textDim)
                .frame(width: 24, height: 24)
                .background(copied ? Color.okGreen
                            : (isCurrent ? Color.accent : Color.textDim.opacity(0.12)))

            Text(text).font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(isLocked ? .textDim : .textPri)
                .textSelection(.enabled).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if copied {
                Text("Copied")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundColor(.okGreen)
            } else if isLocked {
                Text("Locked")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundColor(.textDim.opacity(0.7))
            } else {

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    // This button writes the pasteboard directly rather than
                    // going through ⌘C, so nothing else would tell the
                    // poller to come off its backed-off interval — and by
                    // this point the user has usually been reading this page
                    // for well over the 60s idle threshold.
                    manager.resumeActivePolling()
                } label: {
                    Text("Copy")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .textCase(.uppercase)
                }
                .buttonStyle(.plain)
                .foregroundColor(.textDim)
                .help("Copy")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hairline rows on the page ground, the way the site's .feat-grid
        // separates cells — no radius, no raised fill.
        .background(copied ? Color.okGreenDim : Color.clear)
        .overlay(Rectangle().stroke(copied ? Color.okGreen.opacity(0.4)
                                    : (isCurrent ? Color.accent : Color.border),
                                    lineWidth: isCurrent ? 1.5 : 1))
        .opacity(isLocked ? 0.45 : 1)
        .animation(.spring(response: 0.3), value: copied)
        .animation(.easeOut(duration: 0.25), value: isCurrent)
    }

    @State private var pasteBoxes: [String] = ["", "", ""]
    @FocusState private var focusedPasteBox: Int?

    /// Newest copy first — one tap of V reaches the most recent thing copied,
    /// which is the LAST line the copy gate asked for.
    private var pasteTargets: [String] { copyTargets.reversed() }

    private func isPasted(_ i: Int) -> Bool {
        pasteBoxes[i].trimmingCharacters(in: .whitespacesAndNewlines)
            == pasteTargets[i].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var currentPasteTarget: Int {
        for i in pasteTargets.indices where !isPasted(i) { return i }
        return pasteTargets.count
    }
    private var allPasted: Bool { currentPasteTarget == pasteTargets.count }

    /// Which demo matches the item the user is on: one tap, two, or three.
    private var pasteDemoForTarget: InteractionDemo {
        switch currentPasteTarget {
        case 0:  return .pasteOne
        case 1:  return .pasteTwo
        default: return .pasteThree
        }
    }

    private var pastePracticePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Top half: the ring's contents on the left, the demo on the
            // right, split by the hairline.
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Now paste them back")
                            .font(.system(size: 22, weight: .medium)).tracking(-0.4)
                            .foregroundColor(.textPri)
                        Text("Newest copy first — the top one is a single tap of V.")
                            .font(.system(size: 12)).foregroundColor(.textSec)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Rows never move and never fill; the one being taught
                    // right now simply gets a blue border.
                    VStack(alignment: .leading, spacing: 9) {
                        MicroLabel(text: "Clipboard history — newest first")
                        VStack(spacing: -1) {
                            ForEach(pasteTargets.indices, id: \.self) { i in
                                historyRow(i).zIndex(currentPasteTarget == i ? 2 : 1)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(width: 320)
                .padding(.trailing, 22)

                Rectangle().fill(Color.border).frame(width: 1)

                InteractionLabStage(lab: lab)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            // The target runs the full width of the panel, under both
            // columns — it's the one thing the user has to act on, so it gets
            // the whole width rather than being squeezed into the left third.
            if currentPasteTarget < pasteTargets.count {
                pasteField(currentPasteTarget)
            }
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) { replayButton }
    }

    private var replayButton: some View {
        // Offset left of the sheet's own close button, which is an overlay on
        // the same corner — they were drawing on top of each other.
        Button { lab.play() } label: {
            Text("Replay")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.4).textCase(.uppercase)
                .foregroundColor(.textDim)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Rectangle().stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Play the gesture again")
        .padding(.top, 24).padding(.trailing, 56)
    }

    private func historyRow(_ i: Int) -> some View {
        let isCurrent = currentPasteTarget == i
        let done = isPasted(i)
        return HStack(spacing: 12) {
            Text("\(i + 1)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(done || isCurrent ? .white : .textDim)
                .frame(width: 22, height: 22)
                .background(done ? Color.okGreen : (isCurrent ? Color.accent : Color.textDim.opacity(0.12)))
            Text(pasteTargets[i])
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(isCurrent ? .textPri : .textSec)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text("\(i + 1) tap\(i == 0 ? "" : "s")")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.2).textCase(.uppercase)
                .foregroundColor(isCurrent ? .accent : .textDim.opacity(0.7))
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .overlay(Rectangle().stroke(isCurrent ? Color.accent : Color.border,
                                    lineWidth: isCurrent ? 1.5 : 1))
        .animation(.easeOut(duration: 0.25), value: isCurrent)
    }

    private func pasteField(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: "Paste it here", color: .accent)
            HStack(spacing: 12) {
                Text("\(i + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accent)
                ZStack(alignment: .leading) {
                    TextField("", text: $pasteBoxes[i])
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.textPri)
                        .focused($focusedPasteBox, equals: i)
                    if pasteBoxes[i].isEmpty {
                        Text("press ⌘V here")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.textDim)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .overlay(Rectangle().stroke(Color.accent, lineWidth: 1.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(i)
        .transition(.opacity)
    }

    private var spacePreviewFinalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                // Display sizing matched to the site's section heads:
                // larger, lighter weight, tight tracking — not 17pt bold.
                Text("There's a lot more behind the popup")
                    .font(.system(size: 22, weight: .medium)).tracking(-0.4)
                    .foregroundColor(.textPri)
                Text("Five moves that live inside the ring. Hover one to see what it does.")
                    .font(.system(size: 12)).foregroundColor(.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PopupGestureDemo()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private enum PopupDemoGesture: String, CaseIterable, Identifiable {
    // Declaration order IS the on-screen order (the demo iterates allCases):
    // the single-tap keys first, then the hold gesture, then Details.
    case space, x, del, holdV, details
    var id: String { rawValue }

    var trackingID: String {
        switch self {
        case .space:   return "space"
        case .x:       return "x"
        case .del:     return "del"
        case .holdV:   return "hold-v"
        case .details: return "details"
        }
    }

    /// The keycap face. `label` is a LocalizedStringKey for SwiftUI text;
    /// ClipenKeyCap needs the plain String to size and scale the glyph.
    var plainLabel: String {
        switch self {
        case .space:   return "space"
        case .x:       return "X"
        case .del:     return "del"
        case .holdV:   return "hold V"
        case .details: return "D"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .space:   return "space"
        case .x:       return "X"
        case .del:     return "del"
        case .holdV:   return "hold V"
        case .details: return "D"
        }
    }

    var kbKey: ClipenSettingsView.KBKey {
        switch self {
        case .space:   return .init(id: "onboarding.space", label: "space", demos: [.spacePreview])
        case .x:       return .init(id: "onboarding.x",     label: "X",     demos: [.transform])
        case .del:     return .init(id: "onboarding.del",   label: "del",  demos: [.delete])
        case .holdV:   return .init(id: "onboarding.holdV", label: "hold V", demos: [.multiPaste])
        case .details: return .init(id: "onboarding.details", label: "D",   demos: [.details])
        }
    }
}

private struct PopupGestureDemo: View {
    @StateObject private var lab = InteractionLabController()
    @State private var activeGesture: PopupDemoGesture? = nil

    /// Which move the right-hand column is describing. Follows hover and
    /// click, and starts on the first key so the column is never empty —
    /// it used to hold a static "Click these buttons to see the
    /// interactions", which spent a third of the panel on an instruction
    /// the buttons already imply.
    @State private var describedGesture: PopupDemoGesture = .space

    var body: some View {

        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                MicroLabel(text: "Open the ring")
                openPopupKeys
                VStack(alignment: .leading, spacing: 3) {
                    MicroLabel(text: "Hold ⌘", color: .textDim)
                    MicroLabel(text: "Tap V to step", color: .textDim)
                    MicroLabel(text: "Release to paste", color: .textDim)
                }
            }
            .frame(width: 168, alignment: .leading)

            Rectangle().fill(Color.border).frame(width: 1)
                .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 14) {
                MicroLabel(text: "While it's open")
                VStack(spacing: 6) {
                    ForEach(PopupDemoGesture.allCases) { gesture in
                        demoKey(gesture)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Color.border).frame(width: 1)
                .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 11) {
                MicroLabel(text: "What it does")
                Text(describedGesture.kbKey.label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundColor(.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentDim)
                if let demo = describedGesture.kbKey.demos.first {
                    Text(demo.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.textPri)
                    Text(demo.caption)
                        .font(.system(size: 11))
                        .foregroundColor(.textSec)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 208, alignment: .leading)
            .animation(.easeOut(duration: 0.18), value: describedGesture)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var openPopupKeys: some View {
        HStack(spacing: 9) {
            ClipenKeyCap(label: "⌘")
            Text("+").font(.system(size: 13, design: .monospaced)).foregroundColor(.textDim)
            ClipenKeyCap(label: "V")
        }
    }

    private func demoKey(_ gesture: PopupDemoGesture) -> some View {
        let isActive = activeGesture == gesture
        let isDescribed = describedGesture == gesture
        return HStack(spacing: 13) {
            ClipenKeyCap(label: gesture.plainLabel, width: 64, height: 36,
                         fontSize: 11, pressed: isActive || isDescribed)
            Text(gesture.kbKey.demos.first?.title ?? gesture.plainLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isDescribed ? .textPri : .textSec)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
            .padding(.leading, 6).padding(.trailing, 9)
            .padding(.vertical, 6)
            .background(isDescribed ? Color.accentDim : Color.clear)
            .overlay(Rectangle().stroke(isDescribed ? Color.accent.opacity(0.34) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { describedGesture = gesture }
            }
            .onTapGesture {
                describedGesture = gesture
                if isActive {
                    activeGesture = nil
                } else {
                    AuthManager.shared.registerActionUsage(actionID: "action.onboarding-demo-\(gesture.trackingID)")
                    WakeGuard.afterWakeSettle { activeGesture = gesture }
                }
            }
            .popover(isPresented: Binding(
                get: { activeGesture == gesture },
                set: { isPresented in if !isPresented { activeGesture = nil } }
            ), arrowEdge: .bottom) {
                ClipenSettingsView.KeyDemoPopup(key: gesture.kbKey, lab: lab, showRealKeyboardToggle: false)
            }
    }
}
