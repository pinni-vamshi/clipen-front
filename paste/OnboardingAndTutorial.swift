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

/// Page 2: the ring, demonstrated end to end.
///
/// The page used to name the mechanism in prose and then ask the user to fill
/// three boxes. What actually needs teaching is that you browse *while Command
/// is held*, and that letting go is what commits — and no amount of "tap V
/// twice" text lands that. So this shows one whole loop instead: Command goes
/// down and stays down, V steps the selection, releasing Command sends the
/// highlighted item into a destination field. The animation is the
/// explanation; the closing line is the instruction.
struct RingSimulation: View {
    private static let entries = [
        "Made with care on macOS",
        DeviceIdentity.websiteURLString,
        "Hello from Clipen",
    ]

    @State private var selected: Int? = nil     // 1...3
    @State private var cmdHeld = false
    @State private var cmdReleased = false
    @State private var vTapNonce = 0
    @State private var flying = false
    @State private var dropped = false
    @State private var beat = 0
    @State private var beatKicker = ""
    @State private var beatText = ""
    @State private var finished = false
    @State private var work: [DispatchWorkItem] = []

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            history
                .frame(width: 292)
                .padding(.trailing, 28)

            Rectangle().fill(Color.border).frame(width: 1)

            rightColumn
                .padding(.leading, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: play)
        .onDisappear(perform: cancel)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicroLabel(text: "Clipboard history")
            VStack(spacing: -1) {
                ForEach(1...3, id: \.self) { n in
                    historyRow(n).zIndex(selected == n ? 2 : 1)
                }
            }
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(i < beat ? Color.okGreen : (i == beat ? Color.accent : Color.border))
                        .frame(width: 26, height: 2)
                        .animation(.easeOut(duration: 0.25), value: beat)
                }
            }
            .padding(.top, 2)
        }
    }

    private func historyRow(_ n: Int) -> some View {
        let isSel = selected == n
        let isGone = flying && isSel
        return HStack(spacing: 12) {
            Text("\(n)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isSel ? .white : .textDim)
                .frame(width: 22, height: 22)
                .background(isSel ? Color.accent : Color.textDim.opacity(0.12))
            Text(Self.entries[n - 1])
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(isSel ? .textPri : .textSec)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(isSel ? Color.accentDim : Color.clear)
        .overlay(Rectangle().stroke(isSel ? Color.accent : Color.border, lineWidth: 1))
        // Selection reads as position, not only colour — the row steps right.
        .offset(x: isGone ? 26 : (isSel ? 7 : 0))
        .opacity(isGone ? 0 : 1)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32), value: selected)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32), value: flying)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                VStack(spacing: 7) {
                    MicroLabel(text: cmdHeld ? "holding" : (cmdReleased ? "released" : "hold"),
                               color: cmdHeld ? .accent : (cmdReleased ? .okGreen : .textDim))
                        .frame(height: 11)
                    ClipenKeyCap(label: "⌘", pressed: cmdHeld)
                }
                Text("+").font(.system(size: 13, design: .monospaced)).foregroundColor(.textDim)
                VStack(spacing: 7) {
                    MicroLabel(text: "tap", color: cmdHeld ? .accent : .textDim)
                        .frame(height: 11)
                    // A tap is a bounce, not a state: re-keying replays it.
                    ClipenKeyCap(label: "V", pressed: false)
                        .id(vTapNonce)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(beatKicker)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.4).textCase(.uppercase)
                    .foregroundColor(finished ? .okGreen : .accent)
                Text(beatText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.textPri)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 46, alignment: .top)
            .animation(.easeOut(duration: 0.2), value: beatText)

            VStack(alignment: .leading, spacing: 8) {
                MicroLabel(text: "Wherever you're typing")
                HStack(spacing: 0) {
                    Text(dropped ? Self.entries[1] : String(localized: "Type something here…"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(dropped ? .textPri : .textDim)
                        .lineLimit(1).truncationMode(.middle)
                    if !dropped {
                        Rectangle().fill(Color.accent)
                            .frame(width: 7, height: 15).padding(.leading, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15).padding(.vertical, 14)
                .frame(minHeight: 48, alignment: .leading)
                .background(dropped ? Color.okGreenDim : Color.clear)
                .overlay(Rectangle().stroke(dropped ? Color.okGreen.opacity(0.5) : Color.border,
                                            lineWidth: 1))
                .animation(.easeOut(duration: 0.28), value: dropped)
            }
        }
    }

    // MARK: timeline

    private func step(_ delay: Double, _ body: @escaping () -> Void) {
        let item = DispatchWorkItem(block: body)
        work.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancel() {
        work.forEach { $0.cancel() }
        work.removeAll()
    }

    private func play() {
        cancel()
        selected = nil; cmdHeld = false; cmdReleased = false
        flying = false; dropped = false; finished = false; beat = 0
        beatKicker = String(localized: "Step 1")
        beatText   = String(localized: "Hold ⌘ — the ring opens.")

        // 1. Command goes down and STAYS down for everything that follows.
        step(0.7) { withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) { cmdHeld = true } }

        // 2. first tap lands on #1
        step(1.5) {
            withAnimation { vTapNonce += 1 }
            selected = 1; beat = 1
            beatKicker = String(localized: "Step 2")
            beatText   = String(localized: "Tap V once → you're on #1.")
        }

        // 3. second tap — the selection travels; nothing resets
        step(2.9) {
            withAnimation { vTapNonce += 1 }
            selected = 2; beat = 2
            beatKicker = String(localized: "Step 3")
            beatText   = String(localized: "Tap V again → the selection moves to #2.")
        }

        // 4. the release: the item leaves the ring and lands in the field
        step(4.5) {
            beat = 3
            beatKicker = String(localized: "Step 4")
            beatText   = String(localized: "Release ⌘ → #2 is pasted.")
            withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
                cmdHeld = false; cmdReleased = true
            }
            flying = true
        }
        step(4.82) { dropped = true }
        step(5.1) {
            flying = false; selected = nil; finished = true; beat = 4
            beatKicker = String(localized: "That's the loop")
            beatText   = String(localized: "Hold · tap to move · release to paste.")
        }
    }
}

