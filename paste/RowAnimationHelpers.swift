import SwiftUI

func runDeniedShake(_ offsetX: Binding<CGFloat>) {
    let step: TimeInterval = 0.045
    let amounts: [CGFloat] = [8, -8, 6, -6, 3, -3, 0]
    for (i, amount) in amounts.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) {
            withAnimation(.easeInOut(duration: step)) { offsetX.wrappedValue = amount }
        }
    }
}

private enum AnalysisPulseClock {
    static let referenceDate = Date()
}

func startOrStopAnalysisPulse<F: BinaryFloatingPoint>(_ value: Binding<F>,
                                                       active: Bool,
                                                       restValue: F,
                                                       activeValue: F,
                                                       activeDuration: Double,
                                                       restDuration: Double,
                                                       resumeMidCycle: Bool = false) {
    guard active else {
        withAnimation(.easeOut(duration: restDuration)) { value.wrappedValue = restValue }
        return
    }
    if resumeMidCycle {

        let elapsed = Date().timeIntervalSince(AnalysisPulseClock.referenceDate)
        let cycleLength = activeDuration * 2
        let posInCycle = elapsed.truncatingRemainder(dividingBy: cycleLength) / activeDuration
        let phase = posInCycle <= 1 ? posInCycle : 2 - posInCycle
        value.wrappedValue = restValue + (activeValue - restValue) * F(phase)
    } else {
        value.wrappedValue = restValue
    }
    withAnimation(.easeInOut(duration: activeDuration).repeatForever(autoreverses: true)) {
        value.wrappedValue = activeValue
    }
}
