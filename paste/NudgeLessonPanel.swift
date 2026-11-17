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
    private static let minSize = NSSize(width: 680, height: 440)
    private static let sizeKey = "clipenTipPanelSize"
    private var onLater: (() -> Void)?

    private var shownFeature: NudgeFeature?
    private var shownTotal = 0
    private var shownOnLearned: (() -> Void)?
    private var shownOnLater: (() -> Void)?

    override init() {

        panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Resizable, and it keeps whatever size the user gives it — across
        // tips and across launches. It used to be fixed at 820×500 and was
        // forced back to that size every time a tip opened. The size is
        // stored by hand (`windowDidEndLiveResize`): `setFrameAutosaveName`
        // aborted the app here.
        panel.contentMinSize = Self.minSize
        if let saved = UserDefaults.standard.string(forKey: Self.sizeKey) {
            let size = NSSizeFromString(saved)
            if size.width >= Self.minSize.width, size.height >= Self.minSize.height {
                panel.setContentSize(size)
            }
        }
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init()
        panel.delegate = self
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let size = panel.contentRect(forFrameRect: panel.frame).size
        UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey)
    }

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

        let localizedDemoTitle = String(localized: String.LocalizationValue(feature.demo.title))
        panel.title = String(localized: "Tip: \(localizedDemoTitle)")
        panel.subtitle = String(localized: "\(learnedCount) of \(total) learned")
        centerOnMainScreen()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

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

        onLater = nil
        panel.orderOut(nil)
    }

    private func centerOnMainScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let current = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - current.width / 2,
            y: screenFrame.midY - current.height / 2
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
        // See the note on PopoverPreviewView.body.
        calloutBody.focusEffectDisabled().tracksWindowVisibility()
    }

    private var calloutBody: some View {
        VStack(spacing: 0) {

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

        .overlay {
            if justLearned { NudgeLearnedOverlay() }
        }
        .onAppear {
            lab.select(demo)

            DispatchQueue.main.async { practiceFocused = true }
        }

        .onChange(of: demo) { _, newDemo in
            lab.select(newDemo)
            practiceText = ""
            DispatchQueue.main.async { practiceFocused = true }
        }
        .onDisappear { lab.stop() }
    }
}

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
