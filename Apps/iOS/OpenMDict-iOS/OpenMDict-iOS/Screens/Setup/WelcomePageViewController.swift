//
//  WelcomePageViewController.swift
//  OpenMDict-iOS
//
//  Step 1 of the first-install onboarding flow.
//  Apple TV-style two-zone layout:
//    - Upper zone (white): title + scrollable feature rows
//    - Lower zone (gray):  app icon + resource hint + "Get Started" CTA
//

import UIKit

final class WelcomePageViewController: UIViewController {

    // MARK: - Callback

    var onGetStarted: (() -> Void)?

    // MARK: - Feature Data

    private struct Feature {
        let symbolName: String
        let title: String
        let body: String
    }

    private var features: [Feature] {
        let extensionsIcon: String
        if #available(iOS 18.0, *) {
            extensionsIcon = traitCollection.horizontalSizeClass == .compact
                ? "widget.small.badge.plus"
                : "widget.large.badge.plus"
        } else {
            extensionsIcon = "square.text.square"
        }
        return [
            Feature(
                symbolName: "text.and.command.macwindow",
                title: L10n.Welcome.layoutsTitle,
                body: L10n.Welcome.layoutsBody
            ),
            Feature(
                symbolName: "macwindow.on.rectangle",
                title: L10n.Welcome.multiWindowTitle,
                body: L10n.Welcome.multiWindowBody
            ),
            Feature(
                symbolName: extensionsIcon,
                title: L10n.Welcome.extensionsTitle,
                body: L10n.Welcome.extensionsBody
            ),
            Feature(
                symbolName: "moon.stars",
                title: L10n.Welcome.darkEnhanceTitle,
                body: L10n.Welcome.darkEnhanceBody
            ),
            Feature(
                symbolName: "gift",
                title: L10n.Welcome.presetsTitle,
                body: L10n.Welcome.presetsBody
            ),
            Feature(
                symbolName: "infinity",
                title: L10n.Welcome.noLimitsTitle,
                body: L10n.Welcome.noLimitsBody
            ),
        ]
    }

    // MARK: - Upper Zone (white)

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
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.Welcome.title
        label.font = .systemFont(ofSize: 34, weight: .bold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    // MARK: - Lower Zone (gray footer)

    private let footerContainer: UIView = {
        let v = UIView()
        v.backgroundColor = .secondarySystemBackground
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let footerStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let footerLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.Welcome.footer
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private let getStartedButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = L10n.Welcome.getStarted
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupLayout()
        getStartedButton.addTarget(self, action: #selector(getStartedTapped), for: .touchUpInside)
    }

    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(upperContainer)
        view.addSubview(footerContainer)

        // Two-zone split: upper takes remaining space, footer is intrinsic height
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

        // Content stack: centered, max width for readability
        let maxWidth: CGFloat = 420
        let centerX = contentStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor)
        centerX.priority = .init(999)
        let leading = contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 32)
        leading.priority = .init(999)
        let trailing = contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -32)
        trailing.priority = .init(999)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 32),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            centerX, leading, trailing,
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        ])

        // Title
        contentStack.addArrangedSubview(titleLabel)
        contentStack.setCustomSpacing(28, after: titleLabel)

        // Feature rows
        let featuresStack = UIStackView()
        featuresStack.axis = .vertical
        featuresStack.spacing = 24
        featuresStack.alignment = .leading
        featuresStack.translatesAutoresizingMaskIntoConstraints = false

        for feature in features {
            let row = makeFeatureRow(symbolName: feature.symbolName, title: feature.title, body: feature.body)
            featuresStack.addArrangedSubview(row)
        }

        contentStack.addArrangedSubview(featuresStack)
        featuresStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func setupFooterZone() {
        footerContainer.addSubview(footerStack)
        footerContainer.addSubview(getStartedButton)

        // Use fixed padding (not readableContentGuide) because formSheet is
        // already appropriately sized — readableContentGuide would over-narrow.
        let padding: CGFloat = 32
        let footerStackTop = footerStack.topAnchor.constraint(equalTo: footerContainer.topAnchor, constant: 20)
        footerStackTop.priority = .init(999)
        let btnBottom = getStartedButton.bottomAnchor.constraint(equalTo: footerContainer.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        btnBottom.priority = .init(999)
        let btnLeading = getStartedButton.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: padding)
        btnLeading.priority = .init(999)
        let btnTrailing = getStartedButton.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -padding)
        btnTrailing.priority = .init(999)

        // Lower priority on horizontal constraints to tolerate zero-width
        // during child VC containment transitions (UIView-Encapsulated-Layout-Width == 0)
        let fsLeading = footerStack.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: padding)
        fsLeading.priority = .init(999)
        let fsTrailing = footerStack.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -padding)
        fsTrailing.priority = .init(999)

        NSLayoutConstraint.activate([
            footerStackTop,
            fsLeading, fsTrailing,
            footerStack.bottomAnchor.constraint(equalTo: getStartedButton.topAnchor, constant: -16),

            btnLeading, btnTrailing, btnBottom,
            getStartedButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])

        // Footer text
        footerStack.addArrangedSubview(footerLabel)
    }

    private func makeFeatureRow(symbolName: String, title: String, body: String) -> UIView {
        let hStack = UIStackView()
        hStack.axis = .horizontal
        hStack.alignment = .top
        hStack.spacing = 16

        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        let image = UIImage(systemName: symbolName, withConfiguration: config)
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.heightAnchor.constraint(equalToConstant: 36),
        ])

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 2

        let titleLbl = UILabel()
        titleLbl.text = title
        titleLbl.font = .preferredFont(forTextStyle: .headline)
        titleLbl.textColor = .label
        titleLbl.numberOfLines = 0
        titleLbl.adjustsFontForContentSizeCategory = true

        let bodyLbl = UILabel()
        bodyLbl.text = body
        bodyLbl.font = .preferredFont(forTextStyle: .subheadline)
        bodyLbl.textColor = .secondaryLabel
        bodyLbl.numberOfLines = 0
        bodyLbl.adjustsFontForContentSizeCategory = true

        textStack.addArrangedSubview(titleLbl)
        textStack.addArrangedSubview(bodyLbl)

        hStack.addArrangedSubview(imageView)
        hStack.addArrangedSubview(textStack)

        return hStack
    }

    // MARK: - Action

    @objc private func getStartedTapped() {
        onGetStarted?()
    }
}
