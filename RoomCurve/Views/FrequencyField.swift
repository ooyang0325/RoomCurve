import SwiftUI

/// A frequency you can drag or type.
///
/// The slider is logarithmic, because frequency is. On a linear slider spanning 100 Hz to
/// 20 kHz, everything below 1 kHz — which is where room correction does most of its work — is
/// crammed into the first twentieth of the travel, and the last two thirds are spent on the
/// region you were told not to equalise. In log space an octave is an octave wherever you are.
///
/// Typing exists because a slider cannot express "exactly 80" reliably, and crossover
/// frequencies are the kind of number people already know before they arrive.
struct FrequencyField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 20...20_000

    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                TextField("", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($editing)
                    .frame(maxWidth: 90)
                    .onSubmit(commit)
                Text("Hz").foregroundStyle(.secondary)
            }

            Slider(value: logarithmic, in: log2(range.lowerBound)...log2(range.upperBound))
                .onChange(of: value) { _, _ in if !editing { text = format(value) } }
        }
        .onAppear { text = format(value) }
        .onChange(of: editing) { _, isEditing in
            if isEditing { text = format(value) } else { commit() }
        }
        .toolbar {
            if editing {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
        }
    }

    /// The slider works in octaves; the value stays in hertz.
    private var logarithmic: Binding<Double> {
        Binding(
            get: { log2(value.clamped(to: range)) },
            set: { value = snap(exp2($0)).clamped(to: range) }
        )
    }

    private func commit() {
        guard let entered = Double(text.trimmingCharacters(in: .whitespaces)) else {
            text = format(value)
            return
        }
        value = snap(entered).clamped(to: range)
        text = format(value)
    }

    /// Round to a step that means something at this frequency — 1 Hz matters at 40 Hz and is
    /// noise at 12 kHz.
    private func snap(_ frequency: Double) -> Double {
        switch frequency {
        case ..<100: (frequency).rounded()
        case ..<1_000: (frequency / 5).rounded() * 5
        case ..<10_000: (frequency / 10).rounded() * 10
        default: (frequency / 100).rounded() * 100
        }
    }

    private func format(_ frequency: Double) -> String {
        frequency < 1_000 ? String(format: "%.0f", frequency)
                          : String(format: "%.0f", frequency)
    }
}
