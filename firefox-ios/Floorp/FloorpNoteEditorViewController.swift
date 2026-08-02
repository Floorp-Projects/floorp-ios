// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import Common
import Shared

@MainActor
protocol FloorpNotePersistence: AnyObject {
    func save(_ draft: FloorpNote) async throws -> FloorpNote
    func reload() async throws -> FloorpNote?
    func acceptReloaded(_ note: FloorpNote)
    func saveAsCopy(_ draft: FloorpNote) async throws -> FloorpNote
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

    private static func failureKind(for error: Error) -> FailureKind {
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
///
/// Plain text is fully editable. Rich TipTap/Lexical content remains byte-for-
/// byte unchanged until the user explicitly accepts conversion to plain text.
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

    private let notificationCenter: NotificationProtocol
    private let saveCoordinator: FloorpNoteSaveCoordinator
    private var contentAnalysis: FloorpNoteContent.Analysis
    private var didApprovePlainTextConversion: Bool
    private var autosaveTask: Task<Void, Never>?
    private var savedStatusResetTask: Task<Void, Never>?
    private var isApplyingPendingEdit = false
    private let backgroundSaveLease = FloorpBackgroundSaveLease()
    private let shouldFocusTitleOnFirstAppearance: Bool
    private var didApplyInitialFocus = false

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
        self.contentAnalysis = contentAnalysis
        self.didApprovePlainTextConversion = contentAnalysis.editPolicy == .direct
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
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: UX.padding),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: UX.padding),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -UX.padding),
            titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: UX.minimumControlHeight),

            statusStackView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            statusStackView.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            statusStackView.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            statusStackView.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),

            textView.topAnchor.constraint(equalTo: statusStackView.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: UX.padding),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -UX.padding),
            textView.bottomAnchor.constraint(
                lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor,
                constant: -UX.padding
            ),
            textView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -UX.padding
            ).withPriority(.defaultLow),
        ])

        titleField.text = saveCoordinator.draft.title
        textView.text = contentAnalysis.editorText
        textView.isEditable = contentAnalysis.editPolicy != .readOnly
        if contentAnalysis.editPolicy == .readOnly {
            textView.accessibilityHint = FloorpStrings.Notes.unsupportedContentReadOnlyNotice
        }
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
            switch contentAnalysis.editPolicy {
            case .readOnly:
                statusLabel.text = FloorpStrings.Notes.unsupportedContentReadOnlyNotice
            case .requiresConversion where !didApprovePlainTextConversion:
                statusLabel.text = FloorpStrings.Notes.richTextReadOnlyNotice
            case .direct, .requiresConversion:
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
        textView.isEditable = isEnabled && contentAnalysis.editPolicy != .readOnly
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
        didApprovePlainTextConversion = contentAnalysis.editPolicy == .direct
        titleField.text = note.title
        textView.text = contentAnalysis.editorText
        textView.isEditable = contentAnalysis.editPolicy != .readOnly
        textView.accessibilityHint = contentAnalysis.editPolicy == .readOnly
            ? FloorpStrings.Notes.unsupportedContentReadOnlyNotice
            : FloorpStrings.Notes.contentAccessibilityHint
        setInteractiveDismissalBlocked(false)
        updateSaveState(.idle)
    }

    private func dismissDiscardingChanges() {
        autosaveTask?.cancel()
        setInteractiveDismissalBlocked(false)
        navigationController?.dismiss(animated: true)
    }

    private func requestPlainTextConversion(
        range: NSRange,
        replacementText: String
    ) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: FloorpStrings.Notes.convertRichTextTitle,
            message: FloorpStrings.Notes.convertRichTextMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.Notes.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: FloorpStrings.Notes.convert, style: .destructive) { [weak self] _ in
                self?.applyPendingPlainTextEdit(range: range, replacementText: replacementText)
            }
        )
        present(alert, animated: true)
    }

    private func applyPendingPlainTextEdit(range: NSRange, replacementText: String) {
        let currentText = textView.text ?? ""
        guard let swiftRange = Range(range, in: currentText) else { return }
        let updatedText = currentText.replacingCharacters(in: swiftRange, with: replacementText)
        let cursorOffset = range.location + (replacementText as NSString).length

        didApprovePlainTextConversion = true
        isApplyingPendingEdit = true
        textView.text = updatedText
        textView.selectedRange = NSRange(location: cursorOffset, length: 0)
        isApplyingPendingEdit = false
        if saveCoordinator.updateContent(updatedText, contentFormat: .plainText) {
            draftDidChange()
        }
    }
}

extension FloorpNoteEditorViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textView.becomeFirstResponder()
        return false
    }
}

extension FloorpNoteEditorViewController: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        switch contentAnalysis.editPolicy {
        case .direct:
            return true
        case .readOnly:
            return false
        case .requiresConversion:
            guard !didApprovePlainTextConversion else { return true }
            requestPlainTextConversion(range: range, replacementText: text)
            return false
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isApplyingPendingEdit else { return }
        if saveCoordinator.updateContent(textView.text, contentFormat: .plainText) {
            draftDidChange()
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
