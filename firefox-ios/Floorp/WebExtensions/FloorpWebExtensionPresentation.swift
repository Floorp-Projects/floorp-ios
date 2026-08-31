// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit

struct FloorpWebExtensionIconDescriptor: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case data(Data)
        case resource(name: String, extension: String, subdirectory: String?)
        case system(name: String)
    }

    let source: Source
    let fallbackSystemName: String

    @MainActor
    func image(in bundle: Bundle = .main) -> UIImage? {
        if case let .data(data) = source,
           let image = UIImage(data: data) {
            return image.withRenderingMode(.alwaysOriginal)
        }
        if case let .resource(name, fileExtension, subdirectory) = source,
           let url = bundle.url(
               forResource: name,
               withExtension: fileExtension,
               subdirectory: subdirectory
           ),
           let image = UIImage(contentsOfFile: url.path) {
            return image.withRenderingMode(.alwaysOriginal)
        }

        let systemName: String
        switch source {
        case .data, .resource:
            systemName = fallbackSystemName
        case .system(let name):
            systemName = name
        }
        return UIImage(systemName: systemName)?.withRenderingMode(.alwaysTemplate)
    }

    @MainActor
    func usesTemplateRendering(in bundle: Bundle = .main) -> Bool {
        switch source {
        case let .data(data):
            return UIImage(data: data) == nil
        case let .resource(name, fileExtension, subdirectory):
            return bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ) == nil
        case .system:
            return true
        }
    }
}

enum FloorpWebExtensionIconRegistry {
    static func descriptor(
        for _: FloorpWebExtensionID,
        iconData: Data? = nil
    ) -> FloorpWebExtensionIconDescriptor {
        if let iconData {
            return FloorpWebExtensionIconDescriptor(
                source: .data(iconData),
                fallbackSystemName: "puzzlepiece.extension.fill"
            )
        }
        return FloorpWebExtensionIconDescriptor(
            source: .system(name: "puzzlepiece.extension.fill"),
            fallbackSystemName: "puzzlepiece.extension.fill"
        )
    }
}

struct FloorpWebExtensionCardPresentation: Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case available
        case enabled
        case disabled
        case updateAvailable
        case revoked
        case error

        var title: String {
            switch self {
            case .available: return FloorpStrings.WebExtensions.add
            case .enabled: return FloorpStrings.WebExtensions.enabled
            case .disabled: return FloorpStrings.WebExtensions.disabled
            case .updateAvailable: return FloorpStrings.WebExtensions.updateAvailable
            case .revoked: return FloorpStrings.WebExtensions.revoked
            case .error: return FloorpStrings.WebExtensions.loadErrorTitle
            }
        }
    }

    let extensionID: FloorpWebExtensionID
    let title: String
    let summary: String
    let version: String
    let status: Status
    let iconData: Data?
    let accessibilityIdentifier: String
    let accessibilityHint: String
    let isBusy: Bool

    init(
        extensionID: FloorpWebExtensionID,
        title: String,
        summary: String,
        version: String,
        status: Status,
        iconData: Data? = nil,
        accessibilityIdentifier: String,
        accessibilityHint: String,
        isBusy: Bool = false
    ) {
        self.extensionID = extensionID
        self.title = title
        self.summary = summary
        self.version = version
        self.status = status
        self.iconData = iconData
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityHint = accessibilityHint
        self.isBusy = isBusy
    }
}

@MainActor
final class FloorpWebExtensionCardCell: UITableViewCell, ThemeApplicable {
    static let reuseIdentifier = "FloorpWebExtensionCardCell"

    private let iconView: UIImageView = .build()
    private let titleLabel: UILabel = .build()
    private let summaryLabel: UILabel = .build()
    private let versionLabel: UILabel = .build()
    private let statusLabel: UILabel = .build()
    private let metadataStack: UIStackView = .build()
    private let metadataSeparatorLabel: UILabel = .build()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var presentation: FloorpWebExtensionCardPresentation?

    var displayedTitle: String? { titleLabel.text }
    var displayedSummary: String? { summaryLabel.text }
    var displayedVersion: String? { versionLabel.text }
    var displayedStatus: String? { statusLabel.text }
    var displayedIcon: UIImage? { iconView.image }
    var isShowingActivity: Bool { activityIndicator.isAnimating }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        presentation = nil
        iconView.image = nil
        accessibilityLabel = nil
        accessibilityHint = nil
        accessibilityIdentifier = nil
        accessibilityValue = nil
        isUserInteractionEnabled = true
        activityIndicator.stopAnimating()
        accessoryView = nil
        accessoryType = .none
    }

    func configure(
        with presentation: FloorpWebExtensionCardPresentation,
        theme: Theme,
        bundle: Bundle = .main
    ) {
        self.presentation = presentation
        let descriptor = FloorpWebExtensionIconRegistry.descriptor(
            for: presentation.extensionID,
            iconData: presentation.iconData
        )
        iconView.image = descriptor.image(in: bundle)
        iconView.tintColor = descriptor.usesTemplateRendering(in: bundle) ? theme.colors.iconAccent : nil
        titleLabel.text = presentation.title
        summaryLabel.text = presentation.summary
        versionLabel.text = FloorpStrings.WebExtensions.version(presentation.version)
        statusLabel.text = presentation.status.title
        isUserInteractionEnabled = !presentation.isBusy
        if presentation.isBusy {
            activityIndicator.startAnimating()
            accessoryView = activityIndicator
            accessoryType = .none
            accessibilityValue = FloorpStrings.WebExtensions.loading
        } else {
            activityIndicator.stopAnimating()
            accessoryView = nil
            accessoryType = .disclosureIndicator
            accessibilityValue = presentation.status.title
        }
        accessibilityIdentifier = presentation.accessibilityIdentifier
        accessibilityLabel = [
            presentation.title,
            presentation.status.title,
            FloorpStrings.WebExtensions.version(presentation.version),
            presentation.summary
        ].joined(separator: ", ")
        accessibilityHint = presentation.accessibilityHint
        applyTheme(theme: theme)
    }

    func applyTheme(theme: Theme) {
        backgroundColor = theme.colors.layer2
        contentView.backgroundColor = theme.colors.layer2
        titleLabel.textColor = theme.colors.textPrimary
        summaryLabel.textColor = theme.colors.textSecondary
        versionLabel.textColor = theme.colors.textSecondary
        metadataSeparatorLabel.textColor = theme.colors.textSecondary
        activityIndicator.color = theme.colors.iconAccent

        guard let status = presentation?.status else { return }
        switch status {
        case .available, .updateAvailable:
            statusLabel.textColor = theme.colors.textAccent
        case .enabled:
            statusLabel.textColor = theme.colors.textSecondary
        case .disabled:
            statusLabel.textColor = theme.colors.textSecondary
        case .revoked, .error:
            statusLabel.textColor = theme.colors.textCritical
        }

        let descriptor = presentation.map {
            FloorpWebExtensionIconRegistry.descriptor(for: $0.extensionID, iconData: $0.iconData)
        }
        iconView.tintColor = descriptor?.usesTemplateRendering() == true
            ? theme.colors.iconAccent
            : nil

        let selectedBackground = UIView()
        selectedBackground.backgroundColor = theme.colors.layer5Hover
        selectedBackgroundView = selectedBackground
    }

    private func setupView() {
        selectionStyle = .default
        isAccessibilityElement = true
        accessibilityTraits = .button

        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.numberOfLines = 2
        versionLabel.font = .preferredFont(forTextStyle: .footnote)
        versionLabel.adjustsFontForContentSizeCategory = true
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 1
        metadataSeparatorLabel.text = "·"
        metadataSeparatorLabel.font = .preferredFont(forTextStyle: .footnote)
        metadataSeparatorLabel.adjustsFontForContentSizeCategory = true
        metadataStack.axis = .horizontal
        metadataStack.spacing = 5
        metadataStack.alignment = .firstBaseline
        metadataStack.addArrangedSubview(statusLabel)
        metadataStack.addArrangedSubview(metadataSeparatorLabel)
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
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metadataStack.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            metadataStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadataStack.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),
            metadataStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 84)
        ])
        separatorInset = UIEdgeInsets(top: 0, left: 72, bottom: 0, right: 0)
    }
}

