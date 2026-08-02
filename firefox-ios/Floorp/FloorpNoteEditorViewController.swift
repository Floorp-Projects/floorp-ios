// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import Common
import Photos
import PhotosUI
import Shared
import WebKit

@MainActor
protocol FloorpNotePersistence: AnyObject {
    func preflight(_ draft: FloorpNote) async throws
    func save(_ draft: FloorpNote) async throws -> FloorpNote
    func reload() async throws -> FloorpNote?
    func acceptReloaded(_ note: FloorpNote)
    func saveAsCopy(_ draft: FloorpNote) async throws -> FloorpNote
}

extension FloorpNotePersistence {
    func preflight(_ draft: FloorpNote) async throws {}
}

/// Owns the persistence identity for one editor session.
///
/// New drafts stay in memory until the editor reports its first change. Once
/// created, every later save uses the last persisted revision so concurrent
/// edits continue to be rejected by `FloorpNotesStore`.
@MainActor
final class FloorpNotePersistenceSession: FloorpNotePersistence {
    private let notesStore: FloorpNotesStore
    private let onCreatedNote: @MainActor (FloorpNote) -> Void
    private var persistedNote: FloorpNote?
    private var isOperating = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    init(
        notesStore: FloorpNotesStore,
        persistedNote: FloorpNote?,
        onCreatedNote: @escaping @MainActor (FloorpNote) -> Void = { _ in }
    ) {
        self.notesStore = notesStore
        self.persistedNote = persistedNote
        self.onCreatedNote = onCreatedNote
    }

    func save(_ draft: FloorpNote) async throws -> FloorpNote {
        await beginOperation()
        defer { finishOperation() }

        let savedNote: FloorpNote
        let isCreatingNote = persistedNote == nil
        if let persistedNote {
            savedNote = try await notesStore.updateNote(
                id: persistedNote.id,
                title: draft.title,
                content: draft.content,
                contentFormat: draft.contentFormat,
                expectedUpdatedAt: persistedNote.updatedAt
            )
        } else {
            savedNote = try await notesStore.createNote(
                title: draft.title,
                content: draft.content,
                contentFormat: draft.contentFormat
            )
        }
        persistedNote = savedNote
        if isCreatingNote {
            onCreatedNote(savedNote)
        }
        return savedNote
    }

    func preflight(_ draft: FloorpNote) async throws {
        if let persistedNote {
            try await notesStore.preflightUpdateNote(
                id: persistedNote.id,
                title: draft.title,
                content: draft.content,
                contentFormat: draft.contentFormat
            )
        } else {
            try await notesStore.preflightCreateNote(
                title: draft.title,
                content: draft.content,
                contentFormat: draft.contentFormat,
                candidateID: draft.id
            )
        }
    }

    func reload() async throws -> FloorpNote? {
        await beginOperation()
        defer { finishOperation() }
        guard let persistedNote else { return nil }
        return try await notesStore.loadNotes().first { $0.id == persistedNote.id }
    }

    func acceptReloaded(_ note: FloorpNote) {
        persistedNote = note
    }

    func saveAsCopy(_ draft: FloorpNote) async throws -> FloorpNote {
        await beginOperation()
        defer { finishOperation() }
        let savedNote = try await notesStore.createNote(
            title: draft.title,
            content: draft.content,
            contentFormat: draft.contentFormat
        )
        persistedNote = savedNote
        onCreatedNote(savedNote)
        return savedNote
    }

    private func beginOperation() async {
        if isOperating {
            await withCheckedContinuation { continuation in
                operationWaiters.append(continuation)
            }
            await beginOperation()
            return
        }
        isOperating = true
    }

