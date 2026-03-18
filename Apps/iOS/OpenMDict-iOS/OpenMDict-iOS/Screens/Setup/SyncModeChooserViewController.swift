//
//  SyncModeChooserViewController.swift
//  OpenMDict-iOS
//
//  Setup step: choose between iCloud sync and offline mode.
//
//  Two-zone layout (matches WelcomePageViewController):
//    - Upper zone: Column { icon, title, message }
//    - Lower zone: CTA1 (filled) + CTA2 (plain)
//
//  State communicated through icon + message color:
//    .loading / .available  — "icloud" (blue) + description (secondaryLabel)
//    .unavailable(noNetwork)— "wifi.exclamationmark" (blue) + reason (systemRed)
//    .unavailable(other)    — "exclamationmark.icloud" (blue) + reason (systemRed)
//
//  CTA1 during loading: disabled + Row { spinner, "Checking iCloud..." }
//  CTA2 ("Don't Use iCloud") is always visible.
//

import UIKit

final class SyncModeChooserViewController: UIViewController {

    // MARK: - Callbacks

    /// Called when the user chooses iCloud sync.
    /// `summary` contains the cloud data inventory (dict/group/bookmark counts).
    var onChooseCloudSync: ((_ summary: CloudDataSummary) -> Void)?

    /// Called when the user confirms offline mode (after the warning alert).
    var onChooseOffline: (() -> Void)?

    // MARK: - State

    private enum State {
        case loading
        case available(summary: CloudDataSummary)
        case unavailable(reason: SyncModeService.UnavailableReason)
    }

    private var state: State = .loading {
        didSet { applyState() }
    }

    /// Cached for the callback when CTA1 is tapped.
    private var cachedSummary = CloudDataSummary(dictionaryCount: 0, groupCount: 0, bookmarkCount: 0, lookupHistoryCount: 0)

    // MARK: - Upper Zone

