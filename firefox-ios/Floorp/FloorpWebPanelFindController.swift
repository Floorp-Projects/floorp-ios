// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
@preconcurrency import WebKit

enum FloorpWebPanelFindDirection: Equatable, Sendable {
    case forward
    case backward
}

enum FloorpWebPanelFindRequestKind: Equatable, Sendable {
    case queryChanged
    case navigation
}

struct FloorpWebPanelFindRequest: Equatable, Sendable {
    let query: String
    let direction: FloorpWebPanelFindDirection
    let kind: FloorpWebPanelFindRequestKind

    var wraps: Bool {
        kind == .queryChanged
    }
}

typealias FloorpWebPanelFindCompletion = @MainActor @Sendable (Bool) -> Void
typealias FloorpWebPanelFindTimeoutHandler = @MainActor @Sendable () -> Void

@MainActor
protocol FloorpWebPanelFindTimeoutScheduling {
    func schedule(
        after nanoseconds: UInt64,
        handler: @escaping FloorpWebPanelFindTimeoutHandler
    ) -> Task<Void, Never>
}

@MainActor
final class DefaultFloorpWebPanelFindTimeoutScheduler: FloorpWebPanelFindTimeoutScheduling {
    func schedule(
        after nanoseconds: UInt64,
        handler: @escaping FloorpWebPanelFindTimeoutHandler
    ) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            handler()
        }
    }
}

@MainActor
protocol FloorpWebPanelFindTarget: AnyObject {
    var supportsNativeFindInteraction: Bool { get }

    @discardableResult
    func presentNativeFindNavigator() -> Bool
    func findNextUsingNativeInteraction()
    func findPreviousUsingNativeInteraction()
    func find(
        _ request: FloorpWebPanelFindRequest,
        completion: @escaping FloorpWebPanelFindCompletion
    )
    func endFindSession()
    func invalidate()
}

extension FloorpWebPanelFindTarget {
    func invalidate() {
        endFindSession()
    }
}

@MainActor
final class DefaultFloorpWebPanelFindTarget: FloorpWebPanelFindTarget {
    private weak var webView: WKWebView?
    private var isFindSessionActive = false
    private var isFindOperationInFlight = false
    private var pendingOperations = [FindOperation]()
    private var isInvalidated = false

    private enum FindOperation {
        case find(FloorpWebPanelFindRequest, FloorpWebPanelFindCompletion)
        case clear
    }

    var supportsNativeFindInteraction: Bool {
        if #available(iOS 16.0, *) {
            return webView != nil
        }
        return false
    }

    init(webView: WKWebView) {
        self.webView = webView
    }

    @discardableResult
    func presentNativeFindNavigator() -> Bool {
        guard #available(iOS 16.0, *), let webView else { return false }
        webView.isFindInteractionEnabled = true
        guard let interaction = webView.findInteraction else {
            webView.isFindInteractionEnabled = false
            return false
        }
        if !interaction.isFindNavigatorVisible {
            interaction.searchText = nil
        }
        isFindSessionActive = true
        _ = webView.becomeFirstResponder()
        interaction.presentFindNavigator(showingReplace: false)
        return true
    }

    func findNextUsingNativeInteraction() {
        guard #available(iOS 16.0, *) else { return }
        webView?.findInteraction?.findNext()
    }

    func findPreviousUsingNativeInteraction() {
        guard #available(iOS 16.0, *) else { return }
        webView?.findInteraction?.findPrevious()
    }

    func find(
        _ request: FloorpWebPanelFindRequest,
        completion: @escaping FloorpWebPanelFindCompletion
    ) {
        guard !isInvalidated, webView != nil else {
            completion(false)
            return
        }
        isFindSessionActive = !request.query.isEmpty
        pendingOperations.append(.find(request, completion))
        startNextOperationIfNeeded()
    }

    func endFindSession() {
        guard let webView else { return }
        let wasUsingNativeFind = nativeFindInteractionIsEnabled(on: webView)
        guard isFindSessionActive || wasUsingNativeFind else {
            return
        }
        isFindSessionActive = false
        if #available(iOS 16.0, *), wasUsingNativeFind {
            webView.findInteraction?.searchText = nil
            webView.findInteraction?.dismissFindNavigator()
            webView.isFindInteractionEnabled = false
        }
        guard !wasUsingNativeFind else { return }
        let canceledCompletions = pendingOperations.compactMap { operation in
            if case .find(_, let completion) = operation {
                return completion
            }
            return nil
        }
        pendingOperations.removeAll()
        pendingOperations.append(.clear)
        canceledCompletions.forEach { $0(false) }
        startNextOperationIfNeeded()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        isFindSessionActive = false
        if #available(iOS 16.0, *), let webView, webView.isFindInteractionEnabled {
            webView.findInteraction?.searchText = nil
            webView.findInteraction?.dismissFindNavigator()
            webView.isFindInteractionEnabled = false
        }
        pendingOperations.removeAll()
        isFindOperationInFlight = false
        webView = nil
    }

    private func startNextOperationIfNeeded() {
        guard !isInvalidated, !isFindOperationInFlight else { return }
        guard let webView else {
            let completions = pendingOperations.compactMap { operation in
                if case .find(_, let completion) = operation {
                    return completion
                }
                return nil
            }
            pendingOperations.removeAll()
            completions.forEach { $0(false) }
            return
        }
        guard !pendingOperations.isEmpty else { return }
        let operation = pendingOperations.removeFirst()
        isFindOperationInFlight = true
        switch operation {
        case .find(let request, let completion):
            let configuration = WKFindConfiguration()
            configuration.backwards = request.direction == .backward
            configuration.caseSensitive = false
            configuration.wraps = request.wraps
            webView.find(request.query, configuration: configuration) { [weak self] result in
                guard let self, !self.isInvalidated else { return }
                self.isFindOperationInFlight = false
                completion(result.matchFound)
                self.startNextOperationIfNeeded()
            }
        case .clear:
            let configuration = WKFindConfiguration()
            configuration.wraps = false
            webView.find("", configuration: configuration) { [weak self] _ in
                guard let self, !self.isInvalidated else { return }
                self.isFindOperationInFlight = false
                self.startNextOperationIfNeeded()
            }
        }
    }

    private func nativeFindInteractionIsEnabled(on webView: WKWebView) -> Bool {
        if #available(iOS 16.0, *) {
            return webView.isFindInteractionEnabled
        }
        return false
    }
}

