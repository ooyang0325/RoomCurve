import SwiftUI
import Charts
import RoomCurveKit

/// Drag points to shape a target curve, or edit the numbers directly.
struct CurveEditorView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var state: AppState

    @State private var curve: TargetCurve?
    @State private var original: TargetCurve?
    @State private var dragging: UUID?
    @State private var gestureStart: CGPoint?
    @State private var moved = false
    @State private var showSource = false
    @State private var showNew = false
    @State private var newName = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let range = (low: 20.0, high: 20_000.0)
    private let gainRange = -20.0...20.0

    var body: some View {
        VStack(spacing: 0) {
            editor
            footer
        }
        .navigationTitle("Curve Editor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(store.targetCurves) { candidate in
                        Button(candidate.name) { select(candidate) }
                    }
                    Divider()
                    Button("New curve…") { showNew = true }
                } label: {
                    Image(systemName: "list.bullet")
                }
            }
        }
        .sheet(isPresented: $showSource) {
            if let binding = Binding($curve) { CurveSourceView(curve: binding) }
        }
        .alert("New curve", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                curve = TargetCurve(name: newName.isEmpty ? "New curve" : newName, points: [
                    CurvePoint(frequency: 20, gainDB: 5),
                    CurvePoint(frequency: 1_000, gainDB: 0),
                    CurvePoint(frequency: 20_000, gainDB: -5)
                ])
                original = nil
            }
        }
        .onAppear { if curve == nil { select(state.targetCurve(from: store)) } }
    }

    // MARK: - Editor

    private var editor: some View {
        GeometryReader { geometry in
            ZStack {
                Chart {
                    if let curve {
                        ForEach(sampledPoints(curve), id: \.frequency) { point in
                            LineMark(x: .value("Frequency", point.frequency),
                                     y: .value("Gain", point.gain))
                            .foregroundStyle(.yellow)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.monotone)
                        }
                        ForEach(curve.points) { point in
                            PointMark(x: .value("Frequency", point.frequency),
                                      y: .value("Gain", point.gainDB))
                            .foregroundStyle(.yellow)
                            .symbolSize(dragging == point.id ? 200 : 90)
                        }
                    }
                }
                .chartXScale(domain: range.low...range.high, type: .log)
                .chartYScale(domain: gainRange)
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(.primary.opacity(0.1))
                        AxisValueLabel()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: [20, 50, 100, 200, 500, 1_000, 2_000, 5_000,
                                       10_000, 20_000]) { value in
                        AxisGridLine().foregroundStyle(.primary.opacity(0.1))
                        AxisValueLabel {
                            if let frequency = value.as(Double.self) {
                                Text(frequency >= 1_000 ? "\(Int(frequency / 1_000))k"
                                                        : "\(Int(frequency))")
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    overlay(proxy: proxy, geometry: geometry)
                }
            }
        }
        .padding(8)
    }

    /// One gesture handles moving, adding and removing, because they cannot be separate ones.
    ///
    /// A drag with no minimum distance claims every touch that lands on the plot — a tap is
    /// simply a drag that never moved — so any `onTapGesture` attached alongside it never
    /// fires. Rather than fight that, the decision is made on release: if the finger moved, it
    /// was a drag; if it did not, it was a tap, and what it landed on decides between adding
    /// and removing.
    ///
    /// Removing is a tap on an existing point rather than HouseCurve's double tap. Detecting a
    /// double tap means holding every single tap for the length of the double-tap window before
    /// acting on it, and adding a point is common while removing one is rare. Not worth
    /// delaying the common case for.
    private func overlay(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let plotFrame = proxy.plotFrame, var curve else { return }
                        let point = local(value.location, plotFrame, geometry)

                        // Grab on touch-down so the point reacts before the finger moves.
                        if gestureStart == nil {
                            gestureStart = point
                            dragging = nearestPoint(to: point, proxy: proxy, curve: curve)
                        }
                        if hypot(value.translation.width, value.translation.height) > 8 {
                            moved = true
                        }

                        // Hold still until it is definitely a drag, so a tap cannot nudge a
                        // point by a pixel on its way to being a tap.
                        guard moved, let dragging,
                              let index = curve.points.firstIndex(where: { $0.id == dragging }),
                              let frequency: Double = proxy.value(atX: point.x),
                              let gain: Double = proxy.value(atY: point.y) else { return }

                        curve.points[index].frequency =
                            frequency.clamped(to: range.low...range.high)
                        curve.points[index].gainDB = gain.clamped(to: gainRange)
                        curve.points.sort { $0.frequency < $1.frequency }
                        self.curve = curve
                    }
                    .onEnded { value in
                        defer {
                            gestureStart = nil
                            moved = false
                            withAnimation(reduceMotion ? nil
                                          : .spring(duration: 0.3, bounce: 0.2)) {
                                dragging = nil
                            }
                        }
                        guard !moved, let plotFrame = proxy.plotFrame else { return }
                        tap(at: local(value.location, plotFrame, geometry), proxy: proxy)
                    }
            )
    }

    private func local(_ location: CGPoint, _ plotFrame: Anchor<CGRect>,
                       _ geometry: GeometryProxy) -> CGPoint {
        let origin = geometry[plotFrame].origin
        return CGPoint(x: location.x - origin.x, y: location.y - origin.y)
    }

    /// A tap on a point removes it; a tap anywhere else adds one.
    private func tap(at point: CGPoint, proxy: ChartProxy) {
        guard var curve else { return }

        if let id = nearestPoint(to: point, proxy: proxy, curve: curve) {
            guard curve.points.count > 2 else { return }
            curve.points.removeAll { $0.id == id }
        } else {
            guard curve.points.count < 20,
                  let frequency: Double = proxy.value(atX: point.x),
                  let gain: Double = proxy.value(atY: point.y) else { return }
            curve.points.append(
                CurvePoint(frequency: frequency.clamped(to: range.low...range.high),
                           gainDB: gain.clamped(to: gainRange)))
            curve.points.sort { $0.frequency < $1.frequency }
        }

        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)) {
            self.curve = curve
        }
    }

    private func nearestPoint(to location: CGPoint, proxy: ChartProxy,
                              curve: TargetCurve) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?
        for point in curve.points {
            guard let x = proxy.position(forX: point.frequency),
                  let y = proxy.position(forY: point.gainDB) else { continue }
            let distance = hypot(x - location.x, y - location.y)
            if distance < 44, best == nil || distance < best!.distance {
                best = (point.id, distance)
            }
        }
        return best?.id
    }

    private func sampledPoints(_ curve: TargetCurve) -> [(frequency: Double, gain: Double)] {
        let sampled = curve.sampled(on: state.grid)
        return (0..<state.grid.count).map { (state.grid.frequencies[$0], sampled[$0]) }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Text(curve.map { "\($0.name)\($0.isBuiltIn ? " · built in" : "")"
                             + (hasChanges ? " · edited" : "") } ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 22) {
                Button {
                    if let original { curve = original }
                } label: {
                    Image(systemName: "arrow.uturn.backward").font(.title3)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!hasChanges)

                Button { showSource = true } label: {
                    Image(systemName: "text.alignleft").font(.title3)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(curve == nil)

                Button { save() } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(curve == nil)
            }

            Text("Drag a point to move it. Tap a point to remove it, tap anywhere else to add one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var hasChanges: Bool {
        guard let curve, let original else { return curve != nil && original == nil }
        return curve.points != original.points
    }

    private func select(_ candidate: TargetCurve) {
        curve = candidate
        original = candidate
    }

    private func save() {
        guard var curve else { return }
        // Curves that ship with the app are read only; editing one saves a copy.
        if curve.isBuiltIn {
            curve = TargetCurve(name: curve.name + " (edited)", points: curve.points)
        }
        do {
            try store.save(curve)
            state.selectedTargetName = curve.name
            self.curve = curve
            original = curve
            state.show("Saved \(curve.name)")
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }
}

/// The curve as text, for pasting values in from elsewhere.
struct CurveSourceView: View {
    @Binding var curve: TargetCurve
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .navigationTitle("Curve Source")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") { apply() }
                    }
                }
                .onAppear { text = curve.serialised() }
                .alert("Could not read that", isPresented: $invalid) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Each line needs a frequency and a gain, for example \"100  -3.5\". "
                         + "Lines starting with anything else are treated as comments.")
                }
        }
    }

    private func apply() {
        guard let parsed = TargetCurve.parse(text, name: curve.name) else {
            invalid = true
            return
        }
        curve.points = parsed.points
        dismiss()
    }
}