    private let upperContainer: UIView = {
        let v = UIView()
        v.backgroundColor = .systemBackground
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.alwaysBounceVertical = true
        return sv
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let iconImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 80),
            iv.heightAnchor.constraint(equalToConstant: 80),
        ])
        return iv
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.SyncChooser.title
        label.font = .systemFont(ofSize: 28, weight: .bold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    /// Shows description (normal) or error reason (red) depending on state.
    private let messageLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    // MARK: - Lower Zone (footer)

    private let footerContainer: UIView = {
        let v = UIView()
        v.backgroundColor = .secondarySystemBackground
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// CTA1: filled button — text changes based on state.
    private let primaryButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    /// CTA2: plain button — always "Don't Use iCloud".
    private let secondaryButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = L10n.SyncChooser.dontUseICloud
        config.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupLayout()

        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)

        applyState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkCloud()
    }

    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(upperContainer)
        view.addSubview(footerContainer)

        // Two-zone split
        let upperBottom = upperContainer.bottomAnchor.constraint(equalTo: footerContainer.topAnchor)
        upperBottom.priority = .init(999)
        NSLayoutConstraint.activate([
            upperContainer.topAnchor.constraint(equalTo: view.topAnchor),
            upperContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            upperContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            upperBottom,

            footerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        setupUpperZone()
        setupFooterZone()
    }

    private func setupUpperZone() {
        upperContainer.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        let svTop = scrollView.topAnchor.constraint(equalTo: upperContainer.safeAreaLayoutGuide.topAnchor)
        svTop.priority = .init(999)
        NSLayoutConstraint.activate([
            svTop,
            scrollView.leadingAnchor.constraint(equalTo: upperContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: upperContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: upperContainer.bottomAnchor),
        ])

        let maxWidth: CGFloat = 420
        let centerX = contentStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor)
        centerX.priority = .init(999)
        let leading = contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 32)
        leading.priority = .init(999)
        let trailing = contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -32)
        trailing.priority = .init(999)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 48),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            centerX, leading, trailing,
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        ])

        contentStack.addArrangedSubview(iconImageView)
        contentStack.setCustomSpacing(12, after: iconImageView)

        contentStack.addArrangedSubview(titleLabel)
        contentStack.setCustomSpacing(8, after: titleLabel)

        contentStack.addArrangedSubview(messageLabel)
    }

    private func setupFooterZone() {
        footerContainer.addSubview(primaryButton)
        footerContainer.addSubview(secondaryButton)

        let padding: CGFloat = 32
        let btnBottom = secondaryButton.bottomAnchor.constraint(
            equalTo: footerContainer.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        btnBottom.priority = .init(999)
        let priLeading = primaryButton.leadingAnchor.constraint(
            equalTo: footerContainer.leadingAnchor, constant: padding)
        priLeading.priority = .init(999)
        let priTrailing = primaryButton.trailingAnchor.constraint(
            equalTo: footerContainer.trailingAnchor, constant: -padding)
        priTrailing.priority = .init(999)

        NSLayoutConstraint.activate([
            primaryButton.topAnchor.constraint(equalTo: footerContainer.topAnchor, constant: 20),
            priLeading, priTrailing,
            primaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),

            secondaryButton.topAnchor.constraint(equalTo: primaryButton.bottomAnchor, constant: 8),
            secondaryButton.centerXAnchor.constraint(equalTo: footerContainer.centerXAnchor),
            btnBottom,
        ])
    }

    // MARK: - State Application

    private func applyState() {
        guard isViewLoaded else { return }

        switch state {
        case .loading:
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.systemBlue]))
            iconImageView.image = UIImage(systemName: "icloud", withConfiguration: iconConfig)
            titleLabel.text = L10n.SyncChooser.title
            messageLabel.text = L10n.SyncChooser.description
            messageLabel.textColor = .secondaryLabel

            primaryButton.isEnabled = false
            primaryButton.configuration?.showsActivityIndicator = true
            primaryButton.configuration?.title = L10n.SyncChooser.checkingICloud

        case .available(let summary):
            self.cachedSummary = summary
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.systemBlue]))
            iconImageView.image = UIImage(systemName: "person.icloud.fill", withConfiguration: iconConfig)
            titleLabel.text = L10n.SyncChooser.title
            messageLabel.text = summary.hasData
                ? descriptionWithSummary(summary)
                : L10n.SyncChooser.description
            messageLabel.textColor = .secondaryLabel

            primaryButton.isEnabled = true
            primaryButton.configuration?.showsActivityIndicator = false
            primaryButton.configuration?.title = summary.hasData
                ? L10n.SyncChooser.restoreFromICloud
                : L10n.SyncChooser.useICloudSync

        case .unavailable(let reason):
            let iconConfig = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.systemRed]))
            let iconName = reason == .noNetwork ? "wifi.exclamationmark" : "exclamationmark.icloud"
            iconImageView.image = UIImage(systemName: iconName, withConfiguration: iconConfig)
            titleLabel.text = reason == .noNetwork
                ? L10n.SyncChooser.errorNoNetworkTitle
                : L10n.SyncChooser.errorICloudNotAvailableTitle
            messageLabel.text = errorMessage(for: reason)
            messageLabel.textColor = .secondaryLabel

            primaryButton.isEnabled = true
            primaryButton.configuration?.showsActivityIndicator = false
            primaryButton.configuration?.title = L10n.SyncChooser.retry
        }
    }

    private func errorMessage(for reason: SyncModeService.UnavailableReason) -> String {
        switch reason {
        case .noNetwork:
            return L10n.SyncChooser.errorNoNetwork
        case .notSignedIn:
            return L10n.SyncChooser.errorNotSignedIn
        case .restricted:
            return L10n.SyncChooser.errorRestricted
        case .temporarilyUnavailable:
            return L10n.SyncChooser.errorTemporarilyUnavailable
        case .couldNotDetermine:
            return L10n.SyncChooser.errorUnknown
        }
    }

    /// Build a descriptive message showing what's in the user's iCloud,
    /// e.g. "Your iCloud contains 3 dictionaries, 2 groups, and 5 bookmarks.
    ///        They will be synced to this device."
    private func descriptionWithSummary(_ summary: CloudDataSummary) -> String {
        var parts: [String] = []
        if summary.dictionaryCount > 0 {
            parts.append(L10n.SyncChooser.summaryDictionaries(summary.dictionaryCount))
        }
        if summary.groupCount > 0 {
            parts.append(L10n.SyncChooser.summaryGroups(summary.groupCount))
        }
        if summary.bookmarkCount > 0 {
            parts.append(L10n.SyncChooser.summaryBookmarks(summary.bookmarkCount))
        }
        if summary.lookupHistoryCount > 0 {
            parts.append(L10n.SyncChooser.summaryLookupHistory(summary.lookupHistoryCount))
        }

        let inventory = ListFormatter.localizedString(byJoining: parts)
        return L10n.SyncChooser.descriptionWithData(inventory)
    }

    // MARK: - CloudKit Check

    private func checkCloud() {
        state = .loading
        Task {
            let result = await SyncModeService.shared.checkCloudStatus()
            switch result {
            case .available(let summary):
                state = .available(summary: summary)
            case .unavailable(let reason):
                state = .unavailable(reason: reason)
            }
        }
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch state {
        case .available:
            onChooseCloudSync?(cachedSummary)

        case .unavailable:
            // Retry
            checkCloud()

        case .loading:
            break // ignore tap while loading
        }
    }

    @objc private func secondaryTapped() {
        let alert = UIAlertController(
            title: L10n.SyncChooser.offlineAlertTitle,
            message: L10n.SyncChooser.offlineAlertMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.SyncChooser.confirmOffline, style: .destructive) { [weak self] _ in
            self?.onChooseOffline?()
        })
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        present(alert, animated: true)
    }
}
