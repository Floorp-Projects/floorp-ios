// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import Common
import Shared

/// Owns the persistence identity for one editor session.
///
/// New drafts stay in memory until the editor reports its first change. Once
/// created, every later save uses the last persisted revision so concurrent
/// edits continue to be rejected by `FloorpNotesStore`.
@MainActor
final class FloorpNotePersistenceSession {
    private let notesStore: FloorpNotesStore
    private var persistedNote: FloorpNote?
    private var isSaving = false
    private var saveWaiters = [CheckedContinuation<Void, Never>]()

    init(notesStore: FloorpNotesStore, persistedNote: FloorpNote?) {
        self.notesStore = notesStore
        self.persistedNote = persistedNote
    }

    func save(_ draft: FloorpNote) async throws -> FloorpNote {
        if isSaving {
            await withCheckedContinuation { continuation in
                saveWaiters.append(continuation)
            }
            return try await save(draft)
        }

        isSaving = true
        defer {
            isSaving = false
            let waiters = saveWaiters
            saveWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        let savedNote: FloorpNote
        if let persistedNote {
            savedNote = try await notesStore.updateNote(
                id: persistedNote.id,
                title: draft.title,
                content: draft.content,
                expectedUpdatedAt: persistedNote.updatedAt
            )
        } else {
            savedNote = try await notesStore.createNote(
                title: draft.title,
                content: draft.content
            )
        }
        persistedNote = savedNote
        return savedNote
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
    private let onSave: @MainActor (FloorpNote) async throws -> FloorpNote
    private var draft: FloorpNote
    private let contentAnalysis: FloorpNoteContent.Analysis
    private var didApprovePlainTextConversion: Bool
    private var changeVersion = 0
    private var savedVersion = 0
    private var hasPersistedNote: Bool
    private var isSaving = false
    private var saveWaiters = [CheckedContinuation<Void, Never>]()
    private var autosaveTask: Task<Void, Never>?
    private var savedStatusResetTask: Task<Void, Never>?
    private var isApplyingPendingEdit = false

    private lazy var titleField: UITextField = {
        let field = UITextField()
        field.font = FXFontStyles.Bold.title3.scaledFont()
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .next
        field.borderStyle = .roundedRect
        field.placeholder = FloorpStrings.Notes.titlePlaceholder
        field.accessibilityLabel = FloorpStrings.Notes.titlePlaceholder
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
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
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
        onSave: @escaping @MainActor (FloorpNote) async throws -> FloorpNote
    ) {
        let contentAnalysis = FloorpNoteContent.analyze(note.content)
        self.draft = note
        self.contentAnalysis = contentAnalysis
        self.didApprovePlainTextConversion = contentAnalysis.editPolicy == .direct
        self.windowUUID = windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        self.hasPersistedNote = isPersisted
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
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
        navigationItem.rightBarButtonItem?.accessibilityLabel = FloorpStrings.Notes.saveAccessibilityLabel

        view.addSubview(titleField)
        view.addSubview(statusLabel)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: UX.padding),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: UX.padding),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -UX.padding),
            titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: UX.minimumControlHeight),

            statusLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),

            textView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
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

        titleField.text = draft.title
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
        textView.backgroundColor = colors.layer3
        textView.textColor = colors.textPrimary
        textView.tintColor = colors.actionPrimary
        textView.keyboardAppearance = theme.type.keyboardAppearence(isPrivate: false)
        textView.layer.borderColor = colors.borderPrimary.cgColor
    }

    @objc private func titleChanged() {
        draft.title = titleField.text ?? ""
        markChanged()
    }

    @objc private func saveTapped() {
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
        if !hasPersistedNote && savedVersion == changeVersion {
            changeVersion += 1
            setInteractiveDismissalBlocked(true)
        }
        return await saveLatestDraft()
    }

    @objc private func closeTapped() {
        Task { @MainActor in
            autosaveTask?.cancel()
            if savedVersion != changeVersion {
                guard await saveLatestDraft() else {
                    presentDiscardChangesConfirmation()
                    return
                }
            }
            dismiss(animated: true)
        }
    }

    @objc private func applicationWillResignActive() {
        guard savedVersion != changeVersion else { return }
        autosaveTask?.cancel()
        Task { @MainActor [weak self] in
            _ = await self?.saveLatestDraft()
        }
    }

    private func markChanged() {
        changeVersion += 1
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
    private func saveLatestDraft() async -> Bool {
        if isSaving {
            await withCheckedContinuation { continuation in
                saveWaiters.append(continuation)
            }
            return savedVersion == changeVersion
        }
        guard savedVersion != changeVersion else { return true }

        isSaving = true
        var lastAttemptSucceeded = true

        repeat {
            let versionToSave = changeVersion
            let noteToSave = draft
            updateSaveState(.saving)

            do {
                let persistedNote = try await onSave(noteToSave)
                savedVersion = versionToSave
                hasPersistedNote = true
                // Keep edits made while this save was in flight, but adopt the
                // real identity assigned when a new draft is first persisted.
                draft = FloorpNote(
                    id: persistedNote.id,
                    title: draft.title,
                    content: draft.content,
                    createdAt: persistedNote.createdAt,
                    updatedAt: persistedNote.updatedAt
                )
                lastAttemptSucceeded = true
                if savedVersion == changeVersion {
                    updateSaveState(.saved)
                }
            } catch {
                lastAttemptSucceeded = false
                updateSaveState(.failed)
                break
            }
        } while savedVersion != changeVersion

        isSaving = false
        setInteractiveDismissalBlocked(savedVersion != changeVersion)
        let waiters = saveWaiters
        saveWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return lastAttemptSucceeded && savedVersion == changeVersion
    }

    private func setInteractiveDismissalBlocked(_ isBlocked: Bool) {
        isModalInPresentation = isBlocked
        navigationController?.isModalInPresentation = isBlocked
    }

    private func updateSaveState(_ state: SaveState) {
        savedStatusResetTask?.cancel()
        switch state {
        case .idle:
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
            navigationItem.rightBarButtonItem?.isEnabled = false
        case .saved:
            statusLabel.text = FloorpStrings.Notes.saved
            navigationItem.rightBarButtonItem?.isEnabled = true
            savedStatusResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self?.savedVersion == self?.changeVersion else { return }
                self?.updateSaveState(.idle)
            }
        case .failed:
            statusLabel.text = FloorpStrings.Notes.saveFailed
            navigationItem.rightBarButtonItem?.isEnabled = true
        }
    }

    private func presentDiscardChangesConfirmation() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: FloorpStrings.Notes.discardChangesTitle,
            message: FloorpStrings.Notes.discardChangesMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.Notes.keepEditing, style: .cancel))
        alert.addAction(
            UIAlertAction(title: FloorpStrings.Notes.discardChanges, style: .destructive) { [weak self] _ in
                guard let self else { return }
                autosaveTask?.cancel()
                setInteractiveDismissalBlocked(false)
                navigationController?.dismiss(animated: true)
            }
        )
        present(alert, animated: true)
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
        draft.content = updatedText
        markChanged()
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
        draft.content = textView.text
        markChanged()
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
