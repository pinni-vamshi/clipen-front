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

struct TutorialSheet: View {
    @Binding var isPresented: Bool
    var onSeeMore: () -> Void = {}
    @ObservedObject private var manager = ClipboardManager.shared
    @StateObject private var lab = InteractionLabController()

    @State private var page: Int = 0
    @State private var baselineIDs: Set<UUID> = []
    @State private var pasteBoxes: [String] = ["", "", ""]
    @FocusState private var focusedPasteBox: Int?

    /// Page-1 intro choreography: the philosophy pitch shows on its own first,
    /// then springs aside (smaller, kept visible) while the three copy targets
    /// stagger into place. `revealedRows` gates the one-by-one row entrance;
    /// `promptPulse` drives the slow "copy these" impulse.
    @State private var introRevealed = false
    @State private var revealedRows = 0
    @State private var promptPulse = false
    @State private var wordsShown = 0

    /// The big opening line, revealed one word at a time with a smooth ease.
    /// The two full lines are localized at runtime, then split into words so
    /// the reveal follows each language's own wording/order. (Scripts without
    /// spaces just reveal the whole line as one smooth chunk.)
    private static let philosophyLineKeys = ["A new interaction", "behind every paste."]
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

    /// The three example lines. Localized at runtime so the text the user
    /// copies (and later pastes/matches) is in their language — the URL has no
    /// translation, so it falls back to itself.
    private static let copyTargetKeys = [
        "Hello from Clipen",
        "https://clipen.app",
        "Made with care on macOS",
    ]
    private var copyTargets: [String] {
        Self.copyTargetKeys.map { String(localized: String.LocalizationValue($0)) }
    }

    /// Paste practice targets — the copied lines newest-first, so box 1 (the
    /// most recent copy) is reached with the fewest V taps and box 3 (the
    /// oldest) needs the most. That ordering is what makes the ×1 / ×2 / ×3
    /// paste animations line up with what the user actually has to do.
    private var pasteTargets: [String] { copyTargets.reversed() }

    /// Small header shown above each paste box — spells out the tap count.
    private static let pasteBoxLabelKeys = ["Box 1 — tap V once",
                                            "Box 2 — tap V twice",
                                            "Box 3 — tap V three times"]