struct FloorpWebExtensionPromptPresentation: Hashable, Sendable {
    struct Choice: Hashable, Sendable {
        enum Icon: Hashable, Sendable {
            case system(String)
            case extensionIcon(id: FloorpWebExtensionID, data: Data?)
        }

        enum Role: Hashable, Sendable {
            case standard
            case preferred
            case destructive
        }

        let identifier: String
        let title: String
        let detail: String
        let icon: Icon
        let role: Role
        let isSelected: Bool

        init(
            identifier: String,
            title: String,
            detail: String,
            icon: Icon,
            role: Role = .standard,
            isSelected: Bool = false
        ) {
            self.identifier = identifier
            self.title = title
            self.detail = detail
            self.icon = icon
            self.role = role
            self.isSelected = isSelected
        }
    }

    let title: String
    let message: String
    let heroIcon: Choice.Icon
    let choices: [Choice]
    let cancelTitle: String
    let accessibilityIdentifier: String

    init(
        title: String,
        message: String,
        heroIcon: Choice.Icon,
        choices: [Choice],
        cancelTitle: String = FloorpStrings.WebExtensions.cancel,
        accessibilityIdentifier: String
    ) {
        self.title = title
        self.message = message
        self.heroIcon = heroIcon
        self.choices = choices
        self.cancelTitle = cancelTitle
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

@MainActor
final class FloorpWebExtensionPromptViewController: UIViewController,
                                                      Themeable,
                                                      InjectedThemeUUIDIdentifiable {
    typealias ChoiceHandler = @MainActor (String) -> Void
    typealias CancelHandler = @MainActor () -> Void

    private final class ChoiceButton: UIButton {
        let choice: FloorpWebExtensionPromptPresentation.Choice
        private let image: UIImage?

        init(choice: FloorpWebExtensionPromptPresentation.Choice) {
            self.choice = choice
            switch choice.icon {
            case .system(let name):
                image = UIImage(systemName: name)?.withRenderingMode(.alwaysTemplate)
            case .extensionIcon(let id, let data):
                image = FloorpWebExtensionIconRegistry.descriptor(for: id, iconData: data).image()
            }
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            contentHorizontalAlignment = .leading
            accessibilityIdentifier = choice.identifier
            accessibilityLabel = choice.title
            accessibilityHint = choice.detail
            accessibilityValue = choice.isSelected ? FloorpStrings.WebExtensions.currentSelection : nil
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func applyTheme(theme: Theme) {
            var configuration = UIButton.Configuration.plain()
            configuration.title = choice.title
            configuration.subtitle = choice.isSelected
                ? [choice.detail, FloorpStrings.WebExtensions.currentSelection]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                : choice.detail
            configuration.image = choice.isSelected
                ? UIImage(systemName: "checkmark.circle.fill")
                : image
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
            configuration.background.strokeColor = choice.isSelected
                ? theme.colors.iconAccent
                : theme.colors.borderPrimary
            configuration.background.strokeWidth = choice.isSelected ? 2 : 1
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

    let presentation: FloorpWebExtensionPromptPresentation
    private let notificationCenter: NotificationProtocol
    private let onChoice: ChoiceHandler
    private let onCancel: CancelHandler
    private let scrollView: UIScrollView = .build()
    private let contentStack: UIStackView = .build()
    private let heroCard: UIView = .build()
    private let heroIconView: UIImageView = .build()
    private let titleLabel: UILabel = .build()
    private let messageLabel: UILabel = .build()
    private let cancelButton: UIButton = .build()
    private var choiceButtons = [ChoiceButton]()
    private var didFinish = false
    private var heroUsesTemplateRendering = true

    var displayedChoiceTitles: [String] { choiceButtons.map(\.choice.title) }
    var displayedHeroIcon: UIImage? { heroIconView.image }

    init(
        presentation: FloorpWebExtensionPromptPresentation,
        windowUUID: WindowUUID,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        onChoice: @escaping ChoiceHandler,
        onCancel: @escaping CancelHandler = {}
    ) {
        self.presentation = presentation
        self.windowUUID = windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        self.onChoice = onChoice
        self.onCancel = onCancel
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
    }

    func applyTheme() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        view.backgroundColor = theme.colors.layer1
        scrollView.backgroundColor = theme.colors.layer1
        heroCard.backgroundColor = theme.colors.layer2
        heroCard.layer.borderColor = theme.colors.borderPrimary.cgColor
        heroIconView.tintColor = heroUsesTemplateRendering ? theme.colors.iconAccent : nil
        titleLabel.textColor = theme.colors.textPrimary
        messageLabel.textColor = theme.colors.textSecondary
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
        heroCard.layer.cornerRadius = 18
        heroCard.layer.borderWidth = 1

        configureHero()
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        view.addSubview(cancelButton)
        contentStack.addArrangedSubview(heroCard)
        presentation.choices.forEach(addChoice)

        cancelButton.accessibilityIdentifier = "\(presentation.accessibilityIdentifier).Cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.finishWithCancel() }, for: .touchUpInside)

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
    }

    private func configureHero() {
        let heroStack: UIStackView = .build()
        heroStack.axis = .vertical
        heroStack.alignment = .center
        heroStack.spacing = 10
        heroCard.addSubview(heroStack)

        switch presentation.heroIcon {
        case .system(let name):
            heroIconView.image = UIImage(systemName: name)?.withRenderingMode(.alwaysTemplate)
            heroUsesTemplateRendering = true
        case .extensionIcon(let id, let data):
            let descriptor = FloorpWebExtensionIconRegistry.descriptor(for: id, iconData: data)
            heroIconView.image = descriptor.image()
            heroUsesTemplateRendering = descriptor.usesTemplateRendering()
        }
        heroIconView.contentMode = .scaleAspectFit
        heroIconView.isAccessibilityElement = false
        titleLabel.text = presentation.title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        messageLabel.text = presentation.message
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        heroStack.addArrangedSubview(heroIconView)
        heroStack.addArrangedSubview(titleLabel)
        heroStack.addArrangedSubview(messageLabel)
        NSLayoutConstraint.activate([
            heroStack.topAnchor.constraint(equalTo: heroCard.topAnchor, constant: 20),
            heroStack.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 18),
            heroStack.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor, constant: -18),
            heroStack.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: -20),
            heroIconView.widthAnchor.constraint(equalToConstant: 58),
            heroIconView.heightAnchor.constraint(equalTo: heroIconView.widthAnchor)
        ])
    }

    private func addChoice(_ choice: FloorpWebExtensionPromptPresentation.Choice) {
        let button = ChoiceButton(choice: choice)
        button.addAction(UIAction { [weak self] _ in
            self?.finishWithChoice(choice.identifier)
        }, for: .touchUpInside)
        choiceButtons.append(button)
        contentStack.addArrangedSubview(button)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
    }

    private func finishWithChoice(_ identifier: String) {
        guard !didFinish else { return }
        didFinish = true
        setControlsEnabled(false)
        dismiss(animated: true) { [onChoice] in onChoice(identifier) }
    }

    private func finishWithCancel() {
        guard !didFinish else { return }
        didFinish = true
        setControlsEnabled(false)
        dismiss(animated: true) { [onCancel] in onCancel() }
    }

    private func setControlsEnabled(_ isEnabled: Bool) {
        choiceButtons.forEach { $0.isEnabled = isEnabled }
        cancelButton.isEnabled = isEnabled
    }
}

struct FloorpWebExtensionInstallPresentation: Sendable {
    enum Mode: Sendable, Equatable {
        case install
        case update
    }

