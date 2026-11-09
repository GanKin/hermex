import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The preview owns its temporary file and the bytes written to it. Quick Look
/// and Share read the file; Save to Files writes the same bytes, so exporting
/// never downloads again. Dismissal invalidates late completions and removes
/// only the directory this presentation created.
@MainActor @Observable final class BotArtifactPreviewModel {
    /// What Save to Files writes: the downloaded bytes under the temporary file's
    /// sanitized name, typed by its extension, or `.data` without one.
    struct Export {
        let data: Data
        let filename: String
        let contentType: UTType
    }

    private var loaded: (file: QuickLookTemporaryFile, data: Data)?
    var fileURL: URL? { loaded?.file.url }
    var fileData: Data? { loaded?.data }
    private(set) var errorMessage: String?
    private var generation = 0

    /// Nil while loading, on error and after cleanup, when there are no bytes to save.
    var export: Export? {
        guard let loaded else { return nil }
        let url = loaded.file.url
        return Export(
            data: loaded.data,
            filename: url.lastPathComponent,
            contentType: UTType(filenameExtension: url.pathExtension) ?? .data
        )
    }

    func load(name: String, download: () async throws -> Data) async {
        cleanup()
        let owner = generation
        errorMessage = nil
        do {
            let data = try await download()
            try Task.checkCancellation()
            guard owner == generation else { return }
            let written = try await QuickLookTemporaryFile.write(data: data, name: name)
            // Returning drops a late write, which deletes its directory.
            guard !Task.isCancelled, owner == generation else { return }
            loaded = (written, data)
        } catch {
            guard !Task.isCancelled, owner == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func cleanup() {
        generation += 1
        loaded = nil
    }

}

/// A preview for a Hermes chat's sent file or artifact. Once loaded, Save to Files and
/// Share sit beside Done and act on the bytes already downloaded.
struct BotArtifactPreview: View {
    let reference: TranscriptMediaReference
    /// The title and saved file name; the reference's file name when nil.
    var title: String? = nil
    let rendersHTML: Bool
    let download: () async throws -> Data
    @Environment(\.dismiss) private var dismiss
    @State private var model = BotArtifactPreviewModel()
    @State private var attempt = 0
    @State private var isFileExporterPresented = false
    @State private var exportErrorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if rendersHTML, let data = model.fileData {
                    StaticHTMLReportView(data: data)
                } else if let url = model.fileURL {
                    QuickLookFileView(url: url)
                } else if let error = model.errorMessage {
                    ContentUnavailableView {
                        Label("Could Not Load File", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { attempt += 1 }
                    }
                } else {
                    Text("Loading file...").foregroundStyle(.appSecondary)
                }
            }
            .themedPageBackground()
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let url = model.fileURL {
                        Button {
                            isFileExporterPresented = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel(String(localized: "Save \(name) to Files"))
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(String(localized: "Share \(name)"))
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: model.export.map { ExportedFileDocument(data: $0.data) },
            contentType: model.export?.contentType ?? .data,
            defaultFilename: model.export?.filename
        ) { result in
            if case let .failure(error) = result {
                exportErrorMessage = error.localizedDescription
            }
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK") { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .task(id: attempt) { await model.load(name: name, download: download) }
        .onDisappear { model.cleanup() }
    }

    private var name: String { title ?? reference.displayName }
}

/// Renders the downloaded bytes with a local response and a restrictive policy.
struct StaticHTMLReportView: UIViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(data: data)
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let documentURL = URL(string: "https://hermex-report.invalid/")!
        private var allowsInitialNavigation = true

        func makeWebView(data: Data) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false

            let view = WKWebView(frame: .zero, configuration: configuration)
            view.allowsLinkPreview = false
            view.navigationDelegate = self
            let response = HTTPURLResponse(
                url: documentURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/html",
                    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'",
                    "X-DNS-Prefetch-Control": "off"
                ]
            )!
            view.loadSimulatedRequest(URLRequest(url: documentURL), response: response, responseData: data)
            return view
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isInitialDocument = allowsInitialNavigation && action.targetFrame?.isMainFrame == true
                && action.navigationType == .other && action.request.url == documentURL
            allowsInitialNavigation = false
            decisionHandler(isInitialDocument ? .allow : .cancel)
        }
    }
}
