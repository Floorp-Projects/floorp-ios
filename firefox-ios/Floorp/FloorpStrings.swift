// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Floorp Strings
// Localized string keys for Floorp features.
// Follows Firefox iOS pattern of struct-based string organization.
//
// This file is part of the Floorp customization layer.

import Foundation

/// Centralized localization strings for Floorp features.
///
/// Uses `NSLocalizedString` with a `Floorp` table name to keep
/// Floorp strings separate from Firefox's main string table.
///
/// ## Adding new strings:
/// 1. Add a static property here with a unique key and version suffix
/// 2. Add the localized value in `Floorp.strings` (or `Floorp.stringsdict`)
/// 3. Use `FloorpStrings.Section.propertyName` in code
///
/// ## Naming convention:
/// - Key format: `Floorp.<Section>.<Name>.v<Version>`
/// - Example: `Floorp.Drawer.Title.v1`
enum FloorpStrings {
    // MARK: - Overlay Drawer

    enum Drawer {
        static let title = NSLocalizedString(
            "Floorp.Drawer.Title.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Floorp",
            comment: "Title displayed at the top of the overlay drawer"
        )

        static let closeAccessibilityLabel = NSLocalizedString(
            "Floorp.Drawer.CloseAccessibility.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Close drawer",
            comment: "Accessibility label for the close button in the overlay drawer"
        )

        static let bookmarksTab = NSLocalizedString(
            "Floorp.Drawer.BookmarksTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Bookmarks",
            comment: "Tab title for the bookmarks section in the overlay drawer"
        )

        static let historyTab = NSLocalizedString(
            "Floorp.Drawer.HistoryTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "History",
            comment: "Tab title for the history section in the overlay drawer"
        )

        static let noItemsFound = NSLocalizedString(
            "Floorp.Drawer.NoItemsFound.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "No items found",
            comment: "Empty state message when no bookmarks or history items are found"
        )

        static let retryButton = NSLocalizedString(
            "Floorp.Drawer.RetryButton.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Retry",
            comment: "Button label to retry loading bookmarks or history"
        )

        static let bookmarksLoadError = NSLocalizedString(
            "Floorp.Drawer.BookmarksLoadError.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Failed to load bookmarks",
            comment: "Error message when bookmarks fail to load"
        )

        static let historyLoadError = NSLocalizedString(
            "Floorp.Drawer.HistoryLoadError.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Failed to load history",
            comment: "Error message when history fails to load"
        )

        static let downloadsTab = NSLocalizedString(
            "Floorp.Drawer.DownloadsTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Downloads",
            comment: "Tab title for the downloads section in the overlay drawer"
        )

        static let downloadsLoadError = NSLocalizedString(
            "Floorp.Drawer.DownloadsLoadError.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Failed to load downloads",
            comment: "Error message when downloads fail to load"
        )

        static let noDownloads = NSLocalizedString(
            "Floorp.Drawer.NoDownloads.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "No downloads yet",
            comment: "Empty state message when no downloads are found"
        )

        static let webPanelUnavailable = NSLocalizedString(
            "Floorp.Drawer.WebPanelUnavailable.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Web panels are not available yet",
            comment: "Empty state for an unsupported custom web panel"
        )

        static let searchPlaceholder = NSLocalizedString(
            "Floorp.Drawer.SearchPlaceholder.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Search…",
            comment: "Placeholder text for the search field in the overlay drawer"
        )

        static let searchFieldAccessibility = NSLocalizedString(
            "Floorp.Drawer.SearchFieldAccessibility.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Search items",
            comment: "Accessibility label for the search field in the overlay drawer"
        )

        static let clearSearchAccessibility = NSLocalizedString(
            "Floorp.Drawer.ClearSearchAccessibility.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Clear search",
            comment: "Accessibility label for the clear search button"
        )

        static let panelSidebarAccessibility = NSLocalizedString(
            "Floorp.Drawer.PanelSidebarAccessibility.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Panel sidebar",
            comment: "Accessibility label for the vertical icon sidebar"
        )

        static let openInNewTab = NSLocalizedString(
            "Floorp.Drawer.OpenInNewTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Open in New Tab",
            comment: "Context menu option to open an item in a new tab"
        )

