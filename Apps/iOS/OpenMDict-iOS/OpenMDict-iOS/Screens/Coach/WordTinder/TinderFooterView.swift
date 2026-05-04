//
//  TinderFooterView.swift
//  OpenMDict-iOS
//
//  M14 Word Tinder: Three circular buttons in "∴" (therefore) layout.
//  Left = Antonym (orange, minus), Center-raised = Irrelevant (gray, asterisk),
//  Right = Synonym (indigo, plus). Buttons animate from white-bg/colored-icon
//  to colored-bg/white-icon as the user drags a card toward that direction.
//

import UIKit

@available(iOS 26, *)
protocol TinderFooterViewDelegate: AnyObject {
    func tinderFooter(_ footer: TinderFooterView, didTap direction: CandidateCardView.SwipeDirection)
}

@available(iOS 26, *)
final class TinderFooterView: UIView {

    weak var delegate: TinderFooterViewDelegate?

    // MARK: - Buttons

    private let antonymButton = TinderCircleButton(
        iconName: "minus",
        color: .systemOrange,
        diameter: 75
    )
    private let irrelevantButton = TinderCircleButton(
        iconName: "asterisk",
        color: .secondaryLabel,
        diameter: 60
    )
    private let synonymButton = TinderCircleButton(
        iconName: "plus",
        color: .systemIndigo,
        diameter: 75
    )

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupUI() {
        // "∴" layout: antonym (left), irrelevant (center-raised), synonym (right)
        for btn in [antonymButton, irrelevantButton, synonymButton] {
            btn.translatesAutoresizingMaskIntoConstraints = false
            addSubview(btn)
        }

        antonymButton.addTarget(self, action: #selector(antonymTapped), for: .touchUpInside)
        irrelevantButton.addTarget(self, action: #selector(irrelevantTapped), for: .touchUpInside)
        synonymButton.addTarget(self, action: #selector(synonymTapped), for: .touchUpInside)

        let raisedOffset: CGFloat = -18  // irrelevant floats up

        NSLayoutConstraint.activate([
            // Height for the container
            heightAnchor.constraint(equalToConstant: 100),

            // Antonym: left, vertically centered
            antonymButton.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -95),
            antonymButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Irrelevant: center, raised
            irrelevantButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            irrelevantButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: raisedOffset),

            // Synonym: right, vertically centered
            synonymButton.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 95),
            synonymButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func antonymTapped() {
        delegate?.tinderFooter(self, didTap: .left)
    }

    @objc private func irrelevantTapped() {
        delegate?.tinderFooter(self, didTap: .up)
    }

    @objc private func synonymTapped() {
        delegate?.tinderFooter(self, didTap: .right)
    }

    // MARK: - Highlight Animation

    /// Update button highlights based on swipe direction and progress.
    func updateHighlight(direction: CandidateCardView.SwipeDirection, progress: CGFloat) {
        antonymButton.setHighlight(direction == .left ? progress : 0)
        irrelevantButton.setHighlight(direction == .up ? progress : 0)
        synonymButton.setHighlight(direction == .right ? progress : 0)
    }

    /// Reset all buttons to unhighlighted state.
    func resetHighlight() {
        antonymButton.setHighlight(0)
        irrelevantButton.setHighlight(0)
        synonymButton.setHighlight(0)
    }
}

// MARK: - TinderCircleButton

/// Circular button that transitions from white-bg/colored-icon to
/// colored-bg/white-icon based on a 0→1 highlight progress.
private final class TinderCircleButton: UIButton {

    private let accentColor: UIColor
    private let diameter: CGFloat

    init(iconName: String, color: UIColor, diameter: CGFloat) {
        self.accentColor = color
        self.diameter = diameter
        super.init(frame: .zero)

        setImage(UIImage(systemName: iconName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: diameter * 0.45)),
                 for: .normal)
        tintColor = color
        backgroundColor = .systemBackground
        layer.cornerRadius = diameter / 2
        layer.borderWidth = 1.5
        layer.borderColor = color.withAlphaComponent(0.3).cgColor

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.1
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Animate highlight: 0 = white bg + colored icon, 1 = colored bg + white icon
    func setHighlight(_ progress: CGFloat) {
        let p = min(max(progress, 0), 1)
        backgroundColor = accentColor.withAlphaComponent(p).blended(with: .systemBackground, fraction: 1 - p)
        tintColor = UIColor.white.withAlphaComponent(p).blended(with: accentColor, fraction: 1 - p)
        let scale = 1.0 + p * 0.35  // Dock-style magnification (up to 135%)
        transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

// MARK: - UIColor blending helper

private extension UIColor {
    func blended(with other: UIColor, fraction: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let f = min(max(fraction, 0), 1)
        return UIColor(
            red: r1 * (1 - f) + r2 * f,
            green: g1 * (1 - f) + g2 * f,
            blue: b1 * (1 - f) + b2 * f,
            alpha: a1 * (1 - f) + a2 * f
        )
    }
}