    let extensionID: FloorpWebExtensionID
    let name: String
    let summary: String
    let version: String
    let iconData: Data?
    let catalogPublisher: String?
    let catalogAttribution: String?
    let catalogPrivacySummary: String?
    let catalogRetentionPolicy: String?
    let catalogReviewedAt: String?
    let source: String
    let license: String
    let permissions: [FloorpWebExtensionPermissionCategory]
    let requestedSites: [String]
    let privateProfileCapability: FloorpWebExtensionCatalogPackageMetadata.PrivateProfileCapability?
    let mode: Mode

    init(
        extensionID: FloorpWebExtensionID,
        name: String,
        summary: String,
        version: String,
        iconData: Data? = nil,
        catalogPublisher: String? = nil,
        catalogAttribution: String? = nil,
        catalogPrivacySummary: String? = nil,
        catalogRetentionPolicy: String? = nil,
        catalogReviewedAt: String? = nil,
        source: String,
        license: String,
        permissions: [FloorpWebExtensionPermissionCategory],
        requestedSites: [String],
        privateProfileCapability: FloorpWebExtensionCatalogPackageMetadata.PrivateProfileCapability? = nil,
        mode: Mode = .install
    ) {
        self.extensionID = extensionID
        self.name = name
        self.summary = summary
        self.version = version
        self.iconData = iconData
        self.catalogPublisher = catalogPublisher
        self.catalogAttribution = catalogAttribution
        self.catalogPrivacySummary = catalogPrivacySummary
        self.catalogRetentionPolicy = catalogRetentionPolicy
        self.catalogReviewedAt = catalogReviewedAt
        self.source = source
        self.license = license
        self.permissions = permissions
        self.requestedSites = requestedSites
        self.privateProfileCapability = privateProfileCapability
        self.mode = mode
    }
}

@MainActor
final class FloorpWebExtensionInstallConfirmationViewController: UIViewController,
                                                                  Themeable,
                                                                  InjectedThemeUUIDIdentifiable {
    private struct InfoRow {
        let symbol: String
        let title: String
        let detail: String

        init(_ symbol: String, _ title: String, _ detail: String) {
            self.symbol = symbol
            self.title = title
            self.detail = detail
        }
    }

    typealias Callback = @MainActor () -> Void

    let windowUUID: WindowUUID
    var currentWindowUUID: WindowUUID? { windowUUID }
    var themeManager: ThemeManager
    var themeListenerCancellable: Any?

    let presentation: FloorpWebExtensionInstallPresentation
    private let notificationCenter: NotificationProtocol
    private let onCancel: Callback
    private let onInstall: Callback
    private let scrollView: UIScrollView = .build()
    private let contentStack: UIStackView = .build()
    private let footerView: UIView = .build()
    private let footerButtonStack: UIStackView = .build()
    private let cancelButton: UIButton = .build()
    private let installButton: UIButton = .build()
    private var themedCards = [UIView]()
    private var primaryLabels = [UILabel]()
    private var secondaryLabels = [UILabel]()
    private var iconViews = [UIImageView]()
    private var separators = [UIView]()

    init(
        presentation: FloorpWebExtensionInstallPresentation,
        windowUUID: WindowUUID,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default,
        onCancel: @escaping Callback,
        onInstall: @escaping Callback
    ) {
        self.presentation = presentation
        self.windowUUID = windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        self.onCancel = onCancel
        self.onInstall = onInstall
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "Floorp.WebExtensions.InstallConsent.\(presentation.extensionID.rawValue)"
        setupView()
        listenForThemeChanges(withNotificationCenter: notificationCenter)
        applyTheme()
    }

    func applyTheme() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        view.backgroundColor = theme.colors.layer1
        scrollView.backgroundColor = theme.colors.layer1
        footerView.backgroundColor = theme.colors.layer1
        themedCards.forEach {
            $0.backgroundColor = theme.colors.layer2
            $0.layer.borderColor = theme.colors.borderPrimary.cgColor
        }
        primaryLabels.forEach { $0.textColor = theme.colors.textPrimary }
        secondaryLabels.forEach { $0.textColor = theme.colors.textSecondary }
        iconViews.forEach { $0.tintColor = theme.colors.iconAccent }
        separators.forEach { $0.backgroundColor = theme.colors.borderPrimary }

        var cancelConfiguration = UIButton.Configuration.gray()
        cancelConfiguration.title = FloorpStrings.WebExtensions.cancel
        cancelConfiguration.baseForegroundColor = theme.colors.textPrimary
        cancelButton.configuration = cancelConfiguration

        var installConfiguration = UIButton.Configuration.filled()
        installConfiguration.title = presentation.mode == .update
            ? FloorpStrings.WebExtensions.update
            : FloorpStrings.WebExtensions.install
        installConfiguration.image = UIImage(
            systemName: presentation.mode == .update ? "arrow.down.circle.fill" : "arrow.down.app.fill"
        )
        installConfiguration.imagePadding = 8
        installConfiguration.baseBackgroundColor = theme.colors.actionPrimary
        installConfiguration.baseForegroundColor = theme.colors.textOnDark
        installButton.configuration = installConfiguration
    }