        static let openInPrivateTab = NSLocalizedString(
            "Floorp.Drawer.OpenInPrivateTab.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Open in Private Tab",
            comment: "Context menu option to open an item in a private tab"
        )

        static let deleteItem = NSLocalizedString(
            "Floorp.Drawer.DeleteItem.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Delete",
            comment: "Context menu option to delete an item"
        )
    }

    // MARK: - Notes

    enum Notes {
        static let panelTitle = string(
            "Floorp.Notes.PanelTitle.v1",
            value: "Notes",
            comment: "Title of the Floorp Notes drawer panel"
        )
        static let newNote = string(
            "Floorp.Notes.NewNote.v1",
            value: "New Note",
            comment: "Default title and action for creating a Floorp note"
        )
        static let untitled = string(
            "Floorp.Notes.Untitled.v1",
            value: "Untitled",
            comment: "Fallback title for a Floorp note with an empty title"
        )
        static let noNotes = string(
            "Floorp.Notes.NoNotes.v1",
            value: "No notes yet. Tap + to create one.",
            comment: "Empty state for the Floorp Notes list"
        )
        static let noSearchResults = string(
            "Floorp.Notes.NoSearchResults.v1",
            value: "No notes match your search",
            comment: "Empty state for Floorp Notes search"
        )
        static let searchPlaceholder = string(
            "Floorp.Notes.SearchPlaceholder.v1",
            value: "Search notes…",
            comment: "Placeholder for Floorp Notes search"
        )
        static let loadFailed = string(
            "Floorp.Notes.LoadFailed.v1",
            value: "Failed to load notes",
            comment: "Message shown when Floorp Notes cannot be read"
        )
        static let deleteTitle = string(
            "Floorp.Notes.DeleteTitle.v1",
            value: "Delete Note?",
            comment: "Title of the Floorp note deletion confirmation"
        )
        static let deleteMessage = string(
            "Floorp.Notes.DeleteMessage.v1",
            value: "This note will be permanently deleted.",
            comment: "Message in the Floorp note deletion confirmation"
        )
        static let delete = string(
            "Floorp.Notes.Delete.v1",
            value: "Delete",
            comment: "Destructive action for deleting a Floorp note"
        )
        static let cancel = string(
            "Floorp.Notes.Cancel.v1",
            value: "Cancel",
            comment: "Cancel action in Floorp Notes"
        )
        static let reset = string(
            "Floorp.Notes.Reset.v1",
            value: "Reset Notes",
            comment: "Action that resets a damaged Floorp Notes archive"
        )
        static let damagedDataMessage = string(
            "Floorp.Notes.DamagedDataMessage.v1",
            value: "The notes archive is damaged. A recovery copy was preserved. Reset it to continue.",
            comment: "Message displayed after preserving a damaged notes archive"
        )
        static let damagedDataCouldNotBePreservedMessage = string(
            "Floorp.Notes.DamagedDataCouldNotBePreservedMessage.v1",
            value: "The notes archive is damaged and could not be copied for recovery. It was left unchanged.",
            comment: "Message displayed when a damaged notes archive cannot be copied safely"
        )
        static let newerDataReadOnlyMessage = string(
            "Floorp.Notes.NewerDataReadOnlyMessage.v1",
            value: "These notes were created by a newer version of Floorp and were left unchanged.",
            comment: "Message shown when the local notes schema is newer than this app supports"
        )
        static let archiveTooLargeMessage = string(
            "Floorp.Notes.ArchiveTooLargeMessage.v1",
            value: "The notes archive is too large to open on this device and was left unchanged.",
            comment: "Message shown when the local notes archive exceeds the safety limit"
        )
        static let operationFailedTitle = string(
            "Floorp.Notes.OperationFailedTitle.v1",
            value: "Couldn’t Update Notes",
            comment: "Title of a generic Floorp Notes operation error"
        )
        static let operationFailedMessage = string(
            "Floorp.Notes.OperationFailedMessage.v1",
            value: "Your notes were not changed. Please try again.",
            comment: "Message shown when a Floorp Notes operation fails"
        )
        static let editorTitle = string(
            "Floorp.Notes.EditorTitle.v1",
            value: "Floorp Notes",
            comment: "Navigation title of the Floorp note editor"
        )
        static let titlePlaceholder = string(
            "Floorp.Notes.TitlePlaceholder.v1",
            value: "Title",
            comment: "Placeholder and accessibility label for a note title"
        )
        static let contentAccessibilityLabel = string(
            "Floorp.Notes.ContentAccessibilityLabel.v1",
            value: "Note content",
            comment: "Accessibility label for the note editor"
        )
        static let contentAccessibilityHint = string(
            "Floorp.Notes.ContentAccessibilityHint.v1",
            value: "Edits are saved automatically",
            comment: "Accessibility hint for the note editor"
        )
        static let close = string(
            "Floorp.Notes.Close.v1",
            value: "Close",
            comment: "Close action in the Floorp note editor"
        )
        static let save = string(
            "Floorp.Notes.Save.v1",
            value: "Save",
            comment: "Save action in the Floorp note editor"
        )
        static let saveAccessibilityLabel = string(
            "Floorp.Notes.SaveAccessibilityLabel.v1",
            value: "Save note",
            comment: "Accessibility label for the save note button"
        )
        static let saving = string(
            "Floorp.Notes.Saving.v1",
            value: "Saving…",
            comment: "Floorp note save status"
        )
        static let saved = string(
            "Floorp.Notes.Saved.v1",
            value: "Saved",
            comment: "Floorp note saved status"
        )
        static let saveFailed = string(
            "Floorp.Notes.SaveFailed.v1",
            value: "Save failed — your changes are still here. Tap Save to retry.",
            comment: "Floorp note save failure status"
        )
        static let richTextReadOnlyNotice = string(
            "Floorp.Notes.RichTextReadOnlyNotice.v1",
            value: "Rich formatting is preserved until you edit the content.",
            comment: "Notice for a rich-text note opened by the plain-text iOS editor"
        )
        static let unsupportedContentReadOnlyNotice = string(
            "Floorp.Notes.UnsupportedContentReadOnlyNotice.v1",
            value: "This body contains images or unsupported content. It is read-only on iOS and remains preserved.",
            comment: "Notice shown when a note body cannot be converted safely on iOS"
        )
        static let convertRichTextTitle = string(
            "Floorp.Notes.ConvertRichTextTitle.v1",
            value: "Convert to Plain Text?",
            comment: "Title of rich-text conversion confirmation"
        )
        static let convertRichTextMessage = string(
            "Floorp.Notes.ConvertRichTextMessage.v1",
            value: "Editing this note on iOS will remove its rich formatting. " +
                "The original is preserved unless you continue.",
            comment: "Message explaining destructive rich-text conversion"
        )
        static let convert = string(
            "Floorp.Notes.Convert.v1",
            value: "Convert and Edit",
            comment: "Action confirming rich-text conversion"
        )
        static let discardChangesTitle = string(
            "Floorp.Notes.DiscardChangesTitle.v1",
            value: "Close Without Saving?",
            comment: "Title of the alert offered after a note cannot be saved"
        )
        static let discardChangesMessage = string(
            "Floorp.Notes.DiscardChangesMessage.v1",
            value: "Your latest changes could not be saved. You can keep editing or discard them and close.",
            comment: "Message explaining that closing will discard an unsaved note draft"
        )
        static let keepEditing = string(
            "Floorp.Notes.KeepEditing.v1",
            value: "Keep Editing",
            comment: "Action that returns to an unsaved note draft"
        )
        static let discardChanges = string(
            "Floorp.Notes.DiscardChanges.v1",
            value: "Discard Changes",
            comment: "Destructive action that closes an unsaved note draft"
        )
        static let localOnly = string(
            "Floorp.Notes.LocalOnly.v1",
            value: "Stored on this device",
            comment: "Accessibility and UI notice that iOS Notes are not synced yet"
        )

        private static func string(_ key: String, value: String, comment: String) -> String {
            NSLocalizedString(
                key,
                tableName: "Floorp",
                bundle: .main,
                value: value,
                comment: comment
            )
        }
    }
}
