// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit
import WebKit

@MainActor
private func floorpNavigationReplacesDocument(
    _ navigationAction: WKNavigationAction,
    currentURL: URL?
) -> Bool {
    guard navigationAction.targetFrame?.isMainFrame != false,
          let currentURL,
          let destinationURL = navigationAction.request.url else { return false }
    var current = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
    var destination = URLComponents(url: destinationURL, resolvingAgainstBaseURL: false)
    let changesOnlyFragment = current?.fragment != destination?.fragment
    current?.fragment = nil
    destination?.fragment = nil
    return !(changesOnlyFragment && current == destination)
}

/// WebKit 26.5 can invalidate a popup page asynchronously after UIKit has
/// already released its last WKWebView reference, tripping a WKProcessPool
/// use-after-release assertion. Keep closed extension surfaces alive only for
/// the short asynchronous close window; repeated teardown extends the grace.
@MainActor
private enum FloorpNativeWebExtensionDeferredWebViewRelease {
    private static var retained = [ObjectIdentifier: (token: UUID, webView: WKWebView)]()

    static func retain(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        let token = UUID()
        retained[key] = (token, webView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard retained[key]?.token == token else { return }
            retained.removeValue(forKey: key)
        }
    }
}

/// Bridges `window.close()` for a top-level WKWebView that was not created by
/// JavaScript. WebKit does not call `webViewDidClose` for that case. The random
/// handler is scoped to one main-frame extension origin and removed as soon as
/// the managed surface closes.
@MainActor
private final class FloorpNativeWebExtensionCloseBridge: NSObject, WKScriptMessageHandler {
    let handlerName = "floorpExtensionClose_"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var onClose: (() -> Void)?

    private let expectedScheme: String?
    private let expectedHost: String?
    private weak var webView: WKWebView?
    private var isInstalled = false

    init(expectedURL: URL) {
        expectedScheme = expectedURL.scheme
        expectedHost = expectedURL.host
    }