@MainActor
final class FloorpWebPanelFindController: NSObject {
    enum State: Equatable {
        case inactive
        case native
        case empty
        case searching(String)
        case match(String)
        case noMatch(String)
        case finished(String, FloorpWebPanelFindDirection)
        case unavailable(String)
    }

    typealias AccessibilityAnnouncement = @MainActor (String) -> Void

    static let fallbackToolbarHeight: CGFloat = 52

    let toolbarView: UIView
    private(set) var state: State = .inactive {
        didSet { renderState() }
    }
    private(set) var isUsingNativeFindInteraction = false

    private let target: any FloorpWebPanelFindTarget
    private let accessibilityAnnouncement: AccessibilityAnnouncement
    private let requestTimeoutNanoseconds: UInt64
    private let timeoutScheduler: any FloorpWebPanelFindTimeoutScheduling
    private let scrollView: UIScrollView
    private let stackView: UIStackView
    private let queryTextField: UITextField
    private let statusLabel: UILabel
    private let previousButton: UIButton
    private let nextButton: UIButton
    private let closeButton: UIButton
    private var requestGeneration: UInt64 = 0
    private var activeRequestID: UUID?
    private var pendingRequest: PendingRequest?
    private var requestTimeoutTask: Task<Void, Never>?
    private var hasMatchForCurrentQuery = false
    private var isInvalidated = false

    private struct PendingRequest: Sendable {
        let id: UUID
        let generation: UInt64
        let request: FloorpWebPanelFindRequest
        let canReportFinished: Bool
    }

