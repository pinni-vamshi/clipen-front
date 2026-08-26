import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct LabKeyCapView: View {
    let key: LabKey
    let pressed: Bool
    var size: CGFloat = 44

    /// "HOLD" / "TAP" — shown under the cap only while `pressed`, same
    /// treatment as the website's How It Works demo. Reserves its height
    /// unconditionally (rather than only while pressed) so toggling it on
    /// and off never shifts anything else in the stack around it. Nil for
    /// callers that don't have a fixed hold-vs-tap role to report (e.g.
    /// the per-demo special-key row, whose role varies by demo).
    var roleLabel: String? = nil

    var body: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(pressed ? Color.accent : Color.surfaceHi)
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(Color.border, lineWidth: 1))
                .frame(width: key.isWide ? size * 2.2 : size, height: size)
                .shadow(color: .black.opacity(pressed ? 0 : 0.45), radius: 0, y: pressed ? 0 : 4)
                .overlay(
                    Text(key.symbol)
                        .font(.system(size: key.isWide ? size * 0.26 : size * 0.42, weight: .semibold))
                        .foregroundColor(pressed ? .white : .textPri)
                )
                .offset(y: pressed ? 4 : 0)

            if let roleLabel {
                Text(roleLabel.uppercased())
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(1.4)
                    .foregroundColor(.accent)
                    .opacity(pressed ? 1 : 0)
                    .offset(y: pressed ? 0 : -3)
                    .animation(.easeOut(duration: 0.2), value: pressed)
            }
        }
    }
}