    private func finishOperation() {
        isOperating = false
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
final class FloorpNoteSaveCoordinator {
    enum FailureKind: Equatable, Hashable {
        case conflict
        case noteDeleted
        case archiveTooLarge
        case damagedArchive
        case newerSchema
        case storage
    }

    struct Failure {
        let kind: FailureKind
        let underlyingError: Error
    }

    enum SaveOutcome {
        case noChanges
        case saved(FloorpNote)
        case failed(Failure)
    }

    private let persistence: FloorpNotePersistence
    private(set) var draft: FloorpNote
    private(set) var changeVersion = 0
    private(set) var savedVersion = 0
    private(set) var hasPersistedNote: Bool
    private(set) var lastFailure: Failure?
    private var isSaving = false
    private var saveWaiters = [CheckedContinuation<Void, Never>]()

    var hasUnsavedChanges: Bool { savedVersion != changeVersion }

    init(draft: FloorpNote, isPersisted: Bool, persistence: FloorpNotePersistence) {
        self.draft = draft
        self.hasPersistedNote = isPersisted
        self.persistence = persistence
    }

    @discardableResult
    func updateTitle(_ title: String) -> Bool {
        guard draft.title != title else { return false }
        draft.title = title
        markChanged()
        return true
    }

    @discardableResult
    func updateContent(
        _ content: String,
        contentFormat: FloorpNoteContentFormat? = nil
    ) -> Bool {
        let nextFormat = contentFormat ?? draft.contentFormat
        guard draft.content != content || draft.contentFormat != nextFormat else { return false }
        draft.content = content
        draft.contentFormat = nextFormat
        markChanged()
        return true
    }

    func requestExplicitSave() {
        if !hasPersistedNote && !hasUnsavedChanges {
            markChanged()
        }
    }

    func preflightContentUpdate(
        _ content: String,
        contentFormat: FloorpNoteContentFormat
    ) async throws {
        while true {
            let candidateVersion = changeVersion
            var candidate = draft
            candidate.content = content
            candidate.contentFormat = contentFormat
            try await persistence.preflight(candidate)
            guard changeVersion != candidateVersion else { return }
        }
    }

    func saveLatest() async -> SaveOutcome {
        if isSaving {
            await withCheckedContinuation { continuation in
                saveWaiters.append(continuation)
            }
            if let lastFailure { return .failed(lastFailure) }
            return hasUnsavedChanges ? await saveLatest() : .noChanges
        }
        guard hasUnsavedChanges else { return .noChanges }

        isSaving = true
        var lastSavedNote: FloorpNote?

        repeat {
            let versionToSave = changeVersion
            let noteToSave = draft
            do {
                let persistedNote = try await persistence.save(noteToSave)
                savedVersion = versionToSave
                hasPersistedNote = true
                lastFailure = nil
                adoptPersistenceIdentity(from: persistedNote)
                lastSavedNote = persistedNote
            } catch {
                let failure = Failure(kind: Self.failureKind(for: error), underlyingError: error)
                lastFailure = failure
                finishSaving()
                return .failed(failure)
            }
        } while hasUnsavedChanges

        finishSaving()
        return lastSavedNote.map(SaveOutcome.saved) ?? .noChanges
    }

    func reload() async throws -> FloorpNote {
        let requestedVersion = changeVersion
        let requestedNoteID = draft.id
        await waitUntilIdle()
        isSaving = true
        defer { finishSaving() }
        guard changeVersion == requestedVersion, draft.id == requestedNoteID else {
            throw FloorpNotesStoreError.editConflict(requestedNoteID)
        }
        guard let note = try await persistence.reload() else {
            throw FloorpNotesStoreError.noteNotFound(draft.id)
        }
        guard changeVersion == requestedVersion, draft.id == requestedNoteID else {
            throw FloorpNotesStoreError.editConflict(requestedNoteID)
        }
        persistence.acceptReloaded(note)
        draft = note
        changeVersion = 0
        savedVersion = 0
        hasPersistedNote = true
        lastFailure = nil
        return note
    }

    func saveAsCopy() async -> SaveOutcome {
        await waitUntilIdle()
        isSaving = true
        let versionToSave = changeVersion
        let noteToSave = draft
        do {
            let persistedNote = try await persistence.saveAsCopy(noteToSave)
            savedVersion = versionToSave
            hasPersistedNote = true
            lastFailure = nil
            adoptPersistenceIdentity(from: persistedNote)
            finishSaving()
            if hasUnsavedChanges {
                return await saveLatest()
            }
            return .saved(persistedNote)
        } catch {
            let failure = Failure(kind: Self.failureKind(for: error), underlyingError: error)
            lastFailure = failure
            finishSaving()
            return .failed(failure)
        }
    }

    private func markChanged() {
        changeVersion += 1
        lastFailure = nil
    }

    private func adoptPersistenceIdentity(from persistedNote: FloorpNote) {
        draft = FloorpNote(
            id: persistedNote.id,
            title: draft.title,
            content: draft.content,
            createdAt: persistedNote.createdAt,
            updatedAt: persistedNote.updatedAt,
            contentFormat: draft.contentFormat
        )
    }

    private func finishSaving() {
        isSaving = false
        let waiters = saveWaiters
        saveWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitUntilIdle() async {
        if isSaving {
            await withCheckedContinuation { continuation in
                saveWaiters.append(continuation)
            }
            await waitUntilIdle()
        }
    }

    static func failureKind(for error: Error) -> FailureKind {
        switch error {
        case FloorpNotesStoreError.editConflict:
            return .conflict
        case FloorpNotesStoreError.noteNotFound:
            return .noteDeleted
        case FloorpNotesStoreError.archiveTooLarge, FloorpNotesStoreError.tooManyNotes:
            return .archiveTooLarge
        case FloorpNotesStoreError.corruptArchive,
             FloorpNotesStoreError.corruptArchiveCouldNotBePreserved,
             FloorpNotesStoreError.writesBlockedByCorruption:
            return .damagedArchive
        case FloorpNotesStoreError.unsupportedSchema:
            return .newerSchema
        default:
            return .storage
        }
    }
}

@MainActor
private final class FloorpNoteClosurePersistence: FloorpNotePersistence {
    private let onSave: @MainActor (FloorpNote) async throws -> FloorpNote

    init(onSave: @escaping @MainActor (FloorpNote) async throws -> FloorpNote) {
        self.onSave = onSave
    }

    func save(_ draft: FloorpNote) async throws -> FloorpNote {
        try await onSave(draft)
    }

    func reload() async throws -> FloorpNote? { nil }

    func acceptReloaded(_ note: FloorpNote) {}

    func saveAsCopy(_ draft: FloorpNote) async throws -> FloorpNote {
        try await onSave(draft)
    }
}

@MainActor
private final class FloorpBackgroundSaveLease {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        guard identifier == .invalid else { return }
        // UIApplication retains the expiration handler. Capturing this lease
        // keeps the identifier available even if the editor disappears while
        // iOS is suspending the app.
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Floorp Notes Save"
        ) { [self] in
            end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Native, local-first editor for a single Floorp note.
@MainActor
final class FloorpNoteEditorViewController: UIViewController, Themeable {
    var themeManager: ThemeManager
    var themeListenerCancellable: Any?
    let windowUUID: WindowUUID
    var currentWindowUUID: UUID? { windowUUID }

    private enum UX {
        static let padding: CGFloat = 16
        static let minimumControlHeight: CGFloat = 44
        static let autosaveDelayNanoseconds: UInt64 = 400_000_000
    }

    private enum SaveState {
        case idle
        case saving
        case saved
        case failed
    }

    private enum ContentEditorMode {
        case plainText
        case richText
        case readOnly
    }

    private let notificationCenter: NotificationProtocol
    private let saveCoordinator: FloorpNoteSaveCoordinator
    private var contentAnalysis: FloorpNoteContent.Analysis
    private var editorMode: ContentEditorMode
    private var richDocument: FloorpRichTextDocument?
    private var richSession: FloorpRichTextEditorSessionCursor?
    private var queuedRichUpdates = [FloorpRichTextUpdateEnvelope]()
    private var queuedRichStates = [FloorpRichTextStateEnvelope]()
    private var queuedRichCommands = [FloorpRichTextCommand]()
    private var isProcessingRichUpdates = false
    private var isRichCommandInFlight = false
    private var autosaveTask: Task<Void, Never>?
    private var savedStatusResetTask: Task<Void, Never>?
    private let backgroundSaveLease = FloorpBackgroundSaveLease()
    private let shouldFocusTitleOnFirstAppearance: Bool
    private var didApplyInitialFocus = false

    var currentRichTextSession: FloorpRichTextEditorSessionCursor? { richSession }

    private lazy var titleField: UITextField = {
        let field = UITextField()
        field.font = FXFontStyles.Bold.title3.scaledFont()
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .next
        field.borderStyle = .roundedRect
        field.placeholder = FloorpStrings.Notes.titlePlaceholder
        field.accessibilityLabel = FloorpStrings.Notes.titlePlaceholder
        field.accessibilityIdentifier = "Floorp.Notes.Editor.Title"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.addTarget(self, action: #selector(titleChanged), for: .editingChanged)
        return field
    }()

    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.font = FXFontStyles.Regular.caption1.scaledFont()
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .right
        label.numberOfLines = 0
        label.accessibilityIdentifier = "Floorp.Notes.Editor.Status.Idle"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var retrySaveButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle(FloorpStrings.Notes.retry, for: .normal)
        button.titleLabel?.font = FXFontStyles.Bold.caption1.scaledFont()
        button.accessibilityIdentifier = "Floorp.Notes.Editor.Retry"
        button.addTarget(self, action: #selector(retrySaveTapped), for: .touchUpInside)
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        let minimumWidth = button.widthAnchor.constraint(
            greaterThanOrEqualToConstant: UX.minimumControlHeight
        )
        let minimumHeight = button.heightAnchor.constraint(
            greaterThanOrEqualToConstant: UX.minimumControlHeight
        )
        minimumWidth.priority = .init(999)
        minimumHeight.priority = .init(999)
        NSLayoutConstraint.activate([minimumWidth, minimumHeight])
        return button
    }()

    private lazy var statusStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [statusLabel, retrySaveButton])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    private lazy var textView: UITextView = {
        let textView = UITextView()
        textView.font = FXFontStyles.Regular.body.scaledFont()
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.layer.cornerRadius = 12
        textView.layer.borderWidth = 1
        textView.accessibilityLabel = FloorpStrings.Notes.contentAccessibilityLabel
        textView.accessibilityHint = FloorpStrings.Notes.contentAccessibilityHint
        textView.accessibilityIdentifier = "Floorp.Notes.Editor.Body"
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        return textView
    }()

    private lazy var enableRichTextButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle(FloorpStrings.Notes.enableRichText, for: .normal)
        button.titleLabel?.font = FXFontStyles.Bold.body.scaledFont()
        button.accessibilityIdentifier = "Floorp.Notes.Editor.EnableRichText"
        button.addTarget(self, action: #selector(enableRichTextTapped), for: .touchUpInside)
        button.heightAnchor.constraint(
            greaterThanOrEqualToConstant: UX.minimumControlHeight
        ).isActive = true
        return button
    }()

    private lazy var richEditorView: FloorpRichTextWebEditorView = {
        let editor = FloorpRichTextWebEditorView()
        editor.delegate = self
        editor.layer.cornerRadius = 12
        editor.layer.borderWidth = 1
        editor.clipsToBounds = true
        return editor
    }()

    private lazy var richToolbarStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: richToolbarButtons)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.layoutMargins = UIEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.isLayoutMarginsRelativeArrangement = true
        return stack
    }()

    private lazy var richToolbarScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.accessibilityIdentifier = "Floorp.Notes.RichEditor.Toolbar"
        scrollView.accessibilityLabel = FloorpStrings.Notes.richTextToolbar
        scrollView.addSubview(richToolbarStackView)
        richToolbarStackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            richToolbarStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            richToolbarStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            richToolbarStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            richToolbarStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            richToolbarStackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        scrollView.heightAnchor.constraint(equalToConstant: UX.minimumControlHeight + 4).isActive = true
        return scrollView
    }()

    private lazy var contentStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            enableRichTextButton,
            richToolbarScrollView,
            textView,
            richEditorView,
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var undoButton = makeRichToolbarButton(
        identifier: "Undo",
        label: FloorpStrings.Notes.undo,
        symbolName: "arrow.uturn.backward",
        command: .undo
    )
    private lazy var redoButton = makeRichToolbarButton(
        identifier: "Redo",
        label: FloorpStrings.Notes.redo,
        symbolName: "arrow.uturn.forward",
        command: .redo
    )
    private lazy var heading1Button = makeRichToolbarButton(
        identifier: "Heading1",
        label: FloorpStrings.Notes.heading1,
        title: "H1",
        command: .toggleHeading(level: 1)
    )
    private lazy var heading2Button = makeRichToolbarButton(
        identifier: "Heading2",
        label: FloorpStrings.Notes.heading2,
        title: "H2",
        command: .toggleHeading(level: 2)
    )
    private lazy var heading3Button = makeRichToolbarButton(
        identifier: "Heading3",
        label: FloorpStrings.Notes.heading3,
        title: "H3",
        command: .toggleHeading(level: 3)
    )
    private lazy var boldButton = makeRichToolbarButton(
        identifier: "Bold",
        label: FloorpStrings.Notes.bold,
        symbolName: "bold",
        command: .toggleMark(.bold)
    )
    private lazy var italicButton = makeRichToolbarButton(
        identifier: "Italic",
        label: FloorpStrings.Notes.italic,
        symbolName: "italic",
        command: .toggleMark(.italic)
    )
    private lazy var underlineButton = makeRichToolbarButton(
        identifier: "Underline",
        label: FloorpStrings.Notes.underline,
        symbolName: "underline",
        command: .toggleMark(.underline)
    )
    private lazy var strikeButton = makeRichToolbarButton(
        identifier: "Strikethrough",
        label: FloorpStrings.Notes.strikethrough,
        symbolName: "strikethrough",
        command: .toggleMark(.strike)
    )
    private lazy var bulletButton = makeRichToolbarButton(
        identifier: "BulletList",
        label: FloorpStrings.Notes.bulletList,
        symbolName: "list.bullet",
        command: .toggleList(.bullet)
    )
    private lazy var orderedButton = makeRichToolbarButton(
        identifier: "OrderedList",
        label: FloorpStrings.Notes.orderedList,
        symbolName: "list.number",
        command: .toggleList(.ordered)
    )
    private lazy var alignLeftButton = makeRichToolbarButton(
        identifier: "AlignLeft",
        label: FloorpStrings.Notes.alignLeft,
        symbolName: "text.alignleft",
        command: .setAlignment(.left)
    )
    private lazy var alignCenterButton = makeRichToolbarButton(
        identifier: "AlignCenter",
        label: FloorpStrings.Notes.alignCenter,
        symbolName: "text.aligncenter",
        command: .setAlignment(.center)
    )
    private lazy var alignRightButton = makeRichToolbarButton(
        identifier: "AlignRight",
        label: FloorpStrings.Notes.alignRight,
        symbolName: "text.alignright",
        command: .setAlignment(.right)
    )
    private lazy var insertImageButton: UIButton = {
        let button = makeRichToolbarButton(
            identifier: "InsertImage",
            label: FloorpStrings.Notes.insertImage,
            symbolName: "photo.badge.plus",
            command: nil
        )
        button.addTarget(self, action: #selector(insertImageTapped), for: .touchUpInside)
        return button
    }()

    private var richToolbarButtons: [UIButton] {
        [
            undoButton,
            redoButton,
            heading1Button,
            heading2Button,
            heading3Button,
            boldButton,
            italicButton,
            underlineButton,
            strikeButton,
            bulletButton,
            orderedButton,
            alignLeftButton,
            alignCenterButton,
            alignRightButton,
            insertImageButton,
        ]
    }

    init(
        note: FloorpNote,
        windowUUID: WindowUUID,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        isPersisted: Bool = true,
        persistence: FloorpNotePersistence
    ) {
        let contentAnalysis = FloorpNoteContent.analyze(
            note.content,
            contentFormat: note.contentFormat
        )
        let richPreparation = FloorpRichTextEditorPreparation.prepare(note)
        self.contentAnalysis = contentAnalysis
        switch richPreparation {
        case .plainText:
            self.editorMode = .plainText
            self.richDocument = nil
            self.richSession = nil
        case .editable(let document, _):
            self.editorMode = .richText
            self.richDocument = document
            self.richSession = try? FloorpRichTextEditorSessionCursor(
                noteID: note.id,
                documentID: UUID().uuidString,
                generation: 0,
                revision: 0
            )
        case .readOnly:
            self.editorMode = .readOnly
            self.richDocument = nil
            self.richSession = nil
        }
        self.windowUUID = windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        self.shouldFocusTitleOnFirstAppearance = !isPersisted
        self.saveCoordinator = FloorpNoteSaveCoordinator(
            draft: note,
            isPersisted: isPersisted,
            persistence: persistence
        )
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(
        note: FloorpNote,
        windowUUID: WindowUUID,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        isPersisted: Bool = true,
        onSave: @escaping @MainActor (FloorpNote) async throws -> FloorpNote
    ) {
        self.init(
            note: note,
            windowUUID: windowUUID,
            themeManager: themeManager,
            notificationCenter: notificationCenter,
            isPersisted: isPersisted,
            persistence: FloorpNoteClosurePersistence(onSave: onSave)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = FloorpStrings.Notes.editorTitle
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: FloorpStrings.Notes.close,
            style: .plain,
            target: self,
            action: #selector(closeTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: FloorpStrings.Notes.save,
            style: .done,
            target: self,
            action: #selector(saveTapped)
        )
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "Floorp.Notes.Editor.Close"
        navigationItem.rightBarButtonItem?.accessibilityLabel = FloorpStrings.Notes.saveAccessibilityLabel
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "Floorp.Notes.Editor.Save"

        view.addSubview(titleField)
        view.addSubview(statusStackView)
        view.addSubview(contentStackView)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: UX.padding),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: UX.padding),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -UX.padding),
            titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: UX.minimumControlHeight),

