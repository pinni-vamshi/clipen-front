import AppKit
import AVKit
import Highlightr
import ModelIO
import NaturalLanguage
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit


final class NudgeLessonPanel: NSObject, NSWindowDelegate {
    private let panel: NSWindow
    private static let size = NSSize(width: 820, height: 500)
    private var onLater: (() -> Void)?

    // Retained so the "Learned!" confirmation can rebuild the same lesson
    // view with the success overlay on, instead of the window just blinking
    // out of existence the moment the gesture lands.
    private var shownFeature: NudgeFeature?
    private var shownTotal = 0
    private var shownOnLearned: (() -> Void)?
    private var shownOnLater: (() -> Void)?

    override init() {
        // An ordinary titled window — nothing custom. That is what gives the
        // standard rounded corners, the normal title bar to drag by, the
        // system close button, and (crucially) automatic key-window status,
        // which is what lets the practice text field actually take keyboard
        // focus. The previous borderless build had to fake all four and got
        // every one of them wrong.
        panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init()
        panel.delegate = self
    }

    /// The title bar's close button is a third way out of the lesson, on top
    /// of the two buttons — treat it exactly like "Later" so a lesson closed
    /// this way retries instead of silently vanishing forever.
    func windowWillClose(_ notification: Notification) {
        onLater?()
    }

    var isVisible: Bool { panel.isVisible }

    func show(feature: NudgeFeature, learnedCount: Int, total: Int,
              onLearned: @escaping () -> Void, onLater: @escaping () -> Void) {
        self.onLater = onLater
        shownFeature = feature
        shownTotal = total
        shownOnLearned = onLearned
        shownOnLater = onLater
        let content = NudgeCalloutView(
            demo: feature.demo,
            learnedCount: learnedCount,
            total: total,
            justLearned: false,
            onLearned: onLearned,
            onLater: onLater
        )
        if let hostingController = panel.contentViewController as? NSHostingController<NudgeCalloutView> {
            hostingController.rootView = content
        } else {
            panel.contentViewController = NSHostingController(rootView: content)
        }
        // NSWindow.title/.subtitle are plain Strings — they never go
        // through SwiftUI's catalog lookup, localized or not, so both
        // pieces have to be resolved explicitly here.
        let localizedDemoTitle = String(localized: String.LocalizationValue(feature.demo.title))
        panel.title = String(localized: "Tip: \(localizedDemoTitle)")
        panel.subtitle = String(localized: "\(learnedCount) of \(total) learned")
        panel.setContentSize(Self.size)
        centerOnMainScreen()
        // Clipen is a menu-bar accessory, so it is normally not the active
        // app — a key window in an inactive app still receives no typing.
        // Activating is what actually routes keystrokes into the practice
        // field, and is exactly what FastPasteHintPanel does for the same
        // reason. The lesson is a deliberate, dismiss-to-continue
        // interruption, so taking focus here is correct.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Marks the lesson visibly complete — a checkmark + "Learned!" over the
    /// panel, with the progress count already advanced — and only then hands
    /// back so the caller can close it. Without this the window vanished the
    /// instant the gesture fired, so the user never saw that the thing they
    /// just did was the thing being taught.
    func flashLearnedThenHide(learnedCount: Int, onDone: @escaping () -> Void) {
        guard let feature = shownFeature,
              let hostingController = panel.contentViewController as? NSHostingController<NudgeCalloutView>
        else { onDone(); return }
        hostingController.rootView = NudgeCalloutView(
            demo: feature.demo,
            learnedCount: learnedCount,
            total: shownTotal,
            justLearned: true,
            onLearned: shownOnLearned ?? {},
            onLater: shownOnLater ?? {}
        )
        panel.subtitle = String(localized: "\(learnedCount) of \(shownTotal) learned")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { onDone() }
    }

    func hide() {
        // orderOut, not close — close would fire windowWillClose and count a
        // programmatic hide (e.g. "Learned") as a "Later" retry.
        onLater = nil
        panel.orderOut(nil)
    }

    private func centerOnMainScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - Self.size.width / 2,
            y: screenFrame.midY - Self.size.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

private struct NudgeCalloutView: View {
    let demo: InteractionDemo
    let learnedCount: Int
    let total: Int
    let justLearned: Bool
    let onLearned: () -> Void
    let onLater: () -> Void

    @StateObject private var lab = InteractionLabController()
    @State private var practiceText: String = ""
    @FocusState private var practiceFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // No hand-rolled header row — this is an ordinary titled window
            // now, so the real title bar carries the tip name and the
            // "X of 5 learned" progress as its subtitle.
            //
            // Side by side, matching the "How to Use" paste-practice page:
            // the practice target on the left, the live animation + key
            // legend on the right — not stacked, so both are visible and
            // legible at once instead of the practice field being squeezed
            // in as an afterthought below the animation.
            HStack(alignment: .top, spacing: 44) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("PRACTICE HERE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                        if practiceText.isEmpty {
                            Text("Try the gesture, then paste or type here…")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $practiceText)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .focused($practiceFocused)
                    }
                    .frame(height: 160)
                    Text("Keep using the app to see more interactions.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                InteractionLabStage(lab: lab)
                    .frame(width: 300)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            HStack(spacing: 10) {
                Button("Later") { onLater() }
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Learned") { onLearned() }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // A titled window paints its own standard background — no custom
        // fill needed (and a custom one would square off the system's
        // rounded corners).
        .overlay {
            if justLearned { NudgeLearnedOverlay() }
        }
        .onAppear {
            lab.select(demo)
            // Next runloop turn — the panel isn't key yet during onAppear,
            // and focus set before the window is key doesn't stick.
            DispatchQueue.main.async { practiceFocused = true }
        }
        // The hosting controller reuses one NSHostingController across every
        // nudge (only `rootView` is reassigned — see NudgeLessonPanel.show),
        // so onAppear only ever fires once, for the very first lesson shown.
        // Without this, every later nudge kept replaying that first demo's
        // animation regardless of which feature was actually being taught.
        .onChange(of: demo) { newDemo in
            lab.select(newDemo)
            practiceText = ""
            DispatchQueue.main.async { practiceFocused = true }
        }
        .onDisappear { lab.stop() }
    }
}

/// The "you just did it" confirmation. Shown for ~1.6s over the lesson after
/// the real gesture fires (or "Learned" is clicked) before the window closes,
/// so completing a lesson reads as an accomplishment instead of the panel
/// silently disappearing mid-interaction.
private struct NudgeLearnedOverlay: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundColor(.green)
                Text("Learned!")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { shown = true }
        }
    }
}