    private func setupView() {
        title = presentation.mode == .update
            ? "\(FloorpStrings.WebExtensions.update) · \(presentation.name)"
            : FloorpStrings.WebExtensions.installTitle(name: presentation.name)
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        footerView.layer.shadowOpacity = 0.12
        footerView.layer.shadowRadius = 8
        footerView.layer.shadowOffset = CGSize(width: 0, height: -2)
        footerButtonStack.spacing = 12
        footerButtonStack.distribution = .fillEqually

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        view.addSubview(footerView)
        footerView.addSubview(footerButtonStack)
        footerButtonStack.addArrangedSubview(cancelButton)
        footerButtonStack.addArrangedSubview(installButton)

        NSLayoutConstraint.activate([
            footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerView.topAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            footerButtonStack.topAnchor.constraint(equalTo: footerView.topAnchor, constant: 14),
            footerButtonStack.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 20),
            footerButtonStack.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -20),
            footerButtonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            installButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
        updateFooterAxis()

        cancelButton.accessibilityIdentifier = "Floorp.WebExtensions.InstallConsent.Cancel.\(presentation.extensionID.rawValue)"
        cancelButton.accessibilityHint = FloorpStrings.WebExtensions.cancel
        installButton.accessibilityIdentifier = "Floorp.WebExtensions.InstallConsent.Install.\(presentation.extensionID.rawValue)"
        installButton.accessibilityHint = presentation.mode == .update
            ? FloorpStrings.WebExtensions.update
            : FloorpStrings.WebExtensions.siteAccessStartsOffMessage
        cancelButton.addAction(UIAction { [weak self] _ in
            guard let self, self.cancelButton.isEnabled else { return }
            self.cancelButton.isEnabled = false
            self.installButton.isEnabled = false
            self.onCancel()
        }, for: .touchUpInside)
        installButton.addAction(UIAction { [weak self] _ in
            guard let self, self.installButton.isEnabled else { return }
            self.cancelButton.isEnabled = false
            self.installButton.isEnabled = false
            self.onInstall()
        }, for: .touchUpInside)

        addHero()
        addCapabilityCard()
        addSiteAccessCard()
        addPrivateBrowsingCard()
        addPublisherCard()
    }

