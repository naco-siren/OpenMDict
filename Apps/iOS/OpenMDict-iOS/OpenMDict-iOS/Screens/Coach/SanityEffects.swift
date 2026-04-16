//
//  SanityEffects.swift
//  OpenMDict-iOS
//
//  M14: Data-driven SAN deterioration effect system for Among wUrdS.
//
//  Effect channels:
//  - Vignette: red radial gradient at screen edges, tightening inward
//  - Shake: random micro-transforms on the content view
//  - Screen dim: black overlay darkening everything
//  - Heartbeat: periodic alpha pulse at escalating frequency
//  - Chromatic aberration: red/cyan color strips on opposite edges
//
//  To add new channels: add field to SanityTier, implement in renderer,
//  update tiers table. Existing code doesn't break.
//

import UIKit

// MARK: - Effect Parameters

nonisolated struct VignetteParams: Sendable {
    let size: Double    // 1...3: how far inward the red reaches
    let dim: Double     // 1...3: edge alpha intensity
    static let zero = VignetteParams(size: 0, dim: 0)
}

nonisolated struct ShakeParams: Sendable {
    let intensity: Double  // 1...5
    static let zero = ShakeParams(intensity: 0)
}

nonisolated struct SanityTier: Sendable {
    let vignette: VignetteParams
    let shake: ShakeParams
    let screenDim: Double           // 0...0.35
    /// Heartbeat pulse level. 0 = off. Higher = faster + darker pulse.
    /// Continuous (fractional values work): 0.5 = very faint, 1 = slow, 2 = moderate,
    /// 3 = fast, 4 = frantic, 5+ = dying.
    let heartbeat: Double
    /// Chromatic aberration intensity. 0 = off, 1 = subtle, 2 = noticeable, 3 = severe.
    let chromatic: Double

    static let zero = SanityTier(vignette: .zero, shake: .zero, screenDim: 0, heartbeat: 0, chromatic: 0)
}

// MARK: - Tier Table

enum SanityEffects {
    /// 8-stage monotonic escalation. Every channel stays flat or climbs —
    /// never regresses. Later stages push past "maximum" into genuinely
    /// oppressive territory (heartbeat 4+ = frantic, vignette size 3+dim 3
    /// = half-screen blood glow).
    static let tiers: [SanityTier] = [
        // Kill 1: first unease — faint vignette, tiny shake
        SanityTier(vignette: VignetteParams(size: 1, dim: 1),
                   shake: ShakeParams(intensity: 1), screenDim: 0,
                   heartbeat: 0.5, chromatic: 0),
        // Kill 2: growing dread — slow heartbeat begins
        SanityTier(vignette: VignetteParams(size: 1, dim: 2),
                   shake: ShakeParams(intensity: 2), screenDim: 0.05,
                   heartbeat: 1, chromatic: 0),
        // Kill 3: alarming — chromatic aberration appears
        SanityTier(vignette: VignetteParams(size: 2, dim: 2),
                   shake: ShakeParams(intensity: 3), screenDim: 0.10,
                   heartbeat: 1.5, chromatic: 1),
        // Kill 4: sustained panic — heartbeat quickens
        SanityTier(vignette: VignetteParams(size: 2, dim: 3),
                   shake: ShakeParams(intensity: 3), screenDim: 0.15,
                   heartbeat: 2, chromatic: 2),
        // Kill 5: closing in — screen dimming noticeable
        SanityTier(vignette: VignetteParams(size: 3, dim: 3),
                   shake: ShakeParams(intensity: 4), screenDim: 0.20,
                   heartbeat: 2.5, chromatic: 2),
        // Kill 6: full dread
        SanityTier(vignette: VignetteParams(size: 3, dim: 3),
                   shake: ShakeParams(intensity: 4), screenDim: 0.25,
                   heartbeat: 3, chromatic: 3),
        // Kill 7: frantic — heartbeat pounds
        SanityTier(vignette: VignetteParams(size: 3, dim: 3),
                   shake: ShakeParams(intensity: 5), screenDim: 0.30,
                   heartbeat: 4, chromatic: 3),
        // Kill 8: terminal — heart is going to burst
        SanityTier(vignette: VignetteParams(size: 3, dim: 3),
                   shake: ShakeParams(intensity: 5), screenDim: 0.35,
                   heartbeat: 5, chromatic: 3),
    ]
}

// MARK: - Renderer

@available(iOS 26, *)
final class SanityEffectRenderer {

    private let vignetteLayer = CAGradientLayer()
    private let dimOverlay = UIView()
    private let chromaticLeft = UIView()   // red strip on left edge
    private let chromaticRight = UIView()  // cyan strip on right edge
    private let heartbeatOverlay = UIView() // dark purple pulse
    private var displayLink: CADisplayLink?
    private weak var shakeTarget: UIView?
    private weak var vignetteHostView: UIView?
    private weak var hostView: UIView?

    private var currentShakeIntensity: Double = 0
    private var heartbeatTimer: Timer?
    private var currentChromaticWidth: CGFloat = 0

