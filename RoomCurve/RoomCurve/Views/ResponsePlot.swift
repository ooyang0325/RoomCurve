import SwiftUI
import Charts
import RoomCurveKit

/// One trace on the plot.
struct PlotSeries: Identifiable {
    let id: String
    let values: [Double]
    var color: Color
    var lineWidth: Double = 2
    /// Frequencies to leave out — where the measurement had too little signal to mean anything.
    var blanked: [Bool]?
    var dashed = false
    /// Shaded tolerance band either side, in the plot's units.
    var band: Double?
    var opacity: Double = 1

    /// Split into runs of consecutive visible points, so blanked regions become real gaps in
    /// the line rather than a straight line drawn across missing data.
    func segments(grid: LogGrid) -> [[(frequency: Double, value: Double)]] {
        var result: [[(Double, Double)]] = []
        var current: [(Double, Double)] = []
        for i in 0..<Swift.min(values.count, grid.count) {
            let hidden = blanked?[i] ?? false
            if hidden || !values[i].isFinite {
                if current.count > 1 { result.append(current) }
                current = []
            } else {
                current.append((grid.frequencies[i], values[i]))
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }
}

/// The measurement plot: log frequency across, with pinch to zoom, drag to pan, and a cursor.
struct ResponsePlot: View {
    let series: [PlotSeries]
    let kind: PlotKind
    let grid: LogGrid

    @Binding var lowFrequency: Double
    @Binding var highFrequency: Double

    @State private var cursorFrequency: Double?
    @State private var zoomAnchor: (low: Double, high: Double)?
    @State private var panAnchor: (low: Double, high: Double)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let limit = (low: 15.0, high: 24_000.0)

    var body: some View {
        Chart {
            ForEach(series) { item in
                if let band = item.band {
                    ForEach(Array(item.segments(grid: grid).enumerated()), id: \.offset) { _, run in
                        ForEach(run, id: \.frequency) { point in
                            AreaMark(x: .value("Frequency", point.frequency),
                                     yStart: .value("Low", point.value - band),
                                     yEnd: .value("High", point.value + band))
                            .foregroundStyle(item.color.opacity(0.12))
                        }
                    }
                }
                ForEach(Array(item.segments(grid: grid).enumerated()), id: \.offset) { index, run in
                    ForEach(run, id: \.frequency) { point in
                        LineMark(x: .value("Frequency", point.frequency),
                                 y: .value(kind.unit, point.value),
                                 series: .value("s", "\(item.id)-\(index)"))
                        .foregroundStyle(item.color.opacity(item.opacity))
                        .lineStyle(StrokeStyle(lineWidth: item.lineWidth,
                                               lineCap: .round, lineJoin: .round,
                                               dash: item.dashed ? [4, 4] : []))
                        .interpolationMethod(.monotone)
                    }
                }
            }

            if let cursorFrequency {
                RuleMark(x: .value("Cursor", cursorFrequency))
                    .foregroundStyle(.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: lowFrequency...highFrequency, type: .log)
        .chartYScale(domain: yDomain)
        .chartXAxis { axisMarks }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel()
            }
        }
        .chartPlotStyle { $0.background(Color.primary.opacity(0.02)) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(cursorOrPanGesture(proxy: proxy, geometry: geometry))
                    .gesture(zoomGesture)
                    .onTapGesture { toggleCursor(proxy: proxy, geometry: geometry) }
            }
        }
        .overlay(alignment: .topLeading) { cursorReadout }
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: lowFrequency)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: highFrequency)
    }

    private var axisMarks: some AxisContent {
        AxisMarks(values: [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]) { value in
            AxisGridLine().foregroundStyle(.primary.opacity(0.10))
            AxisValueLabel {
                if let frequency = value.as(Double.self) {
                    Text(frequency >= 1_000
                         ? "\(Int(frequency / 1_000))k"
                         : "\(Int(frequency))")
                }
            }
        }
    }

    /// Fit the vertical axis to what is actually on screen.
    ///
    /// A fixed axis wastes most of the plot: an absolute level sits somewhere around 75 dB but
    /// the detail worth seeing spans maybe 30 dB around it. Only the visible frequency range
    /// counts, so zooming into a region also rescales the level — which is the behaviour that
    /// makes it possible to read a couple of dB of ripple.
    private var yDomain: ClosedRange<Double> {
        if kind == .phase { return -180...180 }

        let visible = grid.indices(from: lowFrequency, to: highFrequency)
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude

        for item in series where item.band == nil {
            for i in visible where i < item.values.count {
                if item.blanked?[i] ?? false { continue }
                let value = item.values[i]
                guard value.isFinite else { continue }
                low = Swift.min(low, value)
                high = Swift.max(high, value)
            }
        }
        guard low < high else { return kind == .groupDelay ? -5...25 : -30...10 }

        let padding = Swift.max((high - low) * 0.12, kind == .groupDelay ? 1 : 3)
        return (low - padding)...(high + padding)
    }

    // MARK: - Cursor

    @ViewBuilder
    private var cursorReadout: some View {
        if let cursorFrequency {
            let index = Int(grid.index(of: cursorFrequency).rounded())
                .clamped(to: 0...(grid.count - 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(format(frequency: cursorFrequency))
                    .font(.caption.weight(.semibold))
                ForEach(series.filter { $0.band == nil }) { item in
                    if index < item.values.count, !(item.blanked?[index] ?? false) {
                        Text(String(format: "%.1f %@", item.values[index], kind.unit))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(item.color)
                    }
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
            .transition(.opacity)
        }
    }

    private func format(frequency: Double) -> String {
        frequency >= 1_000
            ? String(format: "%.2f kHz", frequency / 1_000)
            : String(format: "%.0f Hz", frequency)
    }

    private func toggleCursor(proxy: ChartProxy, geometry: GeometryProxy) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0)) {
            cursorFrequency = cursorFrequency == nil ? sqrt(lowFrequency * highFrequency) : nil
        }
    }

    // MARK: - Gestures

    /// One finger moves the cursor when it is showing, and pans the plot when it is not.
    ///
    /// Feedback is continuous rather than applied on release: the cursor and the frequency
    /// axis follow the finger the whole way, which is what makes the plot feel like a thing
    /// being handled rather than a control being operated.
    private func cursorOrPanGesture(proxy: ChartProxy, geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let plotFrame = proxy.plotFrame else { return }
                let origin = geometry[plotFrame].origin

                if cursorFrequency != nil {
                    let x = value.location.x - origin.x
                    if let frequency: Double = proxy.value(atX: x) {
                        cursorFrequency = frequency.clamped(to: lowFrequency...highFrequency)
                    }
                    return
                }

                if panAnchor == nil { panAnchor = (lowFrequency, highFrequency) }
                guard let anchor = panAnchor else { return }
                let width = geometry[plotFrame].width
                guard width > 0 else { return }
                // Pan by whole octaves so the movement matches the finger on a log axis.
                let octaves = log2(anchor.high / anchor.low)
                let shift = -Double(value.translation.width) / width * octaves
                setDomain(low: anchor.low * exp2(shift), high: anchor.high * exp2(shift),
                          resisting: true)
            }
            .onEnded { _ in
                panAnchor = nil
                settle()
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomAnchor == nil { zoomAnchor = (lowFrequency, highFrequency) }
                guard let anchor = zoomAnchor else { return }
                let centre = sqrt(anchor.low * anchor.high)
                let octaves = log2(anchor.high / anchor.low) / max(value.magnification, 0.1)
                setDomain(low: centre / exp2(octaves / 2), high: centre * exp2(octaves / 2),
                          resisting: true)
            }
            .onEnded { _ in
                zoomAnchor = nil
                settle()
            }
    }

    /// Update the visible range, resisting rather than stopping dead at the ends.
    ///
    /// A hard stop reads as the plot having frozen. Progressive resistance reads as the plot
    /// still responding while telling you there is nothing further out there.
    private func setDomain(low: Double, high: Double, resisting: Bool) {
        var newLow = low, newHigh = high
        if resisting {
            if newLow < limit.low { newLow = limit.low * pow(newLow / limit.low, 0.35) }
            if newHigh > limit.high { newHigh = limit.high * pow(newHigh / limit.high, 0.35) }
        }
        guard newHigh / newLow > 1.05 else { return }
        lowFrequency = newLow
        highFrequency = newHigh
    }

    /// Spring back inside the bounds once the finger lifts.
    private func settle() {
        var low = lowFrequency, high = highFrequency
        low = Swift.max(low, limit.low)
        high = Swift.min(high, limit.high)
        if high / low < 1.2 { high = low * 1.2 }
        guard low != lowFrequency || high != highFrequency else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15)) {
            lowFrequency = low
            highFrequency = high
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
