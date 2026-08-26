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

    private var shownFeature: NudgeFeature?
    private var shownTotal = 0
    private var shownOnLearned: (() -> Void)?
    private var shownOnLater: (() -> Void)?

    override init() {

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
        panel.setContentSize(Self.size)
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

                // No fixed width — was 300, missed in the same pass that
                // fixed the other two InteractionLabStage call sites
                // (SettingsView's KeyDemoPopup, TutorialSheet). LabMockPanel
                // (190) plus LabSidePanel (120) plus their gap alone already
                // exceeded 300 whenever a demo's side panel shows (Preview,
                // Refer, Transform), before the ⌘+V pair added beside them
                // made it worse. Sizes to its own content now, same as the
                // other two.
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

        .onChange(of: demo) { newDemo in
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
