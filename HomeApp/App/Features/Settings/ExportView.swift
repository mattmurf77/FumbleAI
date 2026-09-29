import SwiftUI
import HomeCore
import HomeCoreTesting

/// Settings › Export data (spec 09 FR-SES-20..25, LLD §13): builds `Home-Export-YYYY-MM-DD.zip` through
/// `ExportService` (works offline) and hands it to the share sheet with `ShareLink`. Pushable.
struct ExportView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var includeAttachments = false
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Toggle("Include photos and receipts", isOn: $includeAttachments)
            } footer: {
                Text("One CSV per kind of record (rooms, to-dos, projects, appliances, inventory, measurements, storage spots, housemates, budget summary) plus a README. Opens in Excel and Numbers. Deleted items aren’t included.")
            }
            Section {
                if exporting {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Creating export…")
                    }
                } else if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                    Button("Create a new export") { Task { await runExport() } }
                } else {
                    Button("Create export") { Task { await runExport() } }
                }
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Export data")
        .onChange(of: includeAttachments) { _, _ in exportURL = nil }
    }

    private func runExport() async {
        exporting = true
        errorText = nil
        defer { exporting = false }
        do {
            guard let pid = try await env.plan.currentProperty()?.id else {
                errorText = "There’s no home to export yet."
                return
            }
            exportURL = try await env.export.exportCSV(property: pid, options: ExportOptions(includeAttachments: includeAttachments))
        } catch {
            exportURL = nil
            errorText = "Couldn’t create the export. Free some space and try again."
        }
    }
}

#Preview {
    NavigationStack { ExportView() }.environment(AppEnvironment.preview())
}