    /// Add all effect layers as FOREGROUND overlays. Call LAST in viewDidLoad.
    func install(on hostView: UIView, shakeView: UIView) {
        self.hostView = hostView
        shakeTarget = shakeView

        // ── Vignette ──
        vignetteLayer.type = .radial
        vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignetteLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        vignetteLayer.locations = [0.5, 0.8, 1.0]
        vignetteLayer.colors = clearColors

        let vignetteView = UIView()
        vignetteView.translatesAutoresizingMaskIntoConstraints = false
        vignetteView.isUserInteractionEnabled = false
        vignetteView.layer.addSublayer(vignetteLayer)
        hostView.addSubview(vignetteView)
        vignetteHostView = vignetteView

        // ── Dim overlay ──
        dimOverlay.translatesAutoresizingMaskIntoConstraints = false
        dimOverlay.isUserInteractionEnabled = false
        dimOverlay.backgroundColor = .black
        dimOverlay.alpha = 0
        hostView.addSubview(dimOverlay)

        // ── Chromatic aberration strips ──
        chromaticLeft.translatesAutoresizingMaskIntoConstraints = false
        chromaticLeft.isUserInteractionEnabled = false
        chromaticLeft.backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
        chromaticLeft.alpha = 0
        hostView.addSubview(chromaticLeft)

        chromaticRight.translatesAutoresizingMaskIntoConstraints = false
        chromaticRight.isUserInteractionEnabled = false
        chromaticRight.backgroundColor = UIColor.cyan.withAlphaComponent(0.12)
        chromaticRight.alpha = 0
        hostView.addSubview(chromaticRight)

        // ── Heartbeat overlay (dark purple pulse) ──
        heartbeatOverlay.translatesAutoresizingMaskIntoConstraints = false
        heartbeatOverlay.isUserInteractionEnabled = false
        // Deep eerie purple — unsettling, not celebratory
        heartbeatOverlay.backgroundColor = UIColor(red: 0.18, green: 0.05, blue: 0.25, alpha: 1)
        heartbeatOverlay.alpha = 0
        hostView.addSubview(heartbeatOverlay)

        chromaticLeftWidth = chromaticLeft.widthAnchor.constraint(equalToConstant: 0)
        chromaticRightWidth = chromaticRight.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            vignetteView.topAnchor.constraint(equalTo: hostView.topAnchor),
            vignetteView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            vignetteView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            vignetteView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),