    private func addHero() {
        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 10

        let iconContainer: UIView = .build()
        let iconView: UIImageView = .build()
        let descriptor = FloorpWebExtensionIconRegistry.descriptor(
            for: presentation.extensionID,
            iconData: presentation.iconData
        )
        iconView.image = descriptor.image()
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        if descriptor.usesTemplateRendering() { iconViews.append(iconView) }
        iconContainer.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 64),
            iconContainer.heightAnchor.constraint(equalTo: iconContainer.widthAnchor),
            iconView.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            iconView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor)
        ])

        let titleLabel = makeLabel(text: presentation.name, style: .title2, primary: true)
        titleLabel.textAlignment = .center
        let versionLabel = makeLabel(
            text: FloorpStrings.WebExtensions.version(presentation.version),
            style: .subheadline,
            primary: false
        )
        versionLabel.textAlignment = .center
        let summaryLabel = makeLabel(text: presentation.summary, style: .body, primary: false)
        summaryLabel.textAlignment = .center
        container.addArrangedSubview(iconContainer)
        container.addArrangedSubview(titleLabel)
        container.addArrangedSubview(versionLabel)
        container.addArrangedSubview(summaryLabel)
        contentStack.addArrangedSubview(container)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory !=
                traitCollection.preferredContentSizeCategory else {
            return
        }
        updateFooterAxis()
    }

    private func updateFooterAxis() {
        footerButtonStack.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            ? .vertical
            : .horizontal
    }

    private func addCapabilityCard() {
        let rows: [InfoRow]
        if presentation.permissions.isEmpty {
            rows = [InfoRow(
                "checkmark.shield.fill",
                FloorpStrings.WebExtensions.reviewed,
                FloorpStrings.WebExtensions.introMessage
            )]
        } else {
            rows = presentation.permissions.map { permission in
                InfoRow(
                    permissionSymbol(permission),
                    permission.title,
                    permissionExplanation(permission)
                )
            }
        }
        contentStack.addArrangedSubview(makeSection(
            title: FloorpStrings.WebExtensions.accessSection,
            rows: rows
        ))
    }

    private func addSiteAccessCard() {
        guard !presentation.requestedSites.isEmpty else { return }
        let title: String
        let message: String
        switch presentation.mode {
        case .install:
            title = FloorpStrings.WebExtensions.siteAccessStartsOffTitle
            message = FloorpStrings.WebExtensions.siteAccessStartsOffMessage
        case .update:
            title = FloorpStrings.WebExtensions.siteAccessPreservedTitle
            message = FloorpStrings.WebExtensions.siteAccessPreservedMessage
        }
        let detail = message + "\n\n" + presentation.requestedSites.sorted().joined(separator: "\n")
        contentStack.addArrangedSubview(makeSection(
            title: FloorpStrings.WebExtensions.siteAccess,
            rows: [InfoRow(
                "hand.raised.fill",
                title,
                detail
            )]
        ))
    }

    private func addPrivateBrowsingCard() {
        let detail: String
        switch presentation.privateProfileCapability {
        case .some(.notSupported):
            detail = FloorpStrings.WebExtensions.notSupported
        case .some(.optIn), .some(.supported):
            detail = FloorpStrings.WebExtensions.privateBrowsingOptInMessage
        case .none:
            detail = FloorpStrings.WebExtensions.notSupported
        }
        contentStack.addArrangedSubview(makeSection(
            title: FloorpStrings.WebExtensions.profileSection,
            rows: [InfoRow(
                "eye.slash.fill",
                FloorpStrings.WebExtensions.privateBrowsingOptInTitle,
                detail
            )]
        ))
    }

    private func addPublisherCard() {
        var rows = [InfoRow]()
        rows.append(InfoRow(
            "person.crop.circle.badge.checkmark",
            FloorpStrings.WebExtensions.publisherLabel,
            presentation.catalogPublisher ?? presentation.source
        ))
        if let attribution = presentation.catalogAttribution {
            rows.append(InfoRow(
                "signature",
                FloorpStrings.WebExtensions.attributionLabel,
                attribution
            ))
        }
        if let reviewedAt = presentation.catalogReviewedAt {
            rows.append(InfoRow("checkmark.seal.fill", FloorpStrings.WebExtensions.reviewed, reviewedAt))
        }
        if let privacySummary = presentation.catalogPrivacySummary {
            rows.append(InfoRow("lock.shield.fill", FloorpStrings.WebExtensions.privacySection, privacySummary))
        }
        if let retentionPolicy = presentation.catalogRetentionPolicy {
            rows.append(InfoRow(
                "internaldrive.fill",
                FloorpStrings.WebExtensions.dataRetentionLabel,
                retentionPolicy
            ))
        }
        rows.append(InfoRow(
            "doc.text.fill",
            "\(FloorpStrings.WebExtensions.sourceLabel) · \(FloorpStrings.WebExtensions.licenseLabel)",
            "\(presentation.source) · \(presentation.license)"
        ))
        contentStack.addArrangedSubview(makeSection(title: FloorpStrings.WebExtensions.reviewed, rows: rows))
    }

    private func makeSection(title: String, rows: [InfoRow]) -> UIView {
        let stack: UIStackView = .build()
        stack.axis = .vertical
        stack.spacing = 0
        let titleLabel = makeLabel(text: title, style: .footnote, primary: false)
        titleLabel.accessibilityTraits = .header
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(10, after: titleLabel)

        let card: UIStackView = .build()
        card.axis = .vertical
        card.spacing = 0
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
        themedCards.append(card)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator: UIView = .build()
                separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                card.addArrangedSubview(separator)
                separators.append(separator)
            }
            card.addArrangedSubview(makeInfoRow(
                symbol: row.symbol,
                title: row.title,
                detail: row.detail
            ))
        }
        stack.addArrangedSubview(card)
        return stack
    }

    private func makeInfoRow(symbol: String, title: String, detail: String) -> UIView {
        let container: UIView = .build()
        let iconView: UIImageView = .build()
        iconView.image = UIImage(systemName: symbol)?.withRenderingMode(.alwaysTemplate)
        iconView.contentMode = .scaleAspectFit
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.isAccessibilityElement = false
        iconViews.append(iconView)
        let titleLabel = makeLabel(text: title, style: .subheadline, primary: true)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        let detailLabel = makeLabel(text: detail, style: .footnote, primary: false)
        let labels: UIStackView = .build()
        labels.axis = .vertical
        labels.spacing = 3
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(detailLabel)
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
        container.accessibilityLabel = "\(title). \(detail)"
        return container
    }

    private func makeLabel(text: String, style: UIFont.TextStyle, primary: Bool) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
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

    private func permissionSymbol(_ permission: FloorpWebExtensionPermissionCategory) -> String {
        switch permission.rawValue {
        case "siteData": return "doc.text.magnifyingglass"
        case "tabs": return "rectangle.stack.fill"
        case "storage": return "internaldrive.fill"
        case "networkBlocking": return "shield.lefthalf.filled"
        case "browserAutomation": return "wand.and.stars"
        case "alarms": return "alarm.fill"
        case "fontSettings": return "textformat"
        default: return "puzzlepiece.extension.fill"
        }
    }

    private func permissionExplanation(_ permission: FloorpWebExtensionPermissionCategory) -> String {
        switch permission.rawValue {
        case "siteData": return FloorpStrings.WebExtensions.permissionSiteDataExplanation
        case "tabs": return FloorpStrings.WebExtensions.permissionTabsExplanation
        case "storage": return FloorpStrings.WebExtensions.permissionStorageExplanation
        case "networkBlocking": return FloorpStrings.WebExtensions.permissionNetworkBlockingExplanation
        case "browserAutomation": return FloorpStrings.WebExtensions.permissionBrowserAutomationExplanation
        case "alarms": return FloorpStrings.WebExtensions.permissionAlarmsExplanation
        case "fontSettings": return FloorpStrings.WebExtensions.permissionFontSettingsExplanation
        default: return FloorpStrings.WebExtensions.permissionGenericExplanation
        }
    }
}

struct FloorpWebExtensionInstalledDetailPresentation: Sendable {
    let extensionID: FloorpWebExtensionID
    let name: String
    let summary: String?
    let version: String
    let iconData: Data?
    let isEnabled: Bool
    let isCatalogRevoked: Bool
    let errorDescription: String?
    let permissions: [FloorpWebExtensionPermissionCategory]
    let siteAccessDescription: String
    let privateAccessDescription: String
    let isPrivateBrowsingEnabled: Bool
    let privateProfileCapability: FloorpWebExtensionCatalogPackageMetadata.PrivateProfileCapability?
    let catalogPublisher: String?
    let catalogAttribution: String?
    let catalogPrivacySummary: String?
    let catalogRetentionPolicy: String?
    let catalogReviewedAt: String?
    let catalogSource: String?
    let catalogLicense: String?
    let updateVersion: String?
    let postInstallMessage: String?

