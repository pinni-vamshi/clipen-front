import AppKit
import SwiftUI

/// One-shot educational panel surfaced the first time the user lands on the
/// fast-paste path (released ⌘ inside `firstOpenDelay`).  Branded SwiftUI
/// chrome with a single looping animation that demonstrates the gesture +
/// timer threshold — the threshold visually fills at the user's actual
/// slider speed so they feel their own setting.
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

    /// Show the panel centered on the active screen.
    /// - Parameters:
    ///   - delayMs: the current `firstOpenDelay` in ms.  Used to time the
    ///     progress ring inside the animation, so the demo feels exactly
    ///     as snappy (or slow) as the user's own slider setting.
    ///   - onAdjust: invoked when the user picks "Adjust timer".  The
    ///     handler should open the main window and pulse the slider card.
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
        // Tear down the hosted SwiftUI tree once hidden so its self-rescheduling
        // demo animation stops (fires onDisappear) instead of looping forever
        // behind the invisible panel. Deferred so the view isn't freed while a
        // button action inside it is still executing.
        DispatchQueue.main.async { [weak self] in
            if self?.isVisible == false { self?.contentView = nil }
        }
    }
}

// MARK: - Outer container

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

            // One short explanation underneath — labels what the loop is
            // showing.  Calls out the bit that's easy to miss: ⌘ stays held
            // while the timer runs.
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

// MARK: - The single animated demo
//
// One continuous loop of the real gesture:
//
//   1. ⌘ depresses
//   2. V depresses (the ⌘V paste)
//   3. V releases — ⌘ stays held
//   4. A circular progress ring around ⌘ starts filling.
//      Its fill duration == max(delayMs, 350 ms) so the user sees their
//      OWN slider value play out at real speed.
//   5. Ring completes → a small "Clipen" picker chip pops in beside the keys.
//   6. Hold for a beat, then reset and loop.
//
// One uninterrupted motion — no captions changing mid-flight, no numbered
// steps, no "phase 1 of 4".  The animation tells the whole story.
struct AnimatedGestureDemo: View {
    let delayMs: Int

    // Phase state machine, but only used to schedule frames — the user
    // sees a single continuous motion, not labeled steps.
    @State private var step: Step = .idle
    /// Driven independently from `step` so the trim can be animated with
    /// an EXPLICIT `.linear(duration: ringDuration)` animation — exactly
    /// matching the user's slider value.
    @State private var ringFill: CGFloat = 0

    /// Reference-type liveness flag. The choreography reschedules itself via
    /// escaping `asyncAfter` closures forever; without this they keep firing
    /// after the panel is dismissed (the SwiftUI tree isn't torn down on
    /// `orderOut`). A class lets those already-captured closures observe the
    /// live value — a captured `Bool` would freeze at its closure-creation value.
    private final class LoopToken { var active = true }
    @State private var loopToken = LoopToken()

    private enum Step { case idle, cmdDown, vDown, vUp, ringFull, pickerShown }

    /// The ring's visible fill duration.  We clamp to a minimum 0.35 s so
    /// extremely small delay values (e.g. 30 ms) are still perceptible —
    /// otherwise the ring would snap straight to full and the user
    /// wouldn't see the "timer" beat that's the whole point.
    private var ringDuration: TimeInterval {
        max(0.35, TimeInterval(delayMs) / 1000.0)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                // ⌘ keycap wrapped in the progress ring.  Ring is drawn as
                // a thick outer circle that trims from 0 → 1 during the
                // hold beat.
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

                // Picker chip — slides in from the right once the ring fills.
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
        // Reset to known idle state.  Ring fill resets WITHOUT animation
        // so the next loop starts clean (no rewind line).
        var noAnim = Transaction(); noAnim.disablesAnimations = true
        withTransaction(noAnim) {
            step = .idle
            ringFill = 0
        }

        // Choreography.
        //   t = 0.50  ⌘ depresses
        //   t = 0.85  V depresses
        //   t = 1.20  V releases; ring begins linear fill
        //   t = 1.20 + ringDuration  ring hits 1.0
        //   t = ... + 0.10  picker chip slides in
        //   t = ... + 1.30  loop restarts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            withAnimation { step = .cmdDown }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            withAnimation { step = .vDown }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20) {
            withAnimation { step = .vUp }
            // Start the ring's linear fill at the user's actual rate.
            withAnimation(.linear(duration: ringDuration)) {
                ringFill = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20 + ringDuration + 0.05) {
            withAnimation { step = .pickerShown }
        }
        // Hold the picker on screen, then loop.
        let total = 1.20 + ringDuration + 0.05 + 1.25
        DispatchQueue.main.asyncAfter(deadline: .now() + total) {
            guard loopToken.active else { return }
            startLoop()
        }
    }
}

// MARK: - Keycap

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

// MARK: - Mini picker chip

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