            statusStackView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            statusStackView.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            statusStackView.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            statusStackView.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),

            contentStackView.topAnchor.constraint(equalTo: statusStackView.bottomAnchor, constant: 8),
            contentStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: UX.padding),
            contentStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -UX.padding),
            contentStackView.bottomAnchor.constraint(
                lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor,
                constant: -UX.padding
            ),
            contentStackView.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor,
                constant: -UX.padding
            ).withPriority(UILayoutPriority(749)),
            contentStackView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -UX.padding
            ).withPriority(.defaultHigh),
        ])

        titleField.text = saveCoordinator.draft.title
        textView.text = contentAnalysis.editorText
        configureContentEditor()
        updateSaveState(.idle)
        listenForThemeChanges(withNotificationCenter: notificationCenter)
        applyTheme()

        notificationCenter.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    deinit {
        autosaveTask?.cancel()
        savedStatusResetTask?.cancel()
        notificationCenter.removeObserver(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            endBackgroundSaveTask()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard shouldFocusTitleOnFirstAppearance, !didApplyInitialFocus else { return }
        didApplyInitialFocus = true
        titleField.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self, titleField.isFirstResponder else { return }
            titleField.selectAll(nil)
            UIAccessibility.post(notification: .screenChanged, argument: titleField)
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                title: FloorpStrings.Notes.save,
                action: #selector(saveTapped),
                input: "s",
                modifierFlags: .command,
                discoverabilityTitle: FloorpStrings.Notes.save
            ),
            UIKeyCommand(
                title: FloorpStrings.Notes.close,
                action: #selector(closeTapped),
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                discoverabilityTitle: FloorpStrings.Notes.close
            ),
        ]
    }

    override func accessibilityPerformEscape() -> Bool {
        closeTapped()
        return true
    }

    func applyTheme() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        let colors = theme.colors
        view.backgroundColor = colors.layer1
        titleField.backgroundColor = colors.layer3
        titleField.textColor = colors.textPrimary
        titleField.tintColor = colors.actionPrimary
        titleField.keyboardAppearance = theme.type.keyboardAppearence(isPrivate: false)
        statusLabel.textColor = colors.textSecondary
        retrySaveButton.tintColor = colors.actionPrimary
        textView.backgroundColor = colors.layer3
        textView.textColor = colors.textPrimary
        textView.tintColor = colors.actionPrimary
        textView.keyboardAppearance = theme.type.keyboardAppearence(isPrivate: false)
        textView.layer.borderColor = colors.borderPrimary.cgColor
        enableRichTextButton.tintColor = colors.actionPrimary
        richToolbarButtons.forEach { $0.tintColor = colors.actionPrimary }
        richEditorView.backgroundColor = colors.layer3
        richEditorView.layer.borderColor = colors.borderPrimary.cgColor
    }

    @objc private func titleChanged() {
        if saveCoordinator.updateTitle(titleField.text ?? "") {
            draftDidChange()
        }
    }

    @objc private func saveTapped() {
        Task { @MainActor in
            _ = await saveForExplicitRequest()
        }
    }

    @objc private func retrySaveTapped() {
        Task { @MainActor in
            _ = await saveForExplicitRequest()
        }
    }

    /// Saves in response to an explicit user request.
    ///
    /// An untouched new draft has no content change to autosave, but choosing
    /// Save is still an instruction to create it. Advancing the version also
    /// keeps a failed first save pending so it can be retried before dismissal.
    @discardableResult
    func saveForExplicitRequest() async -> Bool {
        autosaveTask?.cancel()
        saveCoordinator.requestExplicitSave()
        setInteractiveDismissalBlocked(saveCoordinator.hasUnsavedChanges)
        let outcome = await saveLatestDraft()
        if case .failed(let failure) = outcome {
            presentSaveFailure(failure)
            return false
        }
        return true
    }

    @objc private func closeTapped() {
        Task { @MainActor in
            autosaveTask?.cancel()
            if saveCoordinator.hasUnsavedChanges {
                let outcome = await saveLatestDraft()
                if case .failed(let failure) = outcome {
                    presentSaveFailure(failure)
                    return
                }
            }
            dismiss(animated: true)
        }
    }

    @objc private func applicationWillResignActive() {
        guard saveCoordinator.hasUnsavedChanges else { return }
        autosaveTask?.cancel()
        beginBackgroundSaveTask()
        Task { @MainActor [weak self] in
            _ = await self?.saveLatestDraft()
            self?.endBackgroundSaveTask()
        }
    }

    private func draftDidChange() {
        setInteractiveDismissalBlocked(true)
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UX.autosaveDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = await self?.saveLatestDraft()
        }
    }

    @discardableResult
    func saveLatestDraft() async -> FloorpNoteSaveCoordinator.SaveOutcome {
        guard saveCoordinator.hasUnsavedChanges else { return .noChanges }
        updateSaveState(.saving)
        let outcome = await saveCoordinator.saveLatest()
        setInteractiveDismissalBlocked(saveCoordinator.hasUnsavedChanges)
        switch outcome {
        case .noChanges:
            updateSaveState(.idle)
        case .saved:
            updateSaveState(.saved)
        case .failed:
            updateSaveState(.failed)
        }
        return outcome
    }

    private func setInteractiveDismissalBlocked(_ isBlocked: Bool) {
        isModalInPresentation = isBlocked
        navigationController?.isModalInPresentation = isBlocked
    }

    private func beginBackgroundSaveTask() {
        backgroundSaveLease.begin()
    }

    private func endBackgroundSaveTask() {
        backgroundSaveLease.end()
    }

    private func updateSaveState(_ state: SaveState) {
        savedStatusResetTask?.cancel()
        if case .failed = state {
            retrySaveButton.isHidden = false
        } else {
            retrySaveButton.isHidden = true
        }
        switch state {
        case .idle:
            statusLabel.accessibilityIdentifier = "Floorp.Notes.Editor.Status.Idle"
            switch editorMode {
            case .readOnly:
                statusLabel.text = FloorpStrings.Notes.unsupportedContentReadOnlyNotice
            case .plainText, .richText:
                statusLabel.text = nil
            }
            navigationItem.rightBarButtonItem?.isEnabled = true
        case .saving:
            statusLabel.text = FloorpStrings.Notes.saving
            statusLabel.accessibilityIdentifier = "Floorp.Notes.Editor.Status.Saving"
            navigationItem.rightBarButtonItem?.isEnabled = false
        case .saved:
            statusLabel.text = FloorpStrings.Notes.saved
            statusLabel.accessibilityIdentifier = "Floorp.Notes.Editor.Status.Saved"
            navigationItem.rightBarButtonItem?.isEnabled = true
            UIAccessibility.post(
                notification: .announcement,
                argument: FloorpStrings.Notes.saved
            )
            savedStatusResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self?.saveCoordinator.hasUnsavedChanges == false else { return }
                self?.updateSaveState(.idle)
            }
        case .failed:
            statusLabel.text = FloorpStrings.Notes.saveFailed
            statusLabel.accessibilityIdentifier = "Floorp.Notes.Editor.Status.Error"
            navigationItem.rightBarButtonItem?.isEnabled = true
            UIAccessibility.post(
                notification: .announcement,
                argument: FloorpStrings.Notes.saveFailed
            )
        }
    }

    private func presentSaveFailure(_ failure: FloorpNoteSaveCoordinator.Failure) {
        guard presentedViewController == nil else { return }

        let copyActionKinds: Set<FloorpNoteSaveCoordinator.FailureKind> = [.conflict, .noteDeleted]
        let alert = UIAlertController(
            title: saveFailureTitle(for: failure.kind),
            message: saveFailureMessage(for: failure.kind),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.Notes.keepEditing, style: .cancel))

        if failure.kind == .conflict {
            alert.addAction(
                UIAlertAction(title: FloorpStrings.Notes.reload, style: .destructive) { [weak self] _ in
                    self?.reloadAfterConflict()
                }
            )
        }
        if copyActionKinds.contains(failure.kind) {
            alert.addAction(
                UIAlertAction(title: FloorpStrings.Notes.saveCopy, style: .default) { [weak self] _ in
                    self?.saveCurrentDraftAsCopy()
                }
            )
        }
        if failure.kind == .storage {
            alert.addAction(
                UIAlertAction(title: FloorpStrings.Notes.retry, style: .default) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        _ = await self?.saveForExplicitRequest()
                    }
                }
            )
        }
        if failure.kind != .conflict {
            alert.addAction(
                UIAlertAction(title: FloorpStrings.Notes.discardChanges, style: .destructive) { [weak self] _ in
                    self?.dismissDiscardingChanges()
                }
            )
        }
        present(alert, animated: true)
    }

    private func saveFailureTitle(
        for kind: FloorpNoteSaveCoordinator.FailureKind
    ) -> String {
        switch kind {
        case .conflict:
            return FloorpStrings.Notes.conflictTitle
        case .noteDeleted:
            return FloorpStrings.Notes.noteDeletedTitle
        case .archiveTooLarge:
            return FloorpStrings.Notes.archiveTooLargeSaveTitle
        case .damagedArchive:
            return FloorpStrings.Notes.damagedSaveTitle
        case .newerSchema:
            return FloorpStrings.Notes.newerSchemaSaveTitle
        case .storage:
            return FloorpStrings.Notes.saveErrorTitle
        }
    }

    private func saveFailureMessage(
        for kind: FloorpNoteSaveCoordinator.FailureKind
    ) -> String {
        switch kind {
        case .conflict:
            return FloorpStrings.Notes.conflictMessage
        case .noteDeleted:
            return FloorpStrings.Notes.noteDeletedMessage
        case .archiveTooLarge:
            return FloorpStrings.Notes.archiveTooLargeSaveMessage
        case .damagedArchive:
            return FloorpStrings.Notes.damagedSaveMessage
        case .newerSchema:
            return FloorpStrings.Notes.newerSchemaSaveMessage
        case .storage:
            return FloorpStrings.Notes.saveErrorMessage
        }
    }

    private func reloadAfterConflict() {
        setReloadInteractionEnabled(false)
        updateSaveState(.saving)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { setReloadInteractionEnabled(true) }
            do {
                let note = try await saveCoordinator.reload()
                applyReloadedNote(note)
            } catch FloorpNotesStoreError.editConflict(let id) {
                updateSaveState(.failed)
                presentSaveFailure(
                    FloorpNoteSaveCoordinator.Failure(
                        kind: .conflict,
                        underlyingError: FloorpNotesStoreError.editConflict(id)
                    )
                )
            } catch {
                updateSaveState(.failed)
                presentSaveFailure(
                    FloorpNoteSaveCoordinator.Failure(kind: .storage, underlyingError: error)
                )
            }
        }
    }

    private func setReloadInteractionEnabled(_ isEnabled: Bool) {
        titleField.isEnabled = isEnabled
        textView.isEditable = isEnabled && editorMode == .plainText
        richEditorView.setEditable(isEnabled && editorMode == .richText)
        richToolbarButtons.forEach { $0.isEnabled = isEnabled }
        enableRichTextButton.isEnabled = isEnabled
        navigationItem.rightBarButtonItem?.isEnabled = isEnabled
    }

    private func saveCurrentDraftAsCopy() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            updateSaveState(.saving)
            let outcome = await saveCoordinator.saveAsCopy()
            switch outcome {
            case .noChanges, .saved:
                setInteractiveDismissalBlocked(saveCoordinator.hasUnsavedChanges)
                updateSaveState(.saved)
            case .failed(let failure):
                updateSaveState(.failed)
                presentSaveFailure(failure)
            }
        }
    }

    private func applyReloadedNote(_ note: FloorpNote) {
        autosaveTask?.cancel()
        contentAnalysis = FloorpNoteContent.analyze(
            note.content,
            contentFormat: note.contentFormat
        )
        applyRichPreparation(FloorpRichTextEditorPreparation.prepare(note), noteID: note.id)
        titleField.text = note.title
        textView.text = contentAnalysis.editorText
        configureContentEditor()
        setInteractiveDismissalBlocked(false)
        updateSaveState(.idle)
    }

    private func dismissDiscardingChanges() {
        autosaveTask?.cancel()
        setInteractiveDismissalBlocked(false)
        navigationController?.dismiss(animated: true)
    }

    private func configureContentEditor() {
        let showsRichEditor = editorMode == .richText
        enableRichTextButton.isHidden = editorMode != .plainText
        richToolbarScrollView.isHidden = !showsRichEditor
        richEditorView.isHidden = !showsRichEditor
        textView.isHidden = showsRichEditor
        textView.isEditable = editorMode == .plainText
        textView.accessibilityHint = editorMode == .readOnly
            ? FloorpStrings.Notes.unsupportedContentReadOnlyNotice
            : FloorpStrings.Notes.contentAccessibilityHint

        if showsRichEditor, let richDocument, let richSession {
            richEditorView.load(document: richDocument, session: richSession)
            richEditorView.setEditable(true)
        }
        undoButton.isEnabled = false
        redoButton.isEnabled = false
    }

    private func applyRichPreparation(
        _ preparation: FloorpRichTextEditorPreparation,
        noteID: String
    ) {
        queuedRichUpdates.removeAll()
        queuedRichStates.removeAll()
        queuedRichCommands.removeAll()
        isRichCommandInFlight = false
        switch preparation {
        case .plainText:
            editorMode = .plainText
            richDocument = nil
            richSession = nil
        case .editable(let document, _):
            editorMode = .richText
            richDocument = document
            richSession = try? FloorpRichTextEditorSessionCursor(
                noteID: noteID,
                documentID: UUID().uuidString,
                generation: 0,
                revision: 0
            )
        case .readOnly:
            editorMode = .readOnly
            richDocument = nil
            richSession = nil
        }
    }

    private func makeRichToolbarButton(
        identifier: String,
        label: String,
        symbolName: String? = nil,
        title: String? = nil,
        command: FloorpRichTextCommand?
    ) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = symbolName.flatMap { UIImage(systemName: $0) }
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        button.configuration = configuration
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "Floorp.Notes.RichEditor.\(identifier)"
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: UX.minimumControlHeight).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: UX.minimumControlHeight).isActive = true
        if let command {
            button.addAction(
                UIAction { [weak self] _ in
                    self?.enqueueRichCommand(command)
                },
                for: .touchUpInside
            )
        }
        return button
    }

    @objc private func enableRichTextTapped() {
        guard editorMode == .plainText else { return }
        enableRichTextButton.isEnabled = false
        let plainText = textView.text ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { enableRichTextButton.isEnabled = true }
            do {
                let document = try FloorpRichTextCodec.document(fromPlainText: plainText)
                let source = try FloorpRichTextCodec.encode(document)
                try await saveCoordinator.preflightContentUpdate(
                    source,
                    contentFormat: .automatic
                )
                richDocument = document
                richSession = try FloorpRichTextEditorSessionCursor(
                    noteID: saveCoordinator.draft.id,
                    documentID: UUID().uuidString,
                    generation: 0,
                    revision: 0
                )
                editorMode = .richText
                if saveCoordinator.updateContent(source, contentFormat: .automatic) {
                    draftDidChange()
                }
                configureContentEditor()
                UIAccessibility.post(notification: .layoutChanged, argument: richEditorView)
            } catch {
                presentPreflightFailure(error)
            }
        }
    }

    private func enqueueRichCommand(_ command: FloorpRichTextCommand) {
        guard editorMode == .richText else { return }
        queuedRichCommands.append(command)
        sendNextRichCommandIfPossible()
    }

    private func sendNextRichCommandIfPossible() {
        guard !isRichCommandInFlight,
              !isProcessingRichUpdates,
              queuedRichUpdates.isEmpty,
              let document = richDocument,
              let session = richSession,
              !queuedRichCommands.isEmpty else {
            return
        }
        let command = queuedRichCommands.removeFirst()
        do {
            let envelope = try FloorpRichTextCommandPlanner.plan(
                command,
                for: document,
                session: session
            )
            isRichCommandInFlight = true
            richEditorView.send(envelope) { [weak self] wasAccepted in
                guard let self, !wasAccepted else { return }
                isRichCommandInFlight = false
                queuedRichCommands.insert(command, at: 0)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    self?.sendNextRichCommandIfPossible()
                }
            }
        } catch {
            isRichCommandInFlight = false
        }
    }

    @objc private func insertImageTapped() {
        guard editorMode == .richText else { return }
        var configuration = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func processQueuedRichUpdates() {
        guard !isProcessingRichUpdates else { return }
        isProcessingRichUpdates = true
        Task { @MainActor [weak self] in
            await self?.drainQueuedRichUpdates()
        }
    }

    private func drainQueuedRichUpdates() async {
        while !queuedRichUpdates.isEmpty {
            let envelope = queuedRichUpdates.removeFirst()
            guard let document = richDocument, let session = richSession else {
                rejectPendingRichChanges()
                isProcessingRichUpdates = false
                return
            }
            do {
                let accepted = try FloorpRichTextEditorUpdatePolicy.accept(
                    envelope,
                    for: session,
                    replacing: document
                )
                let source = try FloorpRichTextCodec.encode(accepted.document)
                try await saveCoordinator.preflightContentUpdate(
                    source,
                    contentFormat: .automatic
                )
                guard richSession == session else { continue }
                richDocument = accepted.document
                richSession = accepted.session
                isRichCommandInFlight = false
                if saveCoordinator.updateContent(source, contentFormat: .automatic) {
                    draftDidChange()
                }
                applyQueuedRichStateIfPossible()
            } catch {
                rejectPendingRichChanges()
                presentPreflightFailure(error)
                isProcessingRichUpdates = false
                return
            }
        }
        isProcessingRichUpdates = false
        sendNextRichCommandIfPossible()
    }

    private func rejectPendingRichChanges() {
        queuedRichUpdates.removeAll()
        queuedRichStates.removeAll()
        queuedRichCommands.removeAll()
        isRichCommandInFlight = false
        guard let document = richDocument,
              let session = richSession,
              let replacement = try? FloorpRichTextEditorSessionCursor(
                noteID: session.noteID,
                documentID: UUID().uuidString,
                generation: min(
                    session.generation + 1,
                    FloorpRichTextBridgeProtocol.maximumSafeSequenceNumber
                ),
                revision: 0
              ) else {
            return
        }
        richSession = replacement
        richEditorView.load(document: document, session: replacement)
    }

    private func presentPreflightFailure(_ error: Error) {
        let kind = FloorpNoteSaveCoordinator.failureKind(for: error)
        updateSaveState(.failed)
        presentSaveFailure(
            FloorpNoteSaveCoordinator.Failure(kind: kind, underlyingError: error)
        )
    }

    private func applyRichEditorState(_ state: FloorpRichTextEditorState) {
        undoButton.isEnabled = state.canUndo
        redoButton.isEnabled = state.canRedo
        setSelected(heading1Button, state.activeHeadingLevel == 1)
        setSelected(heading2Button, state.activeHeadingLevel == 2)
        setSelected(heading3Button, state.activeHeadingLevel == 3)
        let marks = Set(state.activeMarks ?? [])
        setSelected(boldButton, marks.contains(.bold))
        setSelected(italicButton, marks.contains(.italic))
        setSelected(underlineButton, marks.contains(.underline))
        setSelected(strikeButton, marks.contains(.strike))
        setSelected(bulletButton, state.activeListKind == .bullet)
        setSelected(orderedButton, state.activeListKind == .ordered)
        setSelected(alignLeftButton, state.alignment == .left)
        setSelected(alignCenterButton, state.alignment == .center)
        setSelected(alignRightButton, state.alignment == .right)
    }

    private func applyQueuedRichStateIfPossible() {
        guard let session = richSession else { return }
        if let index = queuedRichStates.lastIndex(where: { $0.session == session }) {
            let envelope = queuedRichStates.remove(at: index)
            queuedRichStates.removeAll { $0.session.revision <= session.revision }
            if let state = try? FloorpRichTextEditorStatePolicy.accept(envelope, for: session) {
                applyRichEditorState(state)
            }
        }
    }

    private func setSelected(_ button: UIButton, _ isSelected: Bool) {
        button.isSelected = isSelected
        if isSelected {
            button.accessibilityTraits.insert(.selected)
            button.configuration?.baseBackgroundColor = button.tintColor.withAlphaComponent(0.18)
        } else {
            button.accessibilityTraits.remove(.selected)
            button.configuration?.baseBackgroundColor = .clear
        }
    }
}