    init(
        extensionID: FloorpWebExtensionID,
        name: String,
        summary: String? = nil,
        version: String,
        iconData: Data? = nil,
        isEnabled: Bool,
        isCatalogRevoked: Bool,
        errorDescription: String? = nil,
        permissions: [FloorpWebExtensionPermissionCategory],
        siteAccessDescription: String,
        privateAccessDescription: String,
        isPrivateBrowsingEnabled: Bool,
        privateProfileCapability: FloorpWebExtensionCatalogPackageMetadata.PrivateProfileCapability? = nil,
        catalogPublisher: String? = nil,
        catalogAttribution: String? = nil,
        catalogPrivacySummary: String? = nil,
        catalogRetentionPolicy: String? = nil,
        catalogReviewedAt: String? = nil,
        catalogSource: String? = nil,
        catalogLicense: String? = nil,
        updateVersion: String? = nil,
        postInstallMessage: String? = nil
    ) {
        self.extensionID = extensionID
        self.name = name
        self.summary = summary
        self.version = version
        self.iconData = iconData
        self.isEnabled = isEnabled
        self.isCatalogRevoked = isCatalogRevoked
        self.errorDescription = errorDescription
        self.permissions = permissions
        self.siteAccessDescription = siteAccessDescription
        self.privateAccessDescription = privateAccessDescription
        self.isPrivateBrowsingEnabled = isPrivateBrowsingEnabled
        self.privateProfileCapability = privateProfileCapability
        self.catalogPublisher = catalogPublisher
        self.catalogAttribution = catalogAttribution
        self.catalogPrivacySummary = catalogPrivacySummary
        self.catalogRetentionPolicy = catalogRetentionPolicy
        self.catalogReviewedAt = catalogReviewedAt
        self.catalogSource = catalogSource
        self.catalogLicense = catalogLicense
        self.updateVersion = updateVersion
        self.postInstallMessage = postInstallMessage
    }
}

@MainActor
struct FloorpWebExtensionInstalledDetailActions {
    let onEnabledChanged: (Bool) -> Void
    let onOpenOptions: (() -> Void)?
    let onManageSiteAccess: (() -> Void)?
    let onTogglePrivateBrowsing: ((Bool) -> Void)?
    let onManagePrivateSiteAccess: (() -> Void)?
    let onManageNetworkProtection: (() -> Void)?
    let onManagePrivateNetworkProtection: (() -> Void)?
    let onOpenWebsite: (() -> Void)?
    let onViewUpdateHistory: (() -> Void)?
    let onUpdate: (() -> Void)?
    let onUninstall: () -> Void
}

