import SwiftUI

struct DocumentSettingsView: View {
    @State private var documentIndexing = false
    @State private var settingsLoaded = false
    @State private var savingDocuments = false
    @State private var documentSettingsError = false
    var engine: any SearchService = Engine()

    var body: some View {
        Form {
            Toggle("Index Common Document Contents", isOn: Binding(
                get: { documentIndexing },
                set: { value in
                    savingDocuments = true; documentSettingsError = false
                    Task {
                        do {
                            let reply = try await engine.request(["op": "settings", "document_indexing": value])
                            guard reply.ok, let enabled = reply.document_indexing else {
                                throw Engine.Failure.message("settings")
                            }
                            documentIndexing = enabled
                        } catch { documentSettingsError = true }
                        savingDocuments = false
                    }
                }))
                .disabled(!settingsLoaded || savingDocuments)
            Text("DOC、DOCX、PDF、XLS / XLSX").font(.caption).foregroundStyle(.secondary)
            if documentSettingsError {
                Button("Could not update document indexing. Retry") {
                    Task { await loadDocumentSettings() }
                }.buttonStyle(.link).font(.caption)
            }
        }
        .formStyle(.grouped).frame(width: 440, height: 160).padding(.vertical, 8)
        .task { await loadDocumentSettings() }
    }
    private func loadDocumentSettings() async {
        do {
            let reply = try await engine.request(["op": "settings"])
            guard reply.ok, let enabled = reply.document_indexing else {
                throw Engine.Failure.message("settings")
            }
            documentIndexing = enabled; settingsLoaded = true; documentSettingsError = false
        } catch { documentSettingsError = true }
    }
}