extension FloorpNoteEditorViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if editorMode == .richText {
            richEditorView.focus()
        } else {
            textView.becomeFirstResponder()
        }
        return false
    }
}

extension FloorpNoteEditorViewController: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        editorMode == .plainText
    }

    func textViewDidChange(_ textView: UITextView) {
        guard editorMode == .plainText else { return }
        if saveCoordinator.updateContent(textView.text, contentFormat: .plainText) {
            draftDidChange()
        }
    }
}

extension FloorpNoteEditorViewController: FloorpRichTextWebEditorDelegate {
    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        received update: FloorpRichTextUpdateEnvelope
    ) {
        guard queuedRichUpdates.count < 128 else {
            rejectPendingRichChanges()
            return
        }
        queuedRichUpdates.append(update)
        processQueuedRichUpdates()
    }

    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        received state: FloorpRichTextStateEnvelope
    ) {
        guard let session = richSession,
              state.schemaVersion == FloorpRichTextBridgeProtocol.currentSchemaVersion,
              state.session.noteID == session.noteID,
              state.session.documentID == session.documentID,
              state.session.generation == session.generation else {
            return
        }
        if let accepted = try? FloorpRichTextEditorStatePolicy.accept(state, for: session) {
            applyRichEditorState(accepted)
            return
        }
        guard state.session.revision > session.revision else { return }
        queuedRichStates.append(state)
        if queuedRichStates.count > 32 {
            queuedRichStates.removeFirst(queuedRichStates.count - 32)
        }
    }
}

