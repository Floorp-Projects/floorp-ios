// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import ToolbarKit

@MainActor
final class LocationTextFieldTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var textField: LocationTextField!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var themeManager: MockThemeManager!

    override func setUp() async throws {
        try await super.setUp()
        textField = LocationTextField(frame: .zero)
        themeManager = MockThemeManager()
    }

    override func tearDown() async throws {
        textField = nil
        themeManager = nil
        try await super.tearDown()
    }

    func testHandleInputModeDidChange_withNoLastMarkedText_doesNothing() {
        textField.text = "www.wikipedia.com"
        textField.setMarkedText("", selectedRange: NSRange())

        textField.handleInputModeDidChange()

        XCTAssertEqual(textField.text, "www.wikipedia.com")
    }

    func testHandleInputModeDidChange_withLastMarkedText_updatesTextAndSetsMarkedText() {
        textField.text = "www.wiki"
        textField.setInlineAutocompleteMarkedText("pedia.com")

        textField.handleInputModeDidChange()

        XCTAssertTrue(textField.text?.contains("www.wiki") ?? false)
        XCTAssertNotNil(textField.markedTextRange)
    }

    func testHandleInputModeDidChange_withJapaneseInput_removesInlineAutocomplete() {
        textField.text = "www.wiki"
        textField.setInlineAutocompleteMarkedText("pedia.com")

        textField.handleInputModeDidChange(primaryLanguage: "ja-JP")

        XCTAssertEqual(textField.text, "www.wiki")
        XCTAssertNil(textField.markedTextRange)
    }

    func testHandleInputModeDidChange_withRealIMEComposition_preservesMarkedText() {
        textField.text = "nihon"
        textField.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        let composedText = textField.text

        textField.handleInputModeDidChange(primaryLanguage: "ja-JP")

        XCTAssertEqual(textField.text, composedText)
        XCTAssertNotNil(textField.markedTextRange)
    }

    func testSupportsInlineAutocomplete_disablesCompositionSensitiveLanguages() {
        XCTAssertFalse(LocationTextField.supportsInlineAutocomplete(primaryLanguage: "ja-JP"))
        XCTAssertFalse(LocationTextField.supportsInlineAutocomplete(primaryLanguage: "zh-Hans"))
        XCTAssertFalse(LocationTextField.supportsInlineAutocomplete(primaryLanguage: "ko-KR"))
        XCTAssertTrue(LocationTextField.supportsInlineAutocomplete(primaryLanguage: "en-US"))
        XCTAssertTrue(LocationTextField.supportsInlineAutocomplete(primaryLanguage: nil))
    }

    func testApplyTheme_refreshesMarkedText() {
        textField.text = "github"
        // Move cursor to end of text before setting marked text
        if let endPosition = textField.position(from: textField.beginningOfDocument, offset: textField.text!.count-1) {
            textField.selectedTextRange = textField.textRange(from: endPosition, to: endPosition)
        }
        textField.setMarkedText(".com", selectedRange: .init())

        XCTAssertNotNil(textField.markedTextRange, "Marked text should exist before theme change.")

        themeManager.setManualTheme(to: .dark)
        textField.applyTheme(theme: themeManager.getCurrentTheme(for: .XCTestDefaultUUID))

        XCTAssertNotNil(textField.markedTextRange, "Marked text should still exist after theme change.")

        XCTAssertEqual(textField.text, "github.com")
    }

    func testApplyTheme_preservesInlineAutocompleteOwnership() {
        textField.text = "github"
        textField.setInlineAutocompleteMarkedText(".com")

        themeManager.setManualTheme(to: .dark)
        textField.applyTheme(theme: themeManager.getCurrentTheme(for: .XCTestDefaultUUID))
        textField.handleInputModeDidChange(primaryLanguage: "ja-JP")

        XCTAssertEqual(textField.text, "github")
        XCTAssertNil(textField.markedTextRange)
    }
}
