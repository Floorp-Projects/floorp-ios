// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import Common
import ImageIO
import Photos
import PhotosUI
import Shared
import UniformTypeIdentifiers
import WebKit

@MainActor
protocol FloorpNotePersistence: AnyObject {
    func preflight(_ draft: FloorpNote) async throws
    func preflightCopy(_ draft: FloorpNote) async throws
    func save(_ draft: FloorpNote) async throws -> FloorpNote
    func reload() async throws -> FloorpNote?
    func acceptReloaded(_ note: FloorpNote)
    func saveAsCopy(_ draft: FloorpNote) async throws -> FloorpNote
}

extension FloorpNotePersistence {
    func preflight(_ draft: FloorpNote) async throws {}
    func preflightCopy(_ draft: FloorpNote) async throws {}
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

    func preflightCopy(_ draft: FloorpNote) async throws {
        try await notesStore.preflightCreateNote(
            title: draft.title,
            content: draft.content,
            contentFormat: draft.contentFormat
        )
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

struct FloorpRichTextRecoveryDraft: Equatable, Sendable {
    let source: String
    let contentFormat: FloorpNoteContentFormat
    let session: FloorpRichTextEditorSessionCursor
}

enum FloorpRichTextFlushError: Error, Equatable, Sendable {
    case editorUnavailable
    case imageImportFailed
    case imageImportTimedOut
    case sessionChanged
    case updateRejected
}

final class FloorpRichTextImageImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
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

    private struct RichCommandFlight: Equatable {
        let requestID: String
        let session: FloorpRichTextEditorSessionCursor
    }

    private let notificationCenter: NotificationProtocol
    private let richTextEditorFactory: @MainActor () -> FloorpRichTextWebEditorView
    private let saveCoordinator: FloorpNoteSaveCoordinator
    private var contentAnalysis: FloorpNoteContent.Analysis
    private var editorMode: ContentEditorMode
    private var richDocument: FloorpRichTextDocument?
    private var richSession: FloorpRichTextEditorSessionCursor?
    private var queuedRichUpdates = [FloorpRichTextUpdateEnvelope]()
    private var queuedRichStates = [FloorpRichTextStateEnvelope]()
    private var queuedRichCommands = [FloorpRichTextCommand]()
    private var isProcessingRichUpdates = false
    private var richCommandInFlight: RichCommandFlight?
    private var richCommandFailure: Error?
    private var richCommandQuiescenceWaiters = [CheckedContinuation<Void, Never>]()
    private var richUpdateDrainTask: Task<Void, Never>?
    private var richAuthoritativeFlushTask: Task<Void, Error>?
    private var plainToRichConversionTask: Task<Void, Never>?
    private var imageProviderProgress: Progress?
    private var imageEncodingTask: Task<FloorpRichTextImage?, Never>?
    private var imageImportID: UUID?
    private var imageImportCancellation: FloorpRichTextImageImportCancellation?
    private var imageImportWaiters = [CheckedContinuation<Void, Error>]()
    private var imageImportTimeoutTask: Task<Void, Never>?
    private var imageImportFailure: Error?
    private var imageImportTimeoutNanoseconds: UInt64 = 5_000_000_000
    private var richEditingLockCount = 0
    private var latestRichEditorState: FloorpRichTextEditorState?
    private var lastRichUpdateFailure: Error?
    private var richBridgeFailure: Error?
    private var richRecoveryDraft: FloorpRichTextRecoveryDraft?
    private var richBridgeRecoverySession: FloorpRichTextEditorSessionCursor?
    private var richBridgeFailureVersion = 0
    private var savedStatusResetTask: Task<Void, Never>?
    private let backgroundSaveLease = FloorpBackgroundSaveLease()
    private let shouldFocusTitleOnFirstAppearance: Bool
    private var didApplyInitialFocus = false
    private var isClosing = false
    private var isEditorSessionTerminated = false

    var currentRichTextSession: FloorpRichTextEditorSessionCursor? { richSession }
    var currentRichTextRecoveryDraft: FloorpRichTextRecoveryDraft? { richRecoveryDraft }

    private var isRichCommandInFlight: Bool { richCommandInFlight != nil }

    private var recoverableRichSource: String? {
        if let richRecoveryDraft { return richRecoveryDraft.source }
        guard editorMode == .richText,
              saveCoordinator.hasUnsavedContentChanges else {
            return nil
        }
        return saveCoordinator.draft.content
    }

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

    private var richEditorView: FloorpRichTextWebEditorView?

    private lazy var richEditorContainerView: UIView = {
        let container = UIView()
        container.accessibilityIdentifier = "Floorp.Notes.RichEditor.Host"
        return container
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
            richEditorContainerView,
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
        persistence: FloorpNotePersistence,
        richTextEditorFactory: @escaping @MainActor () -> FloorpRichTextWebEditorView = {
            FloorpRichTextWebEditorView()
        }
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
            let session = try? FloorpRichTextEditorSessionCursor(
                noteID: note.id,
                documentID: UUID().uuidString,
                generation: 0,
                revision: 0
            )
            self.editorMode = session == nil ? .readOnly : .richText
            self.richDocument = session == nil ? nil : document
            self.richSession = session
        case .readOnly:
            self.editorMode = .readOnly
            self.richDocument = nil
            self.richSession = nil
        }
        self.windowUUID = windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        self.richTextEditorFactory = richTextEditorFactory
        self.shouldFocusTitleOnFirstAppearance = !isPersisted
        self.saveCoordinator = FloorpNoteSaveCoordinator(
            draft: note,
            isPersisted: isPersisted,
            persistence: persistence
        )
        super.init(nibName: nil, bundle: nil)
        saveCoordinator.onAutosave = { [weak self] in
            _ = await self?.saveLatestDraft()
        }
    }

