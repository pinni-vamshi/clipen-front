import AppKit
import SwiftUI

final class FastPasteHintPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        level              = .modalPanel
        isOpaque           = false
        backgroundColor    = .clear
        hasShadow          = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(delayMs: Int, onAdjust: @escaping () -> Void) {
        let view = FastPasteHintView(
            delayMs: delayMs,
            onDismiss: { [weak self] in self?.orderOut(nil) },
            onAdjust:  { [weak self] in
                self?.orderOut(nil)
                onAdjust()
            }
        )
        contentView = NSHostingView(rootView: view)
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { true }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        DispatchQueue.main.async { [weak self] in
            if self?.isVisible == false { self?.contentView = nil }
        }
    }
}

struct FastPasteHintView: View {
    let delayMs: Int
    let onDismiss: () -> Void
    let onAdjust:  () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AnimatedGestureDemo(delayMs: delayMs)
                .padding(.top, 26)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)

            Text("Press ⌘V — keep ⌘ held while the timer fills, and the Clipen picker opens.")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 26)
                .padding(.bottom, 18)

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 360)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                Text("Got it")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )

            Button(action: onAdjust) {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Adjust timer")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#4F8EF7"), Color(hex: "#A855F7")],
                            startPoint: .leading,
                            endPoint:   .trailing
                        )
                    )
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.02))
    }
}

struct AnimatedGestureDemo: View {
    let delayMs: Int

    @State private var step: Step = .idle
    @State private var ringFill: CGFloat = 0

    private final class LoopToken { var active = true }
    @State private var loopToken = LoopToken()

    private enum Step { case idle, cmdDown, vDown, vUp, ringFull, pickerShown }

    private var ringDuration: TimeInterval {
        max(0.35, TimeInterval(delayMs) / 1000.0)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 3)
                        .frame(width: 64, height: 64)
                    Circle()
                        .trim(from: 0, to: ringFill)
                        .stroke(
                            LinearGradient(
                                colors: [Color(hex: "#4F8EF7"), Color(hex: "#A855F7")],
                                startPoint: .top,
                                endPoint:   .bottom
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(-90))
                    Keycap(label: "⌘", pressed: cmdPressed)
                }

                Text("+")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.secondary.opacity(cmdPressed ? 0.6 : 0.3))

                Keycap(label: "V", pressed: vPressed)

                MiniPickerChip(visible: step == .pickerShown)
            }
            .frame(height: 80)
        }
        .onAppear { loopToken.active = true; startLoop() }
        .onDisappear { loopToken.active = false }
    }

    private var cmdPressed: Bool {
        switch step {
        case .idle:        return false
        case .cmdDown, .vDown, .vUp, .ringFull, .pickerShown: return true
        }
    }

    private var vPressed: Bool {
        switch step {
        case .vDown: return true
        default:     return false
        }
    }

    private func startLoop() {
        guard loopToken.active else { return }
        var noAnim = Transaction(); noAnim.disablesAnimations = true
        withTransaction(noAnim) {
            step = .idle
            ringFill = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            withAnimation { step = .cmdDown }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            withAnimation { step = .vDown }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20) {
            withAnimation { step = .vUp }
            withAnimation(.linear(duration: ringDuration)) {
                ringFill = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20 + ringDuration + 0.05) {
            withAnimation { step = .pickerShown }
        }
        let total = 1.20 + ringDuration + 0.05 + 1.25
        DispatchQueue.main.asyncAfter(deadline: .now() + total) {
            guard loopToken.active else { return }
            startLoop()
        }
    }
}

private struct Keycap: View {
    let label: String
    let pressed: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 20, weight: .bold, design: .monospaced))
            .foregroundColor(pressed ? .white : .primary)
            .frame(width: 46, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(pressed
                          ? AnyShapeStyle(LinearGradient(
                                colors: [Color(hex: "#4F8EF7"), Color(hex: "#A855F7")],
                                startPoint: .topLeading,
                                endPoint:   .bottomTrailing))
                          : AnyShapeStyle(Color.primary.opacity(0.08)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(pressed ? Color(hex: "#A855F7") : Color.primary.opacity(0.22),
                            lineWidth: pressed ? 1.5 : 1)
            )
            .scaleEffect(pressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: pressed)
    }
}

private struct MiniPickerChip: View {
    let visible: Bool

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { idx in
                Capsule()
                    .fill(idx == 0
                          ? AnyShapeStyle(LinearGradient(
                                colors: [Color(hex: "#4F8EF7"), Color(hex: "#A855F7")],
                                startPoint: .leading,
                                endPoint:   .trailing))
                          : AnyShapeStyle(Color.primary.opacity(0.18)))
                    .frame(width: 38, height: 5)
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: "#A855F7").opacity(0.45), lineWidth: 1)
        )
        .opacity(visible ? 1.0 : 0.0)
        .scaleEffect(visible ? 1.0 : 0.85)
        .offset(x: visible ? 0 : 16)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: visible)
    }
}
