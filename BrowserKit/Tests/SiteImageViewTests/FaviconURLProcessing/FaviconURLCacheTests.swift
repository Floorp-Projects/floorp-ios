// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
import TestKit
@testable import SiteImageView

@MainActor
class FaviconURLCacheTests: XCTestCase {
    func testGetURLFromCacheWithEmptyCache() async {
        let subject = createSubject(fileManager: MockURLCacheFileManager())
        let cacheKey = "firefox.com"
        let result = try? await subject.getURLFromCache(cacheKey: cacheKey)
        XCTAssertNil(result)
    }

    func testGetURLFromCacheWithValuePresent() async {
        let subject = createSubject(fileManager: MockURLCacheFileManager())
        let cacheKey = "firefox.com"
        await subject.cacheURL(cacheKey: cacheKey, faviconURL: URL(string: "www.firefox.com")!)
        let result = try? await subject.getURLFromCache(cacheKey: cacheKey)

        XCTAssertEqual(result?.absoluteString, "www.firefox.com")
    }

    func testRetrieveCacheNotExpired() async {
        let cacheKey = "google"
        let testFavicons = [FaviconURL(cacheKey: cacheKey, faviconURL: "www.google.com", createdAt: Date())]
        let fileManager = MockURLCacheFileManager(data: getTestData(items: testFavicons))

        let subject = createSubject(fileManager: fileManager)
        let result = try? await subject.getURLFromCache(cacheKey: cacheKey)
        XCTAssertEqual(result?.absoluteString, "www.google.com")
    }

    func testRetrieveCacheWithExpired() async {
        guard let expiredDate = Calendar.current.date(byAdding: .day, value: -31, to: Date()) else {
            XCTFail("Something went wrong generating a date in the past")
            return
        }
        let testFavicons = [FaviconURL(cacheKey: "amazon", faviconURL: "www.amazon.com", createdAt: Date()),
                            FaviconURL(cacheKey: "firefox", faviconURL: "www.firefox.com", createdAt: expiredDate)]
        let fileManager = MockURLCacheFileManager(data: getTestData(items: testFavicons))

        let subject = createSubject(fileManager: fileManager)
        let result1 = try? await subject.getURLFromCache(cacheKey: "amazon")
        XCTAssertEqual(result1?.absoluteString, "www.amazon.com")

        let result2 = try? await subject.getURLFromCache(cacheKey: "firefox")
        XCTAssertNil(result2)
    }

    func testInitializationDoesNotRetainCacheWhileRetrievalIsSuspended() async {
        let readStarted = expectation(description: "Initial cache retrieval started")
        let fileManager = MockURLCacheFileManager(readStarted: readStarted)
        var subject: DefaultFaviconURLCache? = createSubject(fileManager: fileManager)
        weak var weakSubject = subject

        await fulfillment(of: [readStarted], timeout: 5)
        subject = nil

        XCTAssertNil(weakSubject)
        await fileManager.resumeRead()
    }

    func testCacheURLPreservesNewValueAfterInitialRetrieval() async {
        let cacheKey = "firefox"
        let stored = FaviconURL(cacheKey: cacheKey, faviconURL: "https://firefox.com/old.ico", createdAt: Date())
        let readStarted = expectation(description: "Initial cache retrieval started")
        let fileManager = MockURLCacheFileManager(data: getTestData(items: [stored]), readStarted: readStarted)
        let subject = createSubject(fileManager: fileManager)
        await fulfillment(of: [readStarted], timeout: 5)

        let faviconURL = URL(string: "https://firefox.com/new.ico")!
        let updateRequested = expectation(description: "Cache update requested while retrieval is suspended")
        let update = Task {
            updateRequested.fulfill()
            await subject.cacheURL(cacheKey: cacheKey, faviconURL: faviconURL)
        }
        await fulfillment(of: [updateRequested], timeout: 5)
        await fileManager.resumeRead()
        await update.value

        let result = try? await subject.getURLFromCache(cacheKey: cacheKey)
        XCTAssertEqual(result, faviconURL)
        let readCount = await fileManager.readCount
        XCTAssertEqual(readCount, 1)
    }

    func testClearCacheDoesNotRestoreEntriesFromInitialRetrieval() async {
        let cacheKey = "firefox"
        let stored = FaviconURL(cacheKey: cacheKey, faviconURL: "https://firefox.com/favicon.ico", createdAt: Date())
        let readStarted = expectation(description: "Initial cache retrieval started")
        let fileManager = MockURLCacheFileManager(data: getTestData(items: [stored]), readStarted: readStarted)
        let subject = createSubject(fileManager: fileManager)
        await fulfillment(of: [readStarted], timeout: 5)

        let clearRequested = expectation(description: "Cache clear requested while retrieval is suspended")
        let clear = Task {
            clearRequested.fulfill()
            await subject.clearCache()
        }
        await fulfillment(of: [clearRequested], timeout: 5)
        await fileManager.resumeRead()
        await clear.value

        await assertAsyncThrowsEqual(SiteImageError.noURLInCache) {
            try await subject.getURLFromCache(cacheKey: cacheKey)
        }
        let readCount = await fileManager.readCount
        XCTAssertEqual(readCount, 1)
    }

    private func getTestData(items: [FaviconURL], file: String = #filePath, line: UInt = #line) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        do {
            try archiver.encodeEncodable(items, forKey: "favicon-url-cache")
        } catch {
            XCTFail("Something went wrong generating mock favicon data, file: \(file), line: \(line)")
        }
        return archiver.encodedData
    }

    func createSubject(fileManager: URLCacheFileManager,
                       file: StaticString = #filePath,
                       line: UInt = #line) -> DefaultFaviconURLCache {
        let subject = DefaultFaviconURLCache(fileManager: fileManager)
        trackForMemoryLeaks(subject, file: file, line: line)
        return subject
    }
}

actor MockURLCacheFileManager: URLCacheFileManager {
    private let data: Data?
    private let readStarted: XCTestExpectation?
    private var shouldSuspendRead: Bool
    private var readContinuation: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0

    init(data: Data? = nil, readStarted: XCTestExpectation? = nil) {
        self.data = data
        self.readStarted = readStarted
        shouldSuspendRead = readStarted != nil
    }

    func getURLCache() async -> Data? {
        readCount += 1
        if shouldSuspendRead {
            await withCheckedContinuation { continuation in
                readContinuation = continuation
                readStarted?.fulfill()
            }
        }
        return data
    }

    func resumeRead() {
        shouldSuspendRead = false
        readContinuation?.resume()
        readContinuation = nil
    }

    func saveURLCache(data: Data) {}
}