    convenience init(
        note: FloorpNote,
        windowUUID: WindowUUID,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        isPersisted: Bool = true,
        onSave: @escaping @MainActor (FloorpNote) async throws -> FloorpNote,
        richTextEditorFactory: @escaping @MainActor () -> FloorpRichTextWebEditorView = {
            FloorpRichTextWebEditorView()
        }
    ) {
        self.init(
            note: note,
            windowUUID: windowUUID,
            themeManager: themeManager,
            notificationCenter: notificationCenter,
            isPersisted: isPersisted,
            persistence: FloorpNoteClosurePersistence(onSave: onSave),
            richTextEditorFactory: richTextEditorFactory
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
        saveCoordinator.cancelAutosave()
        savedStatusResetTask?.cancel()
        richUpdateDrainTask?.cancel()
        richAuthoritativeFlushTask?.cancel()
        plainToRichConversionTask?.cancel()
        imageImportCancellation?.cancel()
        imageProviderProgress?.cancel()
        imageEncodingTask?.cancel()
        imageImportTimeoutTask?.cancel()
        if let richEditorView {
            Task { @MainActor [richEditorView] in
                richEditorView.invalidate()
            }
        }
        notificationCenter.removeObserver(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            terminateEditorSession()
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
        richEditorContainerView.backgroundColor = colors.layer3
        richEditorView?.backgroundColor = colors.layer3
        richEditorView?.layer.borderColor = colors.borderPrimary.cgColor
    }

    @objc private func titleChanged() {
        guard !isClosing, !isEditorSessionTerminated else { return }
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
        guard !isClosing, !isEditorSessionTerminated else { return false }
        saveCoordinator.cancelAutosave()
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
        Task { @MainActor [weak self] in
            _ = await self?.closeEditor(animated: true)
        }
    }

    @discardableResult
    private func closeEditor(animated: Bool) async -> Bool {
        guard !isClosing, !isEditorSessionTerminated else { return false }
        isClosing = true
        plainToRichConversionTask?.cancel()
        saveCoordinator.cancelAutosave()
        setReloadInteractionEnabled(false, updatesRichEditor: false)
        let outcome = await saveLatestDraft()
        if case .failed(let failure) = outcome {
            isClosing = false
            if let deferredBridgeFailure = richBridgeFailure,
               richBridgeRecoverySession == nil {
                recoverRichEditorAfterBridgeFailure(deferredBridgeFailure)
            }
            setReloadInteractionEnabled(true)
            presentSaveFailure(failure)
            return false
        }
        terminateEditorSession()
        dismiss(animated: animated)
        return true
    }

    @objc private func applicationWillResignActive() {
        guard saveCoordinator.hasUnsavedChanges || editorMode == .richText else { return }
        saveCoordinator.cancelAutosave()
        beginBackgroundSaveTask()
        Task { @MainActor [weak self] in
            _ = await self?.saveLatestDraft()
            self?.endBackgroundSaveTask()
        }
    }

    private func draftDidChange() {
        guard !isClosing, !isEditorSessionTerminated else { return }
        setInteractiveDismissalBlocked(true)
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        saveCoordinator.scheduleAutosave(
            delayNanoseconds: UX.autosaveDelayNanoseconds
        )
    }

    @discardableResult
    func saveLatestDraft() async -> FloorpNoteSaveCoordinator.SaveOutcome {
        guard !isEditorSessionTerminated else { return .noChanges }
        let locksRichEditing = editorMode == .richText || richRecoveryDraft != nil
        if locksRichEditing { lockRichEditing() }
        defer {
            if locksRichEditing { unlockRichEditing() }
        }
        do {
            try await flushRichEditorChanges()
        } catch {
            let failure = FloorpNoteSaveCoordinator.Failure(
                kind: FloorpNoteSaveCoordinator.failureKind(for: error),
                underlyingError: error
            )
            updateSaveState(.failed)
            return .failed(failure)
        }
        guard !isEditorSessionTerminated else { return .noChanges }
        guard saveCoordinator.hasUnsavedChanges else { return .noChanges }
        updateSaveState(.saving)
        let outcome = await saveCoordinator.saveLatest()
        guard !isEditorSessionTerminated else { return .noChanges }
        setInteractiveDismissalBlocked(saveCoordinator.hasUnsavedChanges)
        switch outcome {
        case .noChanges:
            updateSaveState(.idle)
        case .saved:
            rebindRichEditorAfterPersistenceIdentityChangeIfNeeded()
            updateSaveState(.saved)
        case .failed:
            updateSaveState(.failed)
        }
        return outcome
    }

    private func lockRichEditing() {
        richEditingLockCount += 1
        guard richEditingLockCount == 1 else { return }
        // Native controls are locked immediately, but commands accepted just
        // before the lock must finish against an editable DOM before flush.
        setReloadInteractionEnabled(false, updatesRichEditor: false)
    }

    private func unlockRichEditing() {
        richEditingLockCount = max(0, richEditingLockCount - 1)
        guard richEditingLockCount == 0 else { return }
        guard !isClosing, !isEditorSessionTerminated else { return }
        setReloadInteractionEnabled(true)
    }

    private func setInteractiveDismissalBlocked(_ isBlocked: Bool) {
        let shouldBlock = isBlocked || editorMode == .richText || richRecoveryDraft != nil
        isModalInPresentation = shouldBlock
        navigationController?.isModalInPresentation = shouldBlock
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
        if copyActionKinds.contains(failure.kind) || recoverableRichSource != nil {
            alert.addAction(
                UIAlertAction(title: FloorpStrings.Notes.saveCopy, style: .default) { [weak self] _ in
                    self?.saveCurrentDraftAsCopy()
                }
            )
        }
        if recoverableRichSource != nil {
            alert.addAction(
                UIAlertAction(title: FloorpStrings.Notes.exportRecovery, style: .default) { [weak self] _ in
                    self?.exportRecoveryDraft()
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
                guard !isEditorSessionTerminated, !isClosing else { return }
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

    private func setReloadInteractionEnabled(
        _ isEnabled: Bool,
        updatesRichEditor: Bool = true
    ) {
        titleField.isEnabled = isEnabled
        textView.isEditable = isEnabled && editorMode == .plainText
        if updatesRichEditor {
            richEditorView?.setEditable(isEnabled && editorMode == .richText)
        }
        richToolbarButtons.forEach { $0.isEnabled = isEnabled }
        if isEnabled {
            if let latestRichEditorState {
                applyRichEditorState(latestRichEditorState)
            } else {
                undoButton.isEnabled = false
                redoButton.isEnabled = false
            }
        }
        enableRichTextButton.isEnabled = isEnabled
        navigationItem.rightBarButtonItem?.isEnabled = isEnabled
    }

    private func exportRecoveryDraft() {
        guard let source = recoverableRichSource else { return }
        let activity = UIActivityViewController(
            activityItems: [source],
            applicationActivities: nil
        )
        activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        DispatchQueue.main.async { [weak self] in
            guard let self, presentedViewController == nil else { return }
            present(activity, animated: true)
        }
    }

    private func saveCurrentDraftAsCopy() {
        Task { @MainActor [weak self] in
            _ = await self?.saveCurrentDraftAsCopyNow()
        }
    }

    @discardableResult
    private func saveCurrentDraftAsCopyNow() async -> Bool {
        lockRichEditing()
        defer { unlockRichEditing() }
        updateSaveState(.saving)
        do {
            if let source = try await authoritativeRichSourceForCopy(),
               saveCoordinator.updateContent(source, contentFormat: .automatic) {
                draftDidChange()
            }
        } catch {
            updateSaveState(.failed)
            presentPreflightFailure(error)
            return false
        }
        let outcome = await saveCoordinator.saveAsCopy()
        switch outcome {
        case .noChanges, .saved:
            richRecoveryDraft = nil
            lastRichUpdateFailure = nil
            rebindRichEditorAfterPersistenceIdentityChangeIfNeeded()
            setInteractiveDismissalBlocked(saveCoordinator.hasUnsavedChanges)
            updateSaveState(.saved)
            return true
        case .failed(let failure):
            updateSaveState(.failed)
            presentSaveFailure(failure)
            return false
        }
    }

    private func rebindRichEditorAfterPersistenceIdentityChangeIfNeeded() {
        guard !isEditorSessionTerminated,
              !isClosing,
              editorMode == .richText,
              let document = richDocument,
              let currentSession = richSession,
              currentSession.noteID != saveCoordinator.draft.id else {
            return
        }
        guard let session = try? FloorpRichTextEditorSessionCursor(
                noteID: saveCoordinator.draft.id,
                documentID: UUID().uuidString,
                generation: 0,
                revision: 0
              ) else {
            transitionRichEditorToReadOnlyPreservingDraft()
            return
        }
        queuedRichUpdates.removeAll()
        queuedRichStates.removeAll()
        queuedRichCommands.removeAll()
        richCommandInFlight = nil
        richCommandFailure = nil
        resumeRichCommandQuiescenceWaitersIfNeeded()
        latestRichEditorState = nil
        richBridgeRecoverySession = nil
        richBridgeFailure = nil
        richDocument = document
        richSession = session
        guard let editor = installRichEditorIfNeeded() else { return }
        editor.load(
            document: document,
            session: session,
            isDirty: saveCoordinator.hasUnsavedContentChanges
        )
    }

#if TESTING
    func saveRecoveryDraftAsCopyForTesting() async -> Bool {
        await saveCurrentDraftAsCopyNow()
    }

    func closeForTesting() async -> Bool {
        await closeEditor(animated: false)
    }

    var hasTerminatedEditorSessionForTesting: Bool {
        isEditorSessionTerminated
    }

    var pendingRichCommandCountForTesting: Int {
        queuedRichCommands.count + (isRichCommandInFlight ? 1 : 0)
    }

    var hasPendingPlainToRichConversionForTesting: Bool {
        plainToRichConversionTask != nil
    }

    var hasPendingRichUpdateDrainForTesting: Bool {
        richUpdateDrainTask != nil
    }

    var hasRichCommandQuiescenceWaitersForTesting: Bool {
        !richCommandQuiescenceWaiters.isEmpty
    }

    var hasImageImportWaitersForTesting: Bool {
        !imageImportWaiters.isEmpty
    }

    var hasPendingRichBridgeRecoveryForTesting: Bool {
        richBridgeRecoverySession != nil
    }

    var isClosingForTesting: Bool {
        isClosing
    }

    var hasPendingImageImportForTesting: Bool {
        imageImportID != nil
    }

    var currentDraftForTesting: FloorpNote {
        saveCoordinator.draft
    }

    func terminateEditorSessionForTesting() {
        terminateEditorSession()
    }

    func beginImageImportForTesting() -> UUID {
        cancelImageImport()
        imageImportFailure = nil
        richCommandFailure = nil
        let importID = UUID()
        imageImportID = importID
        imageImportCancellation = FloorpRichTextImageImportCancellation()
        return importID
    }

    func completeImageImportForTesting(
        importID: UUID,
        image: FloorpRichTextImage
    ) {
        finishImageImport(importID: importID, result: .success(image))
    }

    func setImageImportTimeoutForTesting(_ nanoseconds: UInt64) {
        imageImportTimeoutNanoseconds = nanoseconds
    }
#endif

    private func applyReloadedNote(_ note: FloorpNote) {
        guard !isEditorSessionTerminated, !isClosing else { return }
        saveCoordinator.cancelAutosave()
        contentAnalysis = FloorpNoteContent.analyze(
            note.content,
            contentFormat: note.contentFormat
        )
        applyRichPreparation(
            FloorpRichTextEditorPreparation.prepare(note),
            noteID: note.id
        )
        titleField.text = note.title
        textView.text = contentAnalysis.editorText
        configureContentEditor()
        setInteractiveDismissalBlocked(false)
        updateSaveState(.idle)
    }

    private func dismissDiscardingChanges() {
        saveCoordinator.cancelAutosave()
        setInteractiveDismissalBlocked(false)
        terminateEditorSession()
        navigationController?.dismiss(animated: true)
    }

    private func terminateEditorSession() {
        guard !isEditorSessionTerminated else { return }
        isEditorSessionTerminated = true
        saveCoordinator.cancelAutosave()
        plainToRichConversionTask?.cancel()
        richUpdateDrainTask?.cancel()
        richAuthoritativeFlushTask?.cancel()
        cancelImageImport()
        queuedRichUpdates.removeAll()
        queuedRichStates.removeAll()
        queuedRichCommands.removeAll()
        richCommandInFlight = nil
        richCommandFailure = nil
        resumeRichCommandQuiescenceWaitersIfNeeded()
        invalidateRichEditor()
    }

    private func configureContentEditor() {
        let showsRichEditor = editorMode == .richText
        enableRichTextButton.isHidden = editorMode != .plainText
        richToolbarScrollView.isHidden = !showsRichEditor
        richEditorContainerView.isHidden = !showsRichEditor
        textView.isHidden = showsRichEditor
        textView.isEditable = editorMode == .plainText
        textView.accessibilityHint = editorMode == .readOnly
            ? FloorpStrings.Notes.unsupportedContentReadOnlyNotice
            : FloorpStrings.Notes.contentAccessibilityHint

        if showsRichEditor, let richDocument, let richSession {
            guard let editor = installRichEditorIfNeeded() else {
                richEditorContainerView.isHidden = true
                return
            }
            editor.load(document: richDocument, session: richSession, isDirty: false)
            editor.setEditable(richEditingLockCount == 0)
        } else {
            invalidateRichEditor()
        }
        latestRichEditorState = nil
        undoButton.isEnabled = false
        redoButton.isEnabled = false
        setInteractiveDismissalBlocked(saveCoordinator.hasUnsavedChanges)
    }

    private func installRichEditorIfNeeded() -> FloorpRichTextWebEditorView? {
        guard !isEditorSessionTerminated,
              !isClosing,
              editorMode == .richText else {
            return nil
        }
        if let richEditorView { return richEditorView }
        let editor = richTextEditorFactory()
        editor.delegate = self
        editor.layer.cornerRadius = 12
        editor.layer.borderWidth = 1
        editor.clipsToBounds = true
        editor.translatesAutoresizingMaskIntoConstraints = false
        richEditorContainerView.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: richEditorContainerView.topAnchor),
            editor.leadingAnchor.constraint(equalTo: richEditorContainerView.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: richEditorContainerView.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: richEditorContainerView.bottomAnchor),
        ])
        let colors = themeManager.getCurrentTheme(for: windowUUID).colors
        editor.backgroundColor = colors.layer3
        editor.layer.borderColor = colors.borderPrimary.cgColor
        richEditorView = editor
        return editor
    }

    private func replaceRichEditor(
        document: FloorpRichTextDocument,
        session: FloorpRichTextEditorSessionCursor,
        isDirty: Bool
    ) {
        invalidateRichEditor()
        guard let editor = installRichEditorIfNeeded() else { return }
        editor.load(document: document, session: session, isDirty: isDirty)
        editor.setEditable(richEditingLockCount == 0)
    }

    private func invalidateRichEditor() {
        guard let editor = richEditorView else { return }
        richEditorView = nil
        editor.isHidden = true
        editor.invalidate()
        editor.removeFromSuperview()
    }

    private func applyRichPreparation(
        _ preparation: FloorpRichTextEditorPreparation,
        noteID: FloorpNoteID
    ) {
        queuedRichUpdates.removeAll()
        queuedRichStates.removeAll()
        queuedRichCommands.removeAll()
        richCommandInFlight = nil
        richCommandFailure = nil
        resumeRichCommandQuiescenceWaitersIfNeeded()
        latestRichEditorState = nil
        richRecoveryDraft = nil
        lastRichUpdateFailure = nil
        richBridgeFailure = nil
        richBridgeRecoverySession = nil
        switch preparation {
        case .plainText:
            editorMode = .plainText
            richDocument = nil
            richSession = nil
        case .editable(let document, _):
            let session = try? FloorpRichTextEditorSessionCursor(
                noteID: noteID,
                documentID: UUID().uuidString,
                generation: 0,
                revision: 0
            )
            editorMode = session == nil ? .readOnly : .richText
            richDocument = session == nil ? nil : document
            richSession = session
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
        guard editorMode == .plainText,
              plainToRichConversionTask == nil,
              !isClosing,
              !isEditorSessionTerminated else {
            return
        }
        view.endEditing(true)
        enableRichTextButton.isEnabled = false
        textView.isEditable = false
        setInteractiveDismissalBlocked(true)
        updateSaveState(.saving)
        plainToRichConversionTask = Task { @MainActor [weak self] in
            await self?.performPlainToRichConversion()
        }
    }

    private func performPlainToRichConversion() async {
        defer {
            plainToRichConversionTask = nil
            if !isClosing, !isEditorSessionTerminated {
                enableRichTextButton.isEnabled = true
                if editorMode == .plainText {
                    textView.isEditable = true
                }
                setInteractiveDismissalBlocked(saveCoordinator.hasUnsavedChanges)
            }
        }
        do {
            while editorMode == .plainText {
                try Task.checkCancellation()
                let expectedContent = saveCoordinator.draft.content
                let expectedFormat = saveCoordinator.draft.contentFormat
                let document = try FloorpRichTextCodec.document(fromPlainText: expectedContent)
                let source = try FloorpRichTextCodec.encode(document)
                let didReplace = try await saveCoordinator.preflightAndReplaceContent(
                    expectedContent: expectedContent,
                    expectedContentFormat: expectedFormat,
                    content: source,
                    contentFormat: .automatic
                )
                try Task.checkCancellation()
                guard !isClosing, !isEditorSessionTerminated else { return }
                guard didReplace else { continue }
                richDocument = document
                richSession = try FloorpRichTextEditorSessionCursor(
                    noteID: saveCoordinator.draft.id,
                    documentID: UUID().uuidString,
                    generation: 0,
                    revision: 0
                )
                editorMode = .richText
                draftDidChange()
                configureContentEditor()
                updateSaveState(.idle)
                UIAccessibility.post(notification: .layoutChanged, argument: richEditorView)
                return
            }
        } catch is CancellationError {
            return
        } catch {
            guard !isClosing, !isEditorSessionTerminated else { return }
            presentPreflightFailure(error)
        }
    }

    private func enqueueRichCommand(_ command: FloorpRichTextCommand) {
        guard editorMode == .richText,
              richEditingLockCount == 0,
              !isClosing,
              !isEditorSessionTerminated else {
            return
        }
        queuedRichCommands.append(command)
        sendNextRichCommandIfPossible()
    }

    private func sendNextRichCommandIfPossible() {
        guard !isEditorSessionTerminated,
              !isRichCommandInFlight,
              !isProcessingRichUpdates,
              queuedRichUpdates.isEmpty,
              let document = richDocument,
              let session = richSession,
              !queuedRichCommands.isEmpty else {
            return
        }
        guard let editor = richEditorView else {
            recoverRichEditorAfterBridgeFailure(FloorpRichTextFlushError.editorUnavailable)
            return
        }
        let command = queuedRichCommands.removeFirst()
        do {
            let envelope = try FloorpRichTextCommandPlanner.plan(
                command,
                for: document,
                session: session
            )
            let flight = RichCommandFlight(
                requestID: UUID().uuidString,
                session: session
            )
            richCommandInFlight = flight
            editor.send(envelope, requestID: flight.requestID) { [weak self] result in
                guard let self else { return }
                guard richCommandInFlight == flight else { return }
                richCommandInFlight = nil
                guard case .success(let update) = result,
                      update.requestID == flight.requestID,
                      update.session.noteID == flight.session.noteID,
                      update.session.documentID == flight.session.documentID,
                      update.session.generation == flight.session.generation,
                      update.session.revision > flight.session.revision else {
                    let error: Error
                    if case .failure(let commandError) = result {
                        error = commandError
                    } else {
                        error = FloorpRichTextFlushError.updateRejected
                    }
                    recoverRichEditorAfterBridgeFailure(error)
                    resumeRichCommandQuiescenceWaitersIfNeeded()
                    return
                }
                enqueueRichUpdate(update)
                sendNextRichCommandIfPossible()
                resumeRichCommandQuiescenceWaitersIfNeeded()
            }
        } catch let error as FloorpRichTextCommandError {
            richCommandInFlight = nil
            richCommandFailure = error
            updateSaveState(.failed)
            resumeRichCommandQuiescenceWaitersIfNeeded()
            sendNextRichCommandIfPossible()
        } catch {
            richCommandInFlight = nil
            recoverRichEditorAfterBridgeFailure(error)
            resumeRichCommandQuiescenceWaitersIfNeeded()
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

    private func cancelImageImport(failure: Error? = nil) {
        guard imageImportID != nil else {
            imageImportTimeoutTask?.cancel()
            imageImportTimeoutTask = nil
            return
        }
        imageImportCancellation?.cancel()
        imageProviderProgress?.cancel()
        imageEncodingTask?.cancel()
        imageImportTimeoutTask?.cancel()
        let waiters = imageImportWaiters
        imageImportID = nil
        imageImportCancellation = nil
        imageProviderProgress = nil
        imageEncodingTask = nil
        imageImportTimeoutTask = nil
        imageImportWaiters.removeAll()
        if let failure {
            if waiters.isEmpty { imageImportFailure = failure }
            waiters.forEach { $0.resume(throwing: failure) }
        } else {
            waiters.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    private func encodeImportedImage(at url: URL, importID: UUID) {
        guard imageImportID == importID, !isEditorSessionTerminated else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        imageProviderProgress = nil
        let task = Task.detached(priority: .userInitiated) { () -> FloorpRichTextImage? in
            defer { try? FileManager.default.removeItem(at: url) }
            guard !Task.isCancelled else { return nil }
            return FloorpRichTextImageEncoder.encodeFile(at: url)
        }
        imageEncodingTask = task
        Task { @MainActor [weak self] in
            let richImage = await task.value
            guard let self, imageImportID == importID else { return }
            imageEncodingTask = nil
            guard let richImage else {
                finishImageImport(importID: importID, result: .failure(.imageImportFailed))
                return
            }
            finishImageImport(importID: importID, result: .success(richImage))
        }
    }

    private func finishImageImport(
        importID: UUID,
        result: Result<FloorpRichTextImage, FloorpRichTextFlushError>
    ) {
        guard imageImportID == importID else { return }
        imageImportTimeoutTask?.cancel()
        let waiters = imageImportWaiters
        imageImportID = nil
        imageImportCancellation = nil
        imageProviderProgress = nil
        imageEncodingTask = nil
        imageImportTimeoutTask = nil
        imageImportWaiters.removeAll()

        switch result {
        case .success(let image):
            guard editorMode == .richText,
                  richSession != nil,
                  !isEditorSessionTerminated else {
                let error = FloorpRichTextFlushError.editorUnavailable
                if waiters.isEmpty { imageImportFailure = error }
                waiters.forEach { $0.resume(throwing: error) }
                return
            }
            imageImportFailure = nil
            // An import accepted before Save/Close owns its insertion even
            // while those operations have locked the toolbar. It must enter
            // the command queue instead of going through the UI guard.
            queuedRichCommands.append(.insertImage(image))
            sendNextRichCommandIfPossible()
            waiters.forEach { $0.resume() }
        case .failure(let error):
            if waiters.isEmpty { imageImportFailure = error }
            updateSaveState(.failed)
            waiters.forEach { $0.resume(throwing: error) }
        }
    }

    private func waitForImageImportToQuiesce() async throws {
        if let failure = imageImportFailure {
            imageImportFailure = nil
            throw failure
        }
        guard let importID = imageImportID else { return }
        if imageImportTimeoutTask == nil {
            let timeout = imageImportTimeoutNanoseconds
            imageImportTimeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeout)
                } catch {
                    return
                }
                guard let self, imageImportID == importID else { return }
                cancelImageImport(failure: FloorpRichTextFlushError.imageImportTimedOut)
                updateSaveState(.failed)
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            imageImportWaiters.append(continuation)
        }
    }

    private func processQueuedRichUpdates() {
        guard !isEditorSessionTerminated, richUpdateDrainTask == nil else { return }
        isProcessingRichUpdates = true
        richUpdateDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await drainQueuedRichUpdates()
            isProcessingRichUpdates = false
            richUpdateDrainTask = nil
            if !queuedRichUpdates.isEmpty {
                processQueuedRichUpdates()
            } else {
                sendNextRichCommandIfPossible()
                resumeRichCommandQuiescenceWaitersIfNeeded()
            }
        }
    }

    private func drainQueuedRichUpdates() async {
        while !queuedRichUpdates.isEmpty {
            let envelope = queuedRichUpdates.removeFirst()
            guard let document = richDocument, let session = richSession else {
                recoverFromRejectedRichUpdate(envelope, error: FloorpRichTextFlushError.editorUnavailable)
                return
            }
            guard envelope.session.noteID == session.noteID,
                  envelope.session.documentID == session.documentID,
                  envelope.session.generation == session.generation else {
                continue
            }
            guard envelope.session.revision > session.revision else { continue }
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
                guard !Task.isCancelled,
                      !isEditorSessionTerminated,
                      richSession == session else {
                    continue
                }
                richDocument = accepted.document
                richSession = accepted.session
                clearRecoveryDraft(through: accepted.session)
                if saveCoordinator.updateContent(source, contentFormat: .automatic) {
                    draftDidChange()
                }
                applyQueuedRichStateIfPossible()
            } catch {
                guard !Task.isCancelled,
                      !isEditorSessionTerminated,
                      !isClosing else {
                    return
                }
                recoverFromRejectedRichUpdate(envelope, error: error)
                presentPreflightFailure(error)
                return
            }
        }
    }

    private func enqueueRichUpdate(_ update: FloorpRichTextUpdateEnvelope) {
        guard !isEditorSessionTerminated,
              update.payload.isDirty,
              let session = richSession,
              update.session.noteID == session.noteID,
              update.session.documentID == session.documentID,
              update.session.generation == session.generation,
              update.session.revision > session.revision else {
            return
        }
        retainRecoveryDraft(update)
        if queuedRichUpdates.count >= 128 {
            let newest = (queuedRichUpdates + [update]).max {
                $0.session.revision < $1.session.revision
            }
            queuedRichUpdates = newest.map { [$0] } ?? []
        } else {
            queuedRichUpdates.append(update)
        }
        processQueuedRichUpdates()
    }

    private func waitForRichUpdateDrain() async {
        while let task = richUpdateDrainTask {
            await task.value
        }
    }

    private func waitForRichCommandsToQuiesce() async {
        sendNextRichCommandIfPossible()
        while !queuedRichCommands.isEmpty || isRichCommandInFlight {
            await withCheckedContinuation { continuation in
                richCommandQuiescenceWaiters.append(continuation)
            }
        }
    }

    private func resumeRichCommandQuiescenceWaitersIfNeeded() {
        guard queuedRichCommands.isEmpty, !isRichCommandInFlight else { return }
        let waiters = richCommandQuiescenceWaiters
        richCommandQuiescenceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func retainRecoveryDraft(_ envelope: FloorpRichTextUpdateEnvelope) {
        if let existing = richRecoveryDraft,
           existing.session.noteID == envelope.session.noteID,
           existing.session.documentID == envelope.session.documentID,
           existing.session.generation == envelope.session.generation,
           existing.session.revision > envelope.session.revision {
            return
        }
        richRecoveryDraft = FloorpRichTextRecoveryDraft(
            source: envelope.payload.source,
            contentFormat: .automatic,
            session: envelope.session
        )
        setInteractiveDismissalBlocked(true)
    }

    private func clearRecoveryDraft(through acceptedSession: FloorpRichTextEditorSessionCursor) {
        guard let recovery = richRecoveryDraft,
              recovery.session.noteID == acceptedSession.noteID,
              recovery.session.documentID == acceptedSession.documentID,
              recovery.session.generation == acceptedSession.generation,
              recovery.session.revision <= acceptedSession.revision else {
            return
        }
        richRecoveryDraft = nil
        lastRichUpdateFailure = nil
    }

    private func recoverFromRejectedRichUpdate(
        _ rejected: FloorpRichTextUpdateEnvelope,
        error: Error
    ) {
        guard !isEditorSessionTerminated, !isClosing else { return }
        let recoveryEnvelope = (queuedRichUpdates + [rejected]).max {
            $0.session.revision < $1.session.revision
        } ?? rejected
        retainRecoveryDraft(recoveryEnvelope)
        lastRichUpdateFailure = error
        richBridgeFailure = nil
        richBridgeRecoverySession = nil
        queuedRichUpdates.removeAll()
        queuedRichStates.removeAll()
        queuedRichCommands.removeAll()
        richCommandInFlight = nil
        resumeRichCommandQuiescenceWaitersIfNeeded()
        guard let recovery = richRecoveryDraft,
              let document = try? FloorpRichTextCodec.decode(recovery.source),
              document.compatibility.isEditable,
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
            contentAnalysis = FloorpNoteContent.analyze(
                recoveryEnvelope.payload.source,
                contentFormat: .automatic
            )
            editorMode = .readOnly
            richDocument = nil
            richSession = nil
            textView.text = contentAnalysis.editorText
            configureContentEditor()
            return
        }
        richDocument = document
        richSession = replacement
        richRecoveryDraft = FloorpRichTextRecoveryDraft(
            source: recovery.source,
            contentFormat: recovery.contentFormat,
            session: replacement
        )
        replaceRichEditor(document: document, session: replacement, isDirty: true)
    }

    private func recoverRichEditorAfterBridgeFailure(_ error: Error) {
        guard !isEditorSessionTerminated,
              editorMode == .richText else {
            return
        }
        guard isClosing || richBridgeRecoverySession == nil else {
            return
        }
        richBridgeFailureVersion += 1
        richBridgeFailure = error
        lastRichUpdateFailure = error
        queuedRichUpdates.removeAll()
        queuedRichStates.removeAll()
        queuedRichCommands.removeAll()
        richCommandInFlight = nil
        latestRichEditorState = nil
        resumeRichCommandQuiescenceWaitersIfNeeded()
        updateSaveState(.failed)

        // Closing must fail instead of resurrecting a web-content process.
        // Once the failed close re-enables the session, it retries this
        // recorded recovery through the normal replacement path.
        guard !isClosing else {
            richBridgeRecoverySession = nil
            invalidateRichEditor()
            return
        }

        guard let document = richDocument,
              let session = richSession,
              session.generation < FloorpRichTextBridgeProtocol.maximumSafeSequenceNumber,
              let replacement = try? FloorpRichTextEditorSessionCursor(
                noteID: session.noteID,
                documentID: UUID().uuidString,
                generation: session.generation + 1,
                revision: 0
              ) else {
            editorMode = .readOnly
            richSession = nil
            configureContentEditor()
            return
        }
        richSession = replacement
        richBridgeRecoverySession = replacement
        replaceRichEditor(
            document: document,
            session: replacement,
            isDirty: saveCoordinator.hasUnsavedContentChanges
        )
    }

    private func transitionRichEditorToReadOnlyAfterLoadFailure() {
        transitionRichEditorToReadOnlyPreservingDraft()
        updateSaveState(.failed)
        resumeRichCommandQuiescenceWaitersIfNeeded()
    }

    private func transitionRichEditorToReadOnlyPreservingDraft() {
        queuedRichUpdates.removeAll()
        queuedRichStates.removeAll()
        queuedRichCommands.removeAll()
        richCommandInFlight = nil
        richBridgeRecoverySession = nil
        richBridgeFailure = nil
        lastRichUpdateFailure = nil
        editorMode = .readOnly
        richSession = nil
        contentAnalysis = FloorpNoteContent.analyze(
            saveCoordinator.draft.content,
            contentFormat: saveCoordinator.draft.contentFormat
        )
        textView.text = contentAnalysis.editorText
        configureContentEditor()
    }

    private func flushRichEditorChanges() async throws {
        if let task = richAuthoritativeFlushTask {
            return try await task.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw FloorpRichTextFlushError.editorUnavailable }
            try await performRichEditorFlush()
        }
        richAuthoritativeFlushTask = task
        defer { richAuthoritativeFlushTask = nil }
        try await task.value
    }

    private func performRichEditorFlush() async throws {
        let startingBridgeFailureVersion = richBridgeFailureVersion
        try await waitForImageImportToQuiesce()
        await waitForRichCommandsToQuiesce()
        await waitForRichUpdateDrain()
        if let failure = richCommandFailure {
            richCommandFailure = nil
            throw failure
        }
        guard startingBridgeFailureVersion == richBridgeFailureVersion,
              richBridgeRecoverySession == nil else {
            throw richBridgeFailure ?? FloorpRichTextFlushError.editorUnavailable
        }
        guard editorMode == .richText else {
            if lastRichUpdateFailure != nil || richRecoveryDraft != nil {
                throw lastRichUpdateFailure ?? FloorpRichTextFlushError.updateRejected
            }
            return
        }
        guard let requestedSession = richSession,
              let editor = richEditorView else {
            throw FloorpRichTextFlushError.editorUnavailable
        }
        try await editor.setEditableAndWait(false)
        let envelope = try await editor.flush(expectedSession: requestedSession)
        guard envelope.session.noteID == requestedSession.noteID,
              envelope.session.documentID == requestedSession.documentID,
              envelope.session.generation == requestedSession.generation,
              envelope.session.revision >= requestedSession.revision else {
            throw FloorpRichTextFlushError.sessionChanged
        }
        guard envelope.payload.isDirty else {
            if lastRichUpdateFailure != nil || richRecoveryDraft != nil {
                throw lastRichUpdateFailure ?? FloorpRichTextFlushError.updateRejected
            }
            return
        }
        enqueueRichUpdate(envelope)
        await waitForRichUpdateDrain()
        guard let acceptedSession = richSession,
              acceptedSession.noteID == envelope.session.noteID,
              acceptedSession.documentID == envelope.session.documentID,
              acceptedSession.generation == envelope.session.generation,
              acceptedSession.revision >= envelope.session.revision,
              richRecoveryDraft == nil else {
            throw lastRichUpdateFailure ?? FloorpRichTextFlushError.updateRejected
        }
    }

    private func authoritativeRichSourceForCopy() async throws -> String? {
        let startingBridgeFailureVersion = richBridgeFailureVersion
        try await waitForImageImportToQuiesce()
        await waitForRichCommandsToQuiesce()
        await waitForRichUpdateDrain()
        if let failure = richCommandFailure {
            richCommandFailure = nil
            throw failure
        }
        guard startingBridgeFailureVersion == richBridgeFailureVersion,
              richBridgeRecoverySession == nil else {
            throw richBridgeFailure ?? FloorpRichTextFlushError.editorUnavailable
        }
        if let recovery = richRecoveryDraft {
            try await saveCoordinator.preflightCopyContent(
                recovery.source,
                contentFormat: recovery.contentFormat
            )
            return recovery.source
        }
        guard editorMode == .richText, let session = richSession else {
            return nil
        }
        guard let editor = richEditorView else {
            throw FloorpRichTextFlushError.editorUnavailable
        }
        try await editor.setEditableAndWait(false)
        let envelope = try await editor.snapshot(expectedSession: session)
        guard envelope.session.noteID == session.noteID,
              envelope.session.documentID == session.documentID,
              envelope.session.generation == session.generation,
              envelope.session.revision >= session.revision else {
            throw FloorpRichTextFlushError.sessionChanged
        }
        let source = envelope.payload.isDirty
            ? envelope.payload.source
            : recoverableRichSource
        guard let source else { return nil }
        try await saveCoordinator.preflightCopyContent(source, contentFormat: .automatic)
        return source
    }

    private func presentPreflightFailure(_ error: Error) {
        let kind = FloorpNoteSaveCoordinator.failureKind(for: error)
        updateSaveState(.failed)
        presentSaveFailure(
            FloorpNoteSaveCoordinator.Failure(kind: kind, underlyingError: error)
        )
    }

    private func applyRichEditorState(_ state: FloorpRichTextEditorState) {
        latestRichEditorState = state
        guard richEditingLockCount == 0 else { return }
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
            richEditorView?.focus()
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
        editorMode == .plainText && textView.isEditable
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
        enqueueRichUpdate(update)
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

    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        didLoad session: FloorpRichTextEditorSessionCursor
    ) {
        guard richBridgeRecoverySession == session else { return }
        richBridgeRecoverySession = nil
        richBridgeFailure = nil
        lastRichUpdateFailure = nil
        updateSaveState(saveCoordinator.hasUnsavedChanges ? .failed : .idle)
    }

    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        didFailLoading session: FloorpRichTextEditorSessionCursor,
        error: Error
    ) {
        if richBridgeRecoverySession == session {
            transitionRichEditorToReadOnlyAfterLoadFailure()
            return
        }
        guard richSession == session else { return }
        recoverRichEditorAfterBridgeFailure(error)
    }

    func richTextEditorWebContentProcessDidTerminate(
        _ editor: FloorpRichTextWebEditorView
    ) {
        recoverRichEditorAfterBridgeFailure(FloorpRichTextFlushError.editorUnavailable)
    }
}

extension FloorpNoteEditorViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            return
        }
        cancelImageImport()
        imageImportFailure = nil
        richCommandFailure = nil
        let importID = UUID()
        let cancellation = FloorpRichTextImageImportCancellation()
        imageImportID = importID
        imageImportCancellation = cancellation
        imageProviderProgress = provider.loadFileRepresentation(
            forTypeIdentifier: UTType.image.identifier
        ) { [weak self] url, _ in
            let ownedURL = url.flatMap {
                FloorpRichTextImageEncoder.copyFileForEncoding(
                    $0,
                    importID: importID,
                    isCancelled: { cancellation.isCancelled }
                )
            }
            Task { @MainActor [weak self] in
                guard let self, imageImportID == importID else {
                    if let ownedURL {
                        try? FileManager.default.removeItem(at: ownedURL)
                    }
                    return
                }
                guard let ownedURL else {
                    finishImageImport(importID: importID, result: .failure(.imageImportFailed))
                    return
                }
                encodeImportedImage(at: ownedURL, importID: importID)
            }
        }
    }
}

