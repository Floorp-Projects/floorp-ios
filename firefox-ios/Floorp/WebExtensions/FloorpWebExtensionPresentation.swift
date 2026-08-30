// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit

struct FloorpWebExtensionIconDescriptor: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case resource(name: String, extension: String, subdirectory: String?)
        case system(name: String)
    }

    let source: Source
    let fallbackSystemName: String
    let accessibilityLabel: String

    @MainActor
    func image(in bundle: Bundle = .main) -> UIImage? {
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
        case .resource:
            systemName = fallbackSystemName
        case .system(let name):
            systemName = name
        }
        return UIImage(systemName: systemName)?.withRenderingMode(.alwaysTemplate)
    }

    func usesTemplateRendering(in bundle: Bundle = .main) -> Bool {
        switch source {
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
    static func descriptor(for extensionID: FloorpWebExtensionID) -> FloorpWebExtensionIconDescriptor {
        switch extensionID.rawValue {
        case "floorp.thirdparty.darkreader":
            return FloorpWebExtensionIconDescriptor(
                source: .resource(name: "dr_128", extension: "png", subdirectory: nil),
                fallbackSystemName: "moon.stars.fill",
                accessibilityLabel: "Dark Reader icon"
            )
        default:
            return FloorpWebExtensionIconDescriptor(
                source: .system(name: "puzzlepiece.extension.fill"),
                fallbackSystemName: "puzzlepiece.extension.fill",
                accessibilityLabel: "Extension icon"
            )
        }
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
            case .available: return "Available"
            case .enabled: return "Enabled"
            case .disabled: return "Disabled"
            case .updateAvailable: return "Update"
            case .revoked: return "Revoked"
            case .error: return "Needs attention"
            }
        }
    }

    let extensionID: FloorpWebExtensionID
    let title: String
    let summary: String
    let version: String
    let status: Status
    let accessibilityIdentifier: String
    let accessibilityHint: String
    let isBusy: Bool

    init(
        extensionID: FloorpWebExtensionID,
        title: String,
        summary: String,
        version: String,
        status: Status,
        accessibilityIdentifier: String,
        accessibilityHint: String,
        isBusy: Bool = false
    ) {
        self.extensionID = extensionID
        self.title = title
        self.summary = summary
        self.version = version
        self.status = status
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityHint = accessibilityHint
        self.isBusy = isBusy
    }
}

@MainActor
final class FloorpWebExtensionCardCell: UITableViewCell, ThemeApplicable {
    static let reuseIdentifier = "FloorpWebExtensionCardCell"

