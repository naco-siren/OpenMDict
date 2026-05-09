//
//  FeudCardView.swift
//  OpenMDict-iOS
//
//  Single answer card. Two visual states share THE SAME internal layout:
//  outer white border (regular) + 4pt gap + inner light-gray border
//  (thin), divided by a thin white vertical line that runs edge-to-edge
//  of the inner border.
//
//  The right-side score box is a hardcoded square (`scoreSize × scoreSize`,
//  passed in at init), pinned top + bottom to the inner border. That
//  forces innerBorder.height = scoreSize and therefore card.height =
//  scoreSize + 8 — a fixed value, independent of card.width. The left
//  answer area then takes whatever width remains (no explicit width
//  constraint, "weight = 1f" semantics).
//
//  Each split half carries a vertical 3-stop gradient. The trick to make
//  CAGradientLayer cooperate with Auto Layout: don't add a CAGradientLayer
//  as a sublayer (it would need manual frame syncing in `layoutSubviews`,
//  which is fragile when the view's frame changes mid-layout). Instead,
//  use a UIView subclass that sets `class var layerClass = CAGradientLayer.self`,
//  so the gradient IS the view's primary layer and resizes automatically.
//
//  States only differ in whether the labels are populated:
//    .blank     → empty labels, gradient bands still visible
//    .revealed  → answer + score painted in
//

import UIKit

@available(iOS 26, *)
final class FeudCardView: UIView {

    // MARK: - State

    nonisolated enum CardState: Equatable, Sendable {
        case blank
        case revealed(answer: String, score: Int)
    }

    // MARK: - Gradient sub-view

    /// UIView subclass whose backing layer IS a CAGradientLayer. Avoids
    /// the manual `gradientLayer.frame = view.bounds` dance in
    /// `layoutSubviews`, which is the root cause of "gradient renders as
    /// solid color" bugs (a 0×0 layer doesn't paint anything; the dance
    /// to correct it is racy with autolayout).
    final class GradientView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        var gradient: CAGradientLayer { layer as! CAGradientLayer }

