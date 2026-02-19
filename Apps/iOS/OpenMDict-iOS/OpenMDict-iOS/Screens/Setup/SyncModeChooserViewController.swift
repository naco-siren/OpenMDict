//
//  SyncModeChooserViewController.swift
//  OpenMDict-iOS
//
//  Setup step: choose between iCloud sync and offline mode.
//
//  Two-zone layout (matches WelcomePageViewController):
//    - Upper zone: cloud icon + title + description text
//    - Lower zone: CTA1 (filled) + CTA2 (plain)
//
//  Three UI states:
//    .loading       — spinner + "Checking iCloud..."
//    .available     — CTA1 = "Restore from iCloud" or "Use iCloud Sync"
//    .unavailable   — error message + CTA1 = "Retry"
//
//  CTA2 ("Don't Use iCloud") is always visible.
//

import UIKit

final class SyncModeChooserViewController: UIViewController {

    // MARK: - Callbacks

    /// Called when the user chooses iCloud sync.
    /// `hasData` indicates whether CloudKit already contains dictionary data.
    var onChooseCloudSync: ((_ hasData: Bool) -> Void)?

    /// Called when the user confirms offline mode (after the warning alert).
    var onChooseOffline: (() -> Void)?

    // MARK: - State

    private enum State {
        case loading
        case available(hasData: Bool)
        case unavailable(reason: SyncModeService.UnavailableReason)
    }

    private var state: State = .loading {
        didSet { applyState() }
    }

    /// Cached for the callback when CTA1 is tapped.
    private var hasData = false

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

    private let cloudImageView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        let image = UIImage(systemName: "icloud", withConfiguration: config)
        let iv = UIImageView(image: image)
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

    private let descriptionLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.SyncChooser.description
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    /// Shown in `.loading` state.
    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.hidesWhenStopped = true
        return s
    }()

    /// Shown in `.loading` state.
    private let checkingLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.SyncChooser.checkingICloud
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    /// Shown in `.unavailable` state — describes the error.
    private let errorLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .systemRed
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.isHidden = true
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

        // Cloud icon
        contentStack.addArrangedSubview(cloudImageView)
        contentStack.setCustomSpacing(12, after: cloudImageView)

        // Title
        contentStack.addArrangedSubview(titleLabel)
        contentStack.setCustomSpacing(8, after: titleLabel)

        // Description
        contentStack.addArrangedSubview(descriptionLabel)
        contentStack.setCustomSpacing(24, after: descriptionLabel)

        // Spinner + checking label (hidden by default via applyState)
        let loadingStack = UIStackView(arrangedSubviews: [spinner, checkingLabel])
        loadingStack.axis = .horizontal
        loadingStack.spacing = 8
        loadingStack.alignment = .center
        loadingStack.tag = 100  // for lookup in applyState
        contentStack.addArrangedSubview(loadingStack)

        // Error label (hidden by default)
        contentStack.addArrangedSubview(errorLabel)
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

        let loadingStack = contentStack.viewWithTag(100)

        switch state {
        case .loading:
            spinner.startAnimating()
            loadingStack?.isHidden = false
            errorLabel.isHidden = true
            primaryButton.isEnabled = false
            primaryButton.configuration?.title = L10n.SyncChooser.checkingICloud
            primaryButton.configuration?.showsActivityIndicator = true

        case .available(let hasData):
            self.hasData = hasData
            spinner.stopAnimating()
            loadingStack?.isHidden = true
            errorLabel.isHidden = true
            primaryButton.isEnabled = true
            primaryButton.configuration?.showsActivityIndicator = false
            primaryButton.configuration?.title = hasData
                ? L10n.SyncChooser.restoreFromICloud
                : L10n.SyncChooser.useICloudSync

        case .unavailable(let reason):
            spinner.stopAnimating()
            loadingStack?.isHidden = true
            errorLabel.isHidden = false
            errorLabel.text = errorMessage(for: reason)
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

    // MARK: - CloudKit Check

    private func checkCloud() {
        state = .loading
        Task {
            let result = await SyncModeService.shared.checkCloudStatus()
            switch result {
            case .available(let hasData):
                state = .available(hasData: hasData)
            case .unavailable(let reason):
                state = .unavailable(reason: reason)
            }
        }
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch state {
        case .available(let hasData):
            onChooseCloudSync?(hasData)

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