    func install(in configuration: WKWebViewConfiguration) {
        guard !isInstalled else { return }
        isInstalled = true
        let controller = configuration.userContentController
        controller.add(self, contentWorld: .page, name: handlerName)
        controller.addUserScript(WKUserScript(
            source: """
            (() => {
                const close = () => window.webkit.messageHandlers['\(handlerName)'].postMessage(null);
                Object.defineProperty(window, 'close', { configurable: true, value: close });
                if (typeof globalThis.floorpPrepareToClose !== 'function') {
                    globalThis.floorpPrepareToClose = () => ({
                        ready: true,
                        noMutation: true,
                        provisional: true
                    });
                }
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    func invalidate(in configuration: WKWebViewConfiguration) {
        guard isInstalled else { return }
        isInstalled = false
        configuration.userContentController.removeScriptMessageHandler(
            forName: handlerName,
            contentWorld: .page
        )
        webView = nil
        onClose = nil
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard isInstalled,
              message.name == handlerName,
              message.frameInfo.isMainFrame,
              message.webView === webView,
              message.webView?.url?.scheme == expectedScheme,
              message.webView?.url?.host == expectedHost else {
            return
        }
        onClose?()
    }
}

@MainActor
private final class FloorpNativeWebExtensionHeroHeaderView: UIView, ThemeApplicable {
    private let cardView: UIView = .build()
    private let iconView: UIImageView = .build()
    private let titleLabel: UILabel = .build()
    private let messageLabel: UILabel = .build()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(theme: Theme) {
        backgroundColor = theme.colors.layer1
        cardView.backgroundColor = theme.colors.layer2
        cardView.layer.borderColor = theme.colors.borderPrimary.cgColor
        iconView.tintColor = theme.colors.iconAccent
        titleLabel.textColor = theme.colors.textPrimary
        messageLabel.textColor = theme.colors.textSecondary
    }

    private func setupView() {
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        cardView.layer.cornerRadius = 18
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        iconView.image = UIImage(systemName: "puzzlepiece.extension.fill")
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        titleLabel.text = FloorpStrings.WebExtensions.introTitle
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        messageLabel.text = FloorpStrings.WebExtensions.introMessage
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0

        let labels: UIStackView = .build()
        labels.axis = .vertical
        labels.spacing = 4
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(messageLabel)
        cardView.addSubview(iconView)
        cardView.addSubview(labels)
        addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            labels.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            labels.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            labels.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
        accessibilityLabel = "\(FloorpStrings.WebExtensions.introTitle). \(FloorpStrings.WebExtensions.introMessage)"
    }
}

@MainActor
private final class FloorpNativeWebExtensionCardCell: UITableViewCell, ThemeApplicable {
    enum StatusStyle {
        case accent
        case secondary
        case critical
    }

    static let reuseIdentifier = "FloorpNativeWebExtensionCardCell"

    private let iconView: UIImageView = .build()
    private let titleLabel: UILabel = .build()
    private let summaryLabel: UILabel = .build()
    private let versionLabel: UILabel = .build()
    private let statusLabel: UILabel = .build()
    private let separatorLabel: UILabel = .build()
    private let metadataStack: UIStackView = .build()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var statusStyle = StatusStyle.secondary
    private var usesTemplateIcon = true

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconView.image = nil
        activityIndicator.stopAnimating()
        accessoryView = nil
        accessoryType = .none
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    func configure(
        title: String,
        summary: String,
        version: String?,
        status: String?,
        statusStyle: StatusStyle,
        icon: UIImage?,
        fallbackSymbol: String,
        isBusy: Bool,
        isSelectable: Bool,
        accessibilityIdentifier: String,
        theme: Theme
    ) {
        titleLabel.text = title
        summaryLabel.text = summary
        versionLabel.text = version.map(FloorpStrings.WebExtensions.version)
        statusLabel.text = status
        versionLabel.isHidden = version == nil
        statusLabel.isHidden = status == nil
        separatorLabel.isHidden = version == nil || status == nil
        metadataStack.isHidden = version == nil && status == nil
        self.statusStyle = statusStyle
        if let icon {
            iconView.image = icon.withRenderingMode(.alwaysOriginal)
            usesTemplateIcon = false
        } else {
            iconView.image = UIImage(systemName: fallbackSymbol)?.withRenderingMode(.alwaysTemplate)
            usesTemplateIcon = true
        }
        selectionStyle = isSelectable ? .default : .none
        isUserInteractionEnabled = isSelectable && !isBusy
        if isBusy {
            activityIndicator.startAnimating()
            accessoryView = activityIndicator
            accessoryType = .none
        } else {
            activityIndicator.stopAnimating()
            accessoryView = nil
            accessoryType = isSelectable ? .disclosureIndicator : .none
        }
        self.accessibilityIdentifier = accessibilityIdentifier
        accessibilityTraits = isSelectable ? .button : .staticText
        accessibilityLabel = [title, status, version.map(FloorpStrings.WebExtensions.version), summary]
            .compactMap { $0 }
            .joined(separator: ", ")
        accessibilityValue = isBusy ? FloorpStrings.WebExtensions.loading : status
        applyTheme(theme: theme)
    }

    func applyTheme(theme: Theme) {
        backgroundColor = theme.colors.layer2
        contentView.backgroundColor = theme.colors.layer2
        titleLabel.textColor = theme.colors.textPrimary
        summaryLabel.textColor = theme.colors.textSecondary
        versionLabel.textColor = theme.colors.textSecondary
        separatorLabel.textColor = theme.colors.textSecondary
        statusLabel.textColor = switch statusStyle {
        case .accent: theme.colors.textAccent
        case .secondary: theme.colors.textSecondary
        case .critical: theme.colors.textCritical
        }
        iconView.tintColor = usesTemplateIcon ? theme.colors.iconAccent : nil
        activityIndicator.color = theme.colors.iconAccent
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = theme.colors.layer5Hover
        selectedBackgroundView = selectedBackground
    }

    private func setupView() {
        isAccessibilityElement = true
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.numberOfLines = 3
        versionLabel.font = .preferredFont(forTextStyle: .footnote)
        versionLabel.adjustsFontForContentSizeCategory = true
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        separatorLabel.text = "·"
        separatorLabel.font = .preferredFont(forTextStyle: .footnote)
        metadataStack.axis = .horizontal
        metadataStack.spacing = 5
        metadataStack.alignment = .firstBaseline
        metadataStack.addArrangedSubview(statusLabel)
        metadataStack.addArrangedSubview(separatorLabel)
        metadataStack.addArrangedSubview(versionLabel)
        activityIndicator.hidesWhenStopped = true

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(summaryLabel)
        contentView.addSubview(metadataStack)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 13),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metadataStack.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            metadataStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadataStack.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),
            metadataStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -13),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 92)
        ])
        separatorInset = UIEdgeInsets(top: 0, left: 72, bottom: 0, right: 0)
    }
}

struct FloorpNativeWebExtensionPromptPresentation {
    struct InfoRow {
        let symbol: String
        let title: String
        let detail: String
    }

    struct Choice {
        enum Role {
            case standard
            case preferred
            case destructive
        }

        let identifier: String
        let title: String
        let detail: String
        let icon: UIImage?
        let usesTemplateIcon: Bool
        var role: Role = .standard
    }

    let title: String
    let message: String
    let heroImage: UIImage?
    let heroUsesTemplateImage: Bool
    let infoRows: [InfoRow]
    let choices: [Choice]
    var cancelTitle = FloorpStrings.WebExtensions.cancel
    let accessibilityIdentifier: String
}

@MainActor
class FloorpNativeWebExtensionPromptViewController: UIViewController,
                                                       Themeable,
                                                       InjectedThemeUUIDIdentifiable {
    private final class ChoiceButton: UIButton {
        let choice: FloorpNativeWebExtensionPromptPresentation.Choice

        init(choice: FloorpNativeWebExtensionPromptPresentation.Choice) {
            self.choice = choice
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            contentHorizontalAlignment = .leading
            accessibilityIdentifier = choice.identifier
            accessibilityLabel = choice.title
            accessibilityHint = choice.detail
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func applyTheme(theme: Theme) {
            var configuration = UIButton.Configuration.plain()
            configuration.title = choice.title
            configuration.subtitle = choice.detail
            if let image = choice.icon {
                configuration.image = image.withRenderingMode(
                    choice.usesTemplateIcon ? .alwaysTemplate : .alwaysOriginal
                )
            }
            configuration.imagePlacement = .leading
            configuration.imagePadding = 14
            configuration.titleAlignment = .leading
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 12,
                leading: 14,
                bottom: 12,
                trailing: 14
            )
            configuration.background.backgroundColor = theme.colors.layer2
            configuration.background.strokeColor = theme.colors.borderPrimary
            configuration.background.strokeWidth = choice.role == .preferred ? 2 : 1
            configuration.background.cornerRadius = 14
            configuration.baseForegroundColor = switch choice.role {
            case .standard: theme.colors.textPrimary
            case .preferred: theme.colors.textAccent
            case .destructive: theme.colors.textCritical
            }
            configuration.titleTextAttributesTransformer = .init { incoming in
                var outgoing = incoming
                outgoing.font = .preferredFont(forTextStyle: .headline)
                return outgoing
            }
            configuration.subtitleTextAttributesTransformer = .init { incoming in
                var outgoing = incoming
                outgoing.font = .preferredFont(forTextStyle: .subheadline)
                outgoing.foregroundColor = theme.colors.textSecondary
                return outgoing
            }
            self.configuration = configuration
        }
    }

    let windowUUID: WindowUUID
    var currentWindowUUID: WindowUUID? { windowUUID }
    var themeManager: ThemeManager
    var themeListenerCancellable: Any?

    let presentation: FloorpNativeWebExtensionPromptPresentation
    private let notificationCenter: NotificationProtocol
    private let onChoice: @MainActor (FloorpNativeWebExtensionPromptPresentation.Choice) -> Void
    private let dismissalHandler: ((@escaping () -> Void) -> Void)?
    private let scrollView: UIScrollView = .build()
    private let contentStack: UIStackView = .build()
    private let heroCard: UIView = .build()
    private let heroIconView: UIImageView = .build()
    private let titleLabel: UILabel = .build()
    private let messageLabel: UILabel = .build()
    private let cancelButton: UIButton = .build()
    private var choiceButtons = [ChoiceButton]()
    private var themedCards = [UIView]()
    private var primaryLabels = [UILabel]()
    private var secondaryLabels = [UILabel]()
    private var infoIconViews = [UIImageView]()
    private var separators = [UIView]()
    private var pendingChoice: FloorpNativeWebExtensionPromptPresentation.Choice?
    private var didFinish = false

    var displayedChoiceTitles: [String] { choiceButtons.map(\.choice.title) }

    func selectChoice(identifier: String) {
        guard let choice = presentation.choices.first(where: { $0.identifier == identifier }) else { return }
        finish(with: choice)
    }

    init(
        presentation: FloorpNativeWebExtensionPromptPresentation,
        windowUUID: WindowUUID,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        dismissalHandler: ((@escaping () -> Void) -> Void)? = nil,
        onChoice: @escaping @MainActor (FloorpNativeWebExtensionPromptPresentation.Choice) -> Void
    ) {
        self.presentation = presentation
        self.windowUUID = windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        self.dismissalHandler = dismissalHandler
        self.onChoice = onChoice
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = presentation.accessibilityIdentifier
        setupView()
        listenForThemeChanges(withNotificationCenter: notificationCenter)
        applyTheme()
        sheetPresentationController?.prefersGrabberVisible = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard dismissalHandler == nil else { return }
        deliverPendingChoice(deferred: true)
    }

    func applyTheme() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        view.backgroundColor = theme.colors.layer1
        scrollView.backgroundColor = theme.colors.layer1
        themedCards.forEach {
            $0.backgroundColor = theme.colors.layer2
            $0.layer.borderColor = theme.colors.borderPrimary.cgColor
        }
        heroIconView.tintColor = presentation.heroUsesTemplateImage ? theme.colors.iconAccent : nil
        primaryLabels.forEach { $0.textColor = theme.colors.textPrimary }
        secondaryLabels.forEach { $0.textColor = theme.colors.textSecondary }
        infoIconViews.forEach { $0.tintColor = theme.colors.iconAccent }
        separators.forEach { $0.backgroundColor = theme.colors.borderPrimary }
        choiceButtons.forEach { $0.applyTheme(theme: theme) }

        var cancelConfiguration = UIButton.Configuration.gray()
        cancelConfiguration.title = presentation.cancelTitle
        cancelConfiguration.baseForegroundColor = theme.colors.textPrimary
        cancelConfiguration.cornerStyle = .large
        cancelButton.configuration = cancelConfiguration
    }

    private func setupView() {
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.alignment = .fill
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        view.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])

        addHero()
        if !presentation.infoRows.isEmpty {
            addInfoCard()
        }
        presentation.choices.forEach(addChoice)
        cancelButton.accessibilityIdentifier = "\(presentation.accessibilityIdentifier).Cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.finishWithCancel() }, for: .touchUpInside)
    }

    private func addHero() {
        heroCard.layer.cornerRadius = 18
        heroCard.layer.cornerCurve = .continuous
        heroCard.layer.borderWidth = 1
        themedCards.append(heroCard)
        let heroStack: UIStackView = .build()
        heroStack.axis = .vertical
        heroStack.alignment = .center
        heroStack.spacing = 10
        heroIconView.image = (presentation.heroImage
            ?? UIImage(systemName: "puzzlepiece.extension.fill"))?.withRenderingMode(
                presentation.heroUsesTemplateImage ? .alwaysTemplate : .alwaysOriginal
            )
        heroIconView.contentMode = .scaleAspectFit
        heroIconView.isAccessibilityElement = false
        titleLabel.text = presentation.title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        primaryLabels.append(titleLabel)
        messageLabel.text = presentation.message
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        secondaryLabels.append(messageLabel)
        heroStack.addArrangedSubview(heroIconView)
        heroStack.addArrangedSubview(titleLabel)
        heroStack.addArrangedSubview(messageLabel)
        heroCard.addSubview(heroStack)
        NSLayoutConstraint.activate([
            heroStack.topAnchor.constraint(equalTo: heroCard.topAnchor, constant: 20),
            heroStack.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 18),
            heroStack.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor, constant: -18),
            heroStack.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: -20),
            heroIconView.widthAnchor.constraint(equalToConstant: 58),
            heroIconView.heightAnchor.constraint(equalTo: heroIconView.widthAnchor)
        ])
        contentStack.addArrangedSubview(heroCard)
    }

    private func addInfoCard() {
        let card: UIStackView = .build()
        card.axis = .vertical
        card.spacing = 0
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        themedCards.append(card)
        for (index, row) in presentation.infoRows.enumerated() {
            if index > 0 {
                let separator: UIView = .build()
                separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                card.addArrangedSubview(separator)
                separators.append(separator)
            }
            card.addArrangedSubview(makeInfoRow(row))
        }
        contentStack.addArrangedSubview(card)
    }

    private func makeInfoRow(_ row: FloorpNativeWebExtensionPromptPresentation.InfoRow) -> UIView {
        let container: UIView = .build()
        let iconView: UIImageView = .build()
        iconView.image = UIImage(systemName: row.symbol)?.withRenderingMode(.alwaysTemplate)
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        infoIconViews.append(iconView)
        let rowTitle = makeLabel(text: row.title, style: .headline, primary: true)
        let detail = makeLabel(text: row.detail, style: .footnote, primary: false)
        let labels: UIStackView = .build()
        labels.axis = .vertical
        labels.spacing = 4
        labels.addArrangedSubview(rowTitle)
        labels.addArrangedSubview(detail)
        container.addSubview(iconView)
        container.addSubview(labels)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            labels.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 13),
            labels.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            labels.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        container.isAccessibilityElement = true
        container.accessibilityLabel = "\(row.title). \(row.detail)"
        return container
    }

    private func makeLabel(
        text: String,
        style: UIFont.TextStyle,
        primary: Bool
    ) -> UILabel {
        let label: UILabel = .build()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        if primary {
            primaryLabels.append(label)
        } else {
            secondaryLabels.append(label)
        }
        return label
    }

    private func addChoice(_ choice: FloorpNativeWebExtensionPromptPresentation.Choice) {
        let button = ChoiceButton(choice: choice)
        button.addAction(UIAction { [weak self] _ in
            self?.selectChoice(identifier: choice.identifier)
        }, for: .touchUpInside)
        choiceButtons.append(button)
        contentStack.addArrangedSubview(button)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
    }

    private func finish(with choice: FloorpNativeWebExtensionPromptPresentation.Choice) {
        guard !didFinish else { return }
        didFinish = true
        pendingChoice = choice
        setControlsEnabled(false)
        if let dismissalHandler {
            dismissalHandler { [weak self] in self?.deliverPendingChoice() }
        } else {
            dismiss(animated: true)
        }
    }

    private func deliverPendingChoice(deferred: Bool = false) {
        guard let pendingChoice else { return }
        self.pendingChoice = nil
        let delivery = { [onChoice] in onChoice(pendingChoice) }
        if deferred {
            DispatchQueue.main.async(execute: delivery)
        } else {
            delivery()
        }
    }

    private func finishWithCancel() {
        guard !didFinish else { return }
        didFinish = true
        setControlsEnabled(false)
        dismiss(animated: true)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        choiceButtons.forEach { $0.isEnabled = enabled }
        cancelButton.isEnabled = enabled
    }
}

@MainActor
final class FloorpNativeWebExtensionActionPickerViewController:
    FloorpNativeWebExtensionPromptViewController {
    init(
        actions: [FloorpNativeWebExtensionActionItem],
        windowUUID: WindowUUID,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        dismissalHandler: ((@escaping () -> Void) -> Void)? = nil,
        onSelection: @escaping @MainActor (FloorpNativeWebExtensionActionItem) -> Void
    ) {
        let actionsByIdentifier = Dictionary(
            uniqueKeysWithValues: actions.map { ($0.contextIdentifier, $0) }
        )
        let choices = actions.map { action in
            FloorpNativeWebExtensionPromptPresentation.Choice(
                identifier: action.contextIdentifier,
                title: action.label,
                detail: FloorpStrings.WebExtensions.version(action.version),
                icon: action.icon ?? UIImage(systemName: "puzzlepiece.extension.fill"),
                usesTemplateIcon: action.icon == nil
            )
        }
        super.init(
            presentation: .init(
                title: FloorpStrings.WebExtensions.actions,
                message: FloorpStrings.WebExtensions.chooseActionMessage,
                heroImage: UIImage(systemName: "puzzlepiece.extension.fill"),
                heroUsesTemplateImage: true,
                infoRows: [],
                choices: choices,
                accessibilityIdentifier: "Floorp.NativeWebExtensions.ActionPicker"
            ),
            windowUUID: windowUUID,
            themeManager: themeManager,
            dismissalHandler: dismissalHandler,
            onChoice: { choice in
                guard let action = actionsByIdentifier[choice.identifier] else { return }
                onSelection(action)
            }
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class FloorpNativeWebExtensionSettingsViewController: ThemedTableViewController {
    private enum Section: Int, CaseIterable {
        case installed
        case available

        var title: String {
            switch self {
            case .installed: return FloorpStrings.WebExtensions.installedSection
            case .available: return FloorpStrings.WebExtensions.availableSection
            }
        }
    }

    private enum Row {
        case installed(FloorpNativeWebExtensionSettingsItem)
        case available(FloorpNativeWebExtensionCatalogItem)
        case emptyInstalled
        case emptyAvailable
        case unavailable
    }

    private weak var host: FloorpNativeWebExtensionHost?
    private weak var tabManager: (any TabManager)?
    private var installedItems = [FloorpNativeWebExtensionSettingsItem]()
    private var isMutating = false
    private var busyIdentifier: String?
    private let heroHeader = FloorpNativeWebExtensionHeroHeaderView()

    init(
        windowUUID: WindowUUID,
        host: FloorpNativeWebExtensionHost?,
        tabManager: any TabManager
    ) {
        self.host = host
        self.tabManager = tabManager
        super.init(style: .insetGrouped, windowUUID: windowUUID)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = FloorpStrings.WebExtensions.title
        tableView.accessibilityIdentifier = "Floorp.NativeWebExtensions.Settings"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 104
        tableView.register(
            FloorpNativeWebExtensionCardCell.self,
            forCellReuseIdentifier: FloorpNativeWebExtensionCardCell.reuseIdentifier
        )
        tableView.tableHeaderView = heroHeader
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(refresh)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = FloorpStrings.WebExtensions.retry
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderSize()
    }

    override func applyTheme() {
        super.applyTheme()
        heroHeader.applyTheme(theme: themeManager.getCurrentTheme(for: windowUUID))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    @objc
    private func refresh() {
        installedItems = host?.settingsItems().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        } ?? []
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        host == nil ? 1 : Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard host != nil else { return FloorpStrings.WebExtensions.title }
        return Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: section).count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: FloorpNativeWebExtensionCardCell.reuseIdentifier,
            for: indexPath
        ) as? FloorpNativeWebExtensionCardCell else {
            return UITableViewCell()
        }
        let theme = themeManager.getCurrentTheme(for: windowUUID)

        switch rows(in: indexPath.section)[indexPath.row] {
        case .installed(let item):
            let status: String
            if item.requiresRestartToEnable {
                status = FloorpStrings.WebExtensions.enableAfterRestartStatus
            } else if item.hasUpdate {
                status = FloorpStrings.WebExtensions.updateAvailable
            } else {
                status = item.isEnabled
                    ? FloorpStrings.WebExtensions.enabled
                    : FloorpStrings.WebExtensions.disabled
            }
            let statusStyle: FloorpNativeWebExtensionCardCell.StatusStyle = item.errorDescription == nil
                ? (item.hasUpdate || item.requiresRestartToEnable ? .accent : .secondary)
                : .critical
            cell.configure(
                title: item.name,
                summary: item.summary ?? FloorpStrings.WebExtensions.introMessage,
                version: item.version,
                status: status,
                statusStyle: statusStyle,
                icon: item.iconData.flatMap(UIImage.init(data:)),
                fallbackSymbol: "puzzlepiece.extension.fill",
                isBusy: busyIdentifier == item.identifier,
                isSelectable: true,
                accessibilityIdentifier: "Floorp.NativeWebExtensions.Installed.\(item.identifier)",
                theme: theme
            )
        case .available(let item):
            cell.configure(
                title: item.name,
                summary: item.summary,
                version: item.expectedVersion,
                status: item.isAvailableOnCurrentOS
                    ? FloorpStrings.WebExtensions.add
                    : FloorpStrings.WebExtensions.requiresOperatingSystem(item.minimumOS.description),
                statusStyle: item.isAvailableOnCurrentOS ? .accent : .critical,
                icon: nil,
                fallbackSymbol: "puzzlepiece.extension.fill",
                isBusy: busyIdentifier == item.identifier,
                isSelectable: item.isAvailableOnCurrentOS,
                accessibilityIdentifier: "Floorp.NativeWebExtensions.Available.\(item.identifier)",
                theme: theme
            )
        case .emptyInstalled:
            cell.configure(
                title: FloorpStrings.WebExtensions.noInstalledTitle,
                summary: FloorpStrings.WebExtensions.noInstalledMessage,
                version: nil,
                status: nil,
                statusStyle: .secondary,
                icon: nil,
                fallbackSymbol: "square.stack.3d.up.slash",
                isBusy: false,
                isSelectable: false,
                accessibilityIdentifier: "Floorp.NativeWebExtensions.EmptyInstalled",
                theme: theme
            )
        case .emptyAvailable:
            cell.configure(
                title: FloorpStrings.WebExtensions.noAvailableTitle,
                summary: FloorpStrings.WebExtensions.noAvailableMessage,
                version: nil,
                status: nil,
                statusStyle: .secondary,
                icon: nil,
                fallbackSymbol: "checkmark.seal.fill",
                isBusy: false,
                isSelectable: false,
                accessibilityIdentifier: "Floorp.NativeWebExtensions.EmptyAvailable",
                theme: theme
            )
        case .unavailable:
            cell.configure(
                title: FloorpStrings.WebExtensions.loadErrorTitle,
                summary: FloorpStrings.WebExtensions.loadErrorMessage,
                version: nil,
                status: nil,
                statusStyle: .critical,
                icon: nil,
                fallbackSymbol: "exclamationmark.triangle.fill",
                isBusy: false,
                isSelectable: false,
                accessibilityIdentifier: "Floorp.NativeWebExtensions.Unavailable",
                theme: theme
            )
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isMutating else { return }
        switch rows(in: indexPath.section)[indexPath.row] {
        case .installed(let item):
            showActions(for: item)
        case .available(let item):
            confirmInstall(item)
        case .emptyInstalled, .emptyAvailable, .unavailable:
            break
        }
    }

    private func rows(in sectionIndex: Int) -> [Row] {
        guard host != nil else { return [.unavailable] }
        guard let section = Section(rawValue: sectionIndex) else { return [] }
        switch section {
        case .installed:
            return installedItems.isEmpty ? [.emptyInstalled] : installedItems.map(Row.installed)
        case .available:
            let installed = Set(installedItems.map(\.identifier))
            let available = FloorpNativeWebExtensionCatalog.items
                .filter { !installed.contains($0.identifier) }
                .map(Row.available)
            return available.isEmpty ? [.emptyAvailable] : available
        }
    }

    private func updateHeaderSize() {
        guard let header = tableView.tableHeaderView, tableView.bounds.width > 0 else { return }
        let targetSize = header.systemLayoutSizeFitting(
            CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        guard abs(header.frame.height - targetSize.height) > 0.5 else { return }
        header.frame.size = CGSize(width: tableView.bounds.width, height: targetSize.height)
        tableView.tableHeaderView = header
    }

    private func confirmInstall(_ item: FloorpNativeWebExtensionCatalogItem) {
        guard item.isAvailableOnCurrentOS else {
            presentError(FloorpNativeWebExtensionError.unsupportedOperatingSystem(required: item.minimumOS))
            return
        }
        guard let host, !isMutating else { return }
        isMutating = true
        busyIdentifier = item.identifier
        tableView.isUserInteractionEnabled = false
        tableView.reloadData()
        Task { [weak self, host] in
            do {
                let preview = try await host.installationPreview(identifier: item.identifier)
                guard let self else { return }
                isMutating = false
                busyIdentifier = nil
                tableView.isUserInteractionEnabled = true
                tableView.reloadData()
                presentInstallConfirmation(preview)
            } catch {
                guard let self else { return }
                isMutating = false
                busyIdentifier = nil
                tableView.isUserInteractionEnabled = true
                tableView.reloadData()
                presentError(error)
            }
        }
    }

    private func presentInstallConfirmation(_ preview: FloorpNativeWebExtensionInstallationPreview) {
        var infoRows = [FloorpNativeWebExtensionPromptPresentation.InfoRow(
            symbol: "checkmark.seal.fill",
            title: FloorpStrings.WebExtensions.reviewed,
            detail: FloorpStrings.WebExtensions.version(preview.version)
        )]
        if !preview.requiredPermissions.isEmpty {
            infoRows.append(.init(
                symbol: "checkmark.shield.fill",
                title: FloorpStrings.WebExtensions.accessSection,
                detail: "• " + preview.requiredPermissions.joined(separator: "\n• ")
            ))
        }
        if !preview.requiredMatchPatterns.isEmpty {
            infoRows.append(.init(
                symbol: "hand.raised.fill",
                title: preview.isUpdate
                    ? FloorpStrings.WebExtensions.siteAccessUpdateTitle
                    : FloorpStrings.WebExtensions.siteAccessGrantedTitle,
                detail: (preview.isUpdate
                    ? FloorpStrings.WebExtensions.siteAccessUpdateMessage
                    : FloorpStrings.WebExtensions.siteAccessGrantedMessage)
                    + "\n\n• " + preview.requiredMatchPatterns.joined(separator: "\n• ")
            ))
        }
        if !preview.optionalPermissions.isEmpty || !preview.optionalMatchPatterns.isEmpty {
            let optionalAccess = (preview.optionalPermissions + preview.optionalMatchPatterns).sorted()
            infoRows.append(.init(
                symbol: "hand.tap.fill",
                title: FloorpStrings.WebExtensions.optionalAccess,
                detail: FloorpStrings.WebExtensions.optionalAccessMessage
                    + (optionalAccess.isEmpty ? "" : "\n\n• " + optionalAccess.joined(separator: "\n• "))
            ))
        }
        infoRows.append(.init(
            symbol: "eye.slash.fill",
            title: FloorpStrings.WebExtensions.privateBrowsingOptInTitle,
            detail: FloorpStrings.WebExtensions.privateBrowsingOptInMessage
        ))
        infoRows.append(.init(
            symbol: "doc.text.fill",
            title: "\(FloorpStrings.WebExtensions.sourceLabel) · \(FloorpStrings.WebExtensions.licenseLabel)",
            detail: "\(preview.source) · \(preview.license)"
        ))
        let catalogSummary = FloorpNativeWebExtensionCatalog.item(identifier: preview.identifier)?.summary
            ?? FloorpStrings.WebExtensions.introMessage
        let installChoice = FloorpNativeWebExtensionPromptPresentation.Choice(
            identifier: "install",
            title: preview.isUpdate
                ? FloorpStrings.WebExtensions.update
                : FloorpStrings.WebExtensions.install,
            detail: preview.isUpdate
                ? FloorpStrings.WebExtensions.siteAccessUpdateMessage
                : FloorpStrings.WebExtensions.siteAccessGrantedMessage,
            icon: UIImage(systemName: preview.isUpdate ? "arrow.down.circle.fill" : "arrow.down.app.fill"),
            usesTemplateIcon: true,
            role: .preferred
        )
        let sheet = FloorpNativeWebExtensionPromptViewController(
            presentation: .init(
                title: preview.isUpdate
                    ? "\(FloorpStrings.WebExtensions.update) · \(preview.name)"
                    : FloorpStrings.WebExtensions.installTitle(name: preview.name),
                message: catalogSummary,
                heroImage: preview.iconData.flatMap(UIImage.init(data:)),
                heroUsesTemplateImage: preview.iconData == nil,
                infoRows: infoRows,
                choices: [installChoice],
                accessibilityIdentifier: "Floorp.NativeWebExtensions.InstallConsent.\(preview.identifier)"
            ),
            windowUUID: windowUUID,
            onChoice: { [weak self] _ in
                self?.mutate(
                    identifier: preview.identifier,
                    progress: preview.isUpdate
                        ? FloorpStrings.WebExtensions.updating
                        : FloorpStrings.WebExtensions.installing
                ) {
                    try await $0.installBundledExtension(identifier: preview.identifier)
                }
            }
        )
        present(sheet, animated: true)
    }

    private func showActions(for item: FloorpNativeWebExtensionSettingsItem) {
        let sheet = FloorpNativeWebExtensionPromptViewController(
            presentation: .init(
                title: item.name,
                message: item.summary ?? FloorpStrings.WebExtensions.detailTitle,
                heroImage: item.iconData.flatMap(UIImage.init(data:)),
                heroUsesTemplateImage: item.iconData == nil,
                infoRows: managementInfoRows(for: item),
                choices: managementChoices(for: item),
                accessibilityIdentifier: "Floorp.NativeWebExtensions.Manage.\(item.identifier)"
            ),
            windowUUID: windowUUID,
            onChoice: { [weak self] choice in
                self?.handleManagementChoice(choice.identifier, for: item)
            }
        )
        present(sheet, animated: true)
    }

    private func managementInfoRows(
        for item: FloorpNativeWebExtensionSettingsItem
    ) -> [FloorpNativeWebExtensionPromptPresentation.InfoRow] {
        var infoRows = [
            FloorpNativeWebExtensionPromptPresentation.InfoRow(
                symbol: "number",
                title: FloorpStrings.WebExtensions.version(item.version),
                detail: item.requiresRestartToEnable
                    ? FloorpStrings.WebExtensions.enableAfterRestartStatus
                    : (item.isEnabled
                        ? FloorpStrings.WebExtensions.enabled
                        : FloorpStrings.WebExtensions.disabled)
            ),
            .init(
                symbol: "doc.text.fill",
                title: "\(FloorpStrings.WebExtensions.sourceLabel) · \(FloorpStrings.WebExtensions.licenseLabel)",
                detail: "\(item.source) · \(item.license)"
            )
        ]
        if item.requiresRestartToEnable {
            infoRows.append(.init(
                symbol: "arrow.clockwise.circle.fill",
                title: FloorpStrings.WebExtensions.enableAfterRestartStatus,
                detail: FloorpStrings.WebExtensions.enableAfterRestartMessage
            ))
        }
        if !item.permissions.isEmpty {
            infoRows.append(.init(
                symbol: "checkmark.shield.fill",
                title: FloorpStrings.WebExtensions.accessSection,
                detail: "• " + item.permissions.joined(separator: "\n• ")
            ))
        }
        if !item.matchPatterns.isEmpty {
            infoRows.append(.init(
                symbol: "hand.raised.fill",
                title: FloorpStrings.WebExtensions.siteAccess,
                detail: "• " + item.matchPatterns.joined(separator: "\n• ")
            ))
        }
        let optionalAccess = Set(item.optionalPermissions + item.optionalMatchPatterns).sorted()
        if !optionalAccess.isEmpty {
            infoRows.append(.init(
                symbol: "hand.tap.fill",
                title: FloorpStrings.WebExtensions.optionalAccess,
                detail: FloorpStrings.WebExtensions.optionalAccessMessage
                    + "\n\n• " + optionalAccess.joined(separator: "\n• ")
            ))
        }
        let diagnosticDetails = item.diagnostics.map {
            "[\($0.phase.rawValue)] \($0.domain) (\($0.code)): \($0.message)"
        }
        let uniqueDiagnosticDetails = diagnosticDetails.reduce(into: [String]()) { details, detail in
            guard !details.contains(detail) else { return }
            details.append(detail)
        }
        if !uniqueDiagnosticDetails.isEmpty {
            infoRows.append(.init(
                symbol: "stethoscope",
                title: FloorpStrings.WebExtensions.diagnostics,
                detail: "• " + uniqueDiagnosticDetails.joined(separator: "\n• ")
            ))
        }
        if let error = item.errorDescription,
           !item.diagnostics.contains(where: { $0.message == error }) {
            infoRows.append(.init(
                symbol: "exclamationmark.triangle.fill",
                title: FloorpStrings.WebExtensions.loadErrorTitle,
                detail: error
            ))
        }
        return infoRows
    }

    private func managementChoices(
        for item: FloorpNativeWebExtensionSettingsItem
    ) -> [FloorpNativeWebExtensionPromptPresentation.Choice] {
        var choices = [
            FloorpNativeWebExtensionPromptPresentation.Choice(
                identifier: "toggle-enabled",
                title: item.requiresRestartToEnable
                    ? FloorpStrings.WebExtensions.cancel
                    : (item.isEnabled
                        ? FloorpStrings.WebExtensions.disableAction
                        : FloorpStrings.WebExtensions.enableAction),
                detail: item.requiresRestartToEnable
                    ? FloorpStrings.WebExtensions.cancelEnableAfterRestartMessage
                    : (item.isEnabled
                        ? FloorpStrings.WebExtensions.standardBrowsingDisableMessage
                        : FloorpStrings.WebExtensions.standardBrowsingEnabledMessage),
                icon: UIImage(systemName: item.requiresRestartToEnable
                    ? "xmark.circle.fill"
                    : (item.isEnabled ? "pause.circle.fill" : "play.circle.fill")),
                usesTemplateIcon: true
            ),
            .init(
                identifier: "toggle-private",
                title: item.hasPrivateAccess
                    ? FloorpStrings.WebExtensions.disallowPrivateBrowsingAction
                    : FloorpStrings.WebExtensions.allowPrivateBrowsingAction,
                detail: item.hasPrivateAccess
                    ? FloorpStrings.WebExtensions.enabled
                    : FloorpStrings.WebExtensions.privateAccessNotAllowed,
                icon: UIImage(systemName: "eye.slash.fill"),
                usesTemplateIcon: true
            )
        ]
        if item.isEnabled, item.hasOptionsPage {
            choices.append(.init(
                identifier: "options",
                title: FloorpStrings.WebExtensions.options,
                detail: item.name,
                icon: UIImage(systemName: "gearshape.fill"),
                usesTemplateIcon: true
            ))
        }
        if item.hasUpdate,
           FloorpNativeWebExtensionCatalog.item(identifier: item.identifier) != nil {
            choices.append(.init(
                identifier: "update",
                title: FloorpStrings.WebExtensions.update,
                detail: FloorpStrings.WebExtensions.updateAvailable,
                icon: UIImage(systemName: "arrow.down.circle.fill"),
                usesTemplateIcon: true,
                role: .preferred
            ))
        }
        choices.append(.init(
            identifier: "uninstall",
            title: FloorpStrings.WebExtensions.uninstall,
            detail: FloorpStrings.WebExtensions.uninstallMessage,
            icon: UIImage(systemName: "trash.fill"),
            usesTemplateIcon: true,
            role: .destructive
        ))
        return choices
    }

    private func handleManagementChoice(
        _ identifier: String,
        for item: FloorpNativeWebExtensionSettingsItem
    ) {
        switch identifier {
        case "toggle-enabled":
            mutate(identifier: item.identifier, progress: FloorpStrings.WebExtensions.loading) {
                try await $0.setEnabled(
                    item.requiresRestartToEnable ? false : !item.isEnabled,
                    identifier: item.identifier
                )
            }
        case "toggle-private":
            mutate(identifier: item.identifier, progress: FloorpStrings.WebExtensions.loading) {
                try await $0.setPrivateAccess(!item.hasPrivateAccess, identifier: item.identifier)
            }
        case "options":
            guard let host, !isMutating else { return }
            let selectedTab = tabManager?.selectedTab
            let isPrivate = (selectedTab?.isPrivate ?? false) && item.hasPrivateAccess
            let sourceTab = selectedTab?.isPrivate == isPrivate ? selectedTab : nil
            isMutating = true
            busyIdentifier = item.identifier
            tableView.isUserInteractionEnabled = false
            navigationItem.prompt = FloorpStrings.WebExtensions.loading
            tableView.reloadData()
            Task { [weak self, host, sourceTab] in
                do {
                    let options = try await host.optionsViewController(
                        identifier: item.identifier,
                        sourceTab: sourceTab,
                        isPrivate: isPrivate
                    )
                    guard let self else { return }
                    isMutating = false
                    busyIdentifier = nil
                    tableView.isUserInteractionEnabled = true
                    navigationItem.prompt = nil
                    tableView.reloadData()
                    present(options, animated: true)
                } catch {
                    guard let self else { return }
                    isMutating = false
                    busyIdentifier = nil
                    tableView.isUserInteractionEnabled = true
                    navigationItem.prompt = nil
                    tableView.reloadData()
                    presentError(error)
                }
            }
        case "update":
            if let catalogItem = FloorpNativeWebExtensionCatalog.item(identifier: item.identifier) {
                confirmInstall(catalogItem)
            }
        case "uninstall":
            confirmUninstall(item)
        default:
            break
        }
    }

    private func confirmUninstall(_ item: FloorpNativeWebExtensionSettingsItem) {
        let sheet = FloorpNativeWebExtensionPromptViewController(
            presentation: .init(
                title: FloorpStrings.WebExtensions.uninstallTitle(name: item.name),
                message: FloorpStrings.WebExtensions.uninstallMessage,
                heroImage: item.iconData.flatMap(UIImage.init(data:)),
                heroUsesTemplateImage: item.iconData == nil,
                infoRows: [],
                choices: [.init(
                    identifier: "confirm-uninstall",
                    title: FloorpStrings.WebExtensions.uninstall,
                    detail: FloorpStrings.WebExtensions.uninstallMessage,
                    icon: UIImage(systemName: "trash.fill"),
                    usesTemplateIcon: true,
                    role: .destructive
                )],
                accessibilityIdentifier: "Floorp.NativeWebExtensions.Uninstall.\(item.identifier)"
            ),
            windowUUID: windowUUID,
            onChoice: { [weak self] _ in
                self?.mutate(
                    identifier: item.identifier,
                    progress: FloorpStrings.WebExtensions.removing
                ) {
                    try await $0.uninstall(identifier: item.identifier)
                }
            }
        )
        present(sheet, animated: true)
    }

    private func mutate(
        identifier: String,
        progress: String,
        _ operation: @escaping @MainActor (FloorpNativeWebExtensionHost) async throws -> Void
    ) {
        guard let host, !isMutating else { return }
        isMutating = true
        busyIdentifier = identifier
        tableView.isUserInteractionEnabled = false
        navigationItem.prompt = progress
        tableView.reloadData()
        Task { [weak self, host] in
            do {
                try await operation(host)
                guard let self else { return }
                isMutating = false
                busyIdentifier = nil
                tableView.isUserInteractionEnabled = true
                navigationItem.prompt = nil
                refresh()
            } catch {
                guard let self else { return }
                isMutating = false
                busyIdentifier = nil
                tableView.isUserInteractionEnabled = true
                navigationItem.prompt = nil
                tableView.reloadData()
                presentError(error)
            }
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(
            title: FloorpStrings.WebExtensions.changeErrorTitle,
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: FloorpStrings.WebExtensions.done, style: .default))
        present(alert, animated: true)
    }
}

@MainActor
final class FloorpNativeWebExtensionPageViewController: UIViewController,
                                                        WKNavigationDelegate,
                                                        WKUIDelegate,
                                                        UIAdaptivePresentationControllerDelegate {
    private struct CloseRequest {
        let animated: Bool
        let completion: (() -> Void)?
    }

    @MainActor
    private final class NavigationRequest {
        let action: WKNavigationAction
        let decisionHandler: @MainActor (WKNavigationActionPolicy) -> Void
        weak var alert: UIAlertController?
        private var isResolved = false

        init(
            action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            self.action = action
            self.decisionHandler = decisionHandler
        }

        func resolve(_ policy: WKNavigationActionPolicy) {
            guard !isResolved else { return }
            isResolved = true
            decisionHandler(policy)
        }
    }

    private enum CloseFailureResolution {
        case keepEditing
        case retry
        case closeAnyway
    }

    private let pageTitle: String
    private let url: URL
    private let configuration: WKWebViewConfiguration
    private let openURLInBrowser: (URL) -> Void
    private let prepareToClose: (@MainActor (WKWebView) async -> Bool)?
    private let onClose: () -> Void
    private let closeBridge: FloorpNativeWebExtensionCloseBridge
    private var webView: WKWebView?
    private var lastRoutedNewWindowRequest: URLRequest?
    private var closePreparationTask: Task<Void, Never>?
    private var failedCloseRequest: CloseRequest?
    private var navigationPreparationTask: Task<Void, Never>?
    private var navigationRequest: NavigationRequest?
    private var hasCommittedDocument = false
    private var didClose = false

    init(
        title: String,
        url: URL,
        configuration: WKWebViewConfiguration,
        openURLInBrowser: @escaping (URL) -> Void = { _ in },
        prepareToClose: (@MainActor (WKWebView) async -> Bool)? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        self.pageTitle = title
        self.url = url
        self.configuration = configuration
        self.openURLInBrowser = openURLInBrowser
        self.prepareToClose = prepareToClose
        self.onClose = onClose
        self.closeBridge = FloorpNativeWebExtensionCloseBridge(expectedURL: url)
        super.init(nibName: nil, bundle: nil)
        closeBridge.onClose = { [weak self] in
            self?.closePage()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = pageTitle
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(closePage)
        )

        closeBridge.install(in: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        closeBridge.attach(to: webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.webView = webView
        webView.load(URLRequest(url: url))
    }

    @objc
    private func closePage() {
        close(animated: true)
    }

    private func close(
        animated: Bool,
        completion: (() -> Void)? = nil,
        preparationAlreadyCompleted: Bool = false
    ) {
        guard !didClose, closePreparationTask == nil else { return }
        cancelNavigationPreparation(dismissAlert: true)
        let request = failedCloseRequest ?? CloseRequest(
            animated: animated,
            completion: completion
        )
        failedCloseRequest = nil
        guard !preparationAlreadyCompleted,
              hasCommittedDocument,
              let webView,
              let prepareToClose else {
            finishClosing()
            dismiss(animated: request.animated, completion: request.completion)
            return
        }

        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.prompt = FloorpStrings.WebExtensions.finishingOptionsChanges
        webView.isUserInteractionEnabled = false
        closePreparationTask = Task { @MainActor [weak self, weak webView] in
            guard !Task.isCancelled,
                  let self, let webView,
                  !self.didClose,
                  self.closePreparationTask != nil,
                  self.webView === webView else { return }
            let isReadyToClose = await prepareToClose(webView)
            guard !Task.isCancelled,
                  !self.didClose,
                  self.webView === webView else { return }
            self.closePreparationTask = nil
            self.navigationItem.rightBarButtonItem?.isEnabled = true
            self.navigationItem.prompt = nil
            guard isReadyToClose else {
                webView.isUserInteractionEnabled = true
                self.failedCloseRequest = request
                self.presentClosePreparationFailure()
                return
            }
            self.finishClosing()
            self.dismiss(animated: request.animated, completion: request.completion)
        }
    }

    private func presentClosePreparationFailure() {
        guard !didClose, failedCloseRequest != nil else { return }
        guard presentedViewController == nil,
              viewIfLoaded?.window != nil else {
            failedCloseRequest = nil
            return
        }
        let alert = UIAlertController(
            title: FloorpStrings.WebExtensions.optionsCloseFailureTitle,
            message: FloorpStrings.WebExtensions.optionsCloseFailureMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.continueEditing,
            style: .cancel
        ) { [weak self] _ in
            self?.resolveClosePreparationFailure(.keepEditing)
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.retry,
            style: .default
        ) { [weak self] _ in
            self?.resolveClosePreparationFailure(.retry)
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.closeAnyway,
            style: .destructive
        ) { [weak self] _ in
            self?.resolveClosePreparationFailure(.closeAnyway)
        })
        present(alert, animated: true)
    }

    private func resolveClosePreparationFailure(_ resolution: CloseFailureResolution) {
        guard let request = failedCloseRequest else { return }
        failedCloseRequest = nil
        let applyResolution: () -> Void = { [weak self] in
            guard let self else { return }
            self.applyClosePreparationFailureResolution(resolution, request: request)
        }
        if let alert = presentedViewController as? UIAlertController,
           alert.presentingViewController != nil {
            alert.dismiss(animated: true, completion: applyResolution)
        } else {
            applyResolution()
        }
    }

    private func applyClosePreparationFailureResolution(
        _ resolution: CloseFailureResolution,
        request: CloseRequest
    ) {
        switch resolution {
        case .keepEditing:
            break
        case .retry:
            close(animated: request.animated, completion: request.completion)
        case .closeAnyway:
            finishClosing()
            dismiss(animated: request.animated, completion: request.completion)
        }
    }

#if DEBUG || TESTING
    func requestCloseForTesting(completion: (() -> Void)? = nil) {
        close(animated: false, completion: completion)
    }

    func retryCloseAfterPreparationFailureForTesting() {
        resolveClosePreparationFailure(.retry)
    }

    func closeAfterPreparationFailureForTesting() {
        resolveClosePreparationFailure(.closeAnyway)
    }

    func closeAfterNavigationPreparationFailureForTesting() {
        guard let request = navigationRequest,
              request.alert != nil,
              let webView else { return }
        finishPreparedNavigation(
            request,
            in: webView,
            closePreservedSurface: true
        )
    }
#endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.isModalInPresentation = prepareToClose != nil
        (navigationController?.presentationController ?? presentationController)?.delegate = self
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePage()
    }

    func prepareForHostTeardown() {
        cancelNavigationPreparation(dismissAlert: true)
        closePreparationTask?.cancel()
        closePreparationTask = nil
        finishClosing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            finishClosing()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishClosing()
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        prepareToClose == nil
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        closePage()
    }

    private func finishClosing() {
        guard !didClose else { return }
        didClose = true
        cancelNavigationPreparation(dismissAlert: true)
        closePreparationTask?.cancel()
        closePreparationTask = nil
        failedCloseRequest = nil
        navigationItem.prompt = nil
        tearDownWebView()
        onClose()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard !didClose else {
            decisionHandler(.cancel)
            return
        }
        if let prepareToClose,
           hasCommittedDocument,
           floorpNavigationReplacesDocument(navigationAction, currentURL: webView.url) {
            prepareNavigation(
                navigationAction,
                in: webView,
                prepareToClose: prepareToClose,
                decisionHandler: decisionHandler
            )
            return
        }
        decideNavigation(
            navigationAction,
            in: webView,
            preparationAlreadyCompleted: false,
            decisionHandler: decisionHandler
        )
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        hasCommittedDocument = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        // WebKit can coalesce the didCommit callback for an extension URL.
        // A finished document is also sufficient to require close preparation.
        hasCommittedDocument = true
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // The navigation-policy callback owns any document-replacing request
        // once a live page needs asynchronous close preparation.
        if prepareToClose != nil,
           hasCommittedDocument,
           floorpNavigationReplacesDocument(navigationAction, currentURL: webView.url) {
            return nil
        }
        _ = routeNewWindowNavigation(navigationAction, in: webView)
        return nil
    }

    @discardableResult
    private func routeNewWindowNavigation(
        _ navigationAction: WKNavigationAction,
        in webView: WKWebView,
        preparationAlreadyCompleted: Bool = false
    ) -> Bool {
        guard let destination = navigationAction.request.url else { return false }
        let isSameExtensionOrigin = destination.scheme == url.scheme && destination.host == url.host
        let opensNewFrame = navigationAction.targetFrame == nil
        guard opensNewFrame || !isSameExtensionOrigin else { return false }
        guard opensNewFrame || ["http", "https"].contains(destination.scheme?.lowercased()) else {
            return false
        }
        guard lastRoutedNewWindowRequest != navigationAction.request else { return true }
        lastRoutedNewWindowRequest = navigationAction.request
        DispatchQueue.main.async { [weak self, request = navigationAction.request] in
            guard self?.lastRoutedNewWindowRequest == request else { return }
            self?.lastRoutedNewWindowRequest = nil
        }
        if isSameExtensionOrigin {
            guard !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView) else {
                return true
            }
            webView.load(navigationAction.request)
        } else if ["http", "https"].contains(destination.scheme?.lowercased()) {
            close(
                animated: true,
                completion: { [openURLInBrowser] in
                    openURLInBrowser(destination)
                },
                preparationAlreadyCompleted: preparationAlreadyCompleted
            )
        }
        return true
    }

    private func prepareNavigation(
        _ navigationAction: WKNavigationAction,
        in webView: WKWebView,
        prepareToClose: @escaping @MainActor (WKWebView) async -> Bool,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard closePreparationTask == nil, failedCloseRequest == nil else {
            decisionHandler(.cancel)
            return
        }
        cancelNavigationPreparation(dismissAlert: true)
        let request = NavigationRequest(
            action: navigationAction,
            decisionHandler: decisionHandler
        )
        navigationRequest = request
        webView.isUserInteractionEnabled = false
        runNavigationPreparation(request, in: webView, prepareToClose: prepareToClose)
    }

    private func runNavigationPreparation(
        _ request: NavigationRequest,
        in webView: WKWebView,
        prepareToClose: @escaping @MainActor (WKWebView) async -> Bool
    ) {
        guard navigationRequest === request, !didClose, self.webView === webView else {
            cancelNavigationPreparation(dismissAlert: true)
            return
        }
        navigationPreparationTask?.cancel()
        navigationPreparationTask = Task { @MainActor [weak self, weak webView, request] in
            guard !Task.isCancelled,
                  let self, let webView,
                  !self.didClose,
                  self.navigationRequest === request,
                  self.webView === webView else {
                request.resolve(.cancel)
                return
            }
            let prepared = await prepareToClose(webView)
            guard !Task.isCancelled,
                  !self.didClose,
                  self.navigationRequest === request,
                  self.webView === webView else { return }
            self.navigationPreparationTask = nil
            if prepared {
                self.finishPreparedNavigation(request, in: webView)
            } else {
                self.presentNavigationPreparationFailure(
                    request,
                    in: webView,
                    prepareToClose: prepareToClose
                )
            }
        }
    }

    private func finishPreparedNavigation(
        _ request: NavigationRequest,
        in webView: WKWebView,
        closePreservedSurface: Bool = false
    ) {
        guard navigationRequest === request, self.webView === webView else {
            request.resolve(.cancel)
            return
        }
        guard !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView) else {
            if closePreservedSurface {
                closeSurfaceWithoutReaccessingPreservedWebView(for: request)
                return
            }
            cancelNavigationPreparation(dismissAlert: true)
            return
        }
        navigationRequest = nil
        navigationPreparationTask = nil
        request.alert = nil
        webView.isUserInteractionEnabled = true
        decideNavigation(
            request.action,
            in: webView,
            preparationAlreadyCompleted: true,
            decisionHandler: { policy in request.resolve(policy) }
        )
    }

    private func closeSurfaceWithoutReaccessingPreservedWebView(
        for request: NavigationRequest
    ) {
        guard navigationRequest === request else {
            request.resolve(.cancel)
            return
        }
        navigationRequest = nil
        navigationPreparationTask?.cancel()
        navigationPreparationTask = nil
        let alert = request.alert
        request.alert = nil
        let completion = browserOpenCompletion(for: request.action.request.url)
        request.resolve(.cancel)
        let closeSurface = { [weak self] in
            self?.close(
                animated: true,
                completion: completion,
                preparationAlreadyCompleted: true
            )
        }
        if alert?.presentingViewController != nil || alert?.viewIfLoaded?.window != nil {
            alert?.dismiss(animated: false, completion: closeSurface)
        } else {
            closeSurface()
        }
    }

    private func browserOpenCompletion(for destination: URL?) -> (() -> Void)? {
        guard let destination,
              ["http", "https"].contains(destination.scheme?.lowercased()) else {
            return nil
        }
        return { [openURLInBrowser] in
            openURLInBrowser(destination)
        }
    }

    private func decideNavigation(
        _ navigationAction: WKNavigationAction,
        in webView: WKWebView,
        preparationAlreadyCompleted: Bool,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(
            routeNewWindowNavigation(
                navigationAction,
                in: webView,
                preparationAlreadyCompleted: preparationAlreadyCompleted
            ) ? .cancel : .allow
        )
    }

    private func presentNavigationPreparationFailure(
        _ request: NavigationRequest,
        in webView: WKWebView,
        prepareToClose: @escaping @MainActor (WKWebView) async -> Bool
    ) {
        guard navigationRequest === request,
              self.webView === webView,
              presentedViewController == nil,
              viewIfLoaded?.window != nil else {
            cancelNavigationPreparation(dismissAlert: true)
            return
        }
        let alert = UIAlertController(
            title: FloorpStrings.WebExtensions.optionsCloseFailureTitle,
            message: FloorpStrings.WebExtensions.optionsCloseFailureMessage,
            preferredStyle: .alert
        )
        request.alert = alert
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.continueEditing,
            style: .cancel
        ) { [weak self] _ in
            self?.cancelNavigationPreparation(dismissAlert: false)
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.retry,
            style: .default
        ) { [weak self, weak webView, request] _ in
            guard let self, let webView, self.navigationRequest === request else { return }
            request.alert = nil
            DispatchQueue.main.async { [weak self, weak webView, request] in
                guard let self, let webView else {
                    request.resolve(.cancel)
                    return
                }
                self.runNavigationPreparation(
                    request,
                    in: webView,
                    prepareToClose: prepareToClose
                )
            }
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.closeAnyway,
            style: .destructive
        ) { [weak self, weak webView, request] _ in
            guard let self, let webView else {
                request.resolve(.cancel)
                return
            }
            self.finishPreparedNavigation(
                request,
                in: webView,
                closePreservedSurface: true
            )
        })
        present(alert, animated: true)
    }

    private func cancelNavigationPreparation(dismissAlert: Bool) {
        guard let request = navigationRequest else { return }
        navigationRequest = nil
        navigationPreparationTask?.cancel()
        navigationPreparationTask = nil
        let alert = request.alert
        request.alert = nil
        if dismissAlert,
           alert?.presentingViewController != nil || alert?.viewIfLoaded?.window != nil {
            alert?.dismiss(animated: false)
        }
        webView?.isUserInteractionEnabled = true
        request.resolve(.cancel)
    }

    private func tearDownWebView() {
        guard let webView else { return }
        let mustPreserve = FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView)
        closeBridge.invalidate(in: configuration)
        hasCommittedDocument = false
        if !mustPreserve {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        self.webView = nil
        FloorpNativeWebExtensionDeferredWebViewRelease.retain(webView)
    }
}

/// A bundled action popup backed by a tab-scoped WebExtension configuration.
///
/// `WKWebExtension.Action.popupWebView` always inherits the controller's
/// persistent default data store. That is not suitable when an action was
/// invoked from a private tab. The host therefore presents the digest-pinned
/// bundled popup page itself, while retaining WebKit's extension controller and
/// swapping only the source tab's data store and a per-surface content controller.
@MainActor
final class FloorpNativeWebExtensionActionPopupViewController: UIViewController,
                                                               WKNavigationDelegate,
                                                               WKUIDelegate,
                                                               UIAdaptivePresentationControllerDelegate {
    private struct CloseRequest {
        let animated: Bool
        let completion: (() -> Void)?
        let outcomeCompletion: ((Bool) -> Void)?
    }

    @MainActor
    private final class CloseOutcomeWaiter: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var resolvedOutcome: Bool?

        func wait() async -> Bool {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let resolvedOutcome {
                        continuation.resume(returning: resolvedOutcome)
                    } else if Task.isCancelled {
                        continuation.resume(returning: false)
                    } else {
                        self.continuation = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resolve(false)
                }
            }
        }

        func resolve(_ outcome: Bool) {
            guard resolvedOutcome == nil else { return }
            resolvedOutcome = outcome
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    @MainActor
    private final class NavigationRequest {
        let action: WKNavigationAction
        let decisionHandler: @MainActor (WKNavigationActionPolicy) -> Void
        weak var alert: UIAlertController?
        private var isResolved = false

        init(
            action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            self.action = action
            self.decisionHandler = decisionHandler
        }

        func resolve(_ policy: WKNavigationActionPolicy) {
            guard !isResolved else { return }
            isResolved = true
            decisionHandler(policy)
        }
    }

    private enum CloseFailureResolution {
        case keepOpen
        case retry
        case closeAnyway
    }

    let webView: WKWebView

    private let popupURL: URL
    private let configuration: WKWebViewConfiguration
    private let openURLInBrowser: (URL) -> Void
    private let prepareToClose: (@MainActor (WKWebView) async -> Bool)?
    private let onClose: () -> Void
    private let closeBridge: FloorpNativeWebExtensionCloseBridge
    private var didClose = false
    private var lastRoutedNewWindowRequest: URLRequest?
    private var closePreparationTask: Task<Void, Never>?
    private var activeCloseRequest: CloseRequest?
    private var failedCloseRequest: CloseRequest?
    private var closeOutcomeWaiters = [UUID: CloseOutcomeWaiter]()
    private var navigationPreparationTask: Task<Void, Never>?
    private var navigationRequest: NavigationRequest?
    private var hasCommittedDocument = false

    init(
        url: URL,
        configuration: WKWebViewConfiguration,
        openURLInBrowser: @escaping (URL) -> Void,
        prepareToClose: (@MainActor (WKWebView) async -> Bool)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.popupURL = url
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.configuration = webView.configuration
        self.webView = webView
        self.openURLInBrowser = openURLInBrowser
        self.prepareToClose = prepareToClose
        self.onClose = onClose
        self.closeBridge = FloorpNativeWebExtensionCloseBridge(expectedURL: url)
        super.init(nibName: nil, bundle: nil)
        closeBridge.onClose = { [weak self] in
            self?.closePopup(animated: true)
        }
        modalPresentationStyle = .popover
        isModalInPresentation = prepareToClose != nil
        preferredContentSize = CGSize(width: 360, height: 600)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityLabel = FloorpStrings.WebExtensions.genericExtensionName

        closeBridge.install(in: configuration)
        closeBridge.attach(to: webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        webView.load(URLRequest(url: popupURL))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isModalInPresentation = prepareToClose != nil
        presentationController?.delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            invalidatePopup()
        }
    }

    func closePopup(animated: Bool, completion: (() -> Void)? = nil) {
        requestClose(
            animated: animated,
            completion: completion,
            outcomeCompletion: nil
        )
    }

    func closePopupAfterPreparing(animated: Bool) async -> Bool {
        if didClose { return true }
        let token = UUID()
        let waiter = CloseOutcomeWaiter()
        closeOutcomeWaiters[token] = waiter
        // `window.close()` can reach WKUIDelegate while the WebExtension
        // delegate is concurrently waiting to open a new tab. Both callers
        // observe the same in-flight preparation instead of racing and
        // treating the second request as a failure.
        if closePreparationTask == nil, failedCloseRequest == nil {
            requestClose(
                animated: animated,
                completion: nil,
                outcomeCompletion: nil
            )
        }
        let outcome = await waiter.wait()
        closeOutcomeWaiters.removeValue(forKey: token)
        return outcome
    }

    private func requestClose(
        animated: Bool,
        completion: (() -> Void)?,
        outcomeCompletion: ((Bool) -> Void)?,
        preparationAlreadyCompleted: Bool = false
    ) {
        guard !didClose else {
            completion?()
            outcomeCompletion?(true)
            return
        }
        guard closePreparationTask == nil else {
            outcomeCompletion?(false)
            return
        }
        cancelNavigationPreparation(dismissAlert: true)
        let request = failedCloseRequest ?? CloseRequest(
            animated: animated,
            completion: completion,
            outcomeCompletion: outcomeCompletion
        )
        failedCloseRequest = nil
        guard !preparationAlreadyCompleted,
              hasCommittedDocument,
              let prepareToClose else {
            finishClosing(request)
            return
        }

        view.isUserInteractionEnabled = false
        activeCloseRequest = request
        closePreparationTask = Task { @MainActor [weak self, weak webView] in
            guard !Task.isCancelled,
                  let self, let webView,
                  !self.didClose,
                  self.activeCloseRequest != nil,
                  self.webView === webView else {
                request.outcomeCompletion?(false)
                return
            }
            let isReadyToClose = await prepareToClose(webView)
            guard !Task.isCancelled,
                  !self.didClose,
                  self.webView === webView else { return }
            self.closePreparationTask = nil
            self.activeCloseRequest = nil
            self.view.isUserInteractionEnabled = true
            guard isReadyToClose else {
                self.failedCloseRequest = request
                self.presentClosePreparationFailure()
                return
            }
            self.finishClosing(request)
        }
    }

    private func finishClosing(_ request: CloseRequest) {
        activeCloseRequest = nil
        failedCloseRequest = nil
        invalidatePopup(closeOutcome: true)
        guard presentingViewController != nil else {
            request.completion?()
            request.outcomeCompletion?(true)
            return
        }
        dismiss(animated: request.animated) {
            request.completion?()
            request.outcomeCompletion?(true)
        }
    }

    func closePopupImmediately(animated: Bool, completion: (() -> Void)? = nil) {
        invalidatePopup(closeOutcome: false)
        guard presentingViewController != nil else {
            completion?()
            return
        }
        dismiss(animated: animated, completion: completion)
    }

#if DEBUG || TESTING
    func requestCloseForTesting(completion: (() -> Void)? = nil) {
        closePopup(animated: false, completion: completion)
    }

    func retryCloseAfterPreparationFailureForTesting() {
        resolveClosePreparationFailure(.retry)
    }

    func closeAfterPreparationFailureForTesting() {
        resolveClosePreparationFailure(.closeAnyway)
    }

    func closeAfterNavigationPreparationFailureForTesting() {
        guard let request = navigationRequest,
              request.alert != nil else { return }
        finishPreparedNavigation(
            request,
            in: webView,
            closePreservedSurface: true
        )
    }
#endif

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        invalidatePopup()
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        prepareToClose == nil
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        closePopup(animated: true)
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePopup(animated: true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        hasCommittedDocument = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        // WebKit can coalesce the didCommit callback for an extension URL.
        // A finished popup must still flush its pending extension state.
        hasCommittedDocument = true
        webView.evaluateJavaScript(
            "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]"
        ) { [weak self] result, _ in
            guard let self, let dimensions = result as? [NSNumber], dimensions.count == 2 else {
                return
            }
            preferredContentSize = CGSize(
                width: min(max(CGFloat(truncating: dimensions[0]), 280), 420),
                height: min(max(CGFloat(truncating: dimensions[1]), 240), 700)
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard !didClose else {
            decisionHandler(.cancel)
            return
        }
        if let prepareToClose,
           hasCommittedDocument,
           floorpNavigationReplacesDocument(navigationAction, currentURL: webView.url) {
            prepareNavigation(
                navigationAction,
                in: webView,
                prepareToClose: prepareToClose,
                decisionHandler: decisionHandler
            )
            return
        }
        decideNavigation(
            navigationAction,
            in: webView,
            preparationAlreadyCompleted: false,
            decisionHandler: decisionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // The navigation-policy callback owns any document-replacing request
        // once a live popup needs asynchronous close preparation.
        if prepareToClose != nil,
           hasCommittedDocument,
           floorpNavigationReplacesDocument(navigationAction, currentURL: webView.url) {
            return nil
        }
        _ = routeNewWindowNavigation(navigationAction, in: webView)
        return nil
    }

    @discardableResult
    private func routeNewWindowNavigation(
        _ navigationAction: WKNavigationAction,
        in webView: WKWebView,
        preparationAlreadyCompleted: Bool = false
    ) -> Bool {
        guard let destination = navigationAction.request.url else { return false }
        let isSameExtensionOrigin = destination.scheme == popupURL.scheme
            && destination.host == popupURL.host
        let opensNewFrame = navigationAction.targetFrame == nil
        guard opensNewFrame || !isSameExtensionOrigin else { return false }
        guard lastRoutedNewWindowRequest != navigationAction.request else { return true }
        lastRoutedNewWindowRequest = navigationAction.request
        DispatchQueue.main.async { [weak self, request = navigationAction.request] in
            guard self?.lastRoutedNewWindowRequest == request else { return }
            self?.lastRoutedNewWindowRequest = nil
        }
        if isSameExtensionOrigin {
            guard !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView) else {
                return true
            }
            webView.load(navigationAction.request)
        } else if ["http", "https"].contains(destination.scheme?.lowercased()) {
            requestClose(
                animated: true,
                completion: { [openURLInBrowser] in
                    openURLInBrowser(destination)
                },
                outcomeCompletion: nil,
                preparationAlreadyCompleted: preparationAlreadyCompleted
            )
        }
        return true
    }

    private func prepareNavigation(
        _ navigationAction: WKNavigationAction,
        in webView: WKWebView,
        prepareToClose: @escaping @MainActor (WKWebView) async -> Bool,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard closePreparationTask == nil, failedCloseRequest == nil else {
            decisionHandler(.cancel)
            return
        }
        cancelNavigationPreparation(dismissAlert: true)
        let request = NavigationRequest(
            action: navigationAction,
            decisionHandler: decisionHandler
        )
        navigationRequest = request
        view.isUserInteractionEnabled = false
        runNavigationPreparation(request, in: webView, prepareToClose: prepareToClose)
    }

    private func runNavigationPreparation(
        _ request: NavigationRequest,
        in webView: WKWebView,
        prepareToClose: @escaping @MainActor (WKWebView) async -> Bool
    ) {
        guard navigationRequest === request, !didClose, self.webView === webView else {
            cancelNavigationPreparation(dismissAlert: true)
            return
        }
        navigationPreparationTask?.cancel()
        navigationPreparationTask = Task { @MainActor [weak self, weak webView, request] in
            guard !Task.isCancelled,
                  let self, let webView,
                  !self.didClose,
                  self.navigationRequest === request,
                  self.webView === webView else {
                request.resolve(.cancel)
                return
            }
            let prepared = await prepareToClose(webView)
            guard !Task.isCancelled,
                  !self.didClose,
                  self.navigationRequest === request,
                  self.webView === webView else { return }
            self.navigationPreparationTask = nil
            if prepared {
                self.finishPreparedNavigation(request, in: webView)
            } else {
                self.presentNavigationPreparationFailure(
                    request,
                    in: webView,
                    prepareToClose: prepareToClose
                )
            }
        }
    }

    private func finishPreparedNavigation(
        _ request: NavigationRequest,
        in webView: WKWebView,
        closePreservedSurface: Bool = false
    ) {
        guard navigationRequest === request, self.webView === webView else {
            request.resolve(.cancel)
            return
        }
        guard !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView) else {
            if closePreservedSurface {
                closeSurfaceWithoutReaccessingPreservedWebView(for: request)
                return
            }
            cancelNavigationPreparation(dismissAlert: true)
            return
        }
        navigationRequest = nil
        navigationPreparationTask = nil
        request.alert = nil
        view.isUserInteractionEnabled = true
        decideNavigation(
            request.action,
            in: webView,
            preparationAlreadyCompleted: true,
            decisionHandler: { policy in request.resolve(policy) }
        )
    }

    private func closeSurfaceWithoutReaccessingPreservedWebView(
        for request: NavigationRequest
    ) {
        guard navigationRequest === request else {
            request.resolve(.cancel)
            return
        }
        navigationRequest = nil
        navigationPreparationTask?.cancel()
        navigationPreparationTask = nil
        let alert = request.alert
        request.alert = nil
        let completion = browserOpenCompletion(for: request.action.request.url)
        request.resolve(.cancel)
        let closeSurface = { [weak self] in
            self?.requestClose(
                animated: true,
                completion: completion,
                outcomeCompletion: nil,
                preparationAlreadyCompleted: true
            )
        }
        if alert?.presentingViewController != nil || alert?.viewIfLoaded?.window != nil {
            alert?.dismiss(animated: false, completion: closeSurface)
        } else {
            closeSurface()
        }
    }

    private func browserOpenCompletion(for destination: URL?) -> (() -> Void)? {
        guard let destination,
              ["http", "https"].contains(destination.scheme?.lowercased()) else {
            return nil
        }
        return { [openURLInBrowser] in
            openURLInBrowser(destination)
        }
    }

    private func decideNavigation(
        _ navigationAction: WKNavigationAction,
        in webView: WKWebView,
        preparationAlreadyCompleted: Bool,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard !FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(
            routeNewWindowNavigation(
                navigationAction,
                in: webView,
                preparationAlreadyCompleted: preparationAlreadyCompleted
            ) ? .cancel : .allow
        )
    }

    private func presentNavigationPreparationFailure(
        _ request: NavigationRequest,
        in webView: WKWebView,
        prepareToClose: @escaping @MainActor (WKWebView) async -> Bool
    ) {
        guard navigationRequest === request,
              self.webView === webView,
              presentedViewController == nil,
              viewIfLoaded?.window != nil else {
            cancelNavigationPreparation(dismissAlert: true)
            return
        }
        let alert = UIAlertController(
            title: FloorpStrings.WebExtensions.optionsCloseFailureTitle,
            message: FloorpStrings.WebExtensions.optionsCloseFailureMessage,
            preferredStyle: .alert
        )
        request.alert = alert
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.continueEditing,
            style: .cancel
        ) { [weak self] _ in
            self?.cancelNavigationPreparation(dismissAlert: false)
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.retry,
            style: .default
        ) { [weak self, weak webView, request] _ in
            guard let self, let webView, self.navigationRequest === request else { return }
            request.alert = nil
            DispatchQueue.main.async { [weak self, weak webView, request] in
                guard let self, let webView else {
                    request.resolve(.cancel)
                    return
                }
                self.runNavigationPreparation(
                    request,
                    in: webView,
                    prepareToClose: prepareToClose
                )
            }
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.closeAnyway,
            style: .destructive
        ) { [weak self, weak webView, request] _ in
            guard let self, let webView else {
                request.resolve(.cancel)
                return
            }
            self.finishPreparedNavigation(
                request,
                in: webView,
                closePreservedSurface: true
            )
        })
        present(alert, animated: true)
    }

    private func cancelNavigationPreparation(dismissAlert: Bool) {
        guard let request = navigationRequest else { return }
        navigationRequest = nil
        navigationPreparationTask?.cancel()
        navigationPreparationTask = nil
        let alert = request.alert
        request.alert = nil
        if dismissAlert,
           alert?.presentingViewController != nil || alert?.viewIfLoaded?.window != nil {
            alert?.dismiss(animated: false)
        }
        view.isUserInteractionEnabled = true
        request.resolve(.cancel)
    }

    private func invalidatePopup(closeOutcome: Bool = false) {
        guard !didClose else { return }
        let mustPreserve = FloorpNativeWebExtensionProcessLifetimeWebViewRegistry.mustPreserve(webView)
        cancelNavigationPreparation(dismissAlert: true)
        let abandonedRequest = activeCloseRequest ?? failedCloseRequest
        didClose = true
        closePreparationTask?.cancel()
        closePreparationTask = nil
        activeCloseRequest = nil
        failedCloseRequest = nil
        view.isUserInteractionEnabled = true
        closeBridge.invalidate(in: configuration)
        hasCommittedDocument = false
        if !mustPreserve {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        FloorpNativeWebExtensionDeferredWebViewRelease.retain(webView)
        onClose()
        abandonedRequest?.outcomeCompletion?(false)
        resolveCloseOutcomeObservers(closeOutcome)
    }

    private func presentClosePreparationFailure() {
        guard !didClose, let request = failedCloseRequest else { return }
        guard presentedViewController == nil,
              viewIfLoaded?.window != nil else {
            failedCloseRequest = nil
            request.outcomeCompletion?(false)
            resolveCloseOutcomeObservers(false)
            return
        }
        let alert = UIAlertController(
            title: FloorpStrings.WebExtensions.optionsCloseFailureTitle,
            message: FloorpStrings.WebExtensions.optionsCloseFailureMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.continueEditing,
            style: .cancel
        ) { [weak self] _ in
            self?.resolveClosePreparationFailure(.keepOpen)
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.retry,
            style: .default
        ) { [weak self] _ in
            self?.resolveClosePreparationFailure(.retry)
        })
        alert.addAction(UIAlertAction(
            title: FloorpStrings.WebExtensions.closeAnyway,
            style: .destructive
        ) { [weak self] _ in
            self?.resolveClosePreparationFailure(.closeAnyway)
        })
        present(alert, animated: true)
    }

    private func resolveClosePreparationFailure(_ resolution: CloseFailureResolution) {
        guard let request = failedCloseRequest else { return }
        failedCloseRequest = nil
        let applyResolution: () -> Void = { [weak self] in
            self?.applyClosePreparationFailureResolution(resolution, request: request)
        }
        if let alert = presentedViewController as? UIAlertController,
           alert.presentingViewController != nil {
            alert.dismiss(animated: true, completion: applyResolution)
        } else {
            applyResolution()
        }
    }

    private func applyClosePreparationFailureResolution(
        _ resolution: CloseFailureResolution,
        request: CloseRequest
    ) {
        switch resolution {
        case .keepOpen:
            request.outcomeCompletion?(false)
            resolveCloseOutcomeObservers(false)
        case .retry:
            failedCloseRequest = request
            requestClose(
                animated: request.animated,
                completion: request.completion,
                outcomeCompletion: request.outcomeCompletion
            )
        case .closeAnyway:
            finishClosing(request)
        }
    }

    private func resolveCloseOutcomeObservers(_ didClose: Bool) {
        let waiters = closeOutcomeWaiters.values
        closeOutcomeWaiters.removeAll()
        waiters.forEach { $0.resolve(didClose) }
    }
}
