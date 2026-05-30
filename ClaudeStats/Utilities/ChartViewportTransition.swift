import SwiftUI
import Charts

enum STXChartViewportMotion {
    static let duration: TimeInterval = 0.34
    static let animation: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: duration)
}

struct STXDateChartViewport: Equatable, Sendable {
    let xStart: Date
    let xEnd: Date
    let yStart: Double
    let yEnd: Double

    var xDuration: TimeInterval {
        xEnd.timeIntervalSinceReferenceDate - xStart.timeIntervalSinceReferenceDate
    }

    init(xStart: Date, xEnd: Date, yStart: Double = 0, yEnd: Double) {
        let orderedXStart = min(xStart, xEnd)
        let orderedXEnd = max(xStart, xEnd)
        let safeYStart = yStart.isFinite ? yStart : 0
        let safeYEnd = yEnd.isFinite ? yEnd : safeYStart + 1

        self.xStart = orderedXStart
        self.xEnd = orderedXEnd > orderedXStart ? orderedXEnd : orderedXStart.addingTimeInterval(1)
        self.yStart = safeYStart
        self.yEnd = max(safeYStart + 1, safeYEnd)
    }
}

extension Animation {
    static let stxChartViewportChange: Animation = STXChartViewportMotion.animation
}

extension View {
    func stxDateChartViewportTransition<Value: Equatable>(
        _ viewport: STXDateChartViewport,
        value: Value
    ) -> some View {
        modifier(STXDateChartViewportModifier(viewport: viewport))
            .animation(.stxChartViewportChange, value: value)
    }
}

private struct STXDateChartViewportModifier: @MainActor AnimatableModifier {
    var xStart: TimeInterval
    var xEnd: TimeInterval
    var yStart: Double
    var yEnd: Double

    init(viewport: STXDateChartViewport) {
        self.xStart = viewport.xStart.timeIntervalSinceReferenceDate
        self.xEnd = viewport.xEnd.timeIntervalSinceReferenceDate
        self.yStart = viewport.yStart
        self.yEnd = viewport.yEnd
    }

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get {
            AnimatablePair(
                AnimatablePair(xStart, xEnd),
                AnimatablePair(yStart, yEnd)
            )
        }
        set {
            xStart = newValue.first.first
            xEnd = newValue.first.second
            yStart = newValue.second.first
            yEnd = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let safeXStart = min(xStart, xEnd)
        let safeXEnd = max(xStart, xEnd, safeXStart + 1)
        let safeYStart = yStart.isFinite ? yStart : 0
        let safeYEnd = max(safeYStart + 1, yEnd.isFinite ? yEnd : safeYStart + 1)
        let xStartDate = Date(timeIntervalSinceReferenceDate: safeXStart)
        let xEndDate = Date(timeIntervalSinceReferenceDate: safeXEnd)

        content
            .chartXScale(domain: xStartDate...xEndDate)
            .chartYScale(domain: safeYStart...safeYEnd)
    }
}