    private var newCopiedTexts: Set<String> {
        let newItems = manager.items.filter { !baselineIDs.contains($0.id) }
        return Set(newItems.compactMap { item in
            item.content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    private func isCopied(_ t: String) -> Bool { newCopiedTexts.contains(t.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var copiedCount: Int { copyTargets.filter(isCopied).count }
    private var canAdvance: Bool { copiedCount == copyTargets.count }

    private func isPasted(_ i: Int) -> Bool {
        pasteBoxes[i].trimmingCharacters(in: .whitespacesAndNewlines)
            == pasteTargets[i].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The first box not yet filled correctly (0–2), or 3 when all are done.
    private var currentPasteTarget: Int {
        for i in 0..<3 where !isPasted(i) { return i }
        return 3
    }
    private var allPasted: Bool { currentPasteTarget == 3 }
    private var pasteDemoForTarget: InteractionDemo {
        switch currentPasteTarget {
        case 0:  return .pasteOne
        case 1:  return .pasteTwo
        default: return .pasteThree
        }
    }

    private func selectDemoForCurrentPage() {
        // Only the paste-practice page (1) shows the live animation now;
        // the final page is a static feature summary.
        if page == 1 { lab.select(pasteDemoForTarget) } else { lab.stop() }
    }

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
            selectDemoForCurrentPage()
        }
        .onDisappear { lab.stop() }
        .onChange(of: page) { _, _ in
            selectDemoForCurrentPage()
            if page == 1 { focusedPasteBox = currentPasteTarget }
        }
        .onChange(of: currentPasteTarget) { _, newTarget in
            guard page == 1 else { return }
            selectDemoForCurrentPage()
            if newTarget < 3 {
                focusedPasteBox = newTarget
            } else {
                // All three pasted — auto-advance to the final page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    guard page == 1, allPasted else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { page = 2 }
                }
            }
        }
    }

    // Overlaid on the current page (not its own row) so it sits level with
    // the page's heading line instead of floating above it with a gap.
    private var closeButton: some View {
        Button { isPresented = false } label: {
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
            // Pages 0 and 1 auto-advance the moment their gate is met (all
            // lines copied / all boxes pasted), so they show a hint instead of
            // a Continue button. Only the final page keeps an explicit Done.
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
                // Final page: the primary action opens Settings' full
                // interactions list instead of just closing.
                Button {
                    isPresented = false
                    onSeeMore()
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
    }

    private var copyGatePage: some View {
        VStack(alignment: .leading, spacing: introRevealed ? 18 : 12) {
            // Big opening line — each word eases in smoothly, one after another.
            // Once read, it shrinks up into the corner and the copy section
            // animates in beneath it.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(philosophyWords.enumerated()), id: \.offset) { lineIdx, line in
                    HStack(spacing: 11) {
                        ForEach(Array(line.enumerated()), id: \.offset) { wordIdx, word in
                            let g = globalWordIndex(line: lineIdx, word: wordIdx)
                            Text(word)
                                .font(.system(size: 42, weight: .heavy))
                                .foregroundColor(.textPri)
                                .opacity(g < wordsShown ? 1 : 0)
                                .offset(y: g < wordsShown ? 0 : 10)
                                .blur(radius: g < wordsShown ? 0 : 4)
                        }
                    }
                }
            }
            // Fixed font + scale shrink keeps the size change smooth (SwiftUI
            // can't tween font size); the negative padding pulls the copy block
            // up to absorb the empty space the two-line shrink leaves behind.
            // Even after shrinking it stays large and prominent.
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
            // Auto-advance to the paste page once all three lines are captured.
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
        // Reveal the tagline one word at a time, each easing in smoothly…
        let wordGap = 0.32
        for i in 1...philosophyWordCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + wordGap * Double(i)) {
                withAnimation(.easeOut(duration: 0.5)) { wordsShown = i }
            }
        }
        // …then, after a beat to let it land, shrink it aside and stagger the
        // copy targets + hints in.
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
            // Description — full width, edge to edge, under the tagline.
            Text("Clipen isn't a list you scroll — it's a keyboard-first ring. Hold ⌘, tap V to cycle, release to paste. Let's feel it in three quick steps.")
                .font(.system(size: 12)).foregroundColor(.textSec)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().background(Color.border)

            // Two halves — instruction on the left, the three stacked cards
            // on the right. `.center` (not `.top`) so the shorter left column
            // vertically centers itself against however tall the card column
            // ends up being — dynamic, no hardcoded height needed.
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Copy these 3 lines")
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.textPri)
                        .scaleEffect(promptPulse ? 1.035 : 1.0, anchor: .leading)
                    Text("Click into each box and press ⌘C. Clipen catches every copy automatically.")
                        .font(.system(size: 11)).foregroundColor(.textSec)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                        Text("copy each of these")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.accent.opacity(0.85))
                    .offset(x: promptPulse ? 3 : -1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    ForEach(Array(copyTargets.enumerated()), id: \.offset) { idx, text in
                        copyTargetCard(index: idx, text: text, copied: isCopied(text))
                            .opacity(idx < revealedRows ? 1 : 0)
                            .offset(y: idx < revealedRows ? 0 : 14)
                    }

                    // Same text/logic/localization as before — just moved to
                    // sit under the three copy targets instead of the left
                    // instruction column.
                    Text(canAdvance
                         ? "Nice! Taking you to pasting them back…"
                         : "Copied \(copiedCount) of \(copyTargets.count).")
                        .font(.system(size: 11))
                        .foregroundColor(canAdvance ? .green : .textDim)
                        .frame(minHeight: 16).animation(.easeInOut(duration: 0.2), value: canAdvance)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyTargetCard(index: Int, text: String, copied: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.system(size: 11, weight: .bold))
                .foregroundColor(copied ? .white : .textSec).frame(width: 22, height: 22)
                .background(copied ? Color.green : Color.textDim.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 6))

            Text(text).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(.textPri)
                .textSelection(.enabled).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if copied {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Copied")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.green)
            } else {
                // Lets someone finish this step with a click instead of
                // needing to select the text and press ⌘C themselves —
                // writes straight to the pasteboard, which Clipen's own
                // clipboard watcher picks up exactly like a real copy,
                // so `isCopied` flips true the same way either path.
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.textDim)
                .help("Copy")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(copied ? Color.green.opacity(0.55) : Color.border, lineWidth: 1))
        .animation(.spring(response: 0.3), value: copied)
    }

    // MARK: - Page 2 · Paste the three items back

    private var pastePracticePage: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Now paste them back").font(.system(size: 17, weight: .bold)).foregroundColor(.textPri)
                    .padding(.bottom, 10)

                VStack(spacing: 18) {
                    ForEach(0..<3, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(LocalizedStringKey(Self.pasteBoxLabelKeys[i]))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(currentPasteTarget == i ? .accent : .textDim)
                            pasteTargetRow(index: i)
                            if i < 2 { Divider().padding(.top, 11) }
                        }
                    }
                }

                Text(allPasted
                     ? "Perfect — taking you to the last step…"
                     : "Filled \(pasteBoxesDone) of 3 — fills auto-continue once all three are done.")
                    .font(.system(size: 11))
                    .foregroundColor(allPasted ? .green : .textDim)
                    .frame(minHeight: 16)
                    .animation(.easeInOut(duration: 0.2), value: allPasted)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InteractionLabStage(lab: lab)
                .frame(width: 280)
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14).frame(maxWidth: .infinity)
    }

    private var pasteBoxesDone: Int { (0..<3).filter(isPasted).count }

    private func pasteTargetRow(index: Int) -> some View {
        let done = isPasted(index)
        let isCurrent = currentPasteTarget == index
        return HStack(spacing: 10) {
            // Arrow that points at the box you should paste into next.
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.accent)
                .opacity(isCurrent ? 1 : 0)
                .offset(x: isCurrent ? 0 : -4)
                .animation(.spring(response: 0.3), value: isCurrent)

            Text("\(index + 1)").font(.system(size: 11, weight: .bold))
                .foregroundColor(done ? .white : .textSec).frame(width: 22, height: 22)
                .background(done ? Color.green : Color.textDim.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 6))

            ZStack(alignment: .leading) {
                TextField("", text: $pasteBoxes[index])
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.textPri)
                    .focused($focusedPasteBox, equals: index)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                if pasteBoxes[index].isEmpty {
                    Text("paste “\(pasteTargets[index])” here")
                        .font(.system(size: 11)).foregroundColor(.textDim)
                        .padding(.horizontal, 10).allowsHitTesting(false)
                }
            }
            .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(done ? Color.green.opacity(0.5)
                             : (isCurrent ? Color.accent : Color.border),
                        lineWidth: isCurrent ? 1.5 : 1))

            Image(systemName: done ? "checkmark.circle.fill" : "\(index + 1).circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(done ? .green : .textDim)
                .frame(width: 22)
                .animation(.spring(response: 0.3), value: done)
        }
    }

    // MARK: - Page 3 · More useful moves, then jump to all interactions

    private var spacePreviewFinalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("There's a lot more behind the popup")
                    .font(.system(size: 17, weight: .bold)).foregroundColor(.textPri)
                Text("A few of the most useful moves — click a key to see it happen.")
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

