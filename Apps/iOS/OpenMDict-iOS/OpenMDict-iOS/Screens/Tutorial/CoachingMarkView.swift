//
//  CoachingMarkView.swift
//  OpenMDict-iOS
//
//  Full-screen coaching mark overlay with spotlight cutout, message card,
//  and directional arrow. Used by TutorialViewController to guide users
//  through interactive tutorial steps.
//
//  Uses frame-based layout for the card + arrow positioning (reliable when
//  reconfigured multiple times). Only internal card subviews use Auto Layout.
//
//  iOS 15.6+ compatible — no third-party dependencies.
//

import UIKit

final class CoachingMarkView: UIView {

    // MARK: - Callbacks

    var onAction: (() -> Void)?

    // MARK: - Configuration

    enum ArrowDirection { case up, down, none }

    struct Configuration {
        let message: String
        let buttonTitle: String
        let spotlightFrame: CGRect?   // nil = no spotlight (centered card)
        let arrowDirection: ArrowDirection
        let stepText: String?         // e.g. "Step 2 of 5"
        var passThroughSpotlight: Bool = false  // When true, taps in spotlight area pass to views below
        /// Celebration mode: shows icon + title row above the message
        var celebrationTitle: String? = nil     // e.g. "Congratulations"
        var celebrationIcon: String? = nil      // SF Symbol name, e.g. "hands.clap"
    }

    // MARK: - UI Constants

    private static let cardCornerRadius: CGFloat = 14
    private static let cardPadding: CGFloat = 16
    private static let cardMaxWidth: CGFloat = 320
    private static let cardMinWidth: CGFloat = 240
    private static let arrowSize: CGFloat = 10
    private static let spotlightPadding: CGFloat = 8
    private static let spotlightCornerRadius: CGFloat = 8
    private static let dimmingAlpha: CGFloat = 0.5
    private static let cardSpacing: CGFloat = 8   // gap between spotlight edge and arrow tip

    // MARK: - Subviews

    private let dimmingLayer = CAShapeLayer()
    private let cardView = UIView()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let stepLabel = UILabel()
    private let arrowLayer = CAShapeLayer()

    // Celebration mode — ContentUnavailableView-style centered stack
    private let celebrationContainer = UIView()

    // State
    private var currentConfig: Configuration?
    private var buttonBottomConstraint: NSLayoutConstraint?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        // Dimming layer
        dimmingLayer.fillRule = .evenOdd
        dimmingLayer.fillColor = UIColor.black.withAlphaComponent(Self.dimmingAlpha).cgColor
        layer.addSublayer(dimmingLayer)

        // Card (frame-based positioning, Auto Layout for internal content)
        cardView.backgroundColor = .systemBackground
        cardView.layer.cornerRadius = Self.cardCornerRadius
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.25
        cardView.layer.shadowRadius = 12
        cardView.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(cardView)

        // Message
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = .label
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(messageLabel)

        // Step indicator
        stepLabel.font = .systemFont(ofSize: 12)
        stepLabel.textColor = .secondaryLabel
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(stepLabel)

        // Action button
        actionButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(actionButton)

        // Arrow layer (drawn directly on self.layer)
        arrowLayer.fillColor = UIColor.systemBackground.cgColor
        layer.addSublayer(arrowLayer)

        // Internal card layout (Auto Layout)
        let p = Self.cardPadding