private struct LabMockPanel: View {
    @ObservedObject var lab: InteractionLabController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 9))
                if lab.searchActive {
                    Text("Type to search")
                        .font(.system(size: 9))
                    Rectangle().fill(Color.textPri).frame(width: 1, height: 10)
                        .opacity(0.9)
                } else {
                    Text("Press F to search").font(.system(size: 9))
                }
                Spacer()
            }
            .foregroundColor(lab.searchActive ? .textPri : .textDim)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(lab.searchActive ? Color.accent.opacity(0.10) : Color.clear)

            Divider().background(Color.border)

            HStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { i in
                    Text(["Recents", "Image"][i])
                        .font(.system(size: 8, weight: lab.activeTab == i ? .bold : .regular))
                        .foregroundColor(lab.activeTab == i ? .white : .textDim)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(lab.activeTab == i ? Color.accent : Color.surfaceHi,
                                    in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            Divider().background(Color.border)

            VStack(spacing: 3) {
                ForEach(Array(lab.items.enumerated()), id: \.element.id) { idx, item in
                    HStack {
                        Text(item.title)
                            .font(.system(size: 10, weight: idx == lab.selectedIndex ? .semibold : .regular))
                            .foregroundColor(idx == lab.selectedIndex ? .white : .textSec)
                        Spacer()
                        if item.pin {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 15, height: 15)
                                .background(Color.blue, in: Circle())
                        }
                        if let mark = item.mark {
                            Text("\(mark)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Color.green, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(idx == lab.selectedIndex ? Color.accent : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(5)

            Spacer(minLength: 0)
        }
        .frame(width: 190, height: 158)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.border, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if lab.showCloseButton {
                Text("✕")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.accent, in: Circle())
                    .offset(x: -8, y: -8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}

private struct LabSidePanel: View {
    @ObservedObject var lab: InteractionLabController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if lab.previewVisible {
                Text("Preview").font(.system(size: 10, weight: .bold)).foregroundColor(.textPri)
                Text("Full text content of the selected item.")
                    .font(.system(size: 9)).foregroundColor(.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if lab.similarVisible {
                Text("Similar items").font(.system(size: 10, weight: .bold)).foregroundColor(.textPri)
                ForEach(Array(lab.similarLabels.enumerated()), id: \.offset) { idx, label in
                    Text(label)
                        .font(.system(size: 9, weight: lab.activeSimilar == idx ? .semibold : .regular))
                        .foregroundColor(lab.activeSimilar == idx ? .white : .textDim)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(lab.activeSimilar == idx ? Color.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer(minLength: 0)
            } else {
                ForEach(Array(lab.transformLabels.enumerated()), id: \.offset) { idx, label in
                    Text(label)
                        .font(.system(size: 9, weight: lab.activeTransform == idx ? .semibold : .regular))
                        .foregroundColor(lab.activeTransform == idx ? .white : .textDim)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(lab.activeTransform == idx ? Color.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(width: 120, height: 158, alignment: .topLeading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
}

struct InteractionLabStage: View {
    @ObservedObject var lab: InteractionLabController

    var showKeyRow: Bool = true

    /// Keys beyond the opening ⌘+V pair, specific to the selected demo —
    /// rendered as special buttons below the pair instead of in one long
    /// row of everything at once. This is a display-only grouping; every
    /// `run*` choreography in InteractionLabController already presses
    /// ⌘ then taps V first, before anything demo-specific happens, so
    /// splitting the pair out from the rest doesn't touch that logic —
    /// it just draws the same live `pressedKeys` state in two places.
    /// HOLD vs TAP for the ⌘V pair that opens the popup. Every demo opens
    /// it with a tap except `.pinnedOpen`, whose entire subject is holding V
    /// *through* the open so the popup stays pinned — this pair used to be
    /// hardcoded "Tap", which contradicted that demo's own caption ("HOLD V
    /// on the very first press") and its `keyLabel` ("⌘ + hold V").
    private var openingVRole: String {
        lab.selectedDemo == .pinnedOpen ? "Hold" : "Tap"
    }

    /// HOLD vs TAP for the per-demo key(s) under the popup, which carried no
    /// role label at all before.
    ///
    /// Mirrors `InteractionDemo.keyLabel` — the user-facing wording of the
    /// same gesture — and both agree with the event tap: a key released
    /// before its hold threshold runs the tap action (cycleNext,
    /// cycleTransform, cyclePinnedItems, cyclePrevious…), while crossing the
    /// threshold runs the hold action (mark for multi-paste, pin). The three
    /// hold cases below are exactly the ones whose keyLabel says "hold".
    private func specialRole(for key: LabKey) -> String {
        switch lab.selectedDemo {
        // "hold V" / "hold V → G" — V marks, G then groups on a plain tap.
        case .multiPaste, .group:  return key == .v ? "Hold" : "Tap"
        // "hold P" — a tap on P cycles pinned items instead of pinning one.
        case .pinItem:             return "Hold"
        // "⇧ + tap V" — shift is the held modifier, V is still tapped.
        case .reverseCycle:        return key == .shift ? "Hold" : "Tap"
        default:                   return "Tap"
        }
    }

    private var specialKeys: [LabKey] {
        switch lab.selectedDemo {
        case .cycle, .pinnedOpen, .pasteOne, .pasteTwo, .pasteThree:
            return []
        case .multiPaste:
            return [.v]
        case .reverseCycle:
            return ClipboardManager.shared.reverseCycleUsesB ? [.b] : [.shift, .v]
        case .cyclePinned, .pinItem:
            return [.p]
        case .spacePreview, .pinPreview:
            return [.space]
        case .group:
            return [.v, .g]
        case .search:
            return [.f]
        case .nextCategory:
            return [.grave]
        case .transform:
            return [.x]
        case .similar:
            return [.r]
        case .moveToFront:
            return [.c]
        case .delete:
            return [.backspace]
        case .collections:
            return [.two, .one]
        }
    }

    @ViewBuilder
    private var popupRow: some View {
        HStack(spacing: 14) {
            LabMockPanel(lab: lab)
                .opacity(lab.panelVisible ? 1 : 0)
            if lab.previewVisible || lab.transformVisible || lab.similarVisible {
                LabSidePanel(lab: lab)
            }
        }
        .animation(.easeOut(duration: 0.25), value: lab.previewVisible || lab.transformVisible || lab.similarVisible)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(lab.instruction ?? LocalizedStringKey(" "))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.white.opacity(0.16), in: Capsule())
                .opacity(lab.instruction == nil ? 0 : 1)
                .frame(height: 20)

            if showKeyRow {
                // ⌘+V beside the popup, not above or below it — this pair
                // is what opens the popup in every demo, so it's fixed and
                // demo-independent, not derived from lab.stageKeys (whose
                // order/contents vary per demo and used to be dumped into
                // one flat row below instead).
                HStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 8) {
                        LabKeyCapView(key: .cmd, pressed: lab.pressedKeys.contains(.cmd), size: 54, roleLabel: "Hold")
                        LabKeyCapView(key: .v, pressed: lab.pressedKeys.contains(.v), size: 54, roleLabel: openingVRole)
                    }
                    popupRow
                }
                .frame(minHeight: 190)
            } else {
                // Real-keyboard mode: the physical keyboard illustration
                // shows which keys to press, so the popup stands alone
                // here instead of duplicating a ⌘V pair beside it.
                popupRow
                    .frame(minHeight: 190)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Text(lab.resultText.map { "→ \($0)" } ?? " ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.green)
                .opacity(lab.resultText == nil ? 0 : 1)
                .frame(height: 16)

            Text(LocalizedStringKey(lab.currentCaption))
                .font(.system(size: 11))
                .foregroundColor(.textSec)
                .multilineTextAlignment(.center)
                .frame(height: 30)

            if showKeyRow {
                VStack(spacing: 8) {
                    if lab.selectedDemo == .pinnedOpen {
                        // No keycap, no animation — this only matters at
                        // the moment the popup opens, on the very first
                        // press, so there's nothing to loop or highlight.
                        Text("V held during opening")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.textDim)
                            .frame(height: 58)
                    } else if !specialKeys.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(Array(specialKeys.enumerated()), id: \.offset) { _, key in
                                // V shows up here for multiPaste/group/reverseCycle
                                // — reads specialVPressed, a state kept completely
                                // separate from the top pair's V, so a hold or a
                                // repeated tap down here doesn't also light up the
                                // opening pair above it.
                                LabKeyCapView(key: key,
                                              pressed: key == .v ? lab.specialVPressed : lab.pressedKeys.contains(key),
                                              size: 54,
                                              roleLabel: specialRole(for: key))
                            }
                        }
                        .frame(height: 58)
                    }

                    ZStack {
                        if lab.pasteTapTarget > 0 {
                            HStack(spacing: 7) {
                                Text("V").font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.textDim)
                                ForEach(0..<lab.pasteTapTarget, id: \.self) { i in
                                    Circle()
                                        .fill(i < lab.pasteTapDone ? Color.accent : Color.textDim.opacity(0.3))
                                        .frame(width: 8, height: 8)
                                        .scaleEffect(i == lab.pasteTapDone - 1 ? 1.4 : 1)
                                        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: lab.pasteTapDone)
                                }
                                Text("×\(lab.pasteTapTarget)").font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.accent)
                            }
                        }
                    }
                    .frame(height: 20)
                }
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .task {

            guard !lab.isPlaying else { return }
            lab.play()
        }
    }
}

extension View {
    func measured<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { geo in
            Color.clear.preference(key: key, value: geo.size.height)
        })
    }

    func measuredWidth<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { geo in
            Color.clear.preference(key: key, value: geo.size.width)
        })
    }
}