    private let cardView: UIView = .build()
    private let iconBackgroundView: UIView = .build()
    private let iconView: UIImageView = .build()
    private let titleLabel: UILabel = .build()
    private let summaryLabel: UILabel = .build()
    private let versionLabel: UILabel = .build()
    private let statusLabel: UILabel = .build()
    private let statusView: UIView = .build()
    private let chevronView: UIImageView = .build()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var presentation: FloorpWebExtensionCardPresentation?
    private var currentTheme: Theme?

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
    }

    func configure(
        with presentation: FloorpWebExtensionCardPresentation,
        theme: Theme,
        bundle: Bundle = .main
    ) {
        self.presentation = presentation
        let descriptor = FloorpWebExtensionIconRegistry.descriptor(for: presentation.extensionID)
        iconView.image = descriptor.image(in: bundle)
        iconView.tintColor = descriptor.usesTemplateRendering(in: bundle) ? theme.colors.iconAccent : nil
        titleLabel.text = presentation.title
        summaryLabel.text = presentation.summary
        versionLabel.text = "Version \(presentation.version)"
        statusLabel.text = presentation.status.title
        chevronView.isHidden = presentation.isBusy
        statusView.isHidden = presentation.isBusy
        isUserInteractionEnabled = !presentation.isBusy
        if presentation.isBusy {
            activityIndicator.startAnimating()
            accessibilityValue = "In progress"
        } else {
            activityIndicator.stopAnimating()
            accessibilityValue = presentation.status.title
        }
        accessibilityIdentifier = presentation.accessibilityIdentifier
        accessibilityLabel = [
            presentation.title,
            presentation.status.title,
            "Version \(presentation.version)",
            presentation.summary
        ].joined(separator: ", ")
        accessibilityHint = presentation.accessibilityHint
        applyTheme(theme: theme)
    }

    func applyTheme(theme: Theme) {
        currentTheme = theme
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        cardView.backgroundColor = theme.colors.layer2
        cardView.layer.borderColor = theme.colors.borderPrimary.cgColor
        iconBackgroundView.backgroundColor = theme.colors.layerAccentNonOpaque
        titleLabel.textColor = theme.colors.textPrimary
        summaryLabel.textColor = theme.colors.textSecondary
        versionLabel.textColor = theme.colors.textSecondary
        chevronView.tintColor = theme.colors.iconSecondary
        activityIndicator.color = theme.colors.iconAccent

        guard let status = presentation?.status else { return }
        switch status {
        case .available, .updateAvailable:
            statusView.backgroundColor = theme.colors.layerAccentNonOpaque
            statusLabel.textColor = theme.colors.textAccent
        case .enabled:
            statusView.backgroundColor = theme.colors.layerSuccess
            statusLabel.textColor = theme.colors.textPrimary
        case .disabled:
            statusView.backgroundColor = theme.colors.layerSurfaceMedium
            statusLabel.textColor = theme.colors.textSecondary
        case .revoked, .error:
            statusView.backgroundColor = theme.colors.layerCriticalSubdued
            statusLabel.textColor = theme.colors.textCritical
        }

        let descriptor = presentation.map {
            FloorpWebExtensionIconRegistry.descriptor(for: $0.extensionID)
        }
        if descriptor?.usesTemplateRendering() == true {
            iconView.tintColor = theme.colors.iconAccent
        }
    }

    private func setupView() {
        selectionStyle = .none
        isAccessibilityElement = true
        accessibilityTraits = .button

        cardView.layer.cornerRadius = 16
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        iconBackgroundView.layer.cornerRadius = 14
        iconBackgroundView.layer.cornerCurve = .continuous
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.numberOfLines = 3
        versionLabel.font = .preferredFont(forTextStyle: .caption1)
        versionLabel.adjustsFontForContentSizeCategory = true
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusView.layer.cornerRadius = 9
        statusView.layer.cornerCurve = .continuous
        chevronView.image = UIImage(systemName: "chevron.right")
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true

        contentView.addSubview(cardView)
        cardView.addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(summaryLabel)
        cardView.addSubview(versionLabel)
        cardView.addSubview(statusView)
        statusView.addSubview(statusLabel)
        cardView.addSubview(chevronView)
        cardView.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            iconBackgroundView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            iconBackgroundView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 56),
            iconBackgroundView.heightAnchor.constraint(equalTo: iconBackgroundView.widthAnchor),
            iconView.topAnchor.constraint(equalTo: iconBackgroundView.topAnchor, constant: 8),
            iconView.leadingAnchor.constraint(equalTo: iconBackgroundView.leadingAnchor, constant: 8),
            iconView.trailingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: -8),
            iconView.bottomAnchor.constraint(equalTo: iconBackgroundView.bottomAnchor, constant: -8),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -10),
            chevronView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            chevronView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            activityIndicator.centerXAnchor.constraint(equalTo: chevronView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: chevronView.centerYAnchor),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            versionLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 12),
            versionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            versionLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -16),
            statusView.leadingAnchor.constraint(greaterThanOrEqualTo: versionLabel.trailingAnchor, constant: 12),
            statusView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            statusView.centerYAnchor.constraint(equalTo: versionLabel.centerYAnchor),
            statusLabel.topAnchor.constraint(equalTo: statusView.topAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: statusView.leadingAnchor, constant: 9),
            statusLabel.trailingAnchor.constraint(equalTo: statusView.trailingAnchor, constant: -9),
            statusLabel.bottomAnchor.constraint(equalTo: statusView.bottomAnchor, constant: -4),

            iconBackgroundView.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -16)
        ])
    }
}

struct FloorpWebExtensionInstallPresentation: Sendable {
    let extensionID: FloorpWebExtensionID
    let name: String
    let summary: String
    let version: String
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

