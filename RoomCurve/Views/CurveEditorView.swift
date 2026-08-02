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
    @State private var pendingTap: PendingTap?
    @State private var showSource = false
    @State private var showNew = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isShort: Bool { verticalSizeClass == .compact }

    /// A tap waiting to see whether a second one follows it.
    private struct PendingTap {
        let id = UUID()
        let location: CGPoint
    }

    private let range = (low: 20.0, high: 20_000.0)
    private let gainRange = -20.0...20.0

    var body: some View {
        Group {
            if isShort {
                editor
                    .padding(.trailing, 68)
                    .overlay(alignment: .trailing) { controls.padding(.trailing, 16) }
            } else {
                VStack(spacing: 0) {
                    editor
                    footer
                }
            }
        }
        // Landscape has no room for the footer, and which curve you are editing is not
        // something to lose; it moves into the title instead.
        .navigationTitle(isShort ? (curve.map { "\($0.name)\(hasChanges ? " · edited" : "")" }
                                    ?? "Curve Editor")
                                 : "Curve Editor")
        .navigationBarTitleDisplayMode(.inline)
        // Hiding the system button also disables the edge swipe, which would otherwise be a
        // way to leave that skips the warning entirely.
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button { confirmDiscard = true } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("Back")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(store.targetCurves) { candidate in
                        Button(candidate.name) { select(candidate) }
                    }
                    Divider()
                    Button("New curve…") { showNew = true }
                    if let curve, !curve.isBuiltIn {
                        Button("Delete \"\(curve.name)\"", role: .destructive) {
                            confirmDelete = true
                        }
                    }
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
        .confirmationDialog("You have unsaved changes", isPresented: $confirmDiscard,
                            titleVisibility: .visible) {
            Button("Save and close") { save(); dismiss() }
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("\(curve?.name ?? "This curve") has been edited but not saved.")
        }
        .confirmationDialog("Delete this curve?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(curve?.name ?? "") will be removed. Curves that ship with the app cannot "
                 + "be deleted.")
        }
        .onAppear {
            if curve == nil { select(state.targetCurve(named: state.eqTargetName, from: store)) }
        }
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
                .chartXScale(domain: (range.low * 0.9)...(range.high * 1.1), type: .log)
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
                                .fixedSize()
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    overlay(proxy: proxy, geometry: geometry)
                }
                .overlay(alignment: .topLeading) { readout }
            }
        }
        .padding(8)
    }

    /// One gesture handles moving, adding and removing, because they cannot be separate ones.
    ///
    /// A drag with no minimum distance claims every touch that lands on the plot — a tap is
    /// simply a drag that never moved — so any `onTapGesture` attached alongside it never
    /// fires. Rather than fight that, the decision is made on release: if the finger moved, it
    /// was a drag; if it did not, it was a tap, and the tap counting happens here too.
    /// Frequency and gain of the point currently under the finger.
    ///
    /// Pinned to a corner rather than floating beside the point: a label that follows the
    /// finger is the label most likely to be underneath it, and near the edges of the plot it
    /// would have to dodge the boundary as well.
    ///
    /// The value shown is the point's own, as it will be written to the curve file — not where
    /// the curve happens to be sitting on a measurement after fitting.
    @ViewBuilder
    private var readout: some View {
        if let dragging, let point = curve?.points.first(where: { $0.id == dragging }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(point.frequency >= 1_000
                     ? String(format: "%.2f kHz", point.frequency / 1_000)
                     : String(format: "%.0f Hz", point.frequency))
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(String(format: "%+.1f dB", point.gainDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(10)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func overlay(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let plotFrame = proxy.plotFrame, var curve else { return }
                        let point = local(value.location, plotFrame, geometry)

                        // The leading edge belongs to the back swipe, not to the editor.
                        if gestureStart == nil && point.x < backSwipeEdge { return }

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
                        tapped(at: local(value.location, plotFrame, geometry), proxy: proxy)
                    }
            )
    }

    private func local(_ location: CGPoint, _ plotFrame: Anchor<CGRect>,
                       _ geometry: GeometryProxy) -> CGPoint {
        let origin = geometry[plotFrame].origin
        return CGPoint(x: location.x - origin.x, y: location.y - origin.y)
    }

    /// Single tap adds a point, double tap on a point removes it.
    ///
    /// Telling those apart costs a delay: the first tap cannot be acted on until the window for
    /// a second one has passed, or every double tap would add a stray point before removing
    /// anything. The delay lands only on adding — dragging is untouched, and the removal fires
    /// immediately on the second tap.
    ///
    /// A single tap that lands on an existing point does nothing. It would otherwise drop a
    /// duplicate exactly on top of the point you were aiming at.
    private func tapped(at point: CGPoint, proxy: ChartProxy) {
        let hit = curve.flatMap { nearestPoint(to: point, proxy: proxy, curve: $0) }

        if let pending = pendingTap,
           hypot(point.x - pending.location.x, point.y - pending.location.y) < 44 {
            pendingTap = nil
            if let hit { remove(hit) } else { add(at: point, proxy: proxy) }
            return
        }

        let pending = PendingTap(location: point)
        pendingTap = pending
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard pendingTap?.id == pending.id else { return }
            pendingTap = nil
            if hit == nil { add(at: point, proxy: proxy) }
        }
    }

    private func add(at point: CGPoint, proxy: ChartProxy) {
        guard var curve, curve.points.count < 20,
              let frequency: Double = proxy.value(atX: point.x),
              let gain: Double = proxy.value(atY: point.y) else { return }
        curve.points.append(CurvePoint(frequency: frequency.clamped(to: range.low...range.high),
                                       gainDB: gain.clamped(to: gainRange)))
        curve.points.sort { $0.frequency < $1.frequency }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)) {
            self.curve = curve
        }
    }

    private func remove(_ id: UUID) {
        // A curve needs at least two points to describe anything.
        guard var curve, curve.points.count > 2 else { return }
        curve.points.removeAll { $0.id == id }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0)) {
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

            controls
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var controlLayout: AnyLayout {
        isShort ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 18))
    }

    private var controls: some View {
        GlassGroup {
                controlLayout {
                    Button { if let original { curve = original } } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.body).frame(width: 30, height: 30)
                    }
                    .secondaryAction()
                    .disabled(!hasChanges)

                    Button { showSource = true } label: {
                        Image(systemName: "text.alignleft")
                            .font(.body).frame(width: 30, height: 30)
                    }
                    .secondaryAction()
                    .disabled(curve == nil)

                    Button { save() } label: {
                        if isShort {
                            Image(systemName: "square.and.arrow.down")
                                .font(.body).frame(width: 30, height: 30)
                        } else {
                            Label("Save", systemImage: "square.and.arrow.down")
                                .font(.subheadline.weight(.semibold))
                                .frame(height: 30)
                                .padding(.horizontal, 6)
                        }
                    }
                    .prominentAction()
                    .disabled(curve == nil)
                }
                .floatingBar(vertical: isShort)
        }
    }

    private var hasChanges: Bool {
        guard let curve, let original else { return curve != nil && original == nil }
        return curve.points != original.points
    }

    private func deleteCurrent() {
        guard let curve, !curve.isBuiltIn else { return }
        store.delete(curve: curve)
        state.show("Deleted \(curve.name)")
        let fallback = store.targetCurves.first { !$0.isBuiltIn && $0.name != curve.name }
            ?? TargetCurve.bundled[0]
        if state.referenceTargetName == curve.name { state.referenceTargetName = fallback.name }
        if state.eqTargetName == curve.name { state.eqTargetName = fallback.name }
        select(fallback)
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
            state.referenceTargetName = curve.name
            state.eqTargetName = curve.name
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
