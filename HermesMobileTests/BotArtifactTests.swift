import XCTest
import UniformTypeIdentifiers
@testable import HermesMobile

@MainActor final class BotArtifactTests: XCTestCase {
    private let address = URL(string: "https://bot.example")!
    private func context(connectionID: UUID = UUID()) -> BotArtifactContext {
        BotArtifactContext(connectionID: connectionID, profile: "inbox-triage", sessionID: "compression-tip", generation: 1)
    }

    func testDownloadURLBindsProfileAndDurableSessionAndDoesNotResolveOnPhone() throws {
        let scope = context()
        let url = try XCTUnwrap(HermesREST.downloadArtifact(path: "../files/a & b.pdf", profile: scope.profile,
                                                            sessionID: scope.sessionID).request(base: address).url)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.host, address.host)
        XCTAssertEqual(url.path, "/api/fs/download")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["path": "../files/a & b.pdf", "profile": scope.profile, "session_id": "compression-tip"])
        XCTAssertEqual(try BotArtifactReference.path("file:///server/a%20b.pdf", address: address), "/server/a b.pdf")
        XCTAssertEqual(try BotArtifactReference.path("~/result.pdf", address: address), "~/result.pdf")
    }

    func testReferencesCannotSelectAnotherHostOrOverrideSession() throws {
        for path in ["https://other.example/a.pdf", "//other.example/a.pdf", "data:text/plain;base64,YQ==", "file://other/server/a.pdf", ""] {
            XCTAssertThrowsError(try BotArtifactReference.path(path, address: address))
        }
        let url = try XCTUnwrap(HermesREST.downloadArtifact(
            path: "https://bot.example/api/fs/download?path=a.pdf&profile=other&session_id=other&token=secret",
            profile: "inbox-triage", sessionID: "compression-tip").request(base: address).url)
        XCTAssertFalse(url.absoluteString.contains("secret"))
        XCTAssertFalse(url.absoluteString.contains("other"))
    }

    func testHTTPDownloadPreservesRawPDFAndRejectsErrorsAndOversize() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotArtifactHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); BotArtifactHTTPFixture.handler = nil }
        let request = try HermesREST.downloadArtifact(path: "report.pdf", profile: "inbox-triage", sessionID: "compression-tip")
            .request(base: address)
        let url = request.url
        let pdf = Data("%PDF-fixture".utf8)
        BotArtifactHTTPFixture.handler = { request in
            XCTAssertEqual(request.url, url)
            return (200, ["Content-Type": "application/pdf"], pdf)
        }
        let bytes = try await BotArtifactDownload.data(session: session, request: request)
        XCTAssertEqual(bytes, pdf)
        for status in [401, 403, 404, 302] {
            BotArtifactHTTPFixture.handler = { _ in (status, [:], Data()) }
            do { _ = try await BotArtifactDownload.data(session: session, request: request); XCTFail("Expected rejection") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
        BotArtifactHTTPFixture.handler = { _ in (200, ["Content-Length": "\(BotArtifactBuffer.maximumBytes + 1)"], Data()) }
        do { _ = try await BotArtifactDownload.data(session: session, request: request); XCTFail("Expected size rejection") }
        catch { XCTAssertTrue(error is BotArtifactFailure) }
    }

    func testCancellingDownloadStopsItsHTTPTask() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotArtifactHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        let started = expectation(description: "HTTP request started")
        let stopped = expectation(description: "HTTP request cancelled")
        BotArtifactHTTPFixture.startHook = { fixture in
            let response = HTTPURLResponse(url: fixture.request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            fixture.client?.urlProtocol(fixture, didReceive: response, cacheStoragePolicy: .notAllowed)
            started.fulfill()
        }
        BotArtifactHTTPFixture.stopHook = { stopped.fulfill() }
        defer {
            session.invalidateAndCancel()
            BotArtifactHTTPFixture.startHook = nil
            BotArtifactHTTPFixture.stopHook = nil
        }
        let request = URLRequest(url: address.appendingPathComponent("api/fs/download"))
        let task = Task { try await BotArtifactDownload.data(session: session, request: request) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled download returned bytes") }
        catch { /* URLSession and AsyncBytes may report different cancellation errors. */ }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testPreviewExportReusesTheOneDownloadUnderItsSanitizedFilename() async throws {
        let model = BotArtifactPreviewModel()
        let pdf = Data("%PDF-fixture".utf8)
        var downloads = 0
        await model.load(name: "Quarter One.pdf") { downloads += 1; return pdf }
        let export = try XCTUnwrap(model.export)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(export.data, pdf)
        XCTAssertEqual(export.filename, "Quarter One.pdf")
        XCTAssertEqual(export.contentType, .pdf)
        XCTAssertEqual(model.fileURL?.lastPathComponent, "Quarter One.pdf")

        await model.load(name: "README") { Data("notes".utf8) }
        XCTAssertEqual(model.export?.filename, "README")
        XCTAssertEqual(model.export?.contentType, .data)
        await model.load(name: "..") { Data("dots".utf8) }
        XCTAssertEqual(model.export?.filename, "File")
        XCTAssertEqual(model.export?.contentType, .data)
    }

    func testHTMLReportRendersInlineContentAndBlocksExternalImagesAndScripts() async throws {
        let html = Data("""
            <!doctype html><meta charset="utf-8">
            <style>td { color: rgb(10, 20, 30) }</style>
            <table><tr><td>每日复盘</td></tr></table>
            <img src="data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20width=%221%22%20height=%221%22/%3E">
            <script>document.body.dataset.ranScript = 'yes';</script>
            """.utf8)
        let model = BotArtifactPreviewModel()
        await model.load(name: "report.html") { html }
        let coordinator = StaticHTMLReportView.Coordinator()
        let webView = coordinator.makeWebView(data: try XCTUnwrap(model.fileData))
        let loaded = expectation(description: "HTML report loaded")
        let observation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { _, change in
            if change.newValue == 1 { loaded.fulfill() }
        }
        await fulfillment(of: [loaded], timeout: 10)
        observation.invalidate()

        let inspected = expectation(description: "HTML report inspected")
        var inspection: Result<Any, Error>?
        let inspect = Task {
            defer { inspected.fulfill() }
            do {
                inspection = .success(try await webView.callAsyncJavaScript("""
                    const cell = document.querySelector('td');
                    const externalImage = 'https://external.invalid/pixel.png';
                    const blocked = new Promise(resolve => {
                        document.addEventListener('securitypolicyviolation', event => {
                            if (event.effectiveDirective === 'img-src') resolve(event.blockedURI);
                        }, { once: true });
                    });
                    document.body.appendChild(new Image()).src = externalImage;
                    return [cell.textContent, getComputedStyle(cell).color,
                            document.images[0].naturalWidth === 1 ? 'image' : 'missing',
                            document.body.dataset.ranScript ?? 'static', await blocked];
                    """, contentWorld: .page))
            } catch {
                inspection = .failure(error)
            }
        }
        defer { inspect.cancel() }
        await fulfillment(of: [inspected], timeout: 10)
        let result = try XCTUnwrap(inspection).get()
        XCTAssertEqual(result as? [String],
                       ["每日复盘", "rgb(10, 20, 30)", "image", "static", "https://external.invalid/pixel.png"])
        XCTAssertEqual(model.export?.data, html)
        withExtendedLifetime(coordinator) {}
    }

    func testInteractiveHTMLDrawsCanvasWithoutExternalScriptsOrNetworkAccess() async throws {
        let html = Data("""
            <!doctype html><meta charset="utf-8">
            <canvas width="32" height="32"></canvas>
            <script src="https://external.invalid/chart.js"></script>
            <script>
            const context = document.querySelector('canvas').getContext('2d');
            context.fillRect(0, 0, 32, 32);
            document.body.dataset.popup = window.open('https://external.invalid/') === null
                ? 'blocked' : 'opened';
            </script>
            """.utf8)
        let coordinator = StaticHTMLReportView.Coordinator()
        let webView = coordinator.makeWebView(data: html, allowsScripts: true)
        let loaded = expectation(description: "Interactive report loaded")
        let observation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { _, change in
            if change.newValue == 1 { loaded.fulfill() }
        }
        await fulfillment(of: [loaded], timeout: 10)
        observation.invalidate()

        let result = try await webView.callAsyncJavaScript("""
            const pixel = document.querySelector('canvas').getContext('2d').getImageData(0, 0, 1, 1);
            const response = await fetch('https://external.invalid/data')
                .then(() => 'connected', () => 'blocked');
            const resources = performance.getEntriesByType('resource');
            return [pixel.data[3] === 255, document.body.dataset.popup === 'blocked',
                    response === 'blocked', !resources.some(entry => entry.name.includes('external.invalid'))];
            """, contentWorld: .page)
        XCTAssertEqual(result as? [Bool], [true, true, true, true])
        withExtendedLifetime(coordinator) {}
    }

    func testPreviewHasNothingToExportAfterAFailedOrOversizedDownload() async throws {
        let model = BotArtifactPreviewModel()
        await model.load(name: "report.pdf") { Data("%PDF-fixture".utf8) }
        XCTAssertEqual(model.export?.filename, "report.pdf")
        await model.load(name: "report.pdf") { throw BotArtifactFailure.tooLarge }
        XCTAssertNil(model.export)
        XCTAssertNil(model.fileURL)
        XCTAssertEqual(model.errorMessage, BotArtifactFailure.tooLarge.localizedDescription)
        await model.load(name: "report.pdf") { throw URLError(.notConnectedToInternet) }
        XCTAssertNil(model.export)
        XCTAssertEqual(model.errorMessage, URLError(.notConnectedToInternet).localizedDescription)
    }

    func testPreviewCleanupAndLateDownloadCannotRecreateDismissedPreview() async throws {
        let model = BotArtifactPreviewModel()
        await model.load(name: "report.pdf") { Data("%PDF-fixture".utf8) }
        let url = try XCTUnwrap(model.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(model.export?.filename, "report.pdf")
        model.cleanup()
        XCTAssertNil(model.export)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let started = expectation(description: "download started")
        var finish: CheckedContinuation<Data, Never>?
        let pending = Task {
            await model.load(name: "late.pdf") {
                await withCheckedContinuation { continuation in finish = continuation; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        model.cleanup()
        finish?.resume(returning: Data("late".utf8))
        await pending.value
        XCTAssertNil(model.fileURL)
        XCTAssertNil(model.export)
        XCTAssertNil(model.errorMessage)
    }

}

final class BotArtifactHTTPFixture: URLProtocol {
    static var startHook: ((BotArtifactHTTPFixture) -> Void)?
    static var stopHook: (() -> Void)?
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let hook = Self.startHook { hook(self); return }
        guard let handler = Self.handler else { return }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopHook?() }
}
