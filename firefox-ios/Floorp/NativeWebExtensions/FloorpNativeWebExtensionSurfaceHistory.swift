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
        if entries.isEmpty, let source {
            entries.append(source)
            currentIndex = entries.startIndex
        } else if let source, let currentIndex, entries.indices.contains(currentIndex) {
            entries[currentIndex] = source
        }

        discardForward()
        if currentEntry == destination { return }
        entries.append(destination)
        currentIndex = entries.index(before: entries.endIndex)
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