extension FloorpNoteEditorViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let richImage = FloorpRichTextImageEncoder.encode(image) else {
                    return
                }
                enqueueRichCommand(.insertImage(richImage))
            }
        }
    }
}

@MainActor
enum FloorpRichTextImageEncoder {
    static func encode(_ image: UIImage) -> FloorpRichTextImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        var maximumDimension: CGFloat = 1_600
        var quality: CGFloat = 0.82

        for _ in 0..<12 {
            let scale = min(
                1,
                maximumDimension / max(image.size.width, image.size.height)
            )
            let size = CGSize(
                width: max(1, floor(image.size.width * scale)),
                height: max(1, floor(image.size.height * scale))
            )
            let renderer = UIGraphicsImageRenderer(size: size)
            let normalized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = normalized.jpegData(compressionQuality: quality) else { return nil }
            let source = "data:image/jpeg;base64," + data.base64EncodedString()
            if FloorpRichTextImagePolicy.isSafePersistedSource(source) {
                let width = Int(size.width.rounded())
                return FloorpRichTextImage(
                    source: source,
                    width: FloorpRichTextImagePolicy.allowedDisplayWidth.contains(width)
                        ? width
                        : nil
                )
            }
            if quality > 0.45 {
                quality -= 0.09
            } else {
                maximumDimension *= 0.75
            }
        }
        return nil
    }
}