    init(
        target: any FloorpWebPanelFindTarget,
        requestTimeoutNanoseconds: UInt64 = 5_000_000_000,
        timeoutScheduler: (any FloorpWebPanelFindTimeoutScheduling)? = nil,
        accessibilityAnnouncement: @escaping AccessibilityAnnouncement = { message in
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    ) {
        self.target = target
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
        self.timeoutScheduler = timeoutScheduler
            ?? DefaultFloorpWebPanelFindTimeoutScheduler()
        self.accessibilityAnnouncement = accessibilityAnnouncement
        self.toolbarView = UIView()
        self.scrollView = UIScrollView()
        self.stackView = UIStackView()
        self.queryTextField = UITextField()
        self.statusLabel = UILabel()
        self.previousButton = UIButton(type: .system)
        self.nextButton = UIButton(type: .system)
        self.closeButton = UIButton(type: .system)
        super.init()
        configureView()
        renderState()
    }

    @discardableResult
    func present() -> Bool {
        guard !isInvalidated else { return false }
        if isUsingNativeFindInteraction {
            return target.presentNativeFindNavigator()
        }
        if target.supportsNativeFindInteraction,
           target.presentNativeFindNavigator() {
            isUsingNativeFindInteraction = true
            toolbarView.isHidden = true
            state = .native
            return true
        }
        toolbarView.isHidden = false
        if state == .inactive {
            queryTextField.text = nil
            state = .empty
        }
        _ = queryTextField.becomeFirstResponder()
        return true
    }

    @discardableResult
    func dismissIfActive() -> Bool {
        guard state != .inactive else { return false }
        resetSession()
        return true
    }

    func updateQuery(_ query: String) {
        guard isFallbackFindActive else { return }
        queryTextField.text = query
        hasMatchForCurrentQuery = false
        guard !query.isEmpty else {
            abandonPendingRequests()
            target.endFindSession()
            state = .empty
            return
        }
        enqueueFind(
            query: query,
            direction: .forward,
            kind: .queryChanged,
            canReportFinished: false
        )
    }

    func findNext() {
        move(to: .forward)
    }

    func findPrevious() {
        move(to: .backward)
    }

    func applyTheme(
        backgroundColor: UIColor,
        textColor: UIColor,
        secondaryTextColor: UIColor,
        tintColor: UIColor
    ) {
        toolbarView.backgroundColor = backgroundColor
        queryTextField.backgroundColor = backgroundColor
        queryTextField.textColor = textColor
        statusLabel.textColor = secondaryTextColor
        [previousButton, nextButton, closeButton].forEach { $0.tintColor = tintColor }
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        resetSession()
    }

    private var isFallbackFindActive: Bool {
        state != .inactive && !isUsingNativeFindInteraction && !isInvalidated
    }

    private func configureView() {
        toolbarView.isHidden = true
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.accessibilityIdentifier = "Floorp.WebPanel.Find.Toolbar"

        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false

        queryTextField.placeholder = FloorpStrings.Drawer.webPanelFindPlaceholder
        queryTextField.accessibilityLabel = FloorpStrings.Drawer.webPanelFind
        queryTextField.accessibilityIdentifier = "Floorp.WebPanel.Find.Query"
        queryTextField.autocorrectionType = .no
        queryTextField.autocapitalizationType = .none
        queryTextField.clearButtonMode = .whileEditing
        queryTextField.returnKeyType = .search
        queryTextField.borderStyle = .roundedRect
        queryTextField.delegate = self
        queryTextField.addTarget(
            self,
            action: #selector(queryDidChange),
            for: .editingChanged
        )

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "Floorp.WebPanel.Find.Status"

        configureButton(
            previousButton,
            systemImageName: "chevron.up",
            accessibilityLabel: FloorpStrings.Drawer.webPanelFindPrevious,
            accessibilityIdentifier: "Floorp.WebPanel.Find.Previous",
            action: #selector(previousTapped)
        )
        configureButton(
            nextButton,
            systemImageName: "chevron.down",
            accessibilityLabel: FloorpStrings.Drawer.webPanelFindNext,
            accessibilityIdentifier: "Floorp.WebPanel.Find.Next",
            action: #selector(nextTapped)
        )
        configureButton(
            closeButton,
            systemImageName: "xmark",
            accessibilityLabel: FloorpStrings.Drawer.webPanelFindClose,
            accessibilityIdentifier: "Floorp.WebPanel.Find.Close",
            action: #selector(closeTapped)
        )

        toolbarView.addSubview(scrollView)
        scrollView.addSubview(stackView)
        [
            queryTextField,
            statusLabel,
            previousButton,
            nextButton,
            closeButton,
        ].forEach(stackView.addArrangedSubview)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: toolbarView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 8
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -8
            ),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            queryTextField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            queryTextField.heightAnchor.constraint(equalToConstant: 38),
            statusLabel.widthAnchor.constraint(equalToConstant: 76),
            previousButton.widthAnchor.constraint(equalToConstant: 44),
            previousButton.heightAnchor.constraint(equalToConstant: 44),
            nextButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureButton(
        _ button: UIButton,
        systemImageName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: Selector
    ) {
        button.setImage(UIImage(systemName: systemImageName), for: .normal)
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = accessibilityIdentifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func move(to direction: FloorpWebPanelFindDirection) {
        guard state != .inactive else { return }
        if isUsingNativeFindInteraction {
            switch direction {
            case .forward: target.findNextUsingNativeInteraction()
            case .backward: target.findPreviousUsingNativeInteraction()
            }
            return
        }
        let query = queryTextField.text ?? ""
        guard !query.isEmpty else {
            state = .empty
            return
        }
        enqueueFind(
            query: query,
            direction: direction,
            kind: .navigation,
            canReportFinished: hasMatchForCurrentQuery
        )
    }

    private func enqueueFind(
        query: String,
        direction: FloorpWebPanelFindDirection,
        kind: FloorpWebPanelFindRequestKind,
        canReportFinished: Bool
    ) {
        requestGeneration &+= 1
        let pending = PendingRequest(
            id: UUID(),
            generation: requestGeneration,
            request: FloorpWebPanelFindRequest(
                query: query,
                direction: direction,
                kind: kind
            ),
            canReportFinished: canReportFinished
        )
        state = .searching(query)
        guard activeRequestID == nil else {
            pendingRequest = pending
            scheduleTimeout(for: pending)
            return
        }
        start(pending)
    }

    private func start(_ pending: PendingRequest) {
        activeRequestID = pending.id
        if pending.generation == requestGeneration {
            state = .searching(pending.request.query)
        }
        scheduleTimeout(for: pending)
        target.find(pending.request) { [weak self] matchFound in
            self?.finish(pending, matchFound: matchFound)
        }
    }

    private func scheduleTimeout(for pending: PendingRequest) {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = timeoutScheduler.schedule(
            after: requestTimeoutNanoseconds
        ) { [weak self] in
            self?.markRequestTimedOut(pending)
        }
    }

    private func markRequestTimedOut(_ pending: PendingRequest) {
        let isTrackedRequest = activeRequestID == pending.id
            || pendingRequest?.id == pending.id
        guard !isInvalidated, isTrackedRequest else { return }
        requestTimeoutTask = nil
        guard pending.generation == requestGeneration else { return }
        state = .unavailable(pending.request.query)
    }

    private func finish(_ pending: PendingRequest, matchFound: Bool) {
        guard !isInvalidated, activeRequestID == pending.id else { return }
        activeRequestID = nil
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil

        if pending.generation == requestGeneration {
            renderResult(for: pending, matchFound: matchFound)
        }
        if let latestRequest = pendingRequest {
            pendingRequest = nil
            start(latestRequest)
        }
    }

    private func renderResult(for pending: PendingRequest, matchFound: Bool) {
        let query = pending.request.query
        if matchFound {
            hasMatchForCurrentQuery = true
            state = .match(query)
            return
        }
        if pending.canReportFinished, hasMatchForCurrentQuery {
            state = .finished(query, pending.request.direction)
        } else {
            hasMatchForCurrentQuery = false
            state = .noMatch(query)
        }
    }

    private func abandonPendingRequests() {
        requestGeneration &+= 1
        pendingRequest = nil
    }

    private func resetSession() {
        requestGeneration &+= 1
        pendingRequest = nil
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        hasMatchForCurrentQuery = false
        queryTextField.resignFirstResponder()
        queryTextField.text = nil
        toolbarView.isHidden = true
        target.endFindSession()
        isUsingNativeFindInteraction = false
        state = .inactive
    }

    private func renderState() {
        let status: String?
        let shouldAnnounce: Bool
        switch state {
        case .inactive, .native:
            status = nil
            shouldAnnounce = false
        case .empty:
            status = FloorpStrings.Drawer.webPanelFindEmpty
            shouldAnnounce = false
        case .searching:
            status = FloorpStrings.Drawer.webPanelFindSearching
            shouldAnnounce = false
        case .match:
            status = FloorpStrings.Drawer.webPanelFindMatch
            shouldAnnounce = true
        case .noMatch:
            status = FloorpStrings.Drawer.webPanelFindNoMatches
            shouldAnnounce = true
        case .unavailable:
            status = FloorpStrings.Drawer.webPanelFindUnavailable
            shouldAnnounce = true
        case .finished(_, let direction):
            status = direction == .forward
                ? FloorpStrings.Drawer.webPanelFindReachedEnd
                : FloorpStrings.Drawer.webPanelFindReachedBeginning
            shouldAnnounce = true
        }
        statusLabel.text = status
        statusLabel.accessibilityLabel = status
        toolbarView.accessibilityValue = status
        let hasQuery = !(queryTextField.text ?? "").isEmpty
        previousButton.isEnabled = hasQuery
        nextButton.isEnabled = hasQuery
        if shouldAnnounce, let status {
            accessibilityAnnouncement(status)
        }
    }

    @objc private func queryDidChange() {
        updateQuery(queryTextField.text ?? "")
    }

    @objc private func previousTapped() {
        findPrevious()
    }

    @objc private func nextTapped() {
        findNext()
    }

    @objc private func closeTapped() {
        _ = dismissIfActive()
    }
}

extension FloorpWebPanelFindController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        findNext()
        return true
    }
}
