// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import WebEngine
import WebKit

@MainActor
final class WKEngineWebViewTests: XCTestCase, @unchecked Sendable {
    private let delegate = MockWKEngineWebViewDelegate()
    private let testURL = URL(string: "https://www.example.com/")!

    func testNoLeaks() {
        let subject = createSubject()
        subject.close()

        // Wait for webView to fully deallocate
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testLoad_callsObservers() async throws {
        let handler = ObserverFixtureSchemeHandler()
        let subject = createSubject(schemeHandler: handler)
        subject.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        defer {
            delegate.webViewPropertyChangedCallback = nil
            subject.stopLoading()
            subject.close()
        }

        var forwardedProperties = [WKEngineWebViewProperty]()
        delegate.webViewPropertyChangedCallback = { forwardedProperties.append($0) }
        // Prime a secure document so the local fixture produces a real security-state change.
        try await completeNavigation(subject) {
            subject.loadHTMLString(
                ObserverFixtureSchemeHandler.secureHTML,
                baseURL: URL(string: "https://observer-fixture.invalid/")
            )
        }
        XCTAssertTrue(subject.hasOnlySecureContent)
        forwardedProperties.removeAll()

        let firstURL = try XCTUnwrap(URL(string: "\(handler.scheme)://local/first"))
        let secondURL = try XCTUnwrap(URL(string: "\(handler.scheme)://local/second"))
        let expectedTitle = ObserverFixtureSchemeHandler.title
        let loadingExpectation = expectation(that: \WKWebView.isLoading, on: subject) { _, change in
            change.newValue == true
        }
        let titleExpectation = expectation(that: \WKWebView.title, on: subject) { _, change in
            change.newValue == expectedTitle
        }
        let urlExpectation = expectation(that: \WKWebView.url, on: subject) { _, change in
            guard let url = change.newValue as? URL else { return false }
            return url == firstURL
        }
        let progressExpectation = expectation(that: \WKWebView.estimatedProgress, on: subject) { _, change in
            guard let progress = change.newValue else { return false }
            XCTAssertGreaterThanOrEqual(progress, 0)
            XCTAssertLessThanOrEqual(progress, 1)
            return progress == 1
        }
        let canGoBackExpectation = expectation(that: \WKWebView.canGoBack, on: subject) { _, change in
            change.newValue == true
        }
        let canGoForwardExpectation = expectation(that: \WKWebView.canGoForward, on: subject) { _, change in
            change.newValue == true
        }
        let contentSizeExpectation = expectation(that: \UIScrollView.contentSize, on: subject.scrollView) { _, change in
            guard let size = change.newValue else { return false }
            return size != .zero
        }
        let hasOnlySecureContentExpectation = expectation(
            that: \WKWebView.hasOnlySecureContent,
            on: subject
        ) { _, change in
            change.newValue == false
        }

        var navigationError: Error?
        do {
            try await completeNavigation(subject) { subject.load(URLRequest(url: firstURL)) }
            XCTAssertEqual(subject.url, firstURL)
            try await completeNavigation(subject) { subject.load(URLRequest(url: secondURL)) }
            XCTAssertEqual(subject.url, secondURL)
            XCTAssertTrue(subject.canGoBack)
            try await completeNavigation(subject) { subject.goBack() }
            XCTAssertEqual(subject.url, firstURL)
            XCTAssertTrue(subject.canGoForward)
        } catch {
            navigationError = error
        }

        await fulfillment(
            of: [
                loadingExpectation,
                titleExpectation,
                urlExpectation,
                progressExpectation,
                canGoBackExpectation,
                canGoForwardExpectation,
                contentSizeExpectation,
                hasOnlySecureContentExpectation
            ],
            timeout: 10
        )

        XCTAssertGreaterThan(delegate.webViewPropertyChangedCalled, 0)
        XCTAssertNotNil(delegate.lastWebViewPropertyChanged)
        XCTAssertTrue(forwardedProperties.contains(.loading(true)))
        XCTAssertTrue(forwardedProperties.contains(.title(expectedTitle)))
        XCTAssertTrue(forwardedProperties.contains(.URL(firstURL)))
        XCTAssertTrue(forwardedProperties.contains(.estimatedProgress(1)))
        XCTAssertTrue(forwardedProperties.contains(.canGoBack(true)))
        XCTAssertTrue(forwardedProperties.contains(.canGoForward(true)))
        XCTAssertTrue(forwardedProperties.contains(.hasOnlySecureContent(false)))
        XCTAssertTrue(forwardedProperties.contains {
            guard case .contentSize(let size) = $0 else { return false }
            return size != .zero
        })
        if let navigationError { throw navigationError }
    }

    private func completeNavigation(_ webView: WKWebView,
                                    action: () -> WKNavigation?) async throws {
        let completion = XCTestExpectation(description: "Local observer fixture navigation completes")
        let observer = ObserverFixtureNavigationDelegate(completion: completion)
        webView.navigationDelegate = observer
        defer { webView.navigationDelegate = nil }
        observer.navigation = try XCTUnwrap(action(), "WebKit did not start the local fixture navigation")
        let result = await XCTWaiter.fulfillment(of: [completion], timeout: 10)
        guard result == .completed else {
            throw NSError(domain: "ObserverFixtureNavigation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Local fixture navigation did not complete: \(result)"
            ])
        }
        if let error = observer.error { throw error }
    }