        // Action button bottom anchor — always installed, ensures card has enough height
        buttonBottomConstraint = actionButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -p)

        NSLayoutConstraint.activate([
            messageLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: p),
            messageLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: p),
            messageLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -p),

            stepLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            stepLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: p),
            stepLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -p).withPriority(.defaultHigh),

            actionButton.centerYAnchor.constraint(equalTo: stepLabel.centerYAnchor).withPriority(.defaultHigh),
            actionButton.topAnchor.constraint(greaterThanOrEqualTo: messageLabel.bottomAnchor, constant: 16),
            actionButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -p),
            actionButton.leadingAnchor.constraint(greaterThanOrEqualTo: stepLabel.trailingAnchor, constant: 12),
            buttonBottomConstraint!,
        ])

        // Celebration container (initially hidden, shown only in celebration mode)
        celebrationContainer.isHidden = true
        celebrationContainer.backgroundColor = .systemBackground
        celebrationContainer.layer.cornerRadius = Self.cardCornerRadius
        celebrationContainer.layer.shadowColor = UIColor.black.cgColor
        celebrationContainer.layer.shadowOpacity = 0.25
        celebrationContainer.layer.shadowRadius = 12
        celebrationContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        celebrationContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(celebrationContainer)
        NSLayoutConstraint.activate([
            celebrationContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            celebrationContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            celebrationContainer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            celebrationContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
    }

    // MARK: - Touch Pass-Through

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Let the card and its subviews handle touches
        let cardHit = cardView.hitTest(convert(point, to: cardView), with: event)
        if cardHit != nil { return cardHit }

        // Let the celebration container and its button handle touches
        if !celebrationContainer.isHidden {
            let celebHit = celebrationContainer.hitTest(convert(point, to: celebrationContainer), with: event)
            if celebHit != nil { return celebHit }
        }

        // If spotlight pass-through is enabled, let touches in the spotlight
        // area reach the views below (e.g. bookmark button)
        if let config = currentConfig, config.passThroughSpotlight,
           let spot = config.spotlightFrame {
            let inflated = spot.insetBy(dx: -Self.spotlightPadding, dy: -Self.spotlightPadding)
            if inflated.contains(point) {
                return nil  // Pass through to views below
            }
        }

        // Dimming area absorbs touches (prevents accidental taps)
        return self
    }

    // MARK: - Configure

    func configure(with config: Configuration) {
        currentConfig = config

        let isCelebration = config.celebrationTitle != nil

        // Toggle card vs celebration mode
        cardView.isHidden = isCelebration
        arrowLayer.isHidden = isCelebration
        celebrationContainer.isHidden = !isCelebration

        if isCelebration {
            configureCelebration(config)
        } else {
            messageLabel.text = config.message
            actionButton.setTitle(config.buttonTitle, for: .normal)
            stepLabel.text = config.stepText
            stepLabel.isHidden = config.stepText == nil
        }

        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Build a ContentUnavailableView-style centered stack for celebration.
    private func configureCelebration(_ config: Configuration) {
        // Remove previous content
        celebrationContainer.subviews.forEach { $0.removeFromSuperview() }

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12

        // Icon (same style as ArticlePlaceholderView)
        let fallbackIcon: String
        if #available(iOS 16.0, *) { fallbackIcon = "trophy" } else { fallbackIcon = "hands.clap" }
        let iconView = UIImageView(image: UIImage(systemName: config.celebrationIcon ?? fallbackIcon))
        iconView.tintColor = .tintColor
        iconView.preferredSymbolConfiguration = .init(pointSize: 48)
        stack.addArrangedSubview(iconView)

        // Title
        let titleLabel = UILabel()
        titleLabel.text = config.celebrationTitle
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        stack.addArrangedSubview(titleLabel)

        // Subtitle
        let subtitleLabel = UILabel()
        subtitleLabel.text = config.message
        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        stack.addArrangedSubview(subtitleLabel)

        // Spacer
        stack.setCustomSpacing(20, after: subtitleLabel)

        // Button (filled rounded rect, matching tint color)
        let button = UIButton(type: .system)
        button.setTitle(config.buttonTitle, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.backgroundColor = .tintColor
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 32, bottom: 12, right: 32)
        button.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        stack.addArrangedSubview(button)

        let inset: CGFloat = 24
        celebrationContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: celebrationContainer.topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: celebrationContainer.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: celebrationContainer.trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: celebrationContainer.bottomAnchor, constant: -inset),
        ])
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let config = currentConfig else { return }

        dimmingLayer.frame = bounds
        updateDimmingMask(spotlight: config.spotlightFrame)
        layoutCardAndArrow(config: config)
    }

    private func updateDimmingMask(spotlight: CGRect?) {
        let fullPath = UIBezierPath(rect: bounds)
        if let spot = spotlight {
            let inflated = spot.insetBy(dx: -Self.spotlightPadding, dy: -Self.spotlightPadding)
            let cutout = UIBezierPath(roundedRect: inflated, cornerRadius: Self.spotlightCornerRadius)
            fullPath.append(cutout)
        }
        dimmingLayer.path = fullPath.cgPath
    }

    private func layoutCardAndArrow(config: Configuration) {
        // 1. Size the card using Auto Layout intrinsic content
        let maxW = min(Self.cardMaxWidth, bounds.width - 32)
        let targetW = max(Self.cardMinWidth, maxW)
        let fittingSize = cardView.systemLayoutSizeFitting(
            CGSize(width: targetW, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let cardW = min(targetW, fittingSize.width)
        let cardH = fittingSize.height

        // 2. Position card
        let safeInsets = safeAreaInsets
        let margin: CGFloat = 16
        let arrowH = Self.arrowSize

        if let spot = config.spotlightFrame, config.arrowDirection != .none {
            // Horizontal: center on spotlight, clamped to safe area
            var cardX = spot.midX - cardW / 2
            cardX = max(safeInsets.left + margin, cardX)
            cardX = min(bounds.width - safeInsets.right - margin - cardW, cardX)

            var cardY: CGFloat
            switch config.arrowDirection {
            case .up:
                // Card below spotlight
                cardY = spot.maxY + Self.spotlightPadding + arrowH + Self.cardSpacing
            case .down:
                // Card above spotlight
                cardY = spot.minY - Self.spotlightPadding - arrowH - Self.cardSpacing - cardH
            case .none:
                cardY = bounds.midY - cardH / 2
            }

            // Clamp vertically
            cardY = max(safeInsets.top + margin, cardY)
            cardY = min(bounds.height - safeInsets.bottom - margin - cardH, cardY)

            cardView.frame = CGRect(x: cardX, y: cardY, width: cardW, height: cardH)

            // 3. Draw arrow
            drawArrow(direction: config.arrowDirection, spotCenter: spot.midX, cardFrame: cardView.frame)
        } else {
            // Center card
            let cardX = (bounds.width - cardW) / 2
            let cardY = (bounds.height - cardH) / 2
            cardView.frame = CGRect(x: cardX, y: cardY, width: cardW, height: cardH)

            // No arrow
            arrowLayer.path = nil
        }
    }

    private func drawArrow(direction: ArrowDirection, spotCenter: CGFloat, cardFrame: CGRect) {
        let s = Self.arrowSize
        let path = UIBezierPath()

        // Clamp arrow X to within the card bounds
        let arrowCenterX = max(cardFrame.minX + Self.cardCornerRadius + s,
                               min(spotCenter, cardFrame.maxX - Self.cardCornerRadius - s))

        switch direction {
        case .up:
            // Arrow points up, sits between spotlight and top edge of card
            let tipY = cardFrame.minY - s
            let baseY = cardFrame.minY
            path.move(to: CGPoint(x: arrowCenterX, y: tipY))
            path.addLine(to: CGPoint(x: arrowCenterX + s, y: baseY))
            path.addLine(to: CGPoint(x: arrowCenterX - s, y: baseY))
            path.close()
        case .down:
            // Arrow points down, sits between bottom edge of card and spotlight
            let baseY = cardFrame.maxY
            let tipY = cardFrame.maxY + s
            path.move(to: CGPoint(x: arrowCenterX, y: tipY))
            path.addLine(to: CGPoint(x: arrowCenterX + s, y: baseY))
            path.addLine(to: CGPoint(x: arrowCenterX - s, y: baseY))
            path.close()
        case .none:
            break
        }

        arrowLayer.path = path.cgPath
    }

    // MARK: - Animation

    func showAnimated() {
        alpha = 0
        cardView.transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
            self.alpha = 1
            self.cardView.transform = .identity
        }
    }

    func hideAnimated(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn, animations: {
            self.alpha = 0
        }) { _ in
            completion?()
        }
    }

    // MARK: - Actions

    @objc private func actionTapped() {
        onAction?()
    }
}

// MARK: - NSLayoutConstraint Priority Helper

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
