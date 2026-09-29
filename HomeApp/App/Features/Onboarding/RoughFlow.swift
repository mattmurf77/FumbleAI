import SwiftUI
import HomeCore

/// "Rough it in" inputs (FR-PLN-10): floors 1–3, basement, approx. above-grade sq ft (400–10,000), bedrooms 0–8,
/// bathrooms in halves 0–6, garage. Continue → `RoughInGenerating.draft` → Review.
struct RoughFlow: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: OnboardingModel

    @State private var floors = 1
    @State private var hasBasement = false
    @State private var sqFt = 1_600
    @State private var bedrooms = 3
    @State private var bathrooms = 2.0
    @State private var garage = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $floors, in: 1...3) {
                    LabeledContent("Floors above ground", value: "\(floors)")
                }
                Toggle("Basement", isOn: $hasBasement)
            } header: {
                Text("Floors")
            }
            Section {
                HStack {
                    Text("Square feet")
                    Spacer()
                    TextField("sq ft", value: $sqFt, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .onSubmit { sqFt = min(max(sqFt, 400), 10_000) }
                }
                Stepper("Adjust by 100", value: $sqFt, in: 400...10_000, step: 100)
                    .labelsHidden()
            } header: {
                Text("Approximate size (above ground)")
            } footer: {
                Text("A rough number is fine. It's saved as a reference and can be refined later.")
            }
            Section("Rooms") {
                Stepper(value: $bedrooms, in: 0...8) { LabeledContent("Bedrooms", value: "\(bedrooms)") }
                Stepper(value: $bathrooms, in: 0...6, step: 0.5) {
                    LabeledContent("Bathrooms", value: bathrooms.formatted(.number.precision(.fractionLength(0...1))))
                }
                Toggle("Garage", isOn: $garage)
            }
        }
        .navigationTitle("Rough it in")
        .safeAreaInset(edge: .bottom) {
            Button {
                let clamped = min(max(sqFt, 400), 10_000)
                sqFt = clamped
                let input = RoughInInput(floors: floors, hasBasement: hasBasement, approxSqFt: clamped,
                                         bedrooms: bedrooms, bathrooms: bathrooms, includeGarage: garage)
                model.approxSqFt = clamped
                model.seedExterior = model.resolved != nil
                model.useDraft(env.roughIn.draft(input), path: .rough, env: env)
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }
}

#Preview("Rough it in") {
    NavigationStack { RoughFlow(model: OnboardingModel()) }
        .environment(AppEnvironment.preview(sample: false))
}