    init(
        extensionID: FloorpWebExtensionID,
        name: String,
        summary: String,
        version: String,
        catalogPublisher: String? = nil,
        catalogAttribution: String? = nil,
        catalogPrivacySummary: String? = nil,
        catalogRetentionPolicy: String? = nil,
        catalogReviewedAt: String? = nil,
        source: String,
        license: String,
        permissions: [FloorpWebExtensionPermissionCategory],
        requestedSites: [String],
        privateProfileCapability: FloorpWebExtensionCatalogPackageMetadata.PrivateProfileCapability? = nil
    ) {
        self.extensionID = extensionID
        self.name = name
        self.summary = summary
        self.version = version
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
    }
}

@MainActor
final class FloorpWebExtensionInstallConfirmationViewController: UIViewController,
                                                                  Themeable,
                                                                  InjectedThemeUUIDIdentifiable {
    typealias Callback = @MainActor () -> Void

    let windowUUID: WindowUUID
    var currentWindowUUID: WindowUUID? { windowUUID }
    var themeManager: ThemeManager
    var themeListenerCancellable: Any?

    private let presentation: FloorpWebExtensionInstallPresentation
    private let notificationCenter: NotificationProtocol
    private let onCancel: Callback
    private let onInstall: Callback
    private let scrollView: UIScrollView = .build()
    private let contentStack: UIStackView = .build()
    private let footerView: UIView = .build()
    private let cancelButton: UIButton = .build()
    private let installButton: UIButton = .build()
    private var themedCards = [UIView]()
    private var primaryLabels = [UILabel]()
    private var secondaryLabels = [UILabel]()
    private var iconViews = [UIImageView]()

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

        var cancelConfiguration = UIButton.Configuration.gray()
        cancelConfiguration.title = "Cancel"
        cancelConfiguration.baseForegroundColor = theme.colors.textPrimary
        cancelButton.configuration = cancelConfiguration

        var installConfiguration = UIButton.Configuration.filled()
        installConfiguration.title = "Install extension"
        installConfiguration.image = UIImage(systemName: "arrow.down.app.fill")
        installConfiguration.imagePadding = 8
        installConfiguration.baseBackgroundColor = theme.colors.actionPrimary
        installConfiguration.baseForegroundColor = theme.colors.textOnDark
        installButton.configuration = installConfiguration
    }

    private func setupView() {
        title = "Review extension"
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        footerView.layer.shadowOpacity = 0.12
        footerView.layer.shadowRadius = 8
        footerView.layer.shadowOffset = CGSize(width: 0, height: -2)

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        view.addSubview(footerView)
        footerView.addSubview(cancelButton)
        footerView.addSubview(installButton)

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
            cancelButton.topAnchor.constraint(equalTo: footerView.topAnchor, constant: 14),
            cancelButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 20),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            installButton.topAnchor.constraint(equalTo: cancelButton.topAnchor),
            installButton.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 12),
            installButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -20),
            installButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
            installButton.widthAnchor.constraint(greaterThanOrEqualTo: cancelButton.widthAnchor, multiplier: 1.5)
        ])

        cancelButton.accessibilityIdentifier = "Floorp.WebExtensions.InstallConsent.Cancel.\(presentation.extensionID.rawValue)"
        cancelButton.accessibilityHint = "Closes the installation review without making changes."
        installButton.accessibilityIdentifier = "Floorp.WebExtensions.InstallConsent.Install.\(presentation.extensionID.rawValue)"
        installButton.accessibilityHint = "Installs this reviewed extension with site access disabled."
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel() }, for: .touchUpInside)
        installButton.addAction(UIAction { [weak self] _ in self?.onInstall() }, for: .touchUpInside)

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
        iconContainer.layer.cornerRadius = 20
        iconContainer.layer.cornerCurve = .continuous
        let iconView: UIImageView = .build()
        let descriptor = FloorpWebExtensionIconRegistry.descriptor(for: presentation.extensionID)
        iconView.image = descriptor.image()
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        if descriptor.usesTemplateRendering() { iconViews.append(iconView) }
        iconContainer.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 82),
            iconContainer.heightAnchor.constraint(equalTo: iconContainer.widthAnchor),
            iconView.topAnchor.constraint(equalTo: iconContainer.topAnchor, constant: 12),
            iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor, constant: 12),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: -12),
            iconView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: -12)
        ])
        themedCards.append(iconContainer)

        let titleLabel = makeLabel(text: presentation.name, style: .title2, primary: true)
        titleLabel.textAlignment = .center
        let versionLabel = makeLabel(text: "Version \(presentation.version)", style: .subheadline, primary: false)
        versionLabel.textAlignment = .center
        let summaryLabel = makeLabel(text: presentation.summary, style: .body, primary: false)
        summaryLabel.textAlignment = .center
        container.addArrangedSubview(iconContainer)
        container.addArrangedSubview(titleLabel)
        container.addArrangedSubview(versionLabel)
        container.addArrangedSubview(summaryLabel)
        contentStack.addArrangedSubview(container)
    }

    private func addCapabilityCard() {
        let rows: [(String, String, String)]
        if presentation.permissions.isEmpty {
            rows = [("checkmark.shield.fill", "No additional capabilities", "This extension requests no product-level capabilities.")]
        } else {
            rows = presentation.permissions.map { permission in
                (permissionSymbol(permission), permission.title, permissionExplanation(permission))
            }
        }
        contentStack.addArrangedSubview(makeSection(
            title: "What this extension can do",
            rows: rows
        ))
    }

    private func addSiteAccessCard() {
        let detail: String
        if presentation.requestedSites.isEmpty {
            detail = "No website access is requested."
        } else {
            detail = "Access starts off. After installation, you choose which requested sites to allow.\n\n" +
                presentation.requestedSites.sorted().joined(separator: "\n")
        }
        contentStack.addArrangedSubview(makeSection(
            title: "Website access",
            rows: [("hand.raised.fill", "You stay in control", detail)]
        ))
    }

    private func addPrivateBrowsingCard() {
        let detail: String
        switch presentation.privateProfileCapability {
        case .some(.notSupported):
            detail = "This extension is not available in private browsing."
        case .some(.optIn), .some(.supported):
            detail = "Private browsing is a separate opt-in with separate, ephemeral storage and site access."
        case .none:
            detail = "Private browsing availability is not declared for this extension."
        }
        contentStack.addArrangedSubview(makeSection(
            title: "Private browsing",
            rows: [("eye.slash.fill", "Separate by design", detail)]
        ))
    }

    private func addPublisherCard() {
        var rows = [(String, String, String)]()
        rows.append(("person.crop.circle.badge.checkmark", "Publisher", presentation.catalogPublisher ?? presentation.source))
        if let attribution = presentation.catalogAttribution {
            rows.append(("signature", "Attribution", attribution))
        }
        if let reviewedAt = presentation.catalogReviewedAt {
            rows.append(("checkmark.seal.fill", "Floorp review", reviewedAt))
        }
        if let privacySummary = presentation.catalogPrivacySummary {
            rows.append(("lock.shield.fill", "Privacy", privacySummary))
        }
        if let retentionPolicy = presentation.catalogRetentionPolicy {
            rows.append(("internaldrive.fill", "Data retention", retentionPolicy))
        }
        rows.append(("doc.text.fill", "Source and license", "\(presentation.source) · \(presentation.license)"))
        contentStack.addArrangedSubview(makeSection(title: "Trust and transparency", rows: rows))
    }

    private func makeSection(title: String, rows: [(String, String, String)]) -> UIView {
        let stack: UIStackView = .build()
        stack.axis = .vertical
        stack.spacing = 0
        let titleLabel = makeLabel(text: title, style: .headline, primary: true)
        titleLabel.accessibilityTraits = .header
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(10, after: titleLabel)

        let card: UIStackView = .build()
        card.axis = .vertical
        card.spacing = 0
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
        themedCards.append(card)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator: UIView = .build()
                separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                card.addArrangedSubview(separator)
                themedCards.append(separator)
            }
            card.addArrangedSubview(makeInfoRow(symbol: row.0, title: row.1, detail: row.2))
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
        case "siteData": return "Only on sites you explicitly allow after installation."
        case "tabs": return "Works with supported tab information and actions."
        case "storage": return "Keeps extension preferences on this device."
        case "networkBlocking": return "Applies reviewed, supported blocking rules."
        case "browserAutomation": return "Runs approved package scripts and styles."
        case "alarms": return "Schedules local extension work using supported alarms."
        case "fontSettings": return "Uses the supported generic font fallback."
        default: return "Uses an approved Floorp extension capability."
        }
    }
}