enum FloorpRichTextImageEncoder {
    static let maximumSourceBytes = 64 * 1_024 * 1_024
    static let maximumSourcePixelDimension: UInt64 = 16_384
    static let maximumSourcePixels: UInt64 = 64 * 1_024 * 1_024

    static func encode(_ data: Data) -> FloorpRichTextImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !data.isEmpty,
              data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }
        return encode(source)
    }

    static func encodeFile(at url: URL) -> FloorpRichTextImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !Task.isCancelled,
              isAllowedImageFile(at: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return nil
        }
        return encode(source)
    }

    static func copyFileForEncoding(
        _ sourceURL: URL,
        importID: UUID,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) -> URL? {
        guard !isCancelled(), isAllowedImageFile(at: sourceURL) else { return nil }
        var ownedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloorpNotesImage-\(importID.uuidString)")
        let pathExtension = sourceURL.pathExtension
        if !pathExtension.isEmpty {
            ownedURL.appendPathExtension(pathExtension)
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: ownedURL)
            guard !isCancelled(), isAllowedImageFile(at: ownedURL) else {
                try? FileManager.default.removeItem(at: ownedURL)
                return nil
            }
            return ownedURL
        } catch {
            try? FileManager.default.removeItem(at: ownedURL)
            return nil
        }
    }

    private static func isAllowedImageFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize else {
            return false
        }
        return (1...maximumSourceBytes).contains(fileSize)
    }

    private static func encode(_ source: CGImageSource) -> FloorpRichTextImage? {
        guard sourceMetadataIsSafe(source) else { return nil }
        var maximumDimension: CGFloat = 1_600
        var quality: CGFloat = 0.82

        for _ in 0..<12 {
            guard !Task.isCancelled else { return nil }
            guard let encoded = autoreleasepool(invoking: { () -> (String, Int)? in
                guard let thumbnail = downsample(source, maximumDimension: maximumDimension),
                      !Task.isCancelled,
                      let jpeg = renderJPEG(thumbnail, quality: quality),
                      !Task.isCancelled else {
                    return nil
                }
                return (
                    "data:image/jpeg;base64," + jpeg.base64EncodedString(),
                    thumbnail.width
                )
            }) else {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            let (encodedSource, width) = encoded
            if FloorpRichTextImagePolicy.isSafePersistedSource(encodedSource) {
                return FloorpRichTextImage(
                    source: encodedSource,
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

    private static func sourceMetadataIsSafe(_ source: CGImageSource) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let sourceProperties = CGImageSourceCopyProperties(
                source,
                options
              ) as? [CFString: Any],
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let frameProperties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                options
              ) as? [CFString: Any],
              dimensionsAreSafe(
                frameProperties,
                widthKey: kCGImagePropertyPixelWidth,
                heightKey: kCGImagePropertyPixelHeight
              ) else {
            return false
        }
        let canvasKeys: [CFString: (width: CFString, height: CFString)] = [
            kCGImagePropertyGIFDictionary: (
                kCGImagePropertyGIFCanvasPixelWidth,
                kCGImagePropertyGIFCanvasPixelHeight
            ),
            kCGImagePropertyPNGDictionary: (
                kCGImagePropertyAPNGCanvasPixelWidth,
                kCGImagePropertyAPNGCanvasPixelHeight
            ),
            kCGImagePropertyWebPDictionary: (
                kCGImagePropertyWebPCanvasPixelWidth,
                kCGImagePropertyWebPCanvasPixelHeight
            ),
            kCGImagePropertyHEICSDictionary: (
                kCGImagePropertyHEICSCanvasPixelWidth,
                kCGImagePropertyHEICSCanvasPixelHeight
            ),
        ]
        return canvasKeys.allSatisfy { dictionaryKey, dimensionKeys in
            guard let dictionary = sourceProperties[dictionaryKey] as? [CFString: Any],
                  dictionary[dimensionKeys.width] != nil
                    || dictionary[dimensionKeys.height] != nil else {
                return true
            }
            return dimensionsAreSafe(
                dictionary,
                widthKey: dimensionKeys.width,
                heightKey: dimensionKeys.height
            )
        }
    }

    private static func dimensionsAreSafe(
        _ properties: [CFString: Any],
        widthKey: CFString,
        heightKey: CFString
    ) -> Bool {
        guard let width = (properties[widthKey] as? NSNumber)?.uint64Value,
              let height = (properties[heightKey] as? NSNumber)?.uint64Value,
              width > 0,
              height > 0,
              width <= maximumSourcePixelDimension,
              height <= maximumSourcePixelDimension else {
            return false
        }
        let (pixels, didOverflow) = width.multipliedReportingOverflow(by: height)
        return !didOverflow && pixels <= maximumSourcePixels
    }

    private static func downsample(
        _ source: CGImageSource,
        maximumDimension: CGFloat
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maximumDimension.rounded(.down))),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func renderJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let normalized = renderer.image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return normalized.jpegData(compressionQuality: quality)
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
    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        didLoad session: FloorpRichTextEditorSessionCursor
    )
    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        didFailLoading session: FloorpRichTextEditorSessionCursor,
        error: Error
    )
    func richTextEditorWebContentProcessDidTerminate(
        _ editor: FloorpRichTextWebEditorView
    )
}

