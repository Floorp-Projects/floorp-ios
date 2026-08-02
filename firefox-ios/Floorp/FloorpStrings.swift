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
            value: "Unable to open this web panel",
            comment: "Error shown when a custom web panel cannot be opened"
        )

        static let webPanelBack = NSLocalizedString(
            "Floorp.Drawer.WebPanelBack.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Back",
            comment: "Accessibility label for the web panel back button"
        )

        static let webPanelForward = NSLocalizedString(
            "Floorp.Drawer.WebPanelForward.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Forward",
            comment: "Accessibility label for the web panel forward button"
        )

        static let webPanelReload = NSLocalizedString(
            "Floorp.Drawer.WebPanelReload.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Reload",
            comment: "Accessibility label for the web panel reload button"
        )

        static let webPanelStopLoading = NSLocalizedString(
            "Floorp.Drawer.WebPanelStopLoading.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Stop loading",
            comment: "Accessibility label for the web panel stop-loading button"
        )

        static let webPanelHome = NSLocalizedString(
            "Floorp.Drawer.WebPanelHome.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Home",
            comment: "Accessibility label for the web panel home button"
        )

        static let webPanelOpenInMainBrowser = NSLocalizedString(
            "Floorp.Drawer.WebPanelOpenInMainBrowser.v1",
            tableName: "Floorp",
            bundle: .main,
            value: "Open in main browser",
            comment: "Accessibility label for opening the current web panel page in the main browser"
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

    // MARK: - Panel Registry

    enum PanelRegistry {
        static let title = string(
            "Floorp.PanelRegistry.Title.v1",
            value: "Manage Panels",
            comment: "Navigation title of the Floorp panel registry"
        )
        static let panelsSection = string(
            "Floorp.PanelRegistry.PanelsSection.v1",
            value: "Panels",
            comment: "Section heading for registered Floorp panels"
        )
        static let recoverySection = string(
            "Floorp.PanelRegistry.RecoverySection.v1",
            value: "Recovery",
            comment: "Section heading for panel recovery actions"
        )
        static let addWebPanel = string(
            "Floorp.PanelRegistry.AddWebPanel.v1",
            value: "Add Web Panel",
            comment: "Action and title for adding a custom Web panel"
        )
        static let editWebPanel = string(
            "Floorp.PanelRegistry.EditWebPanel.v1",
            value: "Edit Web Panel",
            comment: "Title of the custom Web panel editor"
        )
        static let done = string(
            "Floorp.PanelRegistry.Done.v1",
            value: "Done",
            comment: "Action that finishes panel management"
        )
        static let doneEditing = string(
            "Floorp.PanelRegistry.DoneEditing.v1",
            value: "Done Editing",
            comment: "Accessibility label for leaving panel edit mode"
        )
        static let edit = string(
            "Floorp.PanelRegistry.Edit.v1",
            value: "Edit",
            comment: "Action that edits a Web panel or enters panel edit mode"
        )
        static let cancel = string(
            "Floorp.PanelRegistry.Cancel.v1",
            value: "Cancel",
            comment: "Action that cancels Web panel editing"
        )
        static let saveAccessibilityLabel = string(
            "Floorp.PanelRegistry.SaveAccessibilityLabel.v1",
            value: "Save web panel",
            comment: "Accessibility label for the Web panel save button"
        )
        static let detailsSection = string(
            "Floorp.PanelRegistry.DetailsSection.v1",
            value: "Web Panel",
            comment: "Section heading for editable Web panel details"
        )
        static let builtInPanel = string(
            "Floorp.PanelRegistry.BuiltInPanel.v1",
            value: "Built-in Panel",
            comment: "Description of a built-in Floorp panel"
        )
        static let webPanel = string(
            "Floorp.PanelRegistry.WebPanel.v1",
            value: "Web Panel",
            comment: "Description of a custom Web panel"
        )
        static let removeFromSidebar = string(
            "Floorp.PanelRegistry.RemoveFromSidebar.v1",
            value: "Remove from Sidebar",
            comment: "Action that hides a built-in panel from the sidebar"
        )
        static let delete = string(
            "Floorp.PanelRegistry.Delete.v1",
            value: "Delete",
            comment: "Destructive action that deletes a custom Web panel"
        )
        static let restoreBuiltIns = string(
            "Floorp.PanelRegistry.RestoreBuiltIns.v1",
            value: "Restore Built-in Panels",
            comment: "Action that restores removed built-in panels"
        )
        static let restoreBuiltInsDescription = string(
            "Floorp.PanelRegistry.RestoreBuiltInsDescription.v1",
            value: "Add any missing built-in panels back to the sidebar.",
            comment: "Description of the built-in panel restoration action"
        )
        static let allBuiltInsVisible = string(
            "Floorp.PanelRegistry.AllBuiltInsVisible.v1",
            value: "All built-in panels are already in the sidebar.",
            comment: "Status shown when no built-in panels need restoration"
        )
        static let removeBuiltInTitle = string(
            "Floorp.PanelRegistry.RemoveBuiltInTitle.v1",
            value: "Remove from Sidebar?",
            comment: "Title confirming removal of a built-in panel"
        )
        private static let removeBuiltInMessageFormat = string(
            "Floorp.PanelRegistry.RemoveBuiltInMessage.v1",
            value: "Removing this panel does not delete its data. You can restore “%@” later from Manage Panels.",
            comment: "Message confirming removal of a built-in panel; argument is its title"
        )
        static let deleteWebPanelTitle = string(
            "Floorp.PanelRegistry.DeleteWebPanelTitle.v1",
            value: "Delete Web Panel?",
            comment: "Title confirming deletion of a custom Web panel"
        )
        private static let deleteWebPanelMessageFormat = string(
            "Floorp.PanelRegistry.DeleteWebPanelMessage.v1",
            value: "“%@” will be permanently removed from the sidebar.",
            comment: "Message confirming Web panel deletion; argument is its title"
        )
        static let panelLimitTitle = string(
            "Floorp.PanelRegistry.PanelLimitTitle.v1",
            value: "Panel Limit Reached",
            comment: "Title shown when the sidebar has the maximum number of panels"
        )
        static let panelLimitMessage = string(
            "Floorp.PanelRegistry.PanelLimitMessage.v1",
            value: "You can add up to 32 panels. Remove a panel before adding another.",
            comment: "Message shown when the 32-panel limit is reached"
        )
        static let lastPanelTitle = string(
            "Floorp.PanelRegistry.LastPanelTitle.v1",
            value: "Keep One Panel",
            comment: "Title shown when removal would leave the sidebar empty"
        )
        static let lastPanelMessage = string(
            "Floorp.PanelRegistry.LastPanelMessage.v1",
            value: "At least one panel must remain in the sidebar.",
            comment: "Message shown when the user tries to remove the last panel"
        )
        static let registryReadOnlyTitle = string(
            "Floorp.PanelRegistry.RegistryReadOnlyTitle.v1",
            value: "Newer Floorp Version Required",
            comment: "Title shown when a future panel registry cannot be changed"
        )
        static let registryReadOnlyMessage = string(
            "Floorp.PanelRegistry.RegistryReadOnlyMessage.v1",
            value: "These panel settings were created by a newer Floorp version and were left unchanged.",
            comment: "Message shown when a future panel registry is kept read-only"
        )
        static let editConflictTitle = string(
            "Floorp.PanelRegistry.EditConflictTitle.v1",
            value: "Panel Changed Elsewhere",
            comment: "Title shown when another window changed a Web panel during editing"
        )
        static let editConflictMessage = string(
            "Floorp.PanelRegistry.EditConflictMessage.v1",
            value: "This panel changed in another window. Close this editor and reopen it before saving.",
            comment: "Message preventing a stale Web panel edit from overwriting a newer edit"
        )
        static let operationFailedTitle = string(
            "Floorp.PanelRegistry.OperationFailedTitle.v1",
            value: "Couldn’t Update Panels",
            comment: "Title of a generic panel registry operation error"
        )
        static let operationFailedMessage = string(
            "Floorp.PanelRegistry.OperationFailedMessage.v1",
            value: "Your panels were not changed. Please try again.",
            comment: "Message shown when a panel registry operation fails"
        )
        static let validationFailedTitle = string(
            "Floorp.PanelRegistry.ValidationFailedTitle.v1",
            value: "Check Panel Details",
            comment: "Title shown when Web panel input is invalid"
        )
        static let invalidTitleMessage = string(
            "Floorp.PanelRegistry.InvalidTitleMessage.v1",
            value: "Enter a panel name of 100 characters or fewer.",
            comment: "Validation message for an invalid Web panel title"
        )
        static let invalidURLMessage = string(
            "Floorp.PanelRegistry.InvalidURLMessage.v1",
            value: "Enter a valid website address of 2,048 characters or fewer.",
            comment: "Validation message for an invalid Web panel URL"
        )
        static let unsupportedSchemeMessage = string(
            "Floorp.PanelRegistry.UnsupportedSchemeMessage.v1",
            value: "Web panels support only HTTP and HTTPS addresses.",
            comment: "Validation message for a Web panel URL with an unsupported scheme"
        )
        static let credentialsNotAllowedMessage = string(
            "Floorp.PanelRegistry.CredentialsNotAllowedMessage.v1",
            value: "Remove the username and password from the website address.",
            comment: "Validation message for credentials embedded in a Web panel URL"
        )
        static let unsupportedIconMessage = string(
            "Floorp.PanelRegistry.UnsupportedIconMessage.v1",
            value: "Choose one of the available panel icons.",
            comment: "Validation message for an unsupported Web panel icon"
        )
        static let titleField = string(
            "Floorp.PanelRegistry.TitleField.v1",
            value: "Name",
            comment: "Label for a custom Web panel name field"
        )
        static let titlePlaceholder = string(
            "Floorp.PanelRegistry.TitlePlaceholder.v1",
            value: "Panel name",
            comment: "Placeholder for a custom Web panel name field"
        )
        static let urlField = string(
            "Floorp.PanelRegistry.URLField.v1",
            value: "Website Address",
            comment: "Label for a custom Web panel URL field"
        )
        static let urlPlaceholder = string(
            "Floorp.PanelRegistry.URLPlaceholder.v1",
            value: "example.com",
            comment: "Placeholder for a custom Web panel URL field"
        )
        static let iconField = string(
            "Floorp.PanelRegistry.IconField.v1",
            value: "Icon",
            comment: "Label for a custom Web panel icon picker"
        )
        static let iconPlaceholder = string(
            "Floorp.PanelRegistry.IconPlaceholder.v1",
            value: "Choose an icon",
            comment: "Placeholder for a custom Web panel icon picker"
        )
        static let iconHelp = string(
            "Floorp.PanelRegistry.IconHelp.v1",
            value: "Choose an icon for the panel button in the sidebar.",
            comment: "Help text for the custom Web panel icon picker"
        )
        private static let globeIcon = string(
            "Floorp.PanelRegistry.Icon.Globe.v1",
            value: "Globe",
            comment: "Display name for the globe Web panel icon"
        )
        private static let linkIcon = string(
            "Floorp.PanelRegistry.Icon.Link.v1",
            value: "Link",
            comment: "Display name for the link Web panel icon"
        )
        private static let messageIcon = string(
            "Floorp.PanelRegistry.Icon.Message.v1",
            value: "Message",
            comment: "Display name for the message Web panel icon"
        )
        private static let mailIcon = string(
            "Floorp.PanelRegistry.Icon.Mail.v1",
            value: "Mail",
            comment: "Display name for the mail Web panel icon"
        )
        private static let calendarIcon = string(
            "Floorp.PanelRegistry.Icon.Calendar.v1",
            value: "Calendar",
            comment: "Display name for the calendar Web panel icon"
        )
        private static let documentIcon = string(
            "Floorp.PanelRegistry.Icon.Document.v1",
            value: "Document",
            comment: "Display name for the document Web panel icon"
        )
        private static let videoIcon = string(
            "Floorp.PanelRegistry.Icon.Video.v1",
            value: "Video",
            comment: "Display name for the video Web panel icon"
        )
        private static let starIcon = string(
            "Floorp.PanelRegistry.Icon.Star.v1",
            value: "Star",
            comment: "Display name for the star Web panel icon"
        )
        static let needsAttention = string(
            "Floorp.PanelRegistry.NeedsAttention.v1",
            value: "Needs Attention",
            comment: "Status shown for a legacy Web panel with invalid details"
        )
        private static let attentionHostFormat = string(
            "Floorp.PanelRegistry.AttentionHost.v1",
            value: "%1$@ · %2$@",
            comment: "Web panel subtitle containing a host and the Needs Attention status"
        )
        static let insecureHTTPStatus = string(
            "Floorp.PanelRegistry.InsecureHTTPStatus.v1",
            value: "Not Secure",
            comment: "Short status shown for a Web panel that uses HTTP"
        )
        private static let insecureHostFormat = string(
            "Floorp.PanelRegistry.InsecureHost.v1",
            value: "%1$@ · %2$@",
            comment: "Web panel subtitle containing a host and the Not Secure status"
        )
        static let insecureHTTPWarning = string(
            "Floorp.PanelRegistry.InsecureHTTPWarning.v1",
            value: "This site uses HTTP. Information sent to it is not encrypted.",
            comment: "Warning shown while editing a Web panel that uses HTTP"
        )
        static let moveUp = string(
            "Floorp.PanelRegistry.MoveUp.v1",
            value: "Move Up",
            comment: "Accessibility action that moves a panel earlier"
        )
        static let moveDown = string(
            "Floorp.PanelRegistry.MoveDown.v1",
            value: "Move Down",
            comment: "Accessibility action that moves a panel later"
        )
        static let reorderAccessibilityHint = string(
            "Floorp.PanelRegistry.ReorderAccessibilityHint.v1",
            value: "Use the reorder control or accessibility actions to move this panel.",
            comment: "Accessibility hint for a reorderable built-in panel"
        )
        static let webPanelAccessibilityHint = string(
            "Floorp.PanelRegistry.WebPanelAccessibilityHint.v1",
            value: "Double-tap to edit. Use the reorder control or accessibility actions to move this panel.",
            comment: "Accessibility hint for an editable and reorderable Web panel"
        )
        static let insecureHTTPAccessibilityHint = string(
            "Floorp.PanelRegistry.InsecureHTTPAccessibilityHint.v1",
            value: "Not secure. Double-tap to edit this HTTP panel.",
            comment: "Accessibility hint for a Web panel that uses HTTP"
        )
        static let needsAttentionAccessibilityHint = string(
            "Floorp.PanelRegistry.NeedsAttentionAccessibilityHint.v1",
            value: "This panel has invalid details. Double-tap to fix them.",
            comment: "Accessibility hint for a legacy Web panel that needs repair"
        )
        static let discardChangesTitle = string(
            "Floorp.PanelRegistry.DiscardChangesTitle.v1",
            value: "Discard Changes?",
            comment: "Title confirming dismissal of a modified Web panel draft"
        )
        static let discardChangesMessage = string(
            "Floorp.PanelRegistry.DiscardChangesMessage.v1",
            value: "Your unsaved Web panel changes will be lost.",
            comment: "Message confirming dismissal of a modified Web panel draft"
        )
        static let keepEditing = string(
            "Floorp.PanelRegistry.KeepEditing.v1",
            value: "Keep Editing",
            comment: "Action that returns to a modified Web panel draft"
        )
        static let discardChanges = string(
            "Floorp.PanelRegistry.DiscardChanges.v1",
            value: "Discard Changes",
            comment: "Destructive action that dismisses a modified Web panel draft"
        )
        private static let panelAccessibilityLabelFormat = string(
            "Floorp.PanelRegistry.PanelAccessibilityLabel.v1",
            value: "%1$@, %2$@",
            comment: "Accessibility label containing a panel title and panel kind"
        )
        static let restoredAnnouncement = string(
            "Floorp.PanelRegistry.RestoredAnnouncement.v1",
            value: "Built-in panels restored.",
            comment: "Accessibility announcement after restoring built-in panels"
        )
        private static let removedAnnouncementFormat = string(
            "Floorp.PanelRegistry.RemovedAnnouncement.v1",
            value: "%@ removed from the sidebar.",
            comment: "Accessibility announcement after removing a panel; argument is its title"
        )
        private static let moveAnnouncementFormat = string(
            "Floorp.PanelRegistry.MoveAnnouncement.v1",
            value: "%1$@ moved to position %2$d.",
            comment: "Accessibility announcement after moving a panel; arguments are title and position"
        )

        static func removeBuiltInMessage(title: String) -> String {
            String.localizedStringWithFormat(removeBuiltInMessageFormat, title)
        }

        static func deleteWebPanelMessage(title: String) -> String {
            String.localizedStringWithFormat(deleteWebPanelMessageFormat, title)
        }

        static func panelAccessibilityLabel(title: String, kind: String) -> String {
            String.localizedStringWithFormat(panelAccessibilityLabelFormat, title, kind)
        }

        static func insecureHost(host: String) -> String {
            String.localizedStringWithFormat(insecureHostFormat, host, insecureHTTPStatus)
        }

        static func attentionHost(host: String) -> String {
            String.localizedStringWithFormat(attentionHostFormat, host, needsAttention)
        }

        static func iconDisplayName(for systemName: String) -> String {
            switch systemName {
            case "link": return linkIcon
            case "bubble.left": return messageIcon
            case "envelope": return mailIcon
            case "calendar": return calendarIcon
            case "doc": return documentIcon
            case "play.rectangle": return videoIcon
            case "star": return starIcon
            default: return globeIcon
            }
        }

        static func removedAnnouncement(title: String) -> String {
            String.localizedStringWithFormat(removedAnnouncementFormat, title)
        }

        static func moveAnnouncement(title: String, position: Int) -> String {
            String.localizedStringWithFormat(moveAnnouncementFormat, title, position)
        }

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
        static let reorder = string(
            "Floorp.Notes.Reorder.v1",
            value: "Reorder Notes",
            comment: "Action that starts reordering Floorp notes"
        )
        static let reorderDone = string(
            "Floorp.Notes.ReorderDone.v1",
            value: "Done Reordering",
            comment: "Action that saves the staged Floorp note order"
        )
        static let reorderCancelledForChanges = string(
            "Floorp.Notes.ReorderCancelledForChanges.v1",
            value: "Notes changed elsewhere. Reordering was cancelled.",
            comment: "Announcement after an external Notes change invalidates staged reordering"
        )
        static let moveUp = string(
            "Floorp.Notes.MoveUp.v1",
            value: "Move Up",
            comment: "Accessibility action that moves a Floorp note up"
        )
        static let moveDown = string(
            "Floorp.Notes.MoveDown.v1",
            value: "Move Down",
            comment: "Accessibility action that moves a Floorp note down"
        )
        private static let moveAnnouncementFormat = string(
            "Floorp.Notes.MoveAnnouncement.v1",
            value: "%1$@ moved to position %2$ld of %3$ld.",
            comment: "Accessibility announcement after moving a note; note title, position, total"
        )
        static let reorderAccessibilityHint = string(
            "Floorp.Notes.ReorderAccessibilityHint.v1",
            value: "Use the reorder control or Move Up and Move Down actions, then choose Done.",
            comment: "Accessibility hint while Floorp notes are being reordered"
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
        static let conflictTitle = string(
            "Floorp.Notes.ConflictTitle.v1",
            value: "This Note Changed Elsewhere",
            comment: "Title shown when a Floorp note has a concurrent edit conflict"
        )
        static let conflictMessage = string(
            "Floorp.Notes.ConflictMessage.v1",
            value: "Reload the latest version, save your changes as a copy, or keep editing.",
            comment: "Recovery choices for a Floorp note edit conflict"
        )
        static let noteDeletedTitle = string(
            "Floorp.Notes.NoteDeletedTitle.v1",
            value: "This Note Was Deleted",
            comment: "Title shown when saving a Floorp note that was deleted elsewhere"
        )
        static let noteDeletedMessage = string(
            "Floorp.Notes.NoteDeletedMessage.v1",
            value: "Your changes are still here. Save them as a new note or keep editing.",
            comment: "Recovery choices when a Floorp note was deleted elsewhere"
        )
        static let archiveTooLargeSaveTitle = string(
            "Floorp.Notes.ArchiveTooLargeSaveTitle.v1",
            value: "Notes Storage Is Full",
            comment: "Title shown when a Floorp note would exceed the local archive limit"
        )
        static let archiveTooLargeSaveMessage = string(
            "Floorp.Notes.ArchiveTooLargeSaveMessage.v1",
            value: "Shorten this note or remove another note, then try again. Your changes are still here.",
            comment: "Recovery guidance when the Floorp Notes archive is too large"
        )
        static let damagedSaveTitle = string(
            "Floorp.Notes.DamagedSaveTitle.v1",
            value: "Notes Data Needs Recovery",
            comment: "Title shown when saving is blocked by a damaged notes archive"
        )
        static let damagedSaveMessage = string(
            "Floorp.Notes.DamagedSaveMessage.v1",
            value: "Close this editor and use the recovery action in the Notes panel. Your changes remain on screen.",
            comment: "Recovery guidance when saving is blocked by archive corruption"
        )
        static let newerSchemaSaveTitle = string(
            "Floorp.Notes.NewerSchemaSaveTitle.v1",
            value: "A Newer Floorp Version Is Required",
            comment: "Title shown when the notes archive uses a newer schema"
        )
        static let newerSchemaSaveMessage = string(
            "Floorp.Notes.NewerSchemaSaveMessage.v1",
            value: "This version cannot change the newer Notes data. The archive was left untouched.",
            comment: "Message shown when saving to a newer notes schema is blocked"
        )
        static let saveErrorTitle = string(
            "Floorp.Notes.SaveErrorTitle.v1",
            value: "Couldn’t Save This Note",
            comment: "Title shown for a retryable Floorp note persistence error"
        )
        static let saveErrorMessage = string(
            "Floorp.Notes.SaveErrorMessage.v1",
            value: "Your changes are still here. Check available storage and try again.",
            comment: "Message shown for a retryable Floorp note persistence error"
        )
        static let reload = string(
            "Floorp.Notes.Reload.v1",
            value: "Reload Latest",
            comment: "Action that reloads the latest persisted Floorp note"
        )
        static let saveCopy = string(
            "Floorp.Notes.SaveCopy.v1",
            value: "Save as Copy",
            comment: "Action that saves conflicting Floorp note changes as a new note"
        )
        static let retry = string(
            "Floorp.Notes.Retry.v1",
            value: "Retry Save",
            comment: "Action that retries saving a Floorp note"
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

        static func moveAnnouncement(title: String, position: Int, total: Int) -> String {
            String.localizedStringWithFormat(moveAnnouncementFormat, title, position, total)
        }

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
