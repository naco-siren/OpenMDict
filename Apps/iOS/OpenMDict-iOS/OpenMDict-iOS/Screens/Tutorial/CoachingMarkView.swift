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

    // State
    private var currentConfig: Configuration?

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
        NSLayoutConstraint.activate([
            messageLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: p),
            messageLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: p),
            messageLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -p),

            stepLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            stepLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: p),
            stepLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -p),

            actionButton.centerYAnchor.constraint(equalTo: stepLabel.centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -p),
            actionButton.leadingAnchor.constraint(greaterThanOrEqualTo: stepLabel.trailingAnchor, constant: 12),
        ])
    }

    // MARK: - Configure

    func configure(with config: Configuration) {
        currentConfig = config
        messageLabel.text = config.message
        actionButton.setTitle(config.buttonTitle, for: .normal)
        stepLabel.text = config.stepText
        stepLabel.isHidden = config.stepText == nil

        setNeedsLayout()
        layoutIfNeeded()
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