@MainActor
final class FloorpWebExtensionInstalledDetailViewController: UITableViewController,
                                                               Themeable,
                                                               InjectedThemeUUIDIdentifiable {
    private enum Section: Int, CaseIterable {
        case status
        case access
        case controls
        case trust
        case remove

        var title: String? {
            switch self {
            case .status: return nil
            case .access: return FloorpStrings.WebExtensions.accessSection
            case .controls: return FloorpStrings.WebExtensions.manage
            case .trust: return FloorpStrings.WebExtensions.reviewed
            case .remove: return nil
            }
        }
    }

    private enum Row {
        case enabled
        case information(symbol: String, title: String, detail: String)
        case action(symbol: String, title: String, detail: String?, identifier: String, handler: () -> Void)
        case destructive
    }

    let windowUUID: WindowUUID
    var currentWindowUUID: WindowUUID? { windowUUID }
    var themeManager: ThemeManager
    var themeListenerCancellable: Any?

    let presentation: FloorpWebExtensionInstalledDetailPresentation
    private let actions: FloorpWebExtensionInstalledDetailActions
    private let notificationCenter: NotificationProtocol
    private let heroView = FloorpWebExtensionInstalledHeroView()
    private var isEnabled: Bool

    init(
        presentation: FloorpWebExtensionInstalledDetailPresentation,
        actions: FloorpWebExtensionInstalledDetailActions,
        windowUUID: WindowUUID,
        themeManager: ThemeManager = AppContainer.shared.resolve(),
        notificationCenter: NotificationProtocol = NotificationCenter.default
    ) {
        self.presentation = presentation
        self.actions = actions
        self.windowUUID = windowUUID
        self.themeManager = themeManager
        self.notificationCenter = notificationCenter
        self.isEnabled = presentation.isEnabled
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = FloorpStrings.WebExtensions.detailTitle
        view.accessibilityIdentifier = "Floorp.WebExtensions.Detail.\(presentation.extensionID.rawValue)"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "detail")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        heroView.configure(with: presentation)
        tableView.tableHeaderView = heroView
        listenForThemeChanges(withNotificationCenter: notificationCenter)
        applyTheme()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let fittingSize = CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        let height = header.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        if abs(header.frame.height - height) > 0.5 {
            header.frame.size.height = height
            tableView.tableHeaderView = header
        }
    }

    func applyTheme() {
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        tableView.backgroundColor = theme.colors.layer1
        tableView.separatorColor = theme.colors.borderPrimary
        heroView.applyTheme(theme: theme)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: section).count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows(in: indexPath.section)[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let theme = themeManager.getCurrentTheme(for: windowUUID)
        cell.backgroundColor = theme.colors.layer2
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.textColor = theme.colors.textPrimary
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .footnote)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = theme.colors.textSecondary

        switch row {
        case .enabled:
            cell.textLabel?.text = FloorpStrings.WebExtensions.enabled
            cell.detailTextLabel?.text = presentation.isCatalogRevoked
                ? FloorpStrings.WebExtensions.catalogRevokedDisabledMessage
                : FloorpStrings.WebExtensions.standardBrowsingEnabledMessage
            let enabledSwitch = UISwitch()
            enabledSwitch.isOn = isEnabled
            enabledSwitch.isEnabled = !presentation.isCatalogRevoked
            enabledSwitch.accessibilityIdentifier = "Floorp.WebExtensions.Detail.EnabledSwitch.\(presentation.extensionID.rawValue)"
            enabledSwitch.accessibilityLabel = presentation.name
            enabledSwitch.accessibilityHint = presentation.isCatalogRevoked
                ? FloorpStrings.WebExtensions.revoked
                : FloorpStrings.WebExtensions.manage
            enabledSwitch.addAction(UIAction { [weak self, weak enabledSwitch] _ in
                guard let self, let control = enabledSwitch else { return }
                self.isEnabled = control.isOn
                self.actions.onEnabledChanged(control.isOn)
            }, for: .valueChanged)
            cell.accessoryView = enabledSwitch
            cell.selectionStyle = .none
        case let .information(symbol, title, detail):
            configure(cell, symbol: symbol, title: title, detail: detail, theme: theme)
            cell.selectionStyle = .none
        case let .action(symbol, title, detail, identifier, _):
            configure(cell, symbol: symbol, title: title, detail: detail, theme: theme)
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "Floorp.WebExtensions.Detail.\(identifier).\(presentation.extensionID.rawValue)"
        case .destructive:
            cell.textLabel?.text = FloorpStrings.WebExtensions.uninstall
            cell.textLabel?.textColor = theme.colors.textCritical
            cell.imageView?.image = UIImage(systemName: "trash.fill")
            cell.imageView?.tintColor = theme.colors.iconCritical
            cell.accessibilityIdentifier = "Floorp.WebExtensions.Detail.Uninstall.\(presentation.extensionID.rawValue)"
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows(in: indexPath.section)[indexPath.row] {
        case .action(_, _, _, _, let handler): handler()
        case .destructive: actions.onUninstall()
        case .enabled, .information: break
        }
    }

    private func rows(in sectionIndex: Int) -> [Row] {
        guard let section = Section(rawValue: sectionIndex) else { return [] }
        switch section {
        case .status: return statusRows()
        case .access: return accessRows()
        case .controls: return controlRows()
        case .trust: return trustRows()
        case .remove: return [.destructive]
        }
    }

    private func statusRows() -> [Row] {
        var rows: [Row] = [.enabled]
        if let postInstallMessage = presentation.postInstallMessage {
            rows.append(.information(
                symbol: "hand.raised.fill",
                title: FloorpStrings.WebExtensions.siteAccessStartsOffTitle,
                detail: postInstallMessage
            ))
        }
        if presentation.isCatalogRevoked {
            rows.append(.information(
                symbol: "exclamationmark.shield.fill",
                title: FloorpStrings.WebExtensions.revoked,
                detail: FloorpStrings.WebExtensions.catalogRevokedGuidance
            ))
        } else if let error = presentation.errorDescription {
            rows.append(.information(
                symbol: "exclamationmark.triangle.fill",
                title: FloorpStrings.WebExtensions.loadErrorTitle,
                detail: error
            ))
        }
        return rows
    }

    private func accessRows() -> [Row] {
        var rows: [Row] = [.information(
            symbol: "hand.raised.fill",
            title: FloorpStrings.WebExtensions.siteAccess,
            detail: presentation.siteAccessDescription
        )]
        if let action = actions.onManageSiteAccess {
            rows.append(.action(
                symbol: "globe",
                title: FloorpStrings.WebExtensions.siteAccess,
                detail: FloorpStrings.WebExtensions.siteAccessStartsOffMessage,
                identifier: "SiteAccess",
                handler: action
            ))
        }
        rows.append(contentsOf: privateAccessRows())
        return rows
    }

    private func privateAccessRows() -> [Row] {
        let privateTitle = privateBrowsingStatusTitle()
        var rows: [Row] = [.information(
            symbol: "eye.slash.fill",
            title: privateTitle,
            detail: presentation.privateAccessDescription
        )]
        if let action = actions.onTogglePrivateBrowsing,
           presentation.privateProfileCapability != .notSupported,
           !presentation.isCatalogRevoked {
            rows.append(.action(
                symbol: presentation.isPrivateBrowsingEnabled ? "eye.slash" : "eye.slash.fill",
                title: FloorpStrings.WebExtensions.privateBrowsing,
                detail: FloorpStrings.WebExtensions.privateBrowsingOptInMessage,
                identifier: "PrivateBrowsing",
                handler: { [presentation] in action(!presentation.isPrivateBrowsingEnabled) }
            ))
        }
        if let action = actions.onManagePrivateSiteAccess,
           presentation.isPrivateBrowsingEnabled,
           presentation.privateProfileCapability != .notSupported,
           !presentation.isCatalogRevoked {
            rows.append(.action(
                symbol: "lock.shield.fill",
                title: FloorpStrings.WebExtensions.privateBrowsing,
                detail: FloorpStrings.WebExtensions.siteAccess,
                identifier: "PrivateSiteAccess",
                handler: action
            ))
        }
        return rows
    }

    private func privateBrowsingStatusTitle() -> String {
        let status: String
        switch presentation.privateProfileCapability {
        case .some(.notSupported): status = FloorpStrings.WebExtensions.notSupported
        case .some(.optIn), .some(.supported):
            status = presentation.isPrivateBrowsingEnabled
                ? FloorpStrings.WebExtensions.enabled
                : FloorpStrings.WebExtensions.disabled
        case .none: return FloorpStrings.WebExtensions.privateBrowsing
        }
        return "\(FloorpStrings.WebExtensions.privateBrowsing) · \(status)"
    }

    private func controlRows() -> [Row] {
        var rows = [Row]()
        appendControlActions(to: &rows)
        if !presentation.isCatalogRevoked,
           let update = actions.onUpdate,
           let version = presentation.updateVersion {
            rows.append(.action(
                symbol: "arrow.down.circle.fill",
                title: "\(FloorpStrings.WebExtensions.update) \(version)",
                detail: FloorpStrings.WebExtensions.reviewed,
                identifier: "Update",
                handler: update
            ))
        }
        return rows.isEmpty ? [.information(
            symbol: "checkmark.circle.fill",
            title: FloorpStrings.WebExtensions.reviewed,
            detail: FloorpStrings.WebExtensions.introMessage
        )] : rows
    }

    private func appendControlActions(to rows: inout [Row]) {
        appendAction(
            actions.onOpenOptions,
            to: &rows,
            symbol: "gearshape.fill",
            title: FloorpStrings.WebExtensions.options,
            identifier: "Options"
        )
        appendAction(
            actions.onManageNetworkProtection,
            to: &rows,
            symbol: "shield.lefthalf.filled",
            title: FloorpStrings.WebExtensions.networkProtection,
            identifier: "Network"
        )
        appendAction(
            actions.onManagePrivateNetworkProtection,
            to: &rows,
            symbol: "lock.shield.fill",
            title: "\(FloorpStrings.WebExtensions.privateBrowsing) · " +
                FloorpStrings.WebExtensions.networkProtection,
            identifier: "PrivateNetwork"
        )
        appendAction(
            actions.onOpenWebsite,
            to: &rows,
            symbol: "safari.fill",
            title: FloorpStrings.WebExtensions.website,
            identifier: "Website"
        )
        appendAction(
            actions.onViewUpdateHistory,
            to: &rows,
            symbol: "clock.arrow.circlepath",
            title: FloorpStrings.WebExtensions.updateHistory,
            identifier: "History"
        )
    }

    private func trustRows() -> [Row] {
        var rows: [Row] = [.information(
            symbol: "checkmark.seal.fill",
            title: presentation.catalogPublisher ?? FloorpStrings.WebExtensions.reviewed,
            detail: trustReviewDetail()
        )]
        if !presentation.permissions.isEmpty {
            rows.append(.information(
                symbol: "list.bullet.clipboard.fill",
                title: FloorpStrings.WebExtensions.accessSection,
                detail: presentation.permissions.map(\.title).joined(separator: "\n")
            ))
        }
        appendPrivacyRows(to: &rows)
        return rows
    }

    private func appendPrivacyRows(to rows: inout [Row]) {
        if let privacy = presentation.catalogPrivacySummary {
            rows.append(.information(
                symbol: "lock.shield.fill",
                title: FloorpStrings.WebExtensions.privacySection,
                detail: privacy
            ))
        }
        if let retention = presentation.catalogRetentionPolicy {
            rows.append(.information(
                symbol: "internaldrive.fill",
                title: FloorpStrings.WebExtensions.privacySection,
                detail: retention
            ))
        }
        let sourceAndLicense = [presentation.catalogSource, presentation.catalogLicense]
            .compactMap { $0 }
            .joined(separator: " · ")
        guard !sourceAndLicense.isEmpty else { return }
        rows.append(.information(
            symbol: "doc.text.fill",
            title: "\(FloorpStrings.WebExtensions.sourceLabel) · " +
                FloorpStrings.WebExtensions.licenseLabel,
            detail: sourceAndLicense
        ))
    }

    private func trustReviewDetail() -> String {
        [
            presentation.catalogAttribution,
            presentation.catalogReviewedAt.map { "\(FloorpStrings.WebExtensions.reviewed) · \($0)" }
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private func appendAction(
        _ action: (() -> Void)?,
        to rows: inout [Row],
        symbol: String,
        title: String,
        detail: String? = nil,
        identifier: String
    ) {
        guard let action else { return }
        rows.append(.action(
            symbol: symbol,
            title: title,
            detail: detail,
            identifier: identifier,
            handler: action
        ))
    }

    private func configure(
        _ cell: UITableViewCell,
        symbol: String,
        title: String,
        detail: String?,
        theme: Theme
    ) {
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = detail
        cell.imageView?.image = UIImage(systemName: symbol)?.withRenderingMode(.alwaysTemplate)
        cell.imageView?.tintColor = theme.colors.iconAccent
    }
}

@MainActor
private final class FloorpWebExtensionInstalledHeroView: UIView, ThemeApplicable {
    private let iconBackgroundView: UIView = .build()
    private let iconView: UIImageView = .build()
    private let titleLabel: UILabel = .build()
    private let versionLabel: UILabel = .build()
    private let summaryLabel: UILabel = .build()
    private let statusLabel: UILabel = .build()
    private var descriptor: FloorpWebExtensionIconDescriptor?
    private var isEnabled = false
    private var isRevoked = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with presentation: FloorpWebExtensionInstalledDetailPresentation) {
        descriptor = FloorpWebExtensionIconRegistry.descriptor(
            for: presentation.extensionID,
            iconData: presentation.iconData
        )
        iconView.image = descriptor?.image()
        titleLabel.text = presentation.name
        versionLabel.text = FloorpStrings.WebExtensions.version(presentation.version)
        summaryLabel.text = presentation.summary
        summaryLabel.isHidden = presentation.summary?.isEmpty != false
        isEnabled = presentation.isEnabled
        isRevoked = presentation.isCatalogRevoked
        statusLabel.text = presentation.isCatalogRevoked
            ? FloorpStrings.WebExtensions.revoked
            : presentation.isEnabled
                ? FloorpStrings.WebExtensions.enabled
                : FloorpStrings.WebExtensions.disabled
    }

    func applyTheme(theme: Theme) {
        backgroundColor = theme.colors.layer1
        iconBackgroundView.backgroundColor = .clear
        titleLabel.textColor = theme.colors.textPrimary
        versionLabel.textColor = theme.colors.textSecondary
        summaryLabel.textColor = theme.colors.textSecondary
        if descriptor?.usesTemplateRendering() == true {
            iconView.tintColor = theme.colors.iconAccent
        }
        if isRevoked {
            statusLabel.textColor = theme.colors.textCritical
        } else if isEnabled {
            statusLabel.textColor = theme.colors.textSecondary
        } else {
            statusLabel.textColor = theme.colors.textSecondary
        }
        statusLabel.backgroundColor = .clear
    }

    private func setupView() {
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        versionLabel.font = .preferredFont(forTextStyle: .subheadline)
        versionLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.font = .preferredFont(forTextStyle: .body)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.numberOfLines = 3
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textAlignment = .natural

        let textStack: UIStackView = .build()
        textStack.axis = .vertical
        textStack.spacing = 5
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(versionLabel)
        textStack.addArrangedSubview(summaryLabel)
        let hero: UIStackView = .build()
        hero.axis = .horizontal
        hero.alignment = .top
        hero.spacing = 16
        hero.addArrangedSubview(iconBackgroundView)
        hero.addArrangedSubview(textStack)
        addSubview(hero)
        addSubview(statusLabel)
        iconBackgroundView.addSubview(iconView)

        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            hero.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            hero.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 64),
            iconBackgroundView.heightAnchor.constraint(equalTo: iconBackgroundView.widthAnchor),
            iconView.topAnchor.constraint(equalTo: iconBackgroundView.topAnchor),
            iconView.leadingAnchor.constraint(equalTo: iconBackgroundView.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor),
            iconView.bottomAnchor.constraint(equalTo: iconBackgroundView.bottomAnchor),
            statusLabel.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 22)
        ])
    }
}
