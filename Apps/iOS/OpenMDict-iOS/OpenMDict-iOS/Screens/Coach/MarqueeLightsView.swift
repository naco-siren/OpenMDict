//
//  MarqueeLightsView.swift
//  OpenMDict-iOS
//
//  M14 Morpheme Maury: perimeter of alternating light bulbs around the
//  screen edge, evoking old-school TV game-show marquees.
//
//  Two-color palette cycles every 0.6s (🟣🟡🟣🟡 ↔ 🟡🟣🟡🟣), giving the
//  classic chase / flash illusion.
//
//  Palettes:
//  - `.idle`  — purple / yellow (default, always on during the show)
//  - `.correct` — green / white (reveal: user judged correctly)
//  - `.wrong` — red / white   (reveal: user was wrong)
//

import UIKit

@available(iOS 26, *)
final class MarqueeLightsView: UIView {

    // MARK: - Palette

    struct Palette: Equatable {
        let colorA: UIColor
        let colorB: UIColor
        /// Optional glow ring color (for the "on" half). nil = no glow.
        let glow: UIColor?
    }

    // MARK: - State

    /// Bulb radius in points.
    private let bulbRadius: CGFloat = 6
    /// Target center-to-center spacing along a straight edge.
    private let spacing: CGFloat = 22

    private var bulbs: [CAShapeLayer] = []
    private var phase: Bool = false  // flips every tick → alternation swap
    private var timer: Timer?

    var palette: Palette = .idle {
        didSet { if palette != oldValue { applyColors() } }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        rebuildBulbs()
    }

    /// Regenerate bulb layers sized/placed for the current bounds.
    private func rebuildBulbs() {
        bulbs.forEach { $0.removeFromSuperlayer() }
        bulbs.removeAll()

        let inset: CGFloat = bulbRadius + 4
        let rect = bounds.insetBy(dx: inset, dy: inset)

        // Generate points along the perimeter: top, right, bottom, left.
        // We want evenly spaced bulbs with corner bulbs included.
        var points: [CGPoint] = []

        // Top edge — left to right
        let topCount = max(2, Int(rect.width / spacing))
        for i in 0...topCount {
            let t = CGFloat(i) / CGFloat(topCount)
            points.append(CGPoint(x: rect.minX + t * rect.width, y: rect.minY))
        }
        // Right edge — top to bottom (skip first to avoid duplicate corner)
        let rightCount = max(2, Int(rect.height / spacing))
        for i in 1...rightCount {
            let t = CGFloat(i) / CGFloat(rightCount)
            points.append(CGPoint(x: rect.maxX, y: rect.minY + t * rect.height))
        }
        // Bottom edge — right to left
        let bottomCount = max(2, Int(rect.width / spacing))
        for i in 1...bottomCount {
            let t = CGFloat(i) / CGFloat(bottomCount)
            points.append(CGPoint(x: rect.maxX - t * rect.width, y: rect.maxY))
        }
        // Left edge — bottom to top (skip first AND last to avoid corner dup)
        let leftCount = max(2, Int(rect.height / spacing))
        for i in 1..<leftCount {
            let t = CGFloat(i) / CGFloat(leftCount)
            points.append(CGPoint(x: rect.minX, y: rect.maxY - t * rect.height))
        }

        for p in points {
            let bulb = CAShapeLayer()
            let path = UIBezierPath(
                arcCenter: .zero, radius: bulbRadius,
                startAngle: 0, endAngle: .pi * 2, clockwise: true)
            bulb.path = path.cgPath
            bulb.position = p
            bulb.shadowColor = UIColor.white.cgColor
            bulb.shadowOffset = .zero
            bulb.shadowRadius = 6
            bulb.shadowOpacity = 0.8
            layer.addSublayer(bulb)
            bulbs.append(bulb)
        }

        applyColors()
    }

    // MARK: - Start / Stop

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase.toggle()
            self.applyColors(animated: true)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Color Application

    private func applyColors(animated: Bool = false) {
        let duration: CFTimeInterval = animated ? 0.2 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        for (i, bulb) in bulbs.enumerated() {
            // Alternate A/B; flip with `phase`
            let isA = ((i % 2 == 0) != phase)
            let color = isA ? palette.colorA : palette.colorB
            bulb.fillColor = color.cgColor
            if let glow = palette.glow {
                bulb.shadowColor = glow.cgColor
                bulb.shadowOpacity = isA ? 0.95 : 0.4
            } else {
                bulb.shadowColor = color.cgColor
                bulb.shadowOpacity = 0.6
            }
        }
        CATransaction.commit()
    }

    // MARK: - Palettes

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }
}

@available(iOS 26, *)
extension MarqueeLightsView.Palette {
    /// Default — purple + yellow bulbs, classic carnival marquee feel.
    static let idle = MarqueeLightsView.Palette(
        colorA: UIColor(red: 0.70, green: 0.25, blue: 0.85, alpha: 1),   // purple
        colorB: UIColor(red: 1.00, green: 0.85, blue: 0.25, alpha: 1),   // saturated yellow
        glow: UIColor(red: 1.0, green: 0.85, blue: 0.6, alpha: 1)
    )
    /// Reveal — user judged correctly. Gold + white for that Vegas-marquee
    /// "win" feel. Warmer than cold green; matches daytime-TV celebratory vibe.
    static let correct = MarqueeLightsView.Palette(
        colorA: UIColor(red: 1.00, green: 0.80, blue: 0.20, alpha: 1),   // rich gold
        colorB: UIColor.white,
        glow: UIColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1)
    )
    /// Reveal — user was wrong. All-red "warning buzzer" — no cool-tone
    /// whites to break the alarm feel; just bright red alternating with
    /// dim red for the classic "lose" pulse.
    static let wrong = MarqueeLightsView.Palette(
        colorA: UIColor(red: 0.98, green: 0.18, blue: 0.22, alpha: 1),   // siren red
        colorB: UIColor(red: 0.55, green: 0.06, blue: 0.10, alpha: 1),   // dim blood red
        glow: UIColor(red: 1.0, green: 0.25, blue: 0.3, alpha: 1)
    )
}
