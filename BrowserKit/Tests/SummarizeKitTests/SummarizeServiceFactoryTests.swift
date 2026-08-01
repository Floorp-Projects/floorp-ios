// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
import Shared
@testable import SummarizeKit

final class MockSummarizerServiceLifecycle: SummarizerServiceLifecycle, @unchecked Sendable {
    var summarizerServiceDidStartCalled = 0
    var summarizerServiceDidCompleteCalled = 0
    var summarizerServiceDidFailCalled = 0

    func summarizerServiceDidStart(_ text: String) {
        summarizerServiceDidStartCalled += 1
    }

    func summarizerServiceDidComplete(_ summary: String, modelName: SummarizeKit.SummarizerModel) {
        summarizerServiceDidCompleteCalled += 1
    }

    func summarizerServiceDidFail(_ error: SummarizeKit.SummarizerError, modelName: SummarizeKit.SummarizerModel) {
        summarizerServiceDidFailCalled += 1
    }
}

final class SummarizeServiceFactoryTests: XCTestCase {
    var serviceLifecycle: MockSummarizerServiceLifecycle!

    override func setUp() {
        super.setUp()
        serviceLifecycle = MockSummarizerServiceLifecycle()
    }

    override func tearDown() {
        serviceLifecycle = nil
        super.tearDown()
    }

    func test_make_whenAppleIntelligenceAvailable() throws {
        guard #available(iOS 26, *) else {
            throw XCTSkip("Skipping iOS 26-only test on earlier OS versions")
        }
        let subject = createSubject()

        let result = subject.make(
            isAppleSummarizerEnabled: true,
            isHostedSummarizerEnabled: false,
            isAppAttestAuthEnabled: false,
            prefs: MockProfilePrefs(),
            config: nil
        )
        let service = try XCTUnwrap(result as? DefaultSummarizerService)

        XCTAssertNotNil(service.summarizerLifecycle)
    }

    func test_make_whenHostedDisallowedAndAppleAvailable_returnsAppleService() throws {
        guard #available(iOS 26, *) else {
            throw XCTSkip("Skipping iOS 26-only test on earlier OS versions")
        }
        let subject = createSubject(allowsHostedSummarizer: false)

        let result = subject.make(
            isAppleSummarizerEnabled: true,
            isHostedSummarizerEnabled: true,
            isAppAttestAuthEnabled: true,
            prefs: MockProfilePrefs(),
            config: nil
        )

        XCTAssertNotNil(result as? DefaultSummarizerService)
    }

    func test_make_whenHostedSummarizerTrue_returnsNilForLLMConfigNotAvailable() throws {
        let subject = createSubject()

        let result = subject.make(
            isAppleSummarizerEnabled: false,
            isHostedSummarizerEnabled: true,
            isAppAttestAuthEnabled: false,
            prefs: MockProfilePrefs(),
            config: nil
        )

        XCTAssertNil(result)
    }

    func test_make_whenAppAttestAuthEnabled_returnsNilForAppAttestConfigNotAvailable() throws {
        let subject = createSubject()

        let result = subject.make(
            isAppleSummarizerEnabled: false,
            isHostedSummarizerEnabled: true,
            isAppAttestAuthEnabled: true,
            prefs: MockProfilePrefs(),
            config: nil
        )

        XCTAssertNil(result)
    }

    func test_make_returnsNilWhenSummarizerAvailable() throws {
        let subject = createSubject()

        let result = subject.make(
            isAppleSummarizerEnabled: false,
            isHostedSummarizerEnabled: false,
            isAppAttestAuthEnabled: false,
            prefs: MockProfilePrefs(),
            config: nil
        )

        XCTAssertNil(result)
    }

    func test_make_whenHostedDisallowedByAppPolicy_returnsNil() {
        let subject = createSubject(allowsHostedSummarizer: false)
        let config = SummarizerConfig(
            instructions: "Summarize this page",
            options: ["model": "hosted-model"]
        )

        let result = subject.make(
            isAppleSummarizerEnabled: false,
            isHostedSummarizerEnabled: true,
            isAppAttestAuthEnabled: true,
            prefs: MockProfilePrefs(),
            config: config
        )

        XCTAssertNil(result)
    }

    func test_maxWords_whenHostedSummarizerDisallowedByAppPolicy_returnsZero() {
        let subject = createSubject(allowsHostedSummarizer: false)

        let result = subject.maxWords(
            isAppleSummarizerEnabled: false,
            isHostedSummarizerEnabled: true
        )

        XCTAssertEqual(result, 0)
    }

    func test_maxWords_whenAppleSummarizerEnabledAndHostedDisallowed_returnsAppleLimit() {
        let subject = createSubject(allowsHostedSummarizer: false)

        let result = subject.maxWords(
            isAppleSummarizerEnabled: true,
            isHostedSummarizerEnabled: true
        )

        XCTAssertEqual(result, FoundationModelsConfig.maxWords)
    }

    private func createSubject(allowsHostedSummarizer: Bool = true) -> DefaultSummarizerServiceFactory {
        var service = DefaultSummarizerServiceFactory(
            allowsHostedSummarizer: allowsHostedSummarizer
        )
        service.lifecycleDelegate = serviceLifecycle
        return service
    }
}
