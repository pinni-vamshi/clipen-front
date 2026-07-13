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
        ("pin.fill",              "Pin",        "Pin your favourites",  "Right-click any item to pin it so it never falls off the ring"),
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
    @State private var practiceText: String = ""

    private static let totalPages = 4
    private static let demoForPage: [Int: InteractionDemo] = [
        1: .cycle, 2: .spacePreview, 3: .transform,
    ]

    private static let copyTargets: [String] = [
        "Hello from Clipen",
        "https://clipen.app",
        "Made with care on macOS",
    ]

    private var newCopiedTexts: Set<String> {
        let newItems = manager.items.filter { !baselineIDs.contains($0.id) }
        return Set(newItems.compactMap { item in
            item.content.plainText?.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    private func isCopied(_ t: String) -> Bool { newCopiedTexts.contains(t.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var copiedCount: Int { Self.copyTargets.filter(isCopied).count }
    private var canAdvance: Bool { copiedCount == Self.copyTargets.count }

    var body: some View {
        VStack(spacing: 0) {
            tutorialHeader
            Divider().background(Color.border)
            Group {
                switch page {
                case 0:  copyGatePage
                case 1:  cyclePage
                case 2:  spacePreviewPage
                default: transformPage
                }
            }
            .frame(minHeight: 420)
            Divider().background(Color.border)
            tutorialFooter
        }
        .frame(width: 760).background(Color.surface)
        .onAppear {
            baselineIDs = Set(manager.items.map(\.id))
            if let demo = Self.demoForPage[page] { lab.select(demo) }
        }
        .onDisappear { lab.stop() }
        .onChange(of: page) { _, newPage in
            if let demo = Self.demoForPage[newPage] {
                lab.select(demo)
            } else {
                lab.stop()
            }
        }
    }

    private var tutorialHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill").foregroundColor(.accent)
            Text("How Clipen works").font(.system(size: 16, weight: .bold)).foregroundColor(.textPri)
            Spacer()
            Text("Step \(page + 1) of \(Self.totalPages)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(.textDim)
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundColor(.textSec)
            }
            .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
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
            let isLast = page == Self.totalPages - 1
            let enabled = page == 0 ? canAdvance : true
            if isLast {
                Button {
                    isPresented = false
                    onSeeMore()
                } label: {
                    Text("See more").font(.system(size: 12, weight: .medium)).foregroundColor(.textSec)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
            Button {
                if isLast { isPresented = false } else { withAnimation { page += 1 } }
            } label: {
                Text(isLast ? "Done" : "Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(enabled ? .white : .textDim)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .background(enabled ? Color.accent : Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(enabled ? Color.clear : Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(!enabled)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var copyGatePage: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Copy these 3 lines").font(.system(size: 18, weight: .bold)).foregroundColor(.textPri)
                Text("Click into each box, select the text, and press ⌘C. Clipen will catch every copy automatically.")
                    .font(.system(size: 12)).foregroundColor(.textSec)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 400)
            }
            .padding(.top, 4)

            VStack(spacing: 10) {
                ForEach(Array(Self.copyTargets.enumerated()), id: \.offset) { idx, text in
                    copyTargetRow(index: idx, text: text, copied: isCopied(text))
                }
            }

            Text(canAdvance
                 ? "Nice! Tap Continue to learn how to paste them back."
                 : "Copied \(copiedCount) of \(Self.copyTargets.count) — copy the rest to continue.")
                .font(.system(size: 11))
                .foregroundColor(canAdvance ? .green : .textDim)
                .frame(minHeight: 16).animation(.easeInOut(duration: 0.2), value: canAdvance)
        }
        .padding(.horizontal, 22).padding(.vertical, 22).frame(maxWidth: .infinity)
    }

    private func copyTargetRow(index: Int, text: String, copied: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(copied ? .white : .textSec).frame(width: 22, height: 22)
                .background(copied ? Color.green : Color.textDim.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 6))
            Text(text).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(.textPri)
                .textSelection(.enabled).padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(copied ? Color.green.opacity(0.5) : Color.border, lineWidth: 1))
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark.circle.fill" : "command")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(copied ? .green : .textDim)
                Text(copied ? "Copied" : "⌘C")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(copied ? .green : .textDim)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background((copied ? Color.green : Color.textDim).opacity(copied ? 0.14 : 0.08),
                        in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 70, alignment: .center)
            .animation(.spring(response: 0.3), value: copied)
        }
    }

    private var cyclePage: some View {
        animatedPage(
            title: "Hold ⌘ and tap V to cycle",
            detail: "Hold ⌘ to open your clipboard ring. Each tap of V moves to the next item; ⌘⌥V leaps 5 forward. Release ⌘ to paste the highlighted item.",
            hint:   "Click below, then hold ⌘ · tap V to cycle · release ⌘ to paste."
        ) { InteractionLabStage(lab: lab) }
    }

    private var spacePreviewPage: some View {
        animatedPage(
            title: "Tap Space to preview",
            detail: "With an item highlighted, tap Space to see it full-size. Tap Space again to close it — nothing is pasted, it's just a look.",
            hint:   "Click below, hold ⌘, tap V to pick an item, then tap Space to preview it."
        ) { InteractionLabStage(lab: lab) }
    }

    private var transformPage: some View {
        animatedPage(
            title: "Pick with V, then transform with X",
            detail: "First hold ⌘ and tap V to land on the item you want to change. Then tap X to apply a transform — UPPERCASE, lowercase, Base64, JSON pretty-print and more. Tap X again to cycle. Release ⌘ to paste.",
            hint:   "Click below, hold ⌘, tap V to pick an item, then tap X to transform it."
        ) { InteractionLabStage(lab: lab) }
    }

    private func animatedPage<A: View>(title: String, detail: String, hint: String,
                                       @ViewBuilder anim: () -> A) -> some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 17, weight: .bold)).foregroundColor(.textPri)
                    Text(detail).font(.system(size: 12)).foregroundColor(.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
                practiceBox(hint: hint)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            anim()
                .frame(width: 280)
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14).frame(maxWidth: .infinity)
    }

    private func practiceBox(hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.tip.crop.circle").font(.system(size: 10, weight: .semibold)).foregroundColor(.accent)
                Text("TRY IT HERE").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.textDim).tracking(1.4)
                Spacer()
                if !practiceText.isEmpty {
                    Button { practiceText = "" } label: {
                        Text("Clear").font(.system(size: 10, weight: .medium)).foregroundColor(.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $practiceText)
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.textPri)
                    .frame(height: 78).scrollContentBackground(.hidden)
                    .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.border, lineWidth: 1))
                if practiceText.isEmpty {
                    Text(hint).font(.system(size: 11)).foregroundColor(.textDim)
                        .padding(.horizontal, 8).padding(.vertical, 9).allowsHitTesting(false)
                }
            }
        }
    }

}