struct FloorpWebExtensionInstalledDetailPresentation: Sendable {
    let extensionID: FloorpWebExtensionID
    let name: String
    let summary: String?
    let version: String
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

    init(
        extensionID: FloorpWebExtensionID,
        name: String,
        summary: String? = nil,
        version: String,
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
        updateVersion: String? = nil
    ) {
        self.extensionID = extensionID
        self.name = name
        self.summary = summary
        self.version = version
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
            case .access: return "Access"
            case .controls: return "Manage"
            case .trust: return "Trust and transparency"
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

    private let presentation: FloorpWebExtensionInstalledDetailPresentation
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
        title = "Extension"
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
            cell.textLabel?.text = "Enabled"
            cell.detailTextLabel?.text = presentation.isCatalogRevoked
                ? "Disabled because this catalog package was revoked."
                : "Allow this extension to run in standard browsing."
            let enabledSwitch = UISwitch()
            enabledSwitch.isOn = isEnabled
            enabledSwitch.isEnabled = !presentation.isCatalogRevoked
            enabledSwitch.accessibilityIdentifier = "Floorp.WebExtensions.Detail.EnabledSwitch.\(presentation.extensionID.rawValue)"
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
            cell.textLabel?.text = "Uninstall extension"
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
        case .status:
            var rows: [Row] = [.enabled]
            if presentation.isCatalogRevoked {
                rows.append(.information(
                    symbol: "exclamationmark.shield.fill",
                    title: "Catalog package revoked",
                    detail: "This extension cannot be enabled or updated. You can uninstall it below."
                ))
            } else if let error = presentation.errorDescription {
                rows.append(.information(
                    symbol: "exclamationmark.triangle.fill",
                    title: "Needs attention",
                    detail: error
                ))
            }
            return rows
        case .access:
            var rows: [Row] = [
                .information(
                    symbol: "hand.raised.fill",
                    title: "Website access",
                    detail: presentation.siteAccessDescription
                )
            ]
            if let action = actions.onManageSiteAccess {
                rows.append(.action(
                    symbol: "globe",
                    title: "Manage website access",
                    detail: "Choose exactly where this extension can run.",
                    identifier: "SiteAccess",
                    handler: action
                ))
            }
            let privateTitle: String
            switch presentation.privateProfileCapability {
            case .some(.notSupported): privateTitle = "Private browsing unavailable"
            case .some(.optIn), .some(.supported):
                privateTitle = presentation.isPrivateBrowsingEnabled
                    ? "Allowed in private browsing"
                    : "Not allowed in private browsing"
            case .none: privateTitle = "Private browsing not declared"
            }
            rows.append(.information(
                symbol: "eye.slash.fill",
                title: privateTitle,
                detail: presentation.privateAccessDescription
            ))
            if let action = actions.onTogglePrivateBrowsing,
               presentation.privateProfileCapability != .notSupported,
               !presentation.isCatalogRevoked {
                rows.append(.action(
                    symbol: presentation.isPrivateBrowsingEnabled ? "eye.slash" : "eye.slash.fill",
                    title: presentation.isPrivateBrowsingEnabled
                        ? "Disable in private browsing"
                        : "Allow in private browsing",
                    detail: "Uses a separate private-profile installation and storage.",
                    identifier: "PrivateBrowsing",
                    handler: { [presentation] in action(!presentation.isPrivateBrowsingEnabled) }
                ))
            }
            if let action = actions.onManagePrivateSiteAccess, presentation.isPrivateBrowsingEnabled {
                rows.append(.action(
                    symbol: "lock.shield.fill",
                    title: "Private website access",
                    detail: "Manage access separately for private browsing.",
                    identifier: "PrivateSiteAccess",
                    handler: action
                ))
            }
            return rows
        case .controls:
            var rows = [Row]()
            appendAction(actions.onOpenOptions, to: &rows, symbol: "gearshape.fill", title: "Extension settings", detail: nil, identifier: "Options")
            appendAction(actions.onManageNetworkProtection, to: &rows, symbol: "shield.lefthalf.filled", title: "Network protection", detail: "Review active rules and site exclusions.", identifier: "Network")
            appendAction(actions.onManagePrivateNetworkProtection, to: &rows, symbol: "lock.shield.fill", title: "Private network protection", detail: "Review private rules and site exclusions.", identifier: "PrivateNetwork")
            appendAction(actions.onOpenWebsite, to: &rows, symbol: "safari.fill", title: "Project website", detail: nil, identifier: "Website")
            appendAction(actions.onViewUpdateHistory, to: &rows, symbol: "clock.arrow.circlepath", title: "Update history", detail: nil, identifier: "History")
            if let update = actions.onUpdate, let version = presentation.updateVersion {
                rows.append(.action(
                    symbol: "arrow.down.circle.fill",
                    title: "Update to \(version)",
                    detail: "Review and install the latest signed catalog version.",
                    identifier: "Update",
                    handler: update
                ))
            }
            return rows.isEmpty
                ? [.information(symbol: "checkmark.circle.fill", title: "No additional controls", detail: "This extension has no configurable actions.")]
                : rows
        case .trust:
            var rows = [Row]()
            rows.append(.information(
                symbol: "checkmark.seal.fill",
                title: presentation.catalogPublisher ?? "Reviewed extension",
                detail: [presentation.catalogAttribution, presentation.catalogReviewedAt.map { "Reviewed \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            ))
            if !presentation.permissions.isEmpty {
                rows.append(.information(
                    symbol: "list.bullet.clipboard.fill",
                    title: "Capabilities",
                    detail: presentation.permissions.map(\.title).joined(separator: "\n")
                ))
            }
            if let privacy = presentation.catalogPrivacySummary {
                rows.append(.information(symbol: "lock.shield.fill", title: "Privacy", detail: privacy))
            }
            if let retention = presentation.catalogRetentionPolicy {
                rows.append(.information(symbol: "internaldrive.fill", title: "Data retention", detail: retention))
            }
            let sourceAndLicense = [presentation.catalogSource, presentation.catalogLicense]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !sourceAndLicense.isEmpty {
                rows.append(.information(symbol: "doc.text.fill", title: "Source and license", detail: sourceAndLicense))
            }
            return rows
        case .remove:
            return [.destructive]
        }
    }

    private func appendAction(
        _ action: (() -> Void)?,
        to rows: inout [Row],
        symbol: String,
        title: String,
        detail: String?,
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
        descriptor = FloorpWebExtensionIconRegistry.descriptor(for: presentation.extensionID)
        iconView.image = descriptor?.image()
        iconView.accessibilityLabel = descriptor?.accessibilityLabel
        titleLabel.text = presentation.name
        versionLabel.text = "Version \(presentation.version)"
        summaryLabel.text = presentation.summary
        summaryLabel.isHidden = presentation.summary?.isEmpty != false
        isEnabled = presentation.isEnabled
        isRevoked = presentation.isCatalogRevoked
        statusLabel.text = presentation.isCatalogRevoked
            ? "Revoked"
            : presentation.isEnabled ? "Enabled" : "Disabled"
    }

    func applyTheme(theme: Theme) {
        backgroundColor = theme.colors.layer1
        iconBackgroundView.backgroundColor = theme.colors.layerAccentNonOpaque
        titleLabel.textColor = theme.colors.textPrimary
        versionLabel.textColor = theme.colors.textSecondary
        summaryLabel.textColor = theme.colors.textSecondary
        if descriptor?.usesTemplateRendering() == true {
            iconView.tintColor = theme.colors.iconAccent
        }
        if isRevoked {
            statusLabel.textColor = theme.colors.textCritical
            statusLabel.backgroundColor = theme.colors.layerCriticalSubdued
        } else if isEnabled {
            statusLabel.textColor = theme.colors.textPrimary
            statusLabel.backgroundColor = theme.colors.layerSuccess
        } else {
            statusLabel.textColor = theme.colors.textSecondary
            statusLabel.backgroundColor = theme.colors.layerSurfaceMedium
        }
    }

    private func setupView() {
        iconBackgroundView.layer.cornerRadius = 18
        iconBackgroundView.layer.cornerCurve = .continuous
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
        statusLabel.layer.cornerRadius = 9
        statusLabel.layer.cornerCurve = .continuous
        statusLabel.clipsToBounds = true
        statusLabel.textAlignment = .center

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
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 72),
            iconBackgroundView.heightAnchor.constraint(equalTo: iconBackgroundView.widthAnchor),
            iconView.topAnchor.constraint(equalTo: iconBackgroundView.topAnchor, constant: 10),
            iconView.leadingAnchor.constraint(equalTo: iconBackgroundView.leadingAnchor, constant: 10),
            iconView.trailingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: -10),
            iconView.bottomAnchor.constraint(equalTo: iconBackgroundView.bottomAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
    }
}
