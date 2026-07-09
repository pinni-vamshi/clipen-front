import SwiftUI
import AppKit

// MARK: - Onboarding (animated empty state)

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

// MARK: - Tutorial sheet

struct TutorialSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var manager = ClipboardManager.shared

    @State private var page: Int = 0
    @State private var baselineIDs: Set<UUID> = []
    @State private var tick: Int = 0
    @State private var tickTimer: Timer? = nil
    @State private var practiceText: String = ""

    private static let totalPages = 4

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
                case 2:  transformPage
                default: deletePage
                }
            }
            .frame(minHeight: 420)
            Divider().background(Color.border)
            tutorialFooter
        }
        .frame(width: 500).background(Color.surface).preferredColorScheme(.dark)
        .onAppear { baselineIDs = Set(manager.items.map(\.id)); startTick() }
        .onDisappear { stopTick() }
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

    // MARK: Page 1 — copy gate

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

    // MARK: Pages 2-4

    private var cyclePage: some View {
        animatedPage(
            title: "Hold ⌘ and tap V to cycle",
            detail: "Hold ⌘ to open your clipboard ring. Each tap of V moves to the next item; ⌘⌥V leaps 5 forward. Release ⌘ to paste the highlighted item.",
            hint:   "Click below, then hold ⌘ · tap V to cycle · release ⌘ to paste."
        ) { cycleAnimation(active: tick % 5) }
    }

    private var transformPage: some View {
        animatedPage(
            title: "Pick with V, then transform with X",
            detail: "First hold ⌘ and tap V to land on the item you want to change. Then tap X to apply a transform — UPPERCASE, lowercase, Base64, JSON pretty-print and more. Tap X again to cycle. Release ⌘ to paste.",
            hint:   "Click below, hold ⌘, tap V to pick an item, then tap X to transform it."
        ) { transformAnimation(active: tick % 10) }
    }

    private var deletePage: some View {
        animatedPage(
            title: "Pick with V, then delete with ⌫",
            detail: "First hold ⌘ and tap V to land on the item you want to remove. Then tap ⌫ while the popup is still open.",
            hint:   "Click below, hold ⌘, tap V to pick an item, then tap ⌫ to remove it."
        ) { deleteAnimation(active: tick % 6) }
    }

    private func animatedPage<A: View>(title: String, detail: String, hint: String,
                                       @ViewBuilder anim: () -> A) -> some View {
        VStack(spacing: 16) {
            anim()
            VStack(spacing: 6) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundColor(.textPri)
                Text(detail).font(.system(size: 12)).foregroundColor(.textSec)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
            }
            practiceBox(hint: hint)
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

    // MARK: Animations

    private let snippets = ["Hello from Clipen", "https://clipen.app", "Made with care on macOS"]
    private let vTaps = 2
    private var pickFrames: Int { vTaps * 2 }

    private func cycleAnimation(active: Int) -> some View {
        let phase = active % (pickFrames + 1)
        let cmdHeld = phase < pickFrames
        return animCard {
            HStack(spacing: 12) {
                keyCluster(cmdHeld: cmdHeld, vTap: cmdHeld && (phase % 2 == 0),
                           showRelease: phase == pickFrames)
                Spacer()
                if cmdHeld {
                    ringList(snippets: snippets, selected: min(phase / 2, vTaps - 1))
                } else {
                    pasteLabel()
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
    }

    private func transformAnimation(active: Int) -> some View {
        let transforms: [(String, String)] = [("UPPER","HTTPS://CLIPEN.APP"),("lower","https://clipen.app"),("Base64","aHR0cHM6Ly9jbGlwZW4uYXBw")]
        let phase = active % (pickFrames + 6)
        let inPick = phase < pickFrames
        let pickIdx = inPick ? min(phase / 2, vTaps - 1) : vTaps - 1
        let xPhase = phase - pickFrames
        let xIdx = inPick ? 0 : min(xPhase / 2, transforms.count - 1)
        return animCard {
            HStack(spacing: 10) {
                keyCluster(cmdHeld: true, vTap: inPick && phase % 2 == 0, showV: inPick,
                           xTap: !inPick && xPhase % 2 == 0, showX: !inPick)
                Spacer()
                transformRow(pickIdx: inPick ? pickIdx : vTaps - 1,
                             text: inPick ? snippets[pickIdx] : transforms[xIdx].1,
                             label: inPick ? nil : transforms[xIdx].0)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
    }

    private func deleteAnimation(active: Int) -> some View {
        let phase = active % (pickFrames + 2)
        let inPick = phase < pickFrames
        let del = phase == pickFrames
        let removed = phase == pickFrames + 1
        return animCard {
            HStack(spacing: 10) {
                keyCluster(cmdHeld: phase < pickFrames + 1, vTap: inPick && phase % 2 == 0,
                           showV: inPick, delTap: del, showDel: !inPick)
                Spacer()
                deleteRow(snippets: snippets, pickIdx: inPick ? min(phase/2, vTaps-1) : vTaps-1,
                          deleteIdx: vTaps-1, marking: del, removed: removed)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
    }

    private func animCard<C: View>(@ViewBuilder content: () -> C) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.surfaceHi)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border, lineWidth: 1))
            content().padding(.horizontal, 18)
        }
        .frame(height: 140)
    }

    private func keyCluster(cmdHeld: Bool, vTap: Bool = false, showV: Bool = true,
                             xTap: Bool = false, showX: Bool = false,
                             delTap: Bool = false, showDel: Bool = false,
                             showRelease: Bool = false) -> some View {
        HStack(spacing: 6) {
            animKey("⌘", pressed: cmdHeld, caption: cmdHeld ? "hold" : "release")
            if !showRelease {
                if showV {
                    Text("+").font(.system(size: 14, weight: .bold)).foregroundColor(.textDim)
                    animKey("V", pressed: vTap, caption: vTap ? "tap" : nil)
                }
                if showX {
                    Text("→").font(.system(size: 14, weight: .bold)).foregroundColor(.textDim)
                    animKey("X", pressed: xTap, caption: xTap ? "tap" : nil)
                }
                if showDel {
                    Text("→").font(.system(size: 14, weight: .bold)).foregroundColor(.textDim)
                    animKey("⌫", pressed: delTap, caption: delTap ? "tap" : nil)
                }
            }
        }
    }

    private func animKey(_ label: String, pressed: Bool, caption: String?) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(pressed ? .white : .textPri).frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 10).fill(pressed ? Color.accent : Color.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(pressed ? Color.accent : Color.border, lineWidth: 1.5))
                .shadow(color: pressed ? Color.accent.opacity(0.4) : .clear, radius: 8, y: 2)
                .offset(y: pressed ? 2 : 0).animation(.easeOut(duration: 0.2), value: pressed)
            Text(caption ?? " ").font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(pressed ? .accent : .textDim).opacity(caption == nil ? 0 : 1).frame(height: 10)
        }
    }

    private func ringList(snippets: [String], selected: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<snippets.count, id: \.self) { i in
                let sel = i == selected
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(sel ? Color.accent : Color.textDim.opacity(0.4)).frame(width: 12, height: 5)
                    Text(snippets[i]).font(.system(size: 9, weight: sel ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(sel ? .textPri : .textSec).lineLimit(1).truncationMode(.tail).frame(maxWidth: 150, alignment: .leading)
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(sel ? Color.accentDim : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(10).background(Color.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: selected)
    }

    private func pasteLabel() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down").font(.system(size: 14, weight: .bold)).foregroundColor(.accent)
            Text("Pasted!").font(.system(size: 13, weight: .bold)).foregroundColor(.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 8))
        .transition(.scale.combined(with: .opacity))
    }

    private func transformRow(pickIdx: Int, text: String, label: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<3) { i in
                let picked = i == pickIdx
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(picked ? Color.accent : Color.textDim.opacity(0.4)).frame(width: 12, height: 5)
                    if picked {
                        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.textPri).lineLimit(1).truncationMode(.tail).frame(maxWidth: 130, alignment: .leading)
                            .animation(.easeInOut(duration: 0.25), value: text)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(Color.textDim.opacity(0.3)).frame(width: 90, height: 5)
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(picked ? Color.accentDim : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            if let lbl = label {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars").font(.system(size: 8, weight: .semibold)).foregroundColor(.accent)
                    Text(lbl).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.accent)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.accentDim, in: Capsule())
                .overlay(Capsule().stroke(Color.accent.opacity(0.4), lineWidth: 1))
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.25), value: lbl)
            }
        }
        .padding(10).background(Color.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.border, lineWidth: 1))
    }

    private func deleteRow(snippets: [String], pickIdx: Int, deleteIdx: Int,
                           marking: Bool, removed: Bool) -> some View {
        let visible = removed ? snippets.indices.filter { $0 != deleteIdx } : Array(snippets.indices)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(visible, id: \.self) { i in
                let picked   = !removed && i == pickIdx
                let deleting = !removed && marking && i == deleteIdx
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(deleting ? Color.red.opacity(0.9) : (picked ? Color.accent : Color.textDim.opacity(0.4)))
                        .frame(width: 12, height: 5)
                    if picked || removed {
                        Text(snippets[i]).font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(deleting ? .red.opacity(0.85) : .textPri)
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: 130, alignment: .leading)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(Color.textDim.opacity(0.3)).frame(width: 90, height: 5)
                    }
                    if deleting { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(.red) }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(deleting ? Color.red.opacity(0.15) : (picked ? Color.accentDim : Color.clear),
                            in: RoundedRectangle(cornerRadius: 4))
                .opacity(deleting ? 0.7 : 1).scaleEffect(deleting ? 0.96 : 1)
            }
            if removed {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 8, weight: .semibold)).foregroundColor(.red.opacity(0.9))
                    Text("Deleted").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.red.opacity(0.9))
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.red.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(Color.red.opacity(0.35), lineWidth: 1))
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(10).background(Color.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: pickIdx)
        .animation(.easeInOut(duration: 0.3), value: marking)
        .animation(.easeInOut(duration: 0.3), value: removed)
    }

    // MARK: Tick

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: true) { _ in tick &+= 1 }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    private func stopTick() { tickTimer?.invalidate(); tickTimer = nil }
}