extension FloorpRichTextWebEditorDelegate {
    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        didLoad session: FloorpRichTextEditorSessionCursor
    ) {}

    func richTextEditor(
        _ editor: FloorpRichTextWebEditorView,
        didFailLoading session: FloorpRichTextEditorSessionCursor,
        error: Error
    ) {}

    func richTextEditorWebContentProcessDidTerminate(
        _ editor: FloorpRichTextWebEditorView
    ) {}
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

    private enum EditorError: Error {
        case editorInvalidated
        case pageNotReady
        case sessionWasReplaced
        case invalidJavaScriptResult
        case javaScriptRequestTimedOut
        case webContentProcessTerminated
    }

    private struct JavaScriptValue: @unchecked Sendable {
        let value: Any?
    }

    @MainActor
    private final class JavaScriptRequestToken {
        let id: UUID
        private var completion: ((Result<JavaScriptValue, Error>) -> Void)?
        private var timeoutTask: Task<Void, Never>?

        init(id: UUID, completion: @escaping (Result<JavaScriptValue, Error>) -> Void) {
            self.id = id
            self.completion = completion
        }

        func beginTimeout(after nanoseconds: UInt64) {
            timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                resolve(.failure(EditorError.javaScriptRequestTimedOut))
            }
        }

        func resolve(_ result: Result<JavaScriptValue, Error>) {
            guard let completion else { return }
            self.completion = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            completion(result)
        }
    }

    // A nil base URL gives the owned HTML one exact, non-networking main-frame
    // navigation and an opaque origin that can be checked at the bridge.
    private static let editorDocumentURL = URL(string: "about:blank")!

    weak var delegate: FloorpRichTextWebEditorDelegate?

    private let webView: WKWebView
    private var messageHandlerProxy: FloorpWeakScriptMessageHandler?
    private var pendingDocument: FloorpRichTextDocument?
    private var pendingSession: FloorpRichTextEditorSessionCursor?
    private var pendingDocumentIsDirty = false
    private var loadRequestVersion = 0
    private var pendingLoadRequestVersion = 0
    private var loadedSession: FloorpRichTextEditorSessionCursor?
    private var requestedEditable = true
    private var isPageReady = false
    private var isInvalidated = false
    private var didAuthorizeInitialNavigation = false
    private var initialNavigation: WKNavigation?
    private var initialNavigationAttemptVersion = 0
    private var initialNavigationWatchdogTask: Task<Void, Never>?
    private var initialNavigationTimeoutNanoseconds: UInt64 = 5_000_000_000
    private var webContentProcessGeneration = 0
    private var javaScriptRequestTimeoutNanoseconds: UInt64 = 5_000_000_000
    private var pendingJavaScriptRequests = [UUID: JavaScriptRequestToken]()