struct TutorialSheet: View {
    @Binding var isPresented: Bool
    var onSeeMore: () -> Void = {}
    @ObservedObject private var manager = ClipboardManager.shared
    @State private var page: Int = 0
    @State private var baselineIDs: Set<UUID> = []
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
        let newItems = manager.items.filter { !baselineIDs.contains($0.id) }
        return Set(newItems.compactMap { item in
            item.content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    private func isCopied(_ t: String) -> Bool { newCopiedTexts.contains(t.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var copiedCount: Int { copyTargets.filter(isCopied).count }
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
            baselineIDs = Set(manager.items.map(\.id))
            AuthManager.shared.registerActionUsage(actionID: "action.onboarding-started")
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
                // Page 2 no longer gates on three filled boxes — it's a
                // demonstration now, so it needs an explicit way forward.
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { page = 2 }
                } label: {
                    HStack(spacing: 7) {
                        Text("Got it").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Color.accent)
                }
                .buttonStyle(.plain)
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
        HStack(spacing: 13) {
            // Square numeral chip, not a rounded pill — the site numbers
            // things with flat mono squares (.mpx-badge).
            Text("\(index + 1)").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(copied ? .white : .textSec).frame(width: 24, height: 24)
                .background(copied ? Color.okGreen : Color.textDim.opacity(0.12))

            Text(text).font(.system(size: 12, weight: .regular, design: .monospaced)).foregroundColor(.textPri)
                .textSelection(.enabled).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if copied {
                Text("Copied")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundColor(.okGreen)
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
        .overlay(Rectangle().stroke(copied ? Color.okGreen.opacity(0.4) : Color.border, lineWidth: 1))
        .animation(.spring(response: 0.3), value: copied)
    }

    @State private var simNonce = 0

    private var pastePracticePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Watch one paste, end to end")
                    .font(.system(size: 22, weight: .medium)).tracking(-0.4)
                    .foregroundColor(.textPri)
                Text("Three things are on your clipboard. Here's what ⌘V actually does with them.")
                    .font(.system(size: 12)).foregroundColor(.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RingSimulation()
                // Re-keyed so Replay rebuilds the view and restarts its
                // timeline from onAppear, instead of needing a second path
                // into the same animation.
                .id(simNonce)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .topTrailing) {
            Button { simNonce += 1 } label: {
                Text("Replay")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4).textCase(.uppercase)
                    .foregroundColor(.textDim)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(Rectangle().stroke(Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 22).padding(.trailing, 56)
        }
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
