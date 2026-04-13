//
//  CandidateCardView.swift
//  OpenMDict-iOS
//
//  M14 Word Tinder: Single candidate card with swipe direction stamp.
//  InsetGrouped-style flat card (not a full-screen photo card).
//

import UIKit

@available(iOS 26, *)
final class CandidateCardView: UIView {

    // MARK: - Public

    let word: String

    // MARK: - Subviews

    private let wordLabel = UILabel()
    private let iconView = UIImageView()

    /// Directional stamp (like Tinder's "LIKE" / "NOPE"), hidden by default.
    private let synonymStamp = StampLabel(text: "SYNONYM", color: .systemIndigo, angle: -.pi / 12)
    private let antonymStamp = StampLabel(text: "ANTONYM", color: .systemOrange, angle: .pi / 12)
    private let irrelevantStamp = StampLabel(text: "IRRELEVANT", color: .secondaryLabel, angle: 0)

    // MARK: - Init

    init(word: String) {
        self.word = word
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupUI() {
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        layer.borderWidth = 1.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        clipsToBounds = false
        updateBorderColor()

        // Icon (leading)
        iconView.image = UIImage(systemName: "questionmark.diamond")
        iconView.tintColor = .tertiaryLabel
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(iconView)

        // Word label
        wordLabel.text = word
        wordLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        wordLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wordLabel)

        // Stamps (initially hidden)
        for stamp in [synonymStamp, antonymStamp, irrelevantStamp] {
            stamp.translatesAutoresizingMaskIntoConstraints = false
            stamp.alpha = 0
            addSubview(stamp)
            NSLayoutConstraint.activate([
                stamp.centerXAnchor.constraint(equalTo: centerXAnchor),
                stamp.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),

            wordLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            wordLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            wordLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 96),
        ])
    }

    // MARK: - Swipe Feedback

    enum SwipeDirection {
        case right   // synonym
        case left    // antonym
        case up      // irrelevant
    }

    /// Update directional stamp visibility based on swipe progress.
    /// `progress` should be 0...1 (clamped). Only the relevant stamp is shown.
    func updateSwipeFeedback(direction: SwipeDirection, progress: CGFloat) {
        let p = min(max(progress, 0), 1)
        synonymStamp.alpha = direction == .right ? p : 0
        antonymStamp.alpha = direction == .left ? p : 0
        irrelevantStamp.alpha = direction == .up ? p : 0

        // Border color feedback
        let borderColor: UIColor
        switch direction {
        case .right: borderColor = .systemIndigo
        case .left:  borderColor = .systemOrange
        case .up:    borderColor = .secondaryLabel
        }
        // Grow border from default 1.5pt to 3.5pt as drag progresses
        layer.borderWidth = 1.5 + p * 2
        layer.borderColor = borderColor.withAlphaComponent(max(p, 0.15)).cgColor

        // Tint card background with low-saturation direction color.
        // Overlay the tint color at low opacity on top of the base bg.
        let tintAlpha = p * 0.12  // very subtle: max 12% at full drag
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        borderColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        var br: CGFloat = 0, bg2: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        UIColor.secondarySystemGroupedBackground.getRed(&br, green: &bg2, blue: &bb, alpha: &ba)
        backgroundColor = UIColor(
            red: br * (1 - tintAlpha) + r * tintAlpha,
            green: bg2 * (1 - tintAlpha) + g * tintAlpha,
            blue: bb * (1 - tintAlpha) + b * tintAlpha,
            alpha: 1
        )
    }

    /// Reset all stamps, border, and background tint.
    func resetSwipeFeedback() {
        backgroundColor = .secondarySystemGroupedBackground
        synonymStamp.alpha = 0
        antonymStamp.alpha = 0
        irrelevantStamp.alpha = 0
        layer.borderWidth = 1.5
        updateBorderColor()
    }

    // MARK: - Dynamic border color

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateBorderColor()
        }
    }

    private func updateBorderColor() {
        layer.borderColor = UIColor.systemGray2.cgColor
    }
}

// MARK: - StampLabel

/// Rotated text stamp, like Tinder's "LIKE" / "NOPE" overlays.
private final class StampLabel: UIView {
    init(text: String, color: UIColor, angle: CGFloat) {
        super.init(frame: .zero)

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 24, weight: .heavy)
        label.textColor = color
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        layer.borderWidth = 3
        layer.borderColor = color.cgColor
        layer.cornerRadius = 6

        // Padding: label inset inside border
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        transform = CGAffineTransform(rotationAngle: angle)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }
}