#if TESTING
    private var suspendsUpdateDeliveryForTesting = false
    private var bufferedUpdatesForTesting = [FloorpRichTextUpdateEnvelope]()
    private var stalledInitialNavigationAttemptsForTesting = 0
    private var initialNavigationStartCountForTesting = 0
#endif

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
        startInitialNavigationIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(
        document: FloorpRichTextDocument,
        session: FloorpRichTextEditorSessionCursor,
        isDirty: Bool
    ) {
        guard !isInvalidated else { return }
        failPendingJavaScriptRequests(with: EditorError.sessionWasReplaced)
        loadRequestVersion += 1
        pendingDocument = document
        pendingSession = session
        pendingDocumentIsDirty = isDirty
        pendingLoadRequestVersion = loadRequestVersion
        loadedSession = nil
        startInitialNavigationIfNeeded()
        loadPendingDocumentIfPossible()
    }

    func send(
        _ command: FloorpRichTextCommandEnvelope,
        requestID: String,
        completion: @escaping @MainActor (Result<FloorpRichTextUpdateEnvelope, Error>) -> Void
    ) {
        guard !isInvalidated else {
            completion(.failure(EditorError.editorInvalidated))
            return
        }
        guard requestID.utf8.count <= FloorpRichTextBridgeProtocol.maximumDocumentIDBytes,
              var commandObject = jsonObject(command) as? [String: Any] else {
            completion(.failure(EditorError.invalidJavaScriptResult))
            return
        }
        commandObject["requestID"] = requestID
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failure(EditorError.pageNotReady))
                return
            }
            do {
                try await waitUntilLoaded(expectedSession: command.session)
                let value = try await callAsyncJavaScript(
                    "return window.floorpApplyCommand(command);",
                    arguments: ["command": commandObject]
                )
                guard let value,
                      JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let envelope = try? JSONDecoder().decode(
                        FloorpRichTextUpdateEnvelope.self,
                        from: data
                      ),
                      envelope.requestID == requestID else {
                    throw EditorError.invalidJavaScriptResult
                }
                completion(.success(envelope))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func setEditable(_ isEditable: Bool) {
        requestedEditable = isEditable
        guard !isInvalidated, isPageReady else { return }
        webView.callAsyncJavaScript(
            "return window.floorpSetEditable(isEditable);",
            arguments: ["isEditable": isEditable],
            in: nil,
            in: .page
        ) { _ in }
    }

    func setEditableAndWait(_ isEditable: Bool) async throws {
        guard !isInvalidated else { throw EditorError.editorInvalidated }
        requestedEditable = isEditable
        let requestedProcessGeneration = webContentProcessGeneration
        for _ in 0..<600 where !isPageReady {
            try await Task.sleep(nanoseconds: 10_000_000)
            guard requestedProcessGeneration == webContentProcessGeneration else {
                throw EditorError.webContentProcessTerminated
            }
        }
        guard isPageReady else { throw EditorError.pageNotReady }
        let didSetEditable = try await callAsyncJavaScript(
            "return window.floorpSetEditable(isEditable);",
            arguments: ["isEditable": isEditable]
        ) as? Bool
        guard didSetEditable == true else { throw EditorError.invalidJavaScriptResult }
    }

    func focus() {
        guard !isInvalidated, isPageReady else { return }
        webView.callAsyncJavaScript(
            "document.getElementById('editor').focus(); return true;",
            arguments: [:],
            in: nil,
            in: .page
        ) { _ in }
    }

    func flush(
        expectedSession: FloorpRichTextEditorSessionCursor
    ) async throws -> FloorpRichTextUpdateEnvelope {
        try await requestDocumentEnvelope(
            functionName: "floorpFlush",
            expectedSession: expectedSession
        )
    }

    func snapshot(
        expectedSession: FloorpRichTextEditorSessionCursor
    ) async throws -> FloorpRichTextUpdateEnvelope {
        try await requestDocumentEnvelope(
            functionName: "floorpSnapshot",
            expectedSession: expectedSession
        )
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        isHidden = true
        initialNavigationWatchdogTask?.cancel()
        initialNavigationWatchdogTask = nil
        initialNavigationAttemptVersion += 1
        loadRequestVersion += 1
        pendingLoadRequestVersion = loadRequestVersion
        webContentProcessGeneration += 1
        isPageReady = false
        didAuthorizeInitialNavigation = false
        initialNavigation = nil
        loadedSession = nil
        pendingDocument = nil
        pendingSession = nil
        pendingDocumentIsDirty = false
        failPendingJavaScriptRequests(with: EditorError.editorInvalidated)
#if TESTING
        bufferedUpdatesForTesting.removeAll()
#endif
        let userContentController = webView.configuration.userContentController
        userContentController.removeScriptMessageHandler(forName: BridgeName.update)
        userContentController.removeScriptMessageHandler(forName: BridgeName.state)
        messageHandlerProxy?.target = nil
        messageHandlerProxy = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        delegate = nil
    }

#if TESTING
    func evaluateJavaScriptForTesting(_ script: String) async throws -> Any? {
        guard !isInvalidated else { throw EditorError.editorInvalidated }
        return try await evaluateJavaScript(script)
    }

    func waitForNeverResolvingJavaScriptForTesting() async throws {
        _ = try await callAsyncJavaScript(
            "return new Promise(() => {});",
            arguments: [:]
        )
    }

    func setJavaScriptRequestTimeoutForTesting(_ nanoseconds: UInt64) {
        javaScriptRequestTimeoutNanoseconds = nanoseconds
    }

    func simulateWebContentProcessTerminationForTesting() {
        webViewWebContentProcessDidTerminate(webView)
    }

    var pendingJavaScriptRequestCountForTesting: Int {
        pendingJavaScriptRequests.count
    }

    var isInvalidatedForTesting: Bool {
        isInvalidated
    }

    var isPageReadyForTesting: Bool {
        isPageReady
    }

    var hasPendingInitialNavigationForTesting: Bool {
        initialNavigation != nil || initialNavigationWatchdogTask != nil
    }

    var startedInitialNavigationCountForTesting: Int {
        initialNavigationStartCountForTesting
    }

    func setUpdateDeliverySuspendedForTesting(_ isSuspended: Bool) {
        suspendsUpdateDeliveryForTesting = isSuspended
        guard !isSuspended else { return }
        let buffered = bufferedUpdatesForTesting
        bufferedUpdatesForTesting.removeAll()
        buffered.forEach { delegate?.richTextEditor(self, received: $0) }
    }

    func restartWithStalledInitialNavigationForTesting(
        attempts: Int,
        timeoutNanoseconds: UInt64
    ) {
        stallNextInitialNavigationAttemptsForTesting(
            attempts: attempts,
            timeoutNanoseconds: timeoutNanoseconds
        )
        isPageReady = false
        loadedSession = nil
        didAuthorizeInitialNavigation = false
        initialNavigationWatchdogTask?.cancel()
        initialNavigationWatchdogTask = nil
        initialNavigationAttemptVersion += 1
        initialNavigation = nil
        webView.stopLoading()
        startInitialNavigationIfNeeded()
    }

    func stallNextInitialNavigationAttemptsForTesting(
        attempts: Int,
        timeoutNanoseconds: UInt64
    ) {
        stalledInitialNavigationAttemptsForTesting = max(0, attempts)
        initialNavigationTimeoutNanoseconds = timeoutNanoseconds
    }
#endif

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard !isInvalidated,
              navigation === initialNavigation,
              didAuthorizeInitialNavigation else {
            return
        }
        initialNavigationWatchdogTask?.cancel()
        initialNavigationWatchdogTask = nil
        initialNavigation = nil
        isPageReady = true
        setEditable(requestedEditable)
        loadPendingDocumentIfPossible()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        guard !isInvalidated, navigation === initialNavigation else { return }
        failInitialNavigationAttempt(error, version: initialNavigationAttemptVersion)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        guard !isInvalidated, navigation === initialNavigation else { return }
        failInitialNavigationAttempt(error, version: initialNavigationAttemptVersion)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isInvalidated else { return }
        webContentProcessGeneration += 1
        initialNavigationWatchdogTask?.cancel()
        initialNavigationWatchdogTask = nil
        initialNavigationAttemptVersion += 1
        isPageReady = false
        loadedSession = nil
        initialNavigation = nil
        didAuthorizeInitialNavigation = false
        failPendingJavaScriptRequests(with: EditorError.webContentProcessTerminated)
        delegate?.richTextEditorWebContentProcessDidTerminate(self)
        startInitialNavigationIfNeeded()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard !isInvalidated else {
            decisionHandler(.cancel)
            return
        }
        let isOwnedInitialNavigation = !didAuthorizeInitialNavigation
            && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.navigationType == .other
            && navigationAction.request.url == Self.editorDocumentURL
        if isOwnedInitialNavigation {
            didAuthorizeInitialNavigation = true
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let origin = message.frameInfo.securityOrigin
        guard !isInvalidated,
              message.webView === webView,
              message.frameInfo.isMainFrame,
              message.frameInfo.request.url == Self.editorDocumentURL,
              origin.`protocol`.isEmpty,
              origin.host.isEmpty,
              origin.port == 0,
              isPageReady,
              JSONSerialization.isValidJSONObject(message.body),
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
#if TESTING
            if suspendsUpdateDeliveryForTesting {
                bufferedUpdatesForTesting.append(envelope)
                return
            }
#endif
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

    private func startInitialNavigationIfNeeded() {
        guard !isInvalidated,
              !isPageReady,
              initialNavigation == nil,
              initialNavigationWatchdogTask == nil else {
            return
        }
        initialNavigationAttemptVersion += 1
        let attemptVersion = initialNavigationAttemptVersion
        isPageReady = false
        didAuthorizeInitialNavigation = false
#if TESTING
        initialNavigationStartCountForTesting += 1
        if stalledInitialNavigationAttemptsForTesting > 0 {
            stalledInitialNavigationAttemptsForTesting -= 1
            initialNavigation = nil
        } else {
            initialNavigation = webView.loadHTMLString(Self.editorHTML, baseURL: nil)
        }
#else
        initialNavigation = webView.loadHTMLString(Self.editorHTML, baseURL: nil)
#endif
        let timeout = initialNavigationTimeoutNanoseconds
        initialNavigationWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            self?.failInitialNavigationAttempt(
                EditorError.pageNotReady,
                version: attemptVersion
            )
        }
    }

    private func failInitialNavigationAttempt(_ error: Error, version: Int) {
        guard !isInvalidated,
              version == initialNavigationAttemptVersion,
              !isPageReady else {
            return
        }
        initialNavigationWatchdogTask?.cancel()
        initialNavigationWatchdogTask = nil
        initialNavigationAttemptVersion += 1
        initialNavigation = nil
        didAuthorizeInitialNavigation = false
        loadedSession = nil
        webView.stopLoading()
        failPendingJavaScriptRequests(with: error)

        let failedSession = pendingSession
        pendingDocument = nil
        pendingSession = nil
        pendingDocumentIsDirty = false
        if let failedSession {
            delegate?.richTextEditor(self, didFailLoading: failedSession, error: error)
        }
        // A controller recovery synchronously installs one replacement
        // document. Start exactly that next owned-page attempt; if it also
        // stalls, the controller transitions to its read-only fallback and
        // leaves no pending session, bounding the retry sequence.
        if pendingSession != nil {
            startInitialNavigationIfNeeded()
        }
    }

    private func loadPendingDocumentIfPossible() {
        guard !isInvalidated,
              isPageReady,
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
        let isDirty = pendingDocumentIsDirty
        let requestVersion = pendingLoadRequestVersion
        pendingDocumentIsDirty = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await callAsyncJavaScript(
                    "return window.floorpLoad(root, session, strings, isDirty);",
                    arguments: [
                        "root": root,
                        "session": sessionObject,
                        "strings": [
                            "label": FloorpStrings.Notes.contentAccessibilityLabel,
                            "placeholder": FloorpStrings.Notes.contentPlaceholder,
                        ],
                        "isDirty": isDirty,
                    ]
                )
                guard requestVersion == loadRequestVersion,
                      value as? Bool == true else {
                    return
                }
                loadedSession = session
                delegate?.richTextEditor(self, didLoad: session)
            } catch {
                guard requestVersion == loadRequestVersion else { return }
                delegate?.richTextEditor(
                    self,
                    didFailLoading: session,
                    error: error
                )
            }
        }
    }

    private func requestDocumentEnvelope(
        functionName: String,
        expectedSession: FloorpRichTextEditorSessionCursor
    ) async throws -> FloorpRichTextUpdateEnvelope {
        try await waitUntilLoaded(expectedSession: expectedSession)
        guard let sessionObject = jsonObject(expectedSession) else {
            throw EditorError.invalidJavaScriptResult
        }
        let value = try await callAsyncJavaScript(
            "return window[functionName](expectedSession);",
            arguments: [
                "functionName": functionName,
                "expectedSession": sessionObject,
            ]
        )
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            throw EditorError.invalidJavaScriptResult
        }
        guard let envelope = try? JSONDecoder().decode(
                FloorpRichTextUpdateEnvelope.self,
                from: data
              ) else {
            throw EditorError.invalidJavaScriptResult
        }
        return envelope
    }

    private func waitUntilLoaded(
        expectedSession: FloorpRichTextEditorSessionCursor
    ) async throws {
        guard !isInvalidated else { throw EditorError.editorInvalidated }
        let requestedProcessGeneration = webContentProcessGeneration
        for _ in 0..<600 {
            guard !isInvalidated else { throw EditorError.editorInvalidated }
            guard requestedProcessGeneration == webContentProcessGeneration else {
                throw EditorError.webContentProcessTerminated
            }
            if let loadedSession,
               loadedSession.noteID == expectedSession.noteID,
               loadedSession.documentID == expectedSession.documentID,
               loadedSession.generation == expectedSession.generation {
                return
            }
            if let pendingSession,
               pendingSession.noteID != expectedSession.noteID
                || pendingSession.documentID != expectedSession.documentID
                || pendingSession.generation != expectedSession.generation {
                throw EditorError.sessionWasReplaced
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw EditorError.pageNotReady
    }

    private func callAsyncJavaScript(
        _ body: String,
        arguments: [String: Any]
    ) async throws -> Any? {
        guard !isInvalidated else { throw EditorError.editorInvalidated }
        let requestID = UUID()
        let result: JavaScriptValue = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let token = registerJavaScriptRequest(
                    id: requestID,
                    continuation: continuation
                )
                webView.callAsyncJavaScript(
                    body,
                    arguments: arguments,
                    in: nil,
                    in: .page
                ) { result in
                    switch result {
                    case .success(let value):
                        token.resolve(.success(JavaScriptValue(value: value)))
                    case .failure(let error):
                        token.resolve(.failure(error))
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.pendingJavaScriptRequests[requestID]?.resolve(
                    .failure(CancellationError())
                )
            }
        }
        return result.value
    }

    private func evaluateJavaScript(_ script: String) async throws -> Any? {
        guard !isInvalidated else { throw EditorError.editorInvalidated }
        let requestID = UUID()
        let result: JavaScriptValue = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let token = registerJavaScriptRequest(
                    id: requestID,
                    continuation: continuation
                )
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        token.resolve(.failure(error))
                    } else {
                        token.resolve(.success(JavaScriptValue(value: value)))
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.pendingJavaScriptRequests[requestID]?.resolve(
                    .failure(CancellationError())
                )
            }
        }
        return result.value
    }

    private func registerJavaScriptRequest(
        id: UUID,
        continuation: CheckedContinuation<JavaScriptValue, Error>
    ) -> JavaScriptRequestToken {
        let token = JavaScriptRequestToken(id: id) { [weak self] result in
            self?.pendingJavaScriptRequests.removeValue(forKey: id)
            continuation.resume(with: result)
        }
        pendingJavaScriptRequests[id] = token
        token.beginTimeout(after: javaScriptRequestTimeoutNanoseconds)
        return token
    }

    private func failPendingJavaScriptRequests(with error: Error) {
        let requests = Array(pendingJavaScriptRequests.values)
        pendingJavaScriptRequests.removeAll()
        requests.forEach { $0.resolve(.failure(error)) }
    }

    private func jsonObject<Value: Encodable>(_ value: Value) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static let editorHTML = #"""
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy"
            content="default-src 'none'; img-src data:; connect-src 'none';
                     style-src 'unsafe-inline'; script-src 'unsafe-inline'">
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
      <div id="editor" contenteditable="false" role="textbox" aria-multiline="true"
           aria-label="" data-placeholder=""></div>
      <script>
      (() => {
        const editor = document.getElementById('editor');
        let session = null;
        let suppressUpdates = false;
        let dirty = false;
        let savedRange = null;
        let savedTextSelection = null;

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
        const renderMarkedNode = (renderedNode, marks) => {
          let result = renderedNode;
          [...(marks || [])].reverse().forEach((mark) => {
            const names = { bold: 'strong', italic: 'em', underline: 'u', strike: 's', code: 'code' };
            const tag = names[mark.type];
            if (!tag) return;
            const wrapper = document.createElement(tag);
            wrapper.appendChild(result);
            result = wrapper;
          });
          return result;
        };
        const renderText = (node) =>
          renderMarkedNode(document.createTextNode(node.text || ''), node.marks);
        const renderNode = (node) => {
          let element;
          switch (node.type) {
            case 'text': return renderText(node);
            case 'hardBreak': return renderMarkedNode(document.createElement('br'), node.marks);
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
              if (Number.isInteger(node.attrs?.width)) {
                element.setAttribute('width', String(node.attrs.width));
              }
              element.referrerPolicy = 'no-referrer';
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
            const attrs = { src: node.getAttribute('src') || '' };
            if (node.hasAttribute('alt')) attrs.alt = node.alt;
            if (node.hasAttribute('title')) attrs.title = node.title;
            if (node.hasAttribute('width')) {
              const width = Number.parseInt(node.getAttribute('width'), 10);
              if (Number.isInteger(width)) attrs.width = width;
            }
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
        const rangeBelongsToEditor = (range) => {
          if (!range) return false;
          const ancestor = range.commonAncestorContainer;
          const element = ancestor.nodeType === Node.TEXT_NODE ? ancestor.parentElement : ancestor;
          return element === editor || editor.contains(element);
        };
        const textOffsetAt = (container, offset) => {
          const probe = document.createRange();
          probe.selectNodeContents(editor);
          try {
            probe.setEnd(container, offset);
          } catch (_) {
            return null;
          }
          return probe.cloneContents().textContent.length;
        };
        const nodePathFromEditor = (node) => {
          const path = [];
          let current = node;
          while (current && current !== editor) {
            const parent = current.parentNode;
            if (!parent) return null;
            const index = [...parent.childNodes].indexOf(current);
            if (index < 0) return null;
            path.unshift(index);
            current = parent;
          }
          return current === editor ? path : null;
        };
        const domPointFor = (container, offset) => {
          const path = nodePathFromEditor(container);
          if (!path) return null;
          return { path, offset, nodeType: container.nodeType };
        };
        const pointAtDOMPoint = (bookmark) => {
          if (!bookmark || !Array.isArray(bookmark.path)) return null;
          let node = editor;
          for (const index of bookmark.path) {
            if (!Number.isInteger(index) || index < 0 || index >= node.childNodes.length) return null;
            node = node.childNodes[index];
          }
          if (node.nodeType !== bookmark.nodeType) return null;
          const maximumOffset = node.nodeType === Node.TEXT_NODE
            ? node.data.length
            : node.childNodes.length;
          if (!Number.isInteger(bookmark.offset) ||
              bookmark.offset < 0 || bookmark.offset > maximumOffset) return null;
          return { node, offset: bookmark.offset };
        };
        const pointAffinity = (container, offset) => {
          if (container.nodeType === Node.TEXT_NODE && offset === 0) return 'forward';
          return 'backward';
        };
        const textSelectionForRange = (range) => {
          if (!rangeBelongsToEditor(range)) return null;
          const start = textOffsetAt(range.startContainer, range.startOffset);
          const end = textOffsetAt(range.endContainer, range.endOffset);
          return start === null || end === null ? null : {
            start,
            end,
            collapsed: range.collapsed,
            startPoint: domPointFor(range.startContainer, range.startOffset),
            endPoint: domPointFor(range.endContainer, range.endOffset),
            startAffinity: pointAffinity(range.startContainer, range.startOffset),
            endAffinity: pointAffinity(range.endContainer, range.endOffset),
          };
        };
        const pointAtTextOffset = (requestedOffset, affinity = 'backward') => {
          let offset = Math.max(0, requestedOffset);
          const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
          let lastText = null;
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            lastText = node;
            if (offset < node.data.length) return { node, offset };
            if (offset === node.data.length && affinity !== 'forward') return { node, offset };
            offset -= node.data.length;
          }
          if (lastText) return { node: lastText, offset: lastText.data.length };
          return { node: editor, offset: editor.childNodes.length };
        };
        const rangeForTextSelection = (bookmark) => {
          if (!bookmark) return null;
          const collapsedPoint = bookmark.collapsed
            ? pointAtDOMPoint(bookmark.startPoint)
            : null;
          const start = collapsedPoint || pointAtTextOffset(
            bookmark.start,
            bookmark.startAffinity
          );
          const end = collapsedPoint || pointAtTextOffset(
            bookmark.end,
            bookmark.endAffinity
          );
          const range = document.createRange();
          try {
            range.setStart(start.node, start.offset);
            range.setEnd(end.node, end.offset);
          } catch (_) {
            return null;
          }
          return range;
        };
        const sameDOMPoint = (left, right) =>
          left && right &&
          left.nodeType === right.nodeType &&
          left.offset === right.offset &&
          left.path.length === right.path.length &&
          left.path.every((value, index) => value === right.path[index]);
        const rangeMatchesBookmark = (range, bookmark) => {
          const current = textSelectionForRange(range);
          if (!current || !bookmark || current.collapsed !== bookmark.collapsed) return false;
          if (bookmark.collapsed) {
            return sameDOMPoint(current.startPoint, bookmark.startPoint);
          }
          return current.start === bookmark.start && current.end === bookmark.end;
        };
        const rememberSelection = () => {
          const selection = document.getSelection();
          if (!selection?.rangeCount) {
            savedRange = null;
            savedTextSelection = null;
            return;
          }
          const range = selection.getRangeAt(0);
          if (!rangeBelongsToEditor(range)) {
            savedRange = null;
            savedTextSelection = null;
            return;
          }
          savedRange = range.cloneRange();
          savedTextSelection = textSelectionForRange(range);
        };
        const insertionRange = () => {
          const selection = document.getSelection();
          if (selection?.rangeCount) {
            const active = selection.getRangeAt(0);
            if (rangeBelongsToEditor(active)) return active.cloneRange();
          }
          return rangeBelongsToEditor(savedRange) ? savedRange.cloneRange() : null;
        };
        const restoreEditorSelection = () => {
          const selection = document.getSelection();
          if (selection?.rangeCount) {
            const active = selection.getRangeAt(0);
            if (rangeBelongsToEditor(active) && rangeMatchesBookmark(active, savedTextSelection)) {
              savedRange = active.cloneRange();
              savedTextSelection = textSelectionForRange(active);
              return active;
            }
          }
          const rememberedRange = rangeForTextSelection(savedTextSelection);
          const range = rememberedRange || insertionRange();
          if (!range) return null;
          selection.removeAllRanges();
          selection.addRange(range);
          savedRange = range.cloneRange();
          savedTextSelection = textSelectionForRange(range);
          return range;
        };
        const topLevelChild = (node) => {
          let current = node?.nodeType === Node.TEXT_NODE ? node.parentNode : node;
          while (current && current.parentNode !== editor) current = current.parentNode;
          return current?.parentNode === editor ? current : null;
        };
        const insertImageAtSelection = (imageData) => {
          const range = insertionRange();
          if (!range) return false;
          const image = document.createElement('img');
          image.src = imageData.source;
          if (typeof imageData.alt === 'string') image.alt = imageData.alt;
          if (typeof imageData.title === 'string') image.title = imageData.title;
          if (imageData.width) image.setAttribute('width', String(imageData.width));
          image.referrerPolicy = 'no-referrer';
          image.contentEditable = 'false';

          let reference = null;
          if (range.startContainer === editor) {
            reference = editor.childNodes[range.startOffset] || null;
          } else {
            reference = topLevelChild(range.startContainer)?.nextSibling || null;
          }
          try {
            editor.insertBefore(image, reference);
          } catch (_) {
            return false;
          }
          const nextRange = document.createRange();
          nextRange.setStartAfter(image);
          nextRange.collapse(true);
          const selection = document.getSelection();
          selection.removeAllRanges();
          selection.addRange(nextRange);
          savedRange = nextRange.cloneRange();
          savedTextSelection = textSelectionForRange(nextRange);
          return true;
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
        const envelope = (payload, requestID = null) => ({
          schemaVersion: 1,
          ...(typeof requestID === 'string' && requestID ? { requestID } : {}),
          session: clone(session),
          payload,
        });
        const emitState = () => {
          if (!session) return;
          window.webkit.messageHandlers.floorpRichTextState.postMessage(envelope(activeState()));
        };
        const emitUpdate = (requestID = null) => {
          if (!session || suppressUpdates) return;
          dirty = true;
          session.revision += 1;
          const source = JSON.stringify(currentDocument());
          const update = envelope({ source, isDirty: true }, requestID);
          window.webkit.messageHandlers.floorpRichTextUpdate.postMessage(update);
          emitState();
          return update;
        };

        const matchesExpectedSession = (expected) =>
          session && expected &&
          expected.noteID === session.noteID &&
          expected.documentID === session.documentID &&
          expected.generation === session.generation &&
          expected.revision <= session.revision;

        window.floorpLoad = (root, nextSession, strings, isDirty) => {
          suppressUpdates = true;
          session = clone(nextSession);
          dirty = Boolean(isDirty);
          savedRange = null;
          savedTextSelection = null;
          editor.setAttribute('aria-label', strings?.label || '');
          editor.dataset.placeholder = strings?.placeholder || '';
          editor.replaceChildren(...(root.content || [{ type: 'paragraph' }]).map(renderNode));
          const initialRange = document.createRange();
          initialRange.selectNodeContents(editor);
          initialRange.collapse(false);
          savedRange = initialRange;
          savedTextSelection = textSelectionForRange(initialRange);
          suppressUpdates = false;
          emitState();
          return true;
        };
        window.floorpSnapshot = (expected) => {
          if (!matchesExpectedSession(expected)) return null;
          return envelope({ source: JSON.stringify(currentDocument()), isDirty: dirty });
        };
        window.floorpFlush = (expected) => {
          if (!matchesExpectedSession(expected)) return null;
          if (dirty) session.revision += 1;
          return envelope({ source: JSON.stringify(currentDocument()), isDirty: dirty });
        };
        window.floorpSetEditable = (isEditable) => {
          editor.contentEditable = isEditable ? 'true' : 'false';
          editor.setAttribute('aria-readonly', isEditable ? 'false' : 'true');
          return true;
        };
        window.floorpApplyCommand = (message) => {
          if (!session || message.schemaVersion !== 1) return false;
          const requestID = message.requestID;
          if (typeof requestID !== 'string' || !requestID || requestID.length > 128) return false;
          const incoming = message.session;
          if (incoming.noteID !== session.noteID || incoming.documentID !== session.documentID ||
              incoming.generation !== session.generation || incoming.revision > session.revision) return false;
          const planned = message.payload;
          const command = planned.command;
          let applied = true;
          let exclusiveMarkChanged = false;
          const preservesSelection = !['undo', 'redo', 'insertImage'].includes(command.kind);
          const commandRange = preservesSelection ? restoreEditorSelection() : null;
          const commandSelection = textSelectionForRange(commandRange);
          if (preservesSelection && !commandRange) {
            return false;
          }
          suppressUpdates = true;
          try {
            if (planned.exclusiveMarkToUnset) {
              const unset = planned.exclusiveMarkToUnset === 'strike'
                ? 'strikeThrough'
                : planned.exclusiveMarkToUnset;
              if (document.queryCommandState(unset)) {
                exclusiveMarkChanged = document.execCommand(unset, false);
              }
            }
            switch (command.kind) {
              case 'undo': applied = document.execCommand('undo'); break;
              case 'redo': applied = document.execCommand('redo'); break;
              case 'setParagraph': applied = document.execCommand('formatBlock', false, 'p'); break;
              case 'toggleHeading': {
                const block = nearestBlock();
                const activeTag = block?.tagName?.toLowerCase();
                const target = activeTag === `h${command.level}` ? 'p' : `h${command.level}`;
                applied = document.execCommand('formatBlock', false, target);
                break;
              }
              case 'toggleMark':
                applied = document.execCommand(
                  command.mark === 'strike' ? 'strikeThrough' : command.mark,
                  false
                );
                break;
              case 'toggleList':
                applied = document.execCommand(
                  command.listKind === 'ordered' ? 'insertOrderedList' : 'insertUnorderedList'
                );
                break;
              case 'setAlignment':
                applied = document.execCommand(
                  `justify${command.alignment[0].toUpperCase()}${command.alignment.slice(1)}`
                );
                break;
              case 'insertImage':
                applied = insertImageAtSelection(command.image);
                break;
              default: applied = false;
            }
          } catch (_) {
            applied = false;
          } finally {
            suppressUpdates = false;
          }
          if (!applied && !exclusiveMarkChanged) return false;
          const restoredRange = commandSelection?.collapsed
            ? null
            : rangeForTextSelection(commandSelection);
          if (restoredRange && rangeBelongsToEditor(restoredRange)) {
            const selection = document.getSelection();
            selection.removeAllRanges();
            selection.addRange(restoredRange);
            savedRange = restoredRange.cloneRange();
            savedTextSelection = textSelectionForRange(restoredRange);
          } else if (commandSelection?.collapsed) {
            const selection = document.getSelection();
            if (selection?.rangeCount && rangeBelongsToEditor(selection.getRangeAt(0))) {
              savedRange = selection.getRangeAt(0).cloneRange();
              savedTextSelection = textSelectionForRange(selection.getRangeAt(0));
            }
          }
          return emitUpdate(requestID);
        };

        const transferContainsImage = (transfer) => {
          if (!transfer) return false;
          const items = [...(transfer.items || [])];
          const files = [...(transfer.files || [])];
          return items.some((item) => (item.type || '').toLowerCase().startsWith('image/')) ||
            files.some((file) => (file.type || '').toLowerCase().startsWith('image/'));
        };
        const insertTransferredPlainText = (transfer) => {
          if (!transfer || transferContainsImage(transfer)) return false;
          const text = transfer.getData('text/plain');
          if (!text) return false;
          const range = restoreEditorSelection() || insertionRange();
          if (!range) return false;
          const selection = document.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          if (document.execCommand('insertText', false, text)) return true;
          range.deleteContents();
          const textNode = document.createTextNode(text);
          range.insertNode(textNode);
          range.setStartAfter(textNode);
          range.collapse(true);
          selection.removeAllRanges();
          selection.addRange(range);
          savedRange = range.cloneRange();
          savedTextSelection = textSelectionForRange(range);
          editor.dispatchEvent(new InputEvent('input', {
            bubbles: true,
            inputType: 'insertText',
            data: text,
          }));
          return true;
        };
        const handleTransfer = (event, transfer) => {
          event.preventDefault();
          event.stopPropagation();
          if (!session || editor.contentEditable !== 'true') return;
          insertTransferredPlainText(transfer);
        };

        editor.addEventListener('beforeinput', (event) => {
          if (event.inputType === 'insertFromPaste' || event.inputType === 'insertFromDrop') {
            event.preventDefault();
          }
        });
        editor.addEventListener('paste', (event) => handleTransfer(event, event.clipboardData));
        editor.addEventListener('drop', (event) => handleTransfer(event, event.dataTransfer));
        editor.addEventListener('input', emitUpdate);
        editor.addEventListener('keyup', emitState);
        editor.addEventListener('mouseup', emitState);
        document.addEventListener('selectionchange', () => {
          rememberSelection();
          emitState();
        });
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
