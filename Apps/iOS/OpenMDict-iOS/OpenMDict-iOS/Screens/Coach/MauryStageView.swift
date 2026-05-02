//
//  MauryStageView.swift
//  OpenMDict-iOS
//
//  M14 Morpheme Maury: Background stage set — deep purple gradient
//  evoking a daytime-TV talk-show set, with red velvet curtain strips
//  flanking the sides and a soft warm spotlight glow in the center.
//
//  The spotlight center can be moved programmatically (e.g. when a new
//  guest takes the stage, the beam follows them).
//

import UIKit

@available(iOS 26, *)
final class MauryStageView: UIView {

    // MARK: - Layers

    private let bgGradient = CAGradientLayer()
    private let spotlight = CAGradientLayer()   // radial warm glow
    private let leftCurtain = UIView()
    private let rightCurtain = UIView()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupLayers() {
        // ── Background: deep purple vertical gradient ────────────────
        // Plum on top, darker wine at the bottom — feels like a stage
        // proscenium seen from audience level.
        bgGradient.colors = [
            UIColor(red: 0.26, green: 0.06, blue: 0.30, alpha: 1).cgColor,  // plum
            UIColor(red: 0.14, green: 0.03, blue: 0.18, alpha: 1).cgColor,  // deep wine
        ]
        bgGradient.locations = [0, 1]
        layer.addSublayer(bgGradient)

        // ── Spotlight: radial warm glow (champagne → transparent) ────
        spotlight.type = .radial
        spotlight.colors = [
            UIColor(red: 1.0, green: 0.93, blue: 0.68, alpha: 0.22).cgColor,
            UIColor(red: 1.0, green: 0.88, blue: 0.50, alpha: 0.08).cgColor,
            UIColor.clear.cgColor,
        ]
        spotlight.locations = [0, 0.35, 1.0]
        layer.addSublayer(spotlight)

        // ── Curtains: red velvet strips on left + right ──────────────
        [leftCurtain, rightCurtain].forEach {
            $0.backgroundColor = UIColor(red: 0.58, green: 0.08, blue: 0.12, alpha: 1)
            $0.layer.cornerRadius = 8
            addSubview($0)
            addVelvetGathers(to: $0)
        }
    }

    /// Add vertical darker stripes to simulate velvet gathering.
    private func addVelvetGathers(to curtain: UIView) {
        let stripeCount = 4
        for i in 0..<stripeCount {
            let stripe = CAGradientLayer()
            stripe.startPoint = CGPoint(x: 0, y: 0.5)
            stripe.endPoint = CGPoint(x: 1, y: 0.5)
            // Dark → lighter → dark gradient across each stripe = gather shadow
            stripe.colors = [
                UIColor(white: 0, alpha: 0.35).cgColor,
                UIColor(white: 0, alpha: 0).cgColor,
                UIColor(white: 0, alpha: 0.35).cgColor,
            ]
            stripe.locations = [0, 0.5, 1]
            stripe.name = "gather-\(i)"
            curtain.layer.addSublayer(stripe)
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        bgGradient.frame = bounds
        spotlight.frame = bounds
        // Default spotlight: upper-center of the stage
        spotlight.startPoint = spotlightCenter
        spotlight.endPoint = CGPoint(
            x: spotlightCenter.x + 0.55, y: spotlightCenter.y + 0.55)

        let curtainWidth: CGFloat = min(48, bounds.width * 0.12)
        leftCurtain.frame = CGRect(
            x: -4, y: -4, width: curtainWidth, height: bounds.height + 8)
        rightCurtain.frame = CGRect(
            x: bounds.width - curtainWidth + 4, y: -4,
            width: curtainWidth, height: bounds.height + 8)

        layoutGathers(on: leftCurtain)
        layoutGathers(on: rightCurtain)
    }

    private func layoutGathers(on curtain: UIView) {
        let gathers = curtain.layer.sublayers?.compactMap { $0 as? CAGradientLayer } ?? []
        guard !gathers.isEmpty else { return }
        let stripeWidth = curtain.bounds.width / CGFloat(gathers.count)
        for (i, stripe) in gathers.enumerated() {
            stripe.frame = CGRect(
                x: CGFloat(i) * stripeWidth,
                y: 0,
                width: stripeWidth,
                height: curtain.bounds.height)
        }
    }

    // MARK: - Spotlight Control

    /// Normalized 0...1 coordinates within the stage view.
    /// (0.5, 0.35) places the beam's focal point roughly where a standing
    /// guest's face would be.
    var spotlightCenter: CGPoint = CGPoint(x: 0.5, y: 0.35) {
        didSet { setNeedsLayout() }
    }

    /// Smoothly move the spotlight — call when a new guest takes the stage.
    func animateSpotlight(to center: CGPoint, duration: TimeInterval = 0.5) {
        let animation = CABasicAnimation(keyPath: "startPoint")
        animation.fromValue = spotlight.startPoint
        animation.toValue = center
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        spotlight.add(animation, forKey: "spot-move")
        spotlight.startPoint = center
        spotlight.endPoint = CGPoint(x: center.x + 0.55, y: center.y + 0.55)
        spotlightCenter = center
    }
}
