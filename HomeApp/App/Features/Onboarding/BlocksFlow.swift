import SwiftUI
import HomeCore

/// "Build with blocks" (FR-PLN-20/21): pick a style (Ranch, Colonial 2-story, Cape, Split-level, Bi-level,
/// Townhouse, Condo, Blank) plus bedrooms/bathrooms → `BlockTemplating.draft` → Review. After commit the Plan editor
/// refines it. Multi-level styles include stairs on every level; "Same outline on every level" (default on) makes the
/// upper/lower levels take the main floor's outline with the stairs lined up, so the user only subdivides.
struct BlocksFlow: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: OnboardingModel

    /// nil = Blank.
    @State private var style: HouseStyle? = .twoStory
    @State private var bedrooms = 3
    @State private var bathrooms = 2.5
    @State private var matchOutlines = true

    /// Grid order; nil = Blank.
    static let options: [HouseStyle?] = HouseStyle.pickerOrder.map { Optional($0) } + [nil]

    static func name(_ s: HouseStyle?) -> String { s?.displayName ?? "Blank" }

    static func detail(_ s: HouseStyle?) -> String {
        switch s {
        case .townhouse?: return "Narrow and tall"
        case let s?: return s.subtitle
        case nil: return "Start from an empty floor"
        }
    }

    static func symbol(_ s: HouseStyle?) -> String { s?.symbol ?? "square.dashed" }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pick a starting layout").font(.title2.weight(.bold))
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Self.options, id: \.self) { s in
                        Button { style = s } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: Self.symbol(s)).font(.title2)
                                Text(Self.name(s)).font(.headline)
                                Text(Self.detail(s)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(style == s ? Color.accentColor.opacity(0.14) : Color(.secondarySystemGroupedBackground)))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style == s ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: style == s ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(style == s ? .isSelected : [])
                    }
                }
                if style != nil {
                    VStack(spacing: 0) {
                        Stepper(value: $bedrooms, in: 0...8) { LabeledContent("Bedrooms", value: "\(bedrooms)") }
                            .padding(.vertical, 8)
                        Divider()
                        Stepper(value: $bathrooms, in: 0...6, step: 0.5) {
                            LabeledContent("Bathrooms", value: bathrooms.formatted(.number.precision(.fractionLength(0...1))))
                        }
                        .padding(.vertical, 8)
                        if style?.isMultiLevel == true {
                            Divider()
                            Toggle(isOn: $matchOutlines) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Same outline on every level")
                                    Text("Stairs line up floor to floor; you split the rooms.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Build with blocks")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: build) { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .background(.bar)
        }
    }

    private func build() {
        let draft: PlanDraft
        if let style {
            draft = env.blocks.draft(style: style, beds: bedrooms, baths: bathrooms, matchOutlines: matchOutlines)
        } else {
            draft = PlanDraft(levels: [LevelDraft(name: "1st Floor", kind: .floor, sortOrder: 0)], source: .blocks)
        }
        // Condo skips exterior seeding by default (spec 03 edge cases); the review screen can turn it on.
        model.seedExterior = style != .apartment
        model.approxSqFt = nil
        model.useDraft(draft, path: .blocks, env: env)
    }
}

#Preview("Blocks") {
    NavigationStack { BlocksFlow(model: OnboardingModel()) }
        .environment(AppEnvironment.preview(sample: false))
}