            dimOverlay.topAnchor.constraint(equalTo: hostView.topAnchor),
            dimOverlay.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            dimOverlay.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            dimOverlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),

            chromaticLeft.topAnchor.constraint(equalTo: hostView.topAnchor),
            chromaticLeft.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            chromaticLeft.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            chromaticLeftWidth!,

            chromaticRight.topAnchor.constraint(equalTo: hostView.topAnchor),
            chromaticRight.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            chromaticRight.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            chromaticRightWidth!,

            heartbeatOverlay.topAnchor.constraint(equalTo: hostView.topAnchor),
            heartbeatOverlay.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            heartbeatOverlay.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            heartbeatOverlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])

        // Ensure all overlays are on top.
        // Heartbeat goes to the BACK of the overlay stack so it pulses
        // under the vignette/chromatic strips (which should stay visible).
        hostView.bringSubviewToFront(heartbeatOverlay)
        hostView.bringSubviewToFront(vignetteView)
        hostView.bringSubviewToFront(dimOverlay)
        hostView.bringSubviewToFront(chromaticLeft)
        hostView.bringSubviewToFront(chromaticRight)
    }

    private var chromaticLeftWidth: NSLayoutConstraint?
    private var chromaticRightWidth: NSLayoutConstraint?

    func updateLayout() {
        if let host = vignetteHostView {
            vignetteLayer.frame = host.bounds
        }
    }

    // MARK: - Apply

    func apply(tier: SanityTier, animated: Bool = true) {
        let dur: TimeInterval = animated ? 0.6 : 0

        // ── Vignette ──
        let locations = mapVignetteLocations(tier.vignette.size)
        let edgeAlpha = mapVignetteDim(tier.vignette.dim)

        CATransaction.begin()
        CATransaction.setAnimationDuration(dur)
        vignetteLayer.locations = locations.map { NSNumber(value: $0) }
        vignetteLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.systemRed.withAlphaComponent(edgeAlpha * 0.3).cgColor,
            UIColor.systemRed.withAlphaComponent(edgeAlpha).cgColor,
        ]
        CATransaction.commit()

        // ── Screen dim ──
        UIView.animate(withDuration: dur) { self.dimOverlay.alpha = tier.screenDim }

        // ── Shake ──
        currentShakeIntensity = mapShakeIntensity(tier.shake.intensity)
        if currentShakeIntensity > 0 { startShake() }

        // ── Heartbeat ──
        applyHeartbeat(tier.heartbeat)

        // ── Chromatic aberration ──
        applyChromatic(tier.chromatic, animated: animated)
    }

    func reset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        vignetteLayer.colors = clearColors
        vignetteLayer.locations = [0.5, 0.8, 1.0].map { NSNumber(value: $0) }
        CATransaction.commit()

        dimOverlay.alpha = 0
        currentShakeIntensity = 0
        stopShake()
        stopHeartbeat()
        resetChromatic()
    }

    func tearDown() {
        stopShake()
        stopHeartbeat()
    }

    // MARK: - Vignette

    private func mapVignetteLocations(_ size: Double) -> [Double] {
        switch size {
        case ...0: return [0.5, 0.8, 1.0]
        case 1:    return [0.5, 0.8, 1.0]
        case 2:    return [0.35, 0.65, 1.0]
        default:   return [0.2, 0.5, 1.0]
        }
    }

    private func mapVignetteDim(_ dim: Double) -> Double {
        switch dim {
        case ...0: return 0
        case 1:    return 0.20
        case 2:    return 0.35
        default:   return 0.50
        }
    }

    // MARK: - Shake

    private func mapShakeIntensity(_ raw: Double) -> Double {
        switch raw {
        case ...0: return 0
        case 1:    return 0.3
        case 2:    return 0.5
        case 3:    return 0.7
        case 4:    return 0.85
        default:   return 1.0
        }
    }

    private func startShake() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(shakeStep))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopShake() {
        displayLink?.invalidate()
        displayLink = nil
        shakeTarget?.transform = .identity
    }

    @objc private func shakeStep() {
        guard let target = shakeTarget else { return }
        let i = currentShakeIntensity
        let rotation = Double.random(in: -0.004...0.004) * i
        let tx = Double.random(in: -1.2...1.2) * i
        let ty = Double.random(in: -0.6...0.6) * i
        target.transform = CGAffineTransform(translationX: tx, y: ty).rotated(by: rotation)
    }

    // MARK: - Heartbeat Pulse

    /// Periodic dark-purple overlay pulse, like a heartbeat getting faster
    /// and more anxious. Uses a dedicated purple overlay (not alpha-fade on
    /// the host) so the pulse reads as eerie, not as a simple dim.
    ///
    /// Continuous mapping (supports fractional levels):
    /// - Interval: level 0.5 → 2.5s, 1 → 2.0s, 2 → 1.2s, 3 → 0.8s, 4 → 0.55s, 5 → 0.40s
    /// - Peak alpha: level 0.5 → 0.08, 1 → 0.13, 3 → 0.25, 5 → 0.42
    private func applyHeartbeat(_ level: Double) {
        stopHeartbeat()
        guard level > 0 else { return }

        // Inverse-ish decay: interval = 2.8 / (1 + 0.55 * level), clamped to 0.35s floor
        let interval = max(0.35, 2.8 / (1.0 + 0.55 * level))
        // Linear growth capped at 0.45: alpha = 0.05 + 0.075 * level
        let peakAlpha: CGFloat = CGFloat(min(0.45, 0.05 + 0.075 * level))

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let overlay = self?.heartbeatOverlay else { return }
            // Two-beat pulse: lub-dub — quick double throb
            UIView.animate(withDuration: 0.10, animations: {
                overlay.alpha = peakAlpha
            }) { _ in
                UIView.animate(withDuration: 0.15, animations: {
                    overlay.alpha = peakAlpha * 0.3
                }) { _ in
                    UIView.animate(withDuration: 0.10, animations: {
                        overlay.alpha = peakAlpha * 0.85
                    }) { _ in
                        UIView.animate(withDuration: interval * 0.5) {
                            overlay.alpha = 0
                        }
                    }
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heartbeatOverlay.alpha = 0
    }

    // MARK: - Chromatic Aberration

    /// Red/cyan color strips on opposite screen edges that widen with intensity.
    private func applyChromatic(_ level: Double, animated: Bool) {
        guard level > 0 else { resetChromatic(); return }

        // Width: level 1 = 6pt, 2 = 14pt, 3 = 24pt
        let width: CGFloat
        switch level {
        case 1:    width = 6
        case 2:    width = 14
        default:   width = 24
        }

        // Alpha: level 1 = 0.12, 2 = 0.20, 3 = 0.30
        let alpha: CGFloat
        switch level {
        case 1:    alpha = 0.12
        case 2:    alpha = 0.20
        default:   alpha = 0.30
        }

        chromaticLeftWidth?.constant = width
        chromaticRightWidth?.constant = width
        chromaticLeft.backgroundColor = UIColor.systemRed.withAlphaComponent(alpha)
        chromaticRight.backgroundColor = UIColor.cyan.withAlphaComponent(alpha * 0.8)

        let dur: TimeInterval = animated ? 0.5 : 0
        UIView.animate(withDuration: dur) {
            self.chromaticLeft.alpha = 1
            self.chromaticRight.alpha = 1
            self.hostView?.layoutIfNeeded()
        }
    }

    private func resetChromatic() {
        chromaticLeft.alpha = 0
        chromaticRight.alpha = 0
        chromaticLeftWidth?.constant = 0
        chromaticRightWidth?.constant = 0
    }

    // MARK: - Constants

    private var clearColors: [CGColor] {
        [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
    }
}
