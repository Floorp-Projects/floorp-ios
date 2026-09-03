// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// A small browser-owned history for navigations that destroy one WKWebView
/// and create another at the normal/extension-origin trust boundary.
struct FloorpNativeWebExtensionSurfaceHistory: Equatable {
    struct Entry: Equatable {
        let contextIdentifier: String?
        var url: URL
    }

    private(set) var entries = [Entry]()
    private(set) var currentIndex: Int?

    var canGoBack: Bool {
        guard let currentIndex else { return false }
        return currentIndex > entries.startIndex
    }

    var canGoForward: Bool {
        guard let currentIndex else { return false }
        return currentIndex < entries.index(before: entries.endIndex)
    }

    var currentEntry: Entry? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    var backTarget: Entry? {
        guard canGoBack, let currentIndex else { return nil }
        return entries[entries.index(before: currentIndex)]
    }

    var forwardTarget: Entry? {
        guard canGoForward, let currentIndex else { return nil }
        return entries[entries.index(after: currentIndex)]
    }

    mutating func commit(contextIdentifier: String?, url: URL) {
        let entry = Entry(contextIdentifier: contextIdentifier, url: url)
        guard let currentIndex, entries.indices.contains(currentIndex) else {
            entries = [entry]
            self.currentIndex = entries.startIndex
            return
        }
        entries[currentIndex] = entry
    }

    mutating func transition(
        from source: Entry?,
        to destination: Entry
    ) {
        transition(from: source.map { [$0] } ?? [], to: destination)
    }

    mutating func transition(
        from currentSurfaceHistory: [Entry],
        to destination: Entry
    ) {
        mergeCurrentSurfaceHistory(currentSurfaceHistory)

        discardForward()
        if currentEntry == destination { return }
        entries.append(destination)
        currentIndex = entries.index(before: entries.endIndex)
    }

    private mutating func mergeCurrentSurfaceHistory(_ history: [Entry]) {
        guard !history.isEmpty else { return }
        guard let currentIndex, entries.indices.contains(currentIndex) else {
            entries = history
            self.currentIndex = entries.index(before: entries.endIndex)
            return
        }

        guard let currentEntry = history.last else { return }
        entries[currentIndex] = currentEntry
        let existingPrefix = Array(entries[...currentIndex])
        let maximumOverlap = min(existingPrefix.count, history.count)
        let overlap = stride(from: maximumOverlap, through: 1, by: -1).first { count in
            existingPrefix.suffix(count).elementsEqual(history.suffix(count))
        } ?? 0
        let missingHistory = history.dropLast(overlap)
        guard !missingHistory.isEmpty else { return }

        let insertionIndex = currentIndex - overlap + 1
        entries.insert(contentsOf: missingHistory, at: insertionIndex)
        self.currentIndex = currentIndex + missingHistory.count
    }

    @discardableResult
    mutating func moveBack() -> Entry? {
        guard canGoBack, let currentIndex else { return nil }
        self.currentIndex = entries.index(before: currentIndex)
        return entries[self.currentIndex!]
    }

    @discardableResult
    mutating func moveForward() -> Entry? {
        guard canGoForward, let currentIndex else { return nil }
        self.currentIndex = entries.index(after: currentIndex)
        return entries[self.currentIndex!]
    }

    mutating func discardForward() {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return }
        let nextIndex = entries.index(after: currentIndex)
        if nextIndex < entries.endIndex {
            entries.removeSubrange(nextIndex...)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        currentIndex = nil
    }
}