        convenience init(stops: [UIColor]) {
            self.init(frame: .zero)
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradient.colors = stops.map { $0.cgColor }
        }
    }

    // MARK: - UI

    private let innerBorder = UIView()
    private let leftArea = GradientView(stops: [
        FeudPalette.gradientDeep,
        FeudPalette.gradientMid,
        FeudPalette.gradientDeep,
    ])
    private let rightArea = GradientView(stops: [
        FeudPalette.gradientMid,
        FeudPalette.gradientBright,
        FeudPalette.gradientMid,
    ])
    private let divider = UIView()
    private let answerLabel = UILabel()
    private let scoreLabel = UILabel()

    private let leftAreaGuide = UILayoutGuide()
    private let rightAreaGuide = UILayoutGuide()

    // MARK: - State

    private let scoreSize: CGFloat

    // MARK: - Init

    init(scoreSize: CGFloat) {
        self.scoreSize = scoreSize
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        // Outer card: white regular border, transparent inside (the inner
        // card holds the gradients, offset by 4pt = the "padding").
        backgroundColor = .clear
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 2
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true

        // Inner card: light-gray thin border (the outer border
        // is white, this is one step softer for visual hierarchy).
        innerBorder.translatesAutoresizingMaskIntoConstraints = false
        innerBorder.layer.borderColor = UIColor.lightGray.cgColor
        innerBorder.layer.borderWidth = 1
        innerBorder.layer.cornerRadius = 4
        innerBorder.layer.cornerCurve = .continuous
        innerBorder.clipsToBounds = true
        addSubview(innerBorder)

        // 5:1 split via layout guides — exact widths, no fragile multipliers.
        innerBorder.addLayoutGuide(leftAreaGuide)
        innerBorder.addLayoutGuide(rightAreaGuide)

        leftArea.translatesAutoresizingMaskIntoConstraints = false
        rightArea.translatesAutoresizingMaskIntoConstraints = false
        innerBorder.addSubview(leftArea)
        innerBorder.addSubview(rightArea)

        // Vertical divider — thin white line, top-to-bottom of inner border
        // (no inset, runs edge-to-edge).
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .white
        innerBorder.addSubview(divider)

        // Labels
        answerLabel.translatesAutoresizingMaskIntoConstraints = false
        answerLabel.font = FeudPalette.answerFont(size: 22)
        answerLabel.textColor = .white
        answerLabel.numberOfLines = 1
        answerLabel.adjustsFontSizeToFitWidth = true
        answerLabel.minimumScaleFactor = 0.5
        answerLabel.lineBreakMode = .byTruncatingTail
        answerLabel.textAlignment = .center
        leftArea.addSubview(answerLabel)

        scoreLabel.translatesAutoresizingMaskIntoConstraints = false
        scoreLabel.font = FeudPalette.numberFont(size: 22)
        scoreLabel.textColor = .white
        scoreLabel.textAlignment = .center
        rightArea.addSubview(scoreLabel)

        NSLayoutConstraint.activate([
            // Inner border: 4pt padding from outer card
            innerBorder.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            innerBorder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            innerBorder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            innerBorder.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            // RIGHT score box: hardcoded scoreSize × scoreSize square.
            // Pinning top + bottom to innerBorder forces innerBorder.height
            // = scoreSize, which makes card.height = scoreSize + 8 — a
            // fixed value, independent of card.width.
            rightAreaGuide.widthAnchor.constraint(equalToConstant: scoreSize),
            rightAreaGuide.heightAnchor.constraint(equalToConstant: scoreSize),
            rightAreaGuide.trailingAnchor.constraint(equalTo: innerBorder.trailingAnchor),
            rightAreaGuide.topAnchor.constraint(equalTo: innerBorder.topAnchor),
            rightAreaGuide.bottomAnchor.constraint(equalTo: innerBorder.bottomAnchor),

            // LEFT answer area: fills whatever width is left of the score
            // box ("weight = 1f" semantics — no explicit width constraint,
            // just leading + trailing anchors).
            leftAreaGuide.leadingAnchor.constraint(equalTo: innerBorder.leadingAnchor),
            leftAreaGuide.topAnchor.constraint(equalTo: innerBorder.topAnchor),
            leftAreaGuide.bottomAnchor.constraint(equalTo: innerBorder.bottomAnchor),
            leftAreaGuide.trailingAnchor.constraint(equalTo: rightAreaGuide.leadingAnchor),

            // Gradient views fill their respective guides
            leftArea.leadingAnchor.constraint(equalTo: leftAreaGuide.leadingAnchor),
            leftArea.trailingAnchor.constraint(equalTo: leftAreaGuide.trailingAnchor),
            leftArea.topAnchor.constraint(equalTo: leftAreaGuide.topAnchor),
            leftArea.bottomAnchor.constraint(equalTo: leftAreaGuide.bottomAnchor),

            rightArea.leadingAnchor.constraint(equalTo: rightAreaGuide.leadingAnchor),
            rightArea.trailingAnchor.constraint(equalTo: rightAreaGuide.trailingAnchor),
            rightArea.topAnchor.constraint(equalTo: rightAreaGuide.topAnchor),
            rightArea.bottomAnchor.constraint(equalTo: rightAreaGuide.bottomAnchor),

            // Divider on the boundary, edge-to-edge
            divider.leadingAnchor.constraint(equalTo: leftAreaGuide.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: innerBorder.topAnchor),
            divider.bottomAnchor.constraint(equalTo: innerBorder.bottomAnchor),

            // Answer label inset within left area — symmetric padding so
            // center-aligned text sits visually centered in the gradient.
            answerLabel.leadingAnchor.constraint(equalTo: leftArea.leadingAnchor, constant: 14),
            answerLabel.trailingAnchor.constraint(equalTo: leftArea.trailingAnchor, constant: -14),
            answerLabel.centerYAnchor.constraint(equalTo: leftArea.centerYAnchor),

            // Score label centered in right area
            scoreLabel.centerXAnchor.constraint(equalTo: rightArea.centerXAnchor),
            scoreLabel.centerYAnchor.constraint(equalTo: rightArea.centerYAnchor),
            scoreLabel.leadingAnchor.constraint(greaterThanOrEqualTo: rightArea.leadingAnchor, constant: 4),
            scoreLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightArea.trailingAnchor, constant: -4),
        ])
    }

    // MARK: - State

    func apply(_ state: CardState) {
        switch state {
        case .blank:
            answerLabel.text = nil
            scoreLabel.text = nil
        case .revealed(let answer, let score):
            answerLabel.text = answer.uppercased()
            scoreLabel.text = "\(score)"
        }
    }
}
