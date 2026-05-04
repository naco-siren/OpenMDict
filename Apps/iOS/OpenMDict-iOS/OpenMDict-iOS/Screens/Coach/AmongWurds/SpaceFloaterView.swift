//
//  SpaceFloaterView.swift
//  OpenMDict-iOS
//
//  M14 Among wUrdS: Background layer simulating zero-G space for ejected
//  cards. Each ejected card becomes a FloatingCardView with:
//  - Linear drift (random dx/dy) — no external forces, constant velocity
//  - Continuous rotation at a random angular velocity
//  - Fixed scale + alpha representing distance from viewer (smaller=dimmer)
//
//  When floaters drift off-screen they wrap around so they remain visible.
//  A single CADisplayLink drives all floaters at 60/120fps.
//

import UIKit

@available(iOS 26, *)
final class SpaceFloaterView: UIView {

    // MARK: - Floater

    /// One ejected card floating in space.
    private final class Floater {
        weak var view: UIView?
        var position: CGPoint
        var velocity: CGVector     // pt / frame
        var rotation: CGFloat
        var rotationSpeed: CGFloat // rad / frame
        let scale: CGFloat
        let alpha: CGFloat
        let word: String

        init(view: UIView, position: CGPoint, velocity: CGVector,
             rotation: CGFloat, rotationSpeed: CGFloat,
             scale: CGFloat, alpha: CGFloat, word: String) {
            self.view = view
            self.position = position
            self.velocity = velocity
            self.rotation = rotation
            self.rotationSpeed = rotationSpeed
            self.scale = scale
            self.alpha = alpha
            self.word = word
        }
    }

    // MARK: - State

    private var floaters: [Floater] = []
    private var displayLink: CADisplayLink?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false  // never intercept taps
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    /// Spawn a new floating card with randomized physics state.
    /// Called when the user ejects a word — the card joins the space debris.
    func addFloater(word: String, crewColor: UIColor, fromRect: CGRect? = nil) {
        // ── Randomized physics ──────────────────────────────────────
        // Slow drift at ~20-60 pt/sec (60fps → 0.33-1.0 pt/frame).
        let dx = CGFloat.random(in: -1.0...1.0)
        let dy = CGFloat.random(in: -1.0...1.0)
        // Gentle spin, ~0.3-1.7 rad/sec.
        let rotationSpeed = CGFloat.random(in: -0.028...0.028)
        // Scale represents distance: 0.35 (far) to 0.65 (closer).
        let scale = CGFloat.random(in: 0.35...0.65)
        // Alpha derived from scale — smaller = dimmer = more distant.
        let alpha: CGFloat = 0.28 + (scale - 0.35) * 1.1

        // Starting point: prefer the location the card was ejected from,
        // otherwise random within view bounds.
        let startX: CGFloat
        let startY: CGFloat
        if let rect = fromRect, bounds.width > 0 {
            startX = rect.midX
            startY = rect.midY
        } else if bounds.width > 0 {
            startX = CGFloat.random(in: 0...bounds.width)
            startY = CGFloat.random(in: 0...bounds.height)
        } else {
            startX = 100; startY = 100
        }
        let initialRotation = CGFloat.random(in: -.pi...(.pi))

        // ── Card view ───────────────────────────────────────────────
        let card = makeFloaterCard(word: word, crewColor: crewColor)
        card.alpha = alpha
        // Size: 160×64 base (roughly the in-grid cell size), scaled.
        let size = CGSize(width: 160 * scale, height: 64 * scale)
        card.frame = CGRect(origin: .zero, size: size)
        card.center = CGPoint(x: startX, y: startY)
        card.transform = CGAffineTransform(rotationAngle: initialRotation)
        addSubview(card)

        let floater = Floater(
            view: card,
            position: card.center,
            velocity: CGVector(dx: dx, dy: dy),
            rotation: initialRotation,
            rotationSpeed: rotationSpeed,
            scale: scale,
            alpha: alpha,
            word: word
        )
        floaters.append(floater)

        // Ensure physics loop is running
        startDisplayLink()
    }

    /// Remove all floaters and stop the physics loop.
    func clear() {
        for f in floaters {
            f.view?.removeFromSuperview()
        }
        floaters.removeAll()
        stopDisplayLink()
    }

    /// Pause without removing floaters (e.g. on viewWillDisappear).
    func pause() {
        stopDisplayLink()
    }

    /// Resume physics.
    func resume() {
        guard !floaters.isEmpty else { return }
        startDisplayLink()
    }

    // MARK: - Physics Loop

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        for floater in floaters {
            guard let view = floater.view else { continue }

            // Advance position + rotation
            floater.position.x += floater.velocity.dx
            floater.position.y += floater.velocity.dy
            floater.rotation += floater.rotationSpeed

            // Wrap around when off-screen (torus topology — always visible)
            let margin: CGFloat = 100
            if floater.position.x < -margin {
                floater.position.x = bounds.width + margin
            } else if floater.position.x > bounds.width + margin {
                floater.position.x = -margin
            }
            if floater.position.y < -margin {
                floater.position.y = bounds.height + margin
            } else if floater.position.y > bounds.height + margin {
                floater.position.y = -margin
            }

            view.center = floater.position
            view.transform = CGAffineTransform(rotationAngle: floater.rotation)
        }
    }

    // MARK: - Card Builder

    /// Build a compact floating card styled to evoke the crew identity
    /// without the full game-card chrome (no borders, no stamps).
    private func makeFloaterCard(word: String, crewColor: UIColor) -> UIView {
        let card = UIView()
        card.backgroundColor = crewColor.withAlphaComponent(0.45)
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true

        let label = UILabel()
        label.text = word
        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -6),
        ])
        return card
    }
}