/// The four gestures this page teaches, in the fixed order they appear in
/// the demo's key column. Each maps to a `ClipenSettingsView.KBKey` wired
/// to the exact same `KeyDemoPopup` the Settings keyboard-interaction demo
/// uses — clicking a button here opens the real thing, not a second
/// reimplementation of it.
private enum PopupDemoGesture: String, CaseIterable, Identifiable {
    case holdV, space, x, del
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .holdV: return "hold V"
        case .space: return "space"
        case .x:     return "X"
        case .del:   return "del"
        }
    }

    var kbKey: ClipenSettingsView.KBKey {
        switch self {
        case .holdV: return .init(id: "onboarding.holdV", label: "hold V", demos: [.multiPaste])
        case .space: return .init(id: "onboarding.space", label: "space", demos: [.spacePreview])
        case .x:     return .init(id: "onboarding.x",     label: "X",     demos: [.transform])
        case .del:   return .init(id: "onboarding.del",   label: "del",  demos: [.delete])
        }
    }
}

/// A fixed mock popup on the left, the four gesture keys in the middle, and
/// — on click — the exact same `KeyDemoPopup` the Settings keyboard demo
/// already uses, reused directly rather than rebuilt a second time.
/// Deliberately click-driven, not hover-driven: hover fired on every
/// incidental mouse pass over the keys, which is what made the previous
/// version read as jittery/unstable rather than a deliberate interaction.
private struct PopupGestureDemo: View {
    private static let items: [LocalizedStringKey] = ["Item One", "Item Two", "Item Three", "Item Four"]
    private static let selectedIndex = 0

