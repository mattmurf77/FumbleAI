import SwiftUI
import HomeCore

/// Step 2: "How do you want to create your plan?" (mockup 6.1, FR-PLN-02/03). Scan is shown only on LiDAR devices;
/// without it, Rough it in is marked "Suggested".
struct PathChooser: View {
    @Bindable var model: OnboardingModel
    /// nil = detect (previews pass a value).
    var scanSupported: Bool? = nil

    var body: some View {
        let scanSupported = self.scanSupported ?? OnboardingModel.scanSupported
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingStepLabel(step: 2)
                Text("How do you want to create your plan?")
                    .font(.title.weight(.bold))
                Text("All four make the same editable plan. You can switch methods or refine it any time.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                if scanSupported {
                    PathCard(symbol: "camera.viewfinder", title: "Scan",
                             detail: "Walk each room with your iPhone. About 2 minutes a room. Uses LiDAR.") {
                        model.routes.append(.scan)
                    }
                }
                PathCard(symbol: "square.grid.3x3.square", title: "Build with blocks",
                         detail: "Drag rooms onto a grid and type dimensions. Starts from a template: Colonial, Ranch, Split-level, Bi-level.") {
                    model.routes.append(.blocks)
                }
                PathCard(symbol: "photo.on.rectangle", title: "Trace a photo",
                         detail: "Use a listing screenshot or closing papers. Tap two points and enter a known length to set the scale.") {
                    model.routes.append(.trace)
                }
                PathCard(symbol: "wand.and.stars", title: "Rough it in", tag: scanSupported ? "Fastest" : "Suggested",
                         detail: "Enter approximate square footage and a room list. You have a working plan in about 60 seconds and can refine it later.") {
                    model.routes.append(.rough)
                }

                Group {
                    if let r = model.resolved {
                        Text("The yard is set up next, from the satellite view of \(r.address.line ?? r.displayName).")
                    } else {
                        Text("The yard is set up around your house's outline. Add your address later for the satellite view.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            }
            .padding(20)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One option card.
struct PathCard: View {
    let symbol: String
    let title: String
    var tag: String?
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if let tag {
                            Text(tag)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.top, 14)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(detail)
    }
}

#Preview("Chooser – LiDAR") {
    NavigationStack { PathChooser(model: OnboardingModel(), scanSupported: true) }
        .environment(AppEnvironment.preview(sample: false))
}

#Preview("Chooser – no LiDAR") {
    NavigationStack { PathChooser(model: OnboardingModel(), scanSupported: false) }
        .environment(AppEnvironment.preview(sample: false))
}
