//
//  CircularProgressView.swift
//  OpenMDict-iOS
//
//  Circular progress ring indicator (App Store download style).
//  Draws a track circle + filled arc using CAShapeLayer.
//

import UIKit

final class CircularProgressView: UIView {

    // MARK: - Public

    /// Progress value from 0.0 to 1.0.
    var progress: CGFloat = 0 {
        didSet { updateProgress() }
    }

    /// Track (background circle) color.
    var trackColor: UIColor = .tertiarySystemFill {
        didSet { trackLayer.strokeColor = trackColor.cgColor }
    }

    /// Filled arc color.
    var progressColor: UIColor = .tintColor {
        didSet { progressLayer.strokeColor = progressColor.cgColor }
    }

    /// Line width of the ring.
    var lineWidth: CGFloat = 3 {
        didSet {
            trackLayer.lineWidth = lineWidth
            progressLayer.lineWidth = lineWidth
            setNeedsLayout()
        }
    }

    // MARK: - Layers

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Track
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = trackColor.cgColor
        trackLayer.lineWidth = lineWidth
        trackLayer.lineCap = .round
        layer.addSublayer(trackLayer)

        // Progress arc
        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.strokeColor = progressColor.cgColor
        progressLayer.lineWidth = lineWidth
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        layer.addSublayer(progressLayer)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = (min(bounds.width, bounds.height) - lineWidth) / 2
        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: -.pi / 2,          // 12 o'clock
            endAngle: .pi * 3 / 2,         // full circle clockwise
            clockwise: true
        )

        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
        trackLayer.lineWidth = lineWidth
        progressLayer.lineWidth = lineWidth
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: 24, height: 24)
    }

    // MARK: - Private

    private func updateProgress() {
        // Disable implicit animation for real-time updates
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.strokeEnd = min(max(progress, 0), 1)
        CATransaction.commit()
    }
}