    func testLoad_callsBeginRefreshing_onUIRefreshControl() throws {
        let subject = createSubject(pullRefreshViewType: MockUIRefreshControl.self)
        let pullRefresh = try XCTUnwrap(subject.scrollView.refreshControl as? MockUIRefreshControl)

        subject.load(URLRequest(url: testURL))

        XCTAssertEqual(pullRefresh.beginRefreshingCalled, 1)
        XCTAssertEqual(pullRefresh.endRefreshingCalled, 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testInit_setupsPullRefresh() throws {
        let subject = createSubject()

        let pullRefresh = try XCTUnwrap(subject.scrollView.subviews.first {
            $0 is EnginePullRefreshView
        }) as? MockEnginePullRefreshView

        XCTAssertNotNil(pullRefresh)
        XCTAssertNil(subject.scrollView.refreshControl)
        XCTAssertEqual(pullRefresh?.configureCalled, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testInit_withUIRefreshControl_setupsCorrectlyPullRefresh() {
        let subject = createSubject(pullRefreshViewType: UIRefreshControl.self)

        XCTAssertNotNil(subject.scrollView.refreshControl)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testScrollWillBeginZooming_removesPullRefresh() {
        let subject = createSubject()

        subject.scrollViewWillBeginZooming(UIScrollView(), with: nil)

        let pullRefresh = subject.scrollView.subviews.first { $0 is EnginePullRefreshView }
        XCTAssertNil(pullRefresh)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testScrollDidEndZooming_setupsPullRefresh() {
        let subject = createSubject()

        subject.scrollViewWillBeginZooming(UIScrollView(), with: nil)
        subject.scrollViewDidEndZooming(UIScrollView(), with: nil, atScale: 1.0)

        let pullRefresh = subject.scrollView.subviews.first { $0 is EnginePullRefreshView }
        XCTAssertNotNil(pullRefresh)
        XCTAssertNil(subject.scrollView.refreshControl)
        XCTAssertEqual((pullRefresh as? MockEnginePullRefreshView)?.configureCalled, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testScrollDidEndZooming_doesntSetupPullRefreshAgain() {
        let subject = createSubject()

        subject.scrollViewDidEndZooming(UIScrollView(), with: nil, atScale: 1.0)

        let pullRefresh = subject.scrollView.subviews.first { $0 is EnginePullRefreshView }
        XCTAssertNotNil(pullRefresh)
        XCTAssertNil(subject.scrollView.refreshControl)
        XCTAssertEqual((pullRefresh as? MockEnginePullRefreshView)?.configureCalled, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testTriggerPullRefresh_callsDelegate() throws {
        let subject = createSubject()
        let pullRefresh = try XCTUnwrap(subject.scrollView.subviews.first { $0 is EnginePullRefreshView }
                                        as? MockEnginePullRefreshView)

        pullRefresh.onRefresh?()

        XCTAssertEqual(delegate.webViewNeedsReloadCalled, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func createSubject(pullRefreshViewType: EnginePullRefreshViewType = MockEnginePullRefreshView.self,
                       schemeHandler: SchemeHandler? = nil,
                       file: StaticString = #filePath,
                       line: UInt = #line) -> DefaultWKEngineWebView {
        let parameters = WKWebViewParameters(blockPopups: true,
                                             isPrivate: false,
                                             autoPlay: .all,
                                             schemeHandler: schemeHandler ?? WKInternalSchemeHandler(),
                                             pullRefreshType: pullRefreshViewType)
        let configuration = DefaultWKEngineConfigurationProvider()
        let subject = DefaultWKEngineWebView(frame: .zero,
                                             configurationProvider: configuration,
                                             parameters: parameters)!
        subject.delegate = delegate
        trackForMemoryLeaks(subject, file: file, line: line)

        return subject
    }
}

@MainActor
private final class ObserverFixtureSchemeHandler: NSObject, SchemeHandler {
    let scheme = "observer-fixture"
    static let title = "Observer fixture"
    static let secureHTML = """
    <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'">
    <title>Secure baseline</title></head><body>Baseline</body></html>
    """

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == scheme, url.host == "local" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let html = """
        <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(Self.title)</title></head><body style="margin:0"><div style="width:320px;height:2048px">Fixture</div></body></html>
        """
        let data = Data(html.utf8)
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
private final class ObserverFixtureNavigationDelegate: NSObject, WKNavigationDelegate {
    var navigation: WKNavigation?
    private(set) var error: Error?
    private var completed = false
    private let completion: XCTestExpectation

    init(completion: XCTestExpectation) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finish(navigation, error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        finish(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        finish(navigation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(navigation, error: NSError(domain: "ObserverFixtureNavigation", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Local fixture WebContent process terminated"
        ]))
    }

    private func finish(_ navigation: WKNavigation?, error: Error?) {
        guard !completed, let navigation, navigation === self.navigation else { return }
        completed = true
        self.error = error
        completion.fulfill()
    }
}
