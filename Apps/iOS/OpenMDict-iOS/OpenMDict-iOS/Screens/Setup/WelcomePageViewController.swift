//
//  WelcomePageViewController.swift
//  OpenMDict-iOS
//
//  Step 1 of the first-install onboarding flow.
//  Explains what the app is, highlights differentiating features,
//  and provides a "Get Started" button to proceed to dictionary selection.
//

import UIKit

final class WelcomePageViewController: UIViewController {

    // MARK: - Callback

    var onGetStarted: (() -> Void)?

    // MARK: - UI Elements

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
        let config = UIImage.SymbolConfiguration(pointSize: 64, weight: .medium)
        let image = UIImage(systemName: "book.closed.fill", withConfiguration: config)
        let iv = UIImageView(image: image)
        iv.tintColor = .systemBlue
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Welcome to OpenMDict"
        label.font = .systemFont(ofSize: 34, weight: .bold)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = "A free, open-source MDict (MDX) dictionary reader"
        label.font = .preferredFont(forTextStyle: .title3)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private let hintLabel: UILabel = {
        let label = UILabel()
        label.text = "For user-contributed content and format specifications, search for open-source dictionary communities online."
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private let getStartedButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Get Started"
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // MARK: - Feature Data

    private struct Feature {
        let symbolName: String
        let text: String
    }

    private let features: [Feature] = [
        Feature(
            symbolName: "rectangle.split.3x1",
            text: "Three article layout modes — view multiple definitions from different dictionaries at once."
        ),
        Feature(
            symbolName: "macwindow.on.rectangle",
            text: "Multi-window support and native three-column layout on iPadOS."
        ),
        Feature(
            symbolName: "infinity",
            text: "No limits on imported dictionaries or user-created groups — everything is free, forever."
        ),
        Feature(
            symbolName: "gift",
            text: "We include some open-source dictionaries. For richer content, import your own .mdx files."
        ),
    ]

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupLayout()
        getStartedButton.addTarget(self, action: #selector(getStartedTapped), for: .touchUpInside)
    }

    // MARK: - Layout

    private func setupLayout() {
        view.addSubview(scrollView)
        view.addSubview(getStartedButton)
        scrollView.addSubview(contentStack)

        // ScrollView fills the view, leaving room for the button at the bottom.
        // Priority 999 on vertical chain to tolerate zero-height during child VC containment.
        let svTop = scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        svTop.priority = .init(999)
        let svBottom = scrollView.bottomAnchor.constraint(equalTo: getStartedButton.topAnchor, constant: -16)
        svBottom.priority = .init(999)
        NSLayoutConstraint.activate([
            svTop, svBottom,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Content stack: centered within scroll view, max width for readability
        // Use priority 999 on margin/sizing constraints to avoid conflicts when
        // the container has zero width during child VC containment transitions.
        let maxWidth: CGFloat = 500
        let centerX = contentStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor)
        centerX.priority = .init(999)
        let leading = contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 32)
        leading.priority = .init(999)
        let trailing = contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -32)
        trailing.priority = .init(999)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 40),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            centerX, leading, trailing,
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        ])

        // Icon (priority 999 to avoid conflict with zero-width container)
        contentStack.addArrangedSubview(iconImageView)
        let iconWidth = iconImageView.widthAnchor.constraint(equalToConstant: 80)
        iconWidth.priority = .init(999)
        let iconHeight = iconImageView.heightAnchor.constraint(equalToConstant: 80)
        iconHeight.priority = .init(999)
        NSLayoutConstraint.activate([iconHeight, iconWidth])

        // Title
        contentStack.addArrangedSubview(titleLabel)
        contentStack.setCustomSpacing(8, after: titleLabel)

        // Subtitle
        contentStack.addArrangedSubview(subtitleLabel)
        contentStack.setCustomSpacing(32, after: subtitleLabel)

        // Feature rows
        let featuresStack = UIStackView()
        featuresStack.axis = .vertical
        featuresStack.spacing = 20
        featuresStack.alignment = .leading
        featuresStack.translatesAutoresizingMaskIntoConstraints = false

        for feature in features {
            let row = makeFeatureRow(symbolName: feature.symbolName, text: feature.text)
            featuresStack.addArrangedSubview(row)
        }

        contentStack.addArrangedSubview(featuresStack)
        featuresStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.setCustomSpacing(24, after: featuresStack)

        // Hint
        contentStack.addArrangedSubview(hintLabel)

        // Get Started button pinned at bottom (priority 999 for zero-size tolerance)
        let btnLeading = getStartedButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40)
        btnLeading.priority = .init(999)
        let btnTrailing = getStartedButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40)
        btnTrailing.priority = .init(999)
        let btnBottom = getStartedButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        btnBottom.priority = .init(999)
        let btnHeight = getStartedButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        btnHeight.priority = .init(999)
        NSLayoutConstraint.activate([btnLeading, btnTrailing, btnBottom, btnHeight])
    }

    private func makeFeatureRow(symbolName: String, text: String) -> UIView {
        let hStack = UIStackView()
        hStack.axis = .horizontal
        hStack.alignment = .top
        hStack.spacing = 16

        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        let image = UIImage(systemName: symbolName, withConfiguration: config)
        let imageView = UIImageView(image: image)
        imageView.tintColor = .systemBlue
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let imgW = imageView.widthAnchor.constraint(equalToConstant: 32)
        imgW.priority = .init(999)
        let imgH = imageView.heightAnchor.constraint(equalToConstant: 32)
        imgH.priority = .init(999)
        NSLayoutConstraint.activate([imgW, imgH])

        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true

        hStack.addArrangedSubview(imageView)
        hStack.addArrangedSubview(label)

        return hStack
    }

    // MARK: - Action

    @objc private func getStartedTapped() {
        onGetStarted?()
    }
}