    // Shared with KeyDemoPopup exactly like KeyboardInteractionPanel shares
    // its own — one controller per demo session, not one per key.
    @StateObject private var lab = InteractionLabController()
    @State private var activeGesture: PopupDemoGesture? = nil
    // Idle "these are clickable" affordance — a slow breathing border,
    // unrelated to hover/click state, always running while this page is up.
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(spacing: 10) {
                mockPopup
                VStack(spacing: 2) {
                    Text("Open popup").font(.system(size: 10, weight: .semibold)).foregroundColor(.textDim)
                    Text("⌘V").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.textSec)
                }
            }

            VStack(spacing: 10) {
                ForEach(PopupDemoGesture.allCases) { gesture in
                    demoKey(gesture)
                }
            }

            Text("Click these buttons to see the interactions.")
                .font(.system(size: 11))
                .foregroundColor(.textDim)
                .multilineTextAlignment(.leading)
                .frame(width: 150, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var mockPopup: some View {
        VStack(spacing: 4) {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { idx, label in
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 11, weight: idx == Self.selectedIndex ? .semibold : .regular))
                        .foregroundColor(idx == Self.selectedIndex ? .white : .textPri)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(idx == Self.selectedIndex ? Color.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(8)
        .frame(width: 150)
        .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.border, lineWidth: 1))
    }

    /// One square, macOS-keycap-style button per gesture — pulses gently
    /// while idle and snaps to a solid pressed look on click. Clicking opens
    /// `KeyDemoPopup` (the real Settings demo popup) anchored to this key,
    /// exactly like `KeyCapView` does in Settings.
    private func demoKey(_ gesture: PopupDemoGesture) -> some View {
        let isActive = activeGesture == gesture
        return Text(gesture.label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(isActive ? .white : .textSec)
            .frame(width: 54, height: 40)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? Color.accent : Color.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.accent.opacity(isActive ? 1 : (pulse ? 0.9 : 0.35)),
                        lineWidth: isActive ? 2 : 1.4))
            .scaleEffect(isActive ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isActive)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture {
                if isActive {
                    activeGesture = nil
                } else {
                    WakeGuard.afterWakeSettle { activeGesture = gesture }
                }
            }
            .popover(isPresented: Binding(
                get: { activeGesture == gesture },
                set: { isPresented in if !isPresented { activeGesture = nil } }
            ), arrowEdge: .bottom) {
                ClipenSettingsView.KeyDemoPopup(key: gesture.kbKey, lab: lab)
            }
    }
}