@MainActor
protocol FloorpRichTextWebEditorDelegate: AnyObject {
    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        received update: FloorpRichTextUpdateEnvelope
    )
    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        received state: FloorpRichTextStateEnvelope
    )
}

@MainActor
private final class FloorpWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class FloorpRichTextWebEditorView: UIView, WKNavigationDelegate, WKScriptMessageHandler {
    private enum BridgeName {
        static let update = "floorpRichTextUpdate"
        static let state = "floorpRichTextState"
    }

    weak var delegate: FloorpRichTextWebEditorDelegate?

    private let webView: WKWebView
    private var messageHandlerProxy: FloorpWeakScriptMessageHandler?
    private var pendingDocument: FloorpRichTextDocument?
    private var pendingSession: FloorpRichTextEditorSessionCursor?
    private var isPageReady = false

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)

        let proxy = FloorpWeakScriptMessageHandler(target: self)
        messageHandlerProxy = proxy
        controller.add(proxy, name: BridgeName.update)
        controller.add(proxy, name: BridgeName.state)

        accessibilityIdentifier = "Floorp.Notes.RichEditor.Container"
        webView.accessibilityIdentifier = "Floorp.Notes.RichEditor.Body"
        webView.accessibilityLabel = FloorpStrings.Notes.contentAccessibilityLabel
        webView.accessibilityHint = FloorpStrings.Notes.contentAccessibilityHint
        webView.navigationDelegate = self
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        webView.loadHTMLString(Self.editorHTML, baseURL: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(
        document: FloorpRichTextDocument,
        session: FloorpRichTextEditorSessionCursor
    ) {
        pendingDocument = document
        pendingSession = session
        loadPendingDocumentIfPossible()
    }

    func send(
        _ command: FloorpRichTextCommandEnvelope,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let commandObject = jsonObject(command) else {
            completion(false)
            return
        }
        webView.callAsyncJavaScript(
            "return window.floorpApplyCommand(command);",
            arguments: ["command": commandObject],
            in: nil,
            in: .page
        ) { result in
            switch result {
            case .success(let value):
                completion(value as? Bool == true)
            case .failure:
                completion(false)
            }
        }
    }

    func setEditable(_ isEditable: Bool) {
        webView.callAsyncJavaScript(
            "return window.floorpSetEditable(isEditable);",
            arguments: ["isEditable": isEditable],
            in: nil,
            in: .page
        ) { _ in }
    }

    func focus() {
        webView.callAsyncJavaScript(
            "document.getElementById('editor').focus(); return true;",
            arguments: [:],
            in: nil,
            in: .page
        ) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isPageReady = true
        loadPendingDocumentIfPossible()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let isEditorDocument = navigationAction.request.url?.scheme == "about"
        decisionHandler(isEditorDocument ? .allow : .cancel)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body) else {
            return
        }
        let decoder = JSONDecoder()
        switch message.name {
        case BridgeName.update:
            guard let envelope = try? decoder.decode(
                FloorpRichTextUpdateEnvelope.self,
                from: data
            ) else { return }
            delegate?.richTextEditor(self, received: envelope)
        case BridgeName.state:
            guard let envelope = try? decoder.decode(
                FloorpRichTextStateEnvelope.self,
                from: data
            ) else { return }
            delegate?.richTextEditor(self, received: envelope)
        default:
            break
        }
    }

    private func loadPendingDocumentIfPossible() {
        guard isPageReady,
              let document = pendingDocument,
              let session = pendingSession,
              let source = try? FloorpRichTextCodec.encode(document),
              let sourceData = source.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: sourceData),
              let sessionObject = jsonObject(session) else {
            return
        }
        pendingDocument = nil
        pendingSession = nil
        webView.callAsyncJavaScript(
            "return window.floorpLoad(root, session);",
            arguments: ["root": root, "session": sessionObject],
            in: nil,
            in: .page
        ) { _ in }
    }

    private func jsonObject<Value: Encodable>(_ value: Value) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static let editorHTML = #"""
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
      <meta http-equiv="Content-Security-Policy"
            content="default-src 'none'; img-src data: https:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
      <style>
        :root { color-scheme: light dark; }
        html, body { min-height: 100%; margin: 0; padding: 0; background: transparent; }
        #editor {
          box-sizing: border-box;
          min-height: 100vh;
          padding: 12px 10px 40px;
          outline: none;
          font: -apple-system-body;
          overflow-wrap: anywhere;
          -webkit-user-select: text;
        }
        #editor:empty::before { content: attr(data-placeholder); opacity: 0.55; }
        h1 { font: -apple-system-title1; font-weight: 700; }
        h2 { font: -apple-system-title2; font-weight: 700; }
        h3 { font: -apple-system-title3; font-weight: 700; }
        blockquote {
          border-inline-start: 3px solid currentColor;
          margin-inline-start: 0;
          padding-inline-start: 12px;
          opacity: 0.85;
        }
        pre { white-space: pre-wrap; font-family: ui-monospace, monospace; }
        img { display: block; height: auto; max-width: 100%; margin: 8px 0; }
      </style>
    </head>
    <body>
      <div id="editor" contenteditable="true" role="textbox" aria-multiline="true"
           aria-label="Note content" data-placeholder="Write a note…"></div>
      <script>
      (() => {
        const editor = document.getElementById('editor');
        let session = null;
        let suppressUpdates = false;

        const clone = (value) => JSON.parse(JSON.stringify(value));
        const withAttrs = (element, attrs) => {
          if (!attrs) return element;
          if (typeof attrs.textAlign === 'string') element.style.textAlign = attrs.textAlign;
          return element;
        };
        const appendChildren = (element, children) => {
          (children || []).forEach((child) => element.appendChild(renderNode(child)));
          return element;
        };
        const renderText = (node) => {
          let result = document.createTextNode(node.text || '');
          (node.marks || []).forEach((mark) => {
            const names = { bold: 'strong', italic: 'em', underline: 'u', strike: 's', code: 'code' };
            const tag = names[mark.type];
            if (!tag) return;
            const wrapper = document.createElement(tag);
            wrapper.appendChild(result);
            result = wrapper;
          });
          return result;
        };
        const renderNode = (node) => {
          let element;
          switch (node.type) {
            case 'text': return renderText(node);
            case 'hardBreak': return document.createElement('br');
            case 'paragraph':
              return appendChildren(withAttrs(document.createElement('p'), node.attrs), node.content);
            case 'heading':
              element = document.createElement(`h${Math.min(6, Math.max(1, node.attrs?.level || 1))}`);
              return appendChildren(withAttrs(element, node.attrs), node.content);
            case 'blockquote':
              return appendChildren(document.createElement('blockquote'), node.content);
            case 'codeBlock':
              element = document.createElement('pre');
              if (node.attrs?.language) element.dataset.language = node.attrs.language;
              return appendChildren(element, node.content);
            case 'horizontalRule': return document.createElement('hr');
            case 'bulletList': return appendChildren(document.createElement('ul'), node.content);
            case 'orderedList':
              element = document.createElement('ol');
              if (Number.isInteger(node.attrs?.start)) element.start = node.attrs.start;
              if (typeof node.attrs?.type === 'string') element.type = node.attrs.type;
              return appendChildren(element, node.content);
            case 'listItem': return appendChildren(document.createElement('li'), node.content);
            case 'image':
              element = document.createElement('img');
              element.src = node.attrs?.src || '';
              if (typeof node.attrs?.alt === 'string') element.alt = node.attrs.alt;
              if (typeof node.attrs?.title === 'string') element.title = node.attrs.title;
              if (Number.isInteger(node.attrs?.width)) element.width = node.attrs.width;
              element.contentEditable = 'false';
              return element;
            default: return document.createTextNode('');
          }
        };

        const markFromElement = (element) => {
          const tag = element.tagName?.toLowerCase();
          if (tag === 'strong' || tag === 'b') return 'bold';
          if (tag === 'em' || tag === 'i') return 'italic';
          if (tag === 'u') return 'underline';
          if (tag === 's' || tag === 'strike' || tag === 'del') return 'strike';
          if (tag === 'code' && element.parentElement?.tagName.toLowerCase() !== 'pre') return 'code';
          const style = element.style;
          if (style?.fontWeight === 'bold' || Number(style?.fontWeight) >= 600) return 'bold';
          if (style?.fontStyle === 'italic') return 'italic';
          if (style?.textDecorationLine?.includes('underline')) return 'underline';
          if (style?.textDecorationLine?.includes('line-through')) return 'strike';
          return null;
        };
        const uniqueMarks = (marks) => [...new Set(marks)].map((type) => ({ type }));
        const serializeChildren = (element, inheritedMarks = []) =>
          [...element.childNodes].flatMap((child) => serializeNode(child, inheritedMarks));
        const serializeInlineOrBlock = (element, type, attrs) => {
          const content = serializeChildren(element);
          const result = { type };
          if (attrs && Object.keys(attrs).length) result.attrs = attrs;
          if (content.length) result.content = content;
          return result;
        };
        const alignmentAttrs = (element) => {
          const textAlign = element.style?.textAlign;
          return ['left', 'center', 'right', 'justify'].includes(textAlign) ? { textAlign } : undefined;
        };
        const serializeNode = (node, inheritedMarks = []) => {
          if (node.nodeType === Node.TEXT_NODE) {
            if (!node.nodeValue) return [];
            const result = { type: 'text', text: node.nodeValue };
            const marks = uniqueMarks(inheritedMarks);
            if (marks.length) result.marks = marks;
            return [result];
          }
          if (node.nodeType !== Node.ELEMENT_NODE) return [];
          const tag = node.tagName.toLowerCase();
          const mark = markFromElement(node);
          if (mark) return serializeChildren(node, [...inheritedMarks, mark]);
          if (tag === 'br') {
            const result = { type: 'hardBreak' };
            const marks = uniqueMarks(inheritedMarks);
            if (marks.length) result.marks = marks;
            return [result];
          }
          if (tag === 'p' || tag === 'div') {
            return [serializeInlineOrBlock(node, 'paragraph', alignmentAttrs(node))];
          }
          if (/^h[1-6]$/.test(tag)) {
            const attrs = { level: Number(tag.slice(1)), ...(alignmentAttrs(node) || {}) };
            return [serializeInlineOrBlock(node, 'heading', attrs)];
          }
          if (tag === 'blockquote') {
            let content = serializeChildren(node);
            if (content.length && content.every((item) => ['text', 'hardBreak'].includes(item.type))) {
              content = [{ type: 'paragraph', content }];
            }
            return [{ type: 'blockquote', content: content.length ? content : [{ type: 'paragraph' }] }];
          }
          if (tag === 'pre') {
            const text = node.textContent || '';
            const result = { type: 'codeBlock' };
            if (node.dataset.language) result.attrs = { language: node.dataset.language };
            if (text) result.content = [{ type: 'text', text }];
            return [result];
          }
          if (tag === 'hr') return [{ type: 'horizontalRule' }];
          if (tag === 'img') {
            const attrs = { src: node.src };
            if (node.hasAttribute('alt')) attrs.alt = node.alt;
            if (node.hasAttribute('title')) attrs.title = node.title;
            if (node.width) attrs.width = node.width;
            return [{ type: 'image', attrs }];
          }
          if (tag === 'ul' || tag === 'ol') {
            const content = [...node.children].flatMap((child) => serializeNode(child));
            const result = { type: tag === 'ol' ? 'orderedList' : 'bulletList', content };
            if (tag === 'ol') {
              const attrs = {};
              if (node.hasAttribute('start')) attrs.start = node.start;
              if (node.hasAttribute('type')) attrs.type = node.type;
              if (Object.keys(attrs).length) result.attrs = attrs;
            }
            return [result];
          }
          if (tag === 'li') {
            let content = serializeChildren(node);
            const leadingInline = [];
            while (content.length && ['text', 'hardBreak'].includes(content[0].type)) {
              leadingInline.push(content.shift());
            }
            if (leadingInline.length) content.unshift({ type: 'paragraph', content: leadingInline });
            if (!content.length || content[0].type !== 'paragraph') {
              content.unshift({ type: 'paragraph' });
            }
            return [{ type: 'listItem', content }];
          }
          return serializeChildren(node, inheritedMarks);
        };

        const currentDocument = () => {
          let content = [...editor.childNodes].flatMap((child) => serializeNode(child));
          const leadingInline = [];
          while (content.length && ['text', 'hardBreak'].includes(content[0].type)) {
            leadingInline.push(content.shift());
          }
          if (leadingInline.length) content.unshift({ type: 'paragraph', content: leadingInline });
          if (!content.length) content = [{ type: 'paragraph' }];
          return { type: 'doc', content };
        };
        const nearestBlock = () => {
          const selection = document.getSelection();
          let node = selection?.anchorNode;
          if (node?.nodeType === Node.TEXT_NODE) node = node.parentElement;
          while (node && node !== editor) {
            const tag = node.tagName?.toLowerCase();
            if (/^h[1-6]$/.test(tag) || ['p', 'div', 'li'].includes(tag)) return node;
            node = node.parentElement;
          }
          return null;
        };
        const activeState = () => {
          const block = nearestBlock();
          const tag = block?.tagName?.toLowerCase();
          const heading = /^h[1-3]$/.test(tag || '') ? Number(tag.slice(1)) : null;
          const list = block?.closest('li')?.parentElement?.tagName?.toLowerCase();
          const align = block?.style?.textAlign;
          return {
            isReady: true,
            canUndo: document.queryCommandEnabled('undo'),
            canRedo: document.queryCommandEnabled('redo'),
            activeHeadingLevel: heading,
            activeMarks: ['bold', 'italic', 'underline', 'strike'].filter((mark) =>
              document.queryCommandState(mark === 'strike' ? 'strikeThrough' : mark)),
            activeListKind: list === 'ul' ? 'bullet' : list === 'ol' ? 'ordered' : null,
            alignment: ['left', 'center', 'right'].includes(align) ? align : 'left',
          };
        };
        const envelope = (payload) => ({ schemaVersion: 1, session: clone(session), payload });
        const emitState = () => {
          if (!session) return;
          window.webkit.messageHandlers.floorpRichTextState.postMessage(envelope(activeState()));
        };
        const emitUpdate = () => {
          if (!session || suppressUpdates) return;
          session.revision += 1;
          const source = JSON.stringify(currentDocument());
          window.webkit.messageHandlers.floorpRichTextUpdate.postMessage(envelope({ source }));
          emitState();
        };

        window.floorpLoad = (root, nextSession) => {
          suppressUpdates = true;
          session = clone(nextSession);
          editor.replaceChildren(...(root.content || [{ type: 'paragraph' }]).map(renderNode));
          suppressUpdates = false;
          emitState();
          return true;
        };
        window.floorpSetEditable = (isEditable) => {
          editor.contentEditable = isEditable ? 'true' : 'false';
          editor.setAttribute('aria-readonly', isEditable ? 'false' : 'true');
          return true;
        };
        window.floorpApplyCommand = (message) => {
          if (!session || message.schemaVersion !== 1) return false;
          const incoming = message.session;
          if (incoming.noteID !== session.noteID || incoming.documentID !== session.documentID ||
              incoming.generation !== session.generation || incoming.revision !== session.revision) return false;
          const planned = message.payload;
          const command = planned.command;
          if (planned.exclusiveMarkToUnset) {
            const unset = planned.exclusiveMarkToUnset === 'strike' ? 'strikeThrough' : planned.exclusiveMarkToUnset;
            if (document.queryCommandState(unset)) document.execCommand(unset, false);
          }
          switch (command.kind) {
            case 'undo': document.execCommand('undo'); break;
            case 'redo': document.execCommand('redo'); break;
            case 'setParagraph': document.execCommand('formatBlock', false, 'p'); break;
            case 'toggleHeading': document.execCommand('formatBlock', false, `h${command.level}`); break;
            case 'toggleMark':
              document.execCommand(command.mark === 'strike' ? 'strikeThrough' : command.mark, false);
              break;
            case 'toggleList':
              document.execCommand(command.listKind === 'ordered' ? 'insertOrderedList' : 'insertUnorderedList');
              break;
            case 'setAlignment':
              document.execCommand(`justify${command.alignment[0].toUpperCase()}${command.alignment.slice(1)}`);
              break;
            case 'insertImage':
              document.execCommand('insertImage', false, command.image.source);
              const images = editor.querySelectorAll('img');
              const image = images[images.length - 1];
              if (image) {
                if (command.image.alt) image.alt = command.image.alt;
                if (command.image.title) image.title = command.image.title;
                if (command.image.width) image.width = command.image.width;
                image.contentEditable = 'false';
              }
              break;
          }
          emitUpdate();
          return true;
        };

        editor.addEventListener('input', emitUpdate);
        editor.addEventListener('keyup', emitState);
        editor.addEventListener('mouseup', emitState);
        document.addEventListener('selectionchange', emitState);
      })();
      </script>
    </body>
    </html>
    """#
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
