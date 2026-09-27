import SwiftData
import SwiftUI

/// 「先にこの端末の記録を書き出す」 inside a Settings confirmation that deletes
/// this device's records (transfer-02 / transfer-03). It runs the ordinary
/// Settings export against the mounted session and hands the file to the same
/// share sheet; it starts no transfer and changes no record. The note beside
/// it says what the file is for, because it cannot be imported back.
struct StorageTransferExportControl: View {
    typealias Export = @MainActor () async throws -> URL

    let identifier: String
    let export: Export
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var failure: String?

    var body: some View {
        Button {
            run()
        } label: {
            HStack {
                Text(StorageTransferOverwriteCopy.exportTitle)
                Spacer(minLength: 8)
                if isExporting { ProgressView() }
            }
            .frame(minHeight: 44)
        }
        .disabled(isExporting)
        .accessibilityIdentifier(identifier)
        .sheet(isPresented: Binding(
            get: { exportedURL != nil },
            set: { if !$0 { discard() } }
        )) {
            if let exportedURL {
                PomoGemDataExportShareSheet(fileURL: exportedURL) { _ in discard() }
                    .systemShareSheetPresentation()
            }
        }
        Text(failure ?? StorageTransferOverwriteCopy.exportNote)
            .font(.caption)
            .foregroundStyle(failure == nil ? PomoGemTheme.muted : .red)
            .accessibilityIdentifier(identifier + "-note")
    }

    private func run() {
        guard !isExporting else { return }
        isExporting = true
        failure = nil
        Task { @MainActor in
            defer { isExporting = false }
            do {
                exportedURL = try await export()
            } catch {
                failure = "書き出せませんでした。\(error.localizedDescription)"
            }
        }
    }

    /// The ordinary Settings export of the mounted session: pending edits are
    /// saved first, exactly as the Settings row does.
    static func exportMountedSession(_ context: ModelContext) async throws -> URL {
        if context.hasChanges { try context.save() }
        let worker = PomoGemDataExportWorker(modelContainer: context.container)
        let result = try await worker.export(appInfo: .current)
        return result.fileURL
    }

    private func discard() {
        guard let url = exportedURL else { return }
        exportedURL = nil
        try? PomoGemDataExporter.removeExport(at: url)
    }
}
